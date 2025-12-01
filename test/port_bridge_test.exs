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
end
