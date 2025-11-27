defmodule ClaudeAgent.Config do
  @moduledoc """
  Configuration management for ClaudeAgent.

  Configuration can be set in your config.exs:

      config :claude_agent,
        model: "claude-sonnet-4-20250514",
        max_turns: 10,
        max_budget_usd: 1.0,
        timeout: 300_000,
        permission_mode: :bypass_permissions

  Or passed as options to individual function calls, which override the global config.

  ## Options

    * `:model` - The Claude model to use (e.g., "claude-sonnet-4-20250514")
    * `:max_turns` - Maximum number of conversation turns
    * `:max_budget_usd` - Maximum budget in USD for the request
    * `:timeout` - Request timeout in milliseconds (default: 300_000)
    * `:system_prompt` - Custom system prompt
    * `:allowed_tools` - List of tool names Claude is allowed to use
    * `:disallowed_tools` - List of tool names Claude is not allowed to use
    * `:permission_mode` - How Claude handles tool permissions (see below)
    * `:cwd` - Working directory for file operations

  ## Permission Modes

  The `:permission_mode` option controls how Claude handles tool permissions:

    * `:default` - Ask for permission before using tools (interactive)
    * `:accept_edits` - Automatically accept file edits
    * `:bypass_permissions` - Skip all permission prompts (default for SDK usage)
    * `:plan` - Planning mode, no tool execution
    * `:dont_ask` - Don't ask for permissions, deny if not pre-approved

  """

  @type permission_mode :: :default | :accept_edits | :bypass_permissions | :plan | :dont_ask

  @type t :: %__MODULE__{
          model: String.t() | nil,
          max_turns: pos_integer() | nil,
          max_budget_usd: float() | nil,
          timeout: pos_integer(),
          system_prompt: String.t() | nil,
          allowed_tools: list(String.t()) | nil,
          disallowed_tools: list(String.t()) | nil,
          permission_mode: permission_mode() | nil,
          cwd: String.t() | nil
        }

  defstruct [
    :model,
    :max_turns,
    :max_budget_usd,
    :timeout,
    :system_prompt,
    :allowed_tools,
    :disallowed_tools,
    :permission_mode,
    :cwd
  ]

  @defaults %{
    model: nil,
    max_turns: nil,
    max_budget_usd: nil,
    timeout: 300_000,
    system_prompt: nil,
    allowed_tools: nil,
    disallowed_tools: nil,
    permission_mode: :bypass_permissions,
    cwd: nil
  }

  @doc """
  Creates a new Config struct from the given options, merged with application config and defaults.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    app_config = Application.get_all_env(:claude_agent)

    merged =
      @defaults
      |> Map.merge(Map.new(app_config))
      |> Map.merge(Map.new(opts))

    struct(__MODULE__, merged)
  end

  @doc """
  Converts the config to a map suitable for JSON encoding and sending to the Node bridge.
  """
  @spec to_bridge_opts(t()) :: map()
  def to_bridge_opts(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {to_camel_case(k), convert_value(k, v)} end)
    |> Map.new()
  end

  # Convert permission_mode atom to SDK format
  defp convert_value(:permission_mode, :default), do: "default"
  defp convert_value(:permission_mode, :accept_edits), do: "acceptEdits"
  defp convert_value(:permission_mode, :bypass_permissions), do: "bypassPermissions"
  defp convert_value(:permission_mode, :plan), do: "plan"
  defp convert_value(:permission_mode, :dont_ask), do: "dontAsk"
  defp convert_value(_key, value), do: value

  defp to_camel_case(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [first | rest] ->
        first <> Enum.map_join(rest, "", &String.capitalize/1)
    end
  end
end
