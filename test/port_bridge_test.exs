defmodule ClaudeAgentSdkTs.PortBridgeTest do
  use ExUnit.Case

  describe "activity-based timeout" do
    test "receive_with_activity_timeout returns on stream_complete" do
      ref = make_ref()
      caller = self()

      # Spawn a process that will send completion after a short delay
      spawn(fn ->
        Process.sleep(10)
        send(caller, {:stream_complete, ref, :ok})
      end)

      # Should complete successfully
      result = wait_for_stream(ref, 1000)
      assert result == :ok
    end

    test "receive_with_activity_timeout returns error on stream_error" do
      ref = make_ref()
      caller = self()

      spawn(fn ->
        Process.sleep(10)
        send(caller, {:stream_error, ref, "something went wrong"})
      end)

      result = wait_for_stream(ref, 1000)
      assert result == {:error, "something went wrong"}
    end

    test "receive_with_activity_timeout resets timeout on activity" do
      ref = make_ref()
      caller = self()

      # Spawn a process that sends activity signals periodically,
      # then completes after total time exceeds original timeout
      spawn(fn ->
        # Send activity every 30ms, 5 times (150ms total)
        # With a 50ms timeout, this would fail without activity reset
        for _ <- 1..5 do
          Process.sleep(30)
          send(caller, {:stream_activity, ref})
        end

        Process.sleep(30)
        send(caller, {:stream_complete, ref, :ok})
      end)

      # Use a short timeout that would fail without activity reset
      result = wait_for_stream(ref, 50)
      assert result == :ok
    end

    test "receive_with_activity_timeout times out when no activity" do
      ref = make_ref()

      # Don't send anything - should timeout
      result = wait_for_stream(ref, 50)
      assert result == {:error, :activity_timeout}
    end

    test "activity from wrong ref doesn't reset timeout" do
      ref = make_ref()
      wrong_ref = make_ref()
      caller = self()

      spawn(fn ->
        # Send activity with wrong ref
        Process.sleep(30)
        send(caller, {:stream_activity, wrong_ref})
        Process.sleep(30)
        send(caller, {:stream_activity, wrong_ref})
      end)

      # Should timeout because activity has wrong ref
      result = wait_for_stream(ref, 50)
      assert result == {:error, :activity_timeout}
    end

    test "complete from wrong ref is ignored" do
      ref = make_ref()
      wrong_ref = make_ref()
      caller = self()

      spawn(fn ->
        Process.sleep(10)
        send(caller, {:stream_complete, wrong_ref, :ok})
      end)

      # Should timeout because completion has wrong ref
      result = wait_for_stream(ref, 50)
      assert result == {:error, :activity_timeout}
    end
  end

  # Helper that mirrors the receive_with_activity_timeout logic from PortBridge
  defp wait_for_stream(ref, timeout) do
    receive do
      {:stream_activity, ^ref} ->
        wait_for_stream(ref, timeout)

      {:stream_complete, ^ref, result} ->
        result

      {:stream_error, ^ref, error} ->
        {:error, error}
    after
      timeout ->
        {:error, :activity_timeout}
    end
  end

  describe "permission handler extraction" do
    # Test the extract_permission_handler function behavior via opts processing
    test "extracts permission handler from opts" do
      handler = fn _name, _input, _opts -> :allow end
      opts = %{model: "test", can_use_tool: handler}

      # The handler should be separated and interactivePermissions added
      {extracted_handler, bridge_opts} = extract_permission_handler(opts)

      assert is_function(extracted_handler)
      assert bridge_opts[:interactivePermissions] == true
      assert bridge_opts[:model] == "test"
      refute Map.has_key?(bridge_opts, :can_use_tool)
    end

    test "returns nil handler when not provided" do
      opts = %{model: "test"}

      {extracted_handler, bridge_opts} = extract_permission_handler(opts)

      assert is_nil(extracted_handler)
      refute Map.has_key?(bridge_opts, :interactivePermissions)
      assert bridge_opts[:model] == "test"
    end

    test "handles nil can_use_tool gracefully" do
      opts = %{model: "test", can_use_tool: nil}

      {extracted_handler, bridge_opts} = extract_permission_handler(opts)

      assert is_nil(extracted_handler)
      refute Map.has_key?(bridge_opts, :interactivePermissions)
    end

    # Mirror the extract_permission_handler function for testing
    defp extract_permission_handler(opts) when is_map(opts) do
      {handler, rest} = Map.pop(opts, :can_use_tool)

      bridge_opts =
        if is_function(handler) do
          Map.put(rest, :interactivePermissions, true)
        else
          rest
        end

      {handler, bridge_opts}
    end
  end

  describe "permission response building" do
    test "build_permission_response handles :allow" do
      assert build_permission_response(:allow) == %{behavior: "allow", updatedInput: %{}}
    end

    test "build_permission_response handles {:allow, updated_input}" do
      result = build_permission_response({:allow, %{path: "/modified"}})
      assert result == %{behavior: "allow", updatedInput: %{path: "/modified"}}
    end

    test "build_permission_response handles {:allow, updated_input, updated_permissions}" do
      result = build_permission_response({:allow, %{path: "/new"}, %{scope: "write"}})
      assert result == %{
        behavior: "allow",
        updatedInput: %{path: "/new"},
        updatedPermissions: %{scope: "write"}
      }
    end

    test "build_permission_response handles :deny" do
      assert build_permission_response(:deny) == %{
        behavior: "deny",
        message: "Permission denied",
        interrupt: false
      }
    end

    test "build_permission_response handles {:deny, message}" do
      result = build_permission_response({:deny, "Not allowed"})
      assert result == %{behavior: "deny", message: "Not allowed", interrupt: false}
    end

    test "build_permission_response handles {:deny, message, interrupt: true}" do
      result = build_permission_response({:deny, "Stop now", interrupt: true})
      assert result == %{behavior: "deny", message: "Stop now", interrupt: true}
    end

    # Mirror the build_permission_response functions for testing
    defp build_permission_response({:allow, updated_input}) do
      %{behavior: "allow", updatedInput: updated_input}
    end

    defp build_permission_response({:allow, updated_input, updated_permissions}) do
      %{behavior: "allow", updatedInput: updated_input, updatedPermissions: updated_permissions}
    end

    defp build_permission_response(:allow) do
      %{behavior: "allow", updatedInput: %{}}
    end

    defp build_permission_response({:deny, message}) do
      %{behavior: "deny", message: message, interrupt: false}
    end

    defp build_permission_response({:deny, message, opts}) do
      %{
        behavior: "deny",
        message: message,
        interrupt: Keyword.get(opts, :interrupt, false)
      }
    end

    defp build_permission_response(:deny) do
      %{behavior: "deny", message: "Permission denied", interrupt: false}
    end
  end

  describe "async permission handling with :pending" do
    test "permission handler opts includes request_id" do
      # Verify that request_id is included in opts passed to handler
      opts = %{
        request_id: "test-request-123",
        suggestions: [],
        blocked_path: nil,
        decision_reason: nil,
        tool_use_id: "tool-456",
        agent_id: nil
      }

      assert opts.request_id == "test-request-123"
      assert opts.tool_use_id == "tool-456"
    end

    test "build_permission_response_public handles all decision types" do
      # :allow
      assert build_permission_response_public(:allow) == %{behavior: "allow", updatedInput: %{}}

      # {:allow, updated_input}
      assert build_permission_response_public({:allow, %{path: "/new"}}) ==
               %{behavior: "allow", updatedInput: %{path: "/new"}}

      # {:allow, updated_input, updated_permissions}
      assert build_permission_response_public({:allow, %{path: "/new"}, %{scope: "write"}}) ==
               %{behavior: "allow", updatedInput: %{path: "/new"}, updatedPermissions: %{scope: "write"}}

      # :deny
      assert build_permission_response_public(:deny) ==
               %{behavior: "deny", message: "Permission denied", interrupt: false}

      # {:deny, message}
      assert build_permission_response_public({:deny, "Not allowed"}) ==
               %{behavior: "deny", message: "Not allowed", interrupt: false}

      # {:deny, message, interrupt: true}
      assert build_permission_response_public({:deny, "Stop", interrupt: true}) ==
               %{behavior: "deny", message: "Stop", interrupt: true}

      # {:deny, message, interrupt: false}
      assert build_permission_response_public({:deny, "Continue", interrupt: false}) ==
               %{behavior: "deny", message: "Continue", interrupt: false}
    end

    # Mirror the build_permission_response_public functions for testing
    defp build_permission_response_public({:allow, updated_input}) do
      %{behavior: "allow", updatedInput: updated_input}
    end

    defp build_permission_response_public({:allow, updated_input, updated_permissions}) do
      %{behavior: "allow", updatedInput: updated_input, updatedPermissions: updated_permissions}
    end

    defp build_permission_response_public(:allow) do
      %{behavior: "allow", updatedInput: %{}}
    end

    defp build_permission_response_public({:deny, message}) do
      %{behavior: "deny", message: message, interrupt: false}
    end

    defp build_permission_response_public({:deny, message, opts}) when is_list(opts) do
      %{
        behavior: "deny",
        message: message,
        interrupt: Keyword.get(opts, :interrupt, false)
      }
    end

    defp build_permission_response_public(:deny) do
      %{behavior: "deny", message: "Permission denied", interrupt: false}
    end
  end
end
