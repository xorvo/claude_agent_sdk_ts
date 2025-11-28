defmodule ClaudeAgentSdkTsTest do
  use ExUnit.Case
  doctest ClaudeAgentSdkTs

  alias ClaudeAgentSdkTs.{Config, Tool, Response}

  describe "Config" do
    test "new/0 creates config with defaults" do
      config = Config.new()

      assert config.permission_mode == :bypass_permissions
      assert config.timeout == 300_000
    end

    test "new/1 merges options with defaults" do
      config = Config.new(model: "custom-model", max_turns: 5)

      assert config.model == "custom-model"
      assert config.max_turns == 5
      assert config.permission_mode == :bypass_permissions
    end

    test "to_bridge_opts/1 converts to camelCase map" do
      config = Config.new(max_turns: 5, system_prompt: "Hello")
      opts = Config.to_bridge_opts(config)

      assert opts["maxTurns"] == 5
      assert opts["systemPrompt"] == "Hello"
      refute Map.has_key?(opts, "max_turns")
    end

    test "to_bridge_opts/1 excludes nil values" do
      config = Config.new()
      opts = Config.to_bridge_opts(config)

      refute Map.has_key?(opts, "model")
      assert Map.has_key?(opts, "permissionMode")
    end

    test "to_bridge_opts/1 converts permission_mode atom to SDK format" do
      config = Config.new(permission_mode: :accept_edits)
      opts = Config.to_bridge_opts(config)

      assert opts["permissionMode"] == "acceptEdits"
    end
  end

  describe "Tool" do
    test "new/1 creates a tool struct" do
      tool =
        Tool.new(
          name: "test_tool",
          description: "A test tool",
          handler: fn _params -> {:ok, "result"} end
        )

      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert is_function(tool.handler, 1)
    end

    test "to_definition/1 converts tool for JSON" do
      tool =
        Tool.new(
          name: "calculator",
          description: "Does math",
          parameters: %{type: "object", properties: %{expr: %{type: "string"}}},
          handler: fn _ -> {:ok, 42} end
        )

      definition = Tool.to_definition(tool)

      assert definition.name == "calculator"
      assert definition.description == "Does math"
      assert definition.parameters.type == "object"
      refute Map.has_key?(definition, :handler)
    end

    test "execute/2 runs the handler" do
      tool =
        Tool.new(
          name: "adder",
          description: "Adds numbers",
          handler: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      assert Tool.execute(tool, %{"a" => 1, "b" => 2}) == {:ok, 3}
    end

    test "execute/2 handles errors gracefully" do
      tool =
        Tool.new(
          name: "crasher",
          description: "Crashes",
          handler: fn _ -> raise "boom" end
        )

      assert {:error, "boom"} = Tool.execute(tool, %{})
    end

    test "execute/2 wraps plain return values in :ok tuple" do
      tool =
        Tool.new(
          name: "plain",
          description: "Returns plain value",
          handler: fn _ -> "plain result" end
        )

      assert Tool.execute(tool, %{}) == {:ok, "plain result"}
    end
  end

  describe "Response" do
    test "parse/1 handles text responses" do
      response = Response.parse(%{"type" => "text", "content" => "Hello"})

      assert response.type == :text
      assert response.content == "Hello"
    end

    test "parse/1 handles tool_use responses" do
      response =
        Response.parse(%{
          "type" => "tool_use",
          "name" => "calculator",
          "input" => %{"expr" => "1+1"},
          "id" => "tool_123"
        })

      assert response.type == :tool_use
      assert response.tool_name == "calculator"
      assert response.tool_input == %{"expr" => "1+1"}
      assert response.tool_use_id == "tool_123"
    end

    test "parse/1 handles error responses" do
      response = Response.parse(%{"type" => "error", "message" => "Something went wrong"})

      assert response.type == :error
      assert response.error == "Something went wrong"
    end

    test "parse/1 handles end responses" do
      response = Response.parse(%{"type" => "end"})

      assert response.type == :end
    end

    test "final?/1 returns true for end and error types" do
      assert Response.final?(%Response{type: :end})
      assert Response.final?(%Response{type: :error})
      refute Response.final?(%Response{type: :text})
      refute Response.final?(%Response{type: :tool_use})
    end

    test "tool_use?/1 returns true only for tool_use type" do
      assert Response.tool_use?(%Response{type: :tool_use})
      refute Response.tool_use?(%Response{type: :text})
      refute Response.tool_use?(%Response{type: :end})
    end
  end
end
