# ClaudeAgentSdkTs

An Elixir wrapper around the official [TypeScript Claude Agent SDK](https://platform.claude.com/docs/en/agent-sdk/typescript) (`@anthropic-ai/claude-agent-sdk`).

This library provides a native Elixir interface for interacting with Claude, with support for streaming responses and working directory configuration.

## Features

- **Native Elixir API** - Idiomatic Elixir functions and patterns
- **AWS Bedrock Support** - Automatic credential detection from `~/.aws` config
- **Streaming** - Both callback-based and Elixir Stream-based streaming
- **Working Directory** - Configure `cwd` for file operations
- **Permission Modes** - Control tool permissions (bypass, accept edits, etc.)
- **Abort Support** - Cancel in-flight requests at any time
- **Supervised** - OTP-compliant with supervision trees

## Requirements

- Elixir ~> 1.15
- Node.js >= 18.0.0
- AWS credentials configured (for Bedrock) or Anthropic API key

## Installation

Add `claude_agent_sdk_ts` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:claude_agent_sdk_ts, "~> 1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

This will automatically install the Node.js dependencies and build the TypeScript bridge.

## Configuration

Configure in your `config/config.exs`:

```elixir
config :claude_agent_sdk_ts,
  model: "claude-sonnet-4-20250514",
  max_turns: 10,
  timeout: 300_000,
  permission_mode: :bypass_permissions
```

Or pass options directly to function calls.

### Available Options

| Option | Type | Description |
|--------|------|-------------|
| `model` | string | Claude model to use |
| `max_turns` | integer | Maximum conversation turns |
| `max_budget_usd` | float | Maximum budget in USD |
| `timeout` | integer | Request timeout in milliseconds |
| `system_prompt` | string | Custom system prompt |
| `cwd` | string | Working directory for file operations |
| `allowed_tools` | list | List of allowed tool names |
| `disallowed_tools` | list | List of disallowed tool names |
| `permission_mode` | atom | Permission mode (see below) |
| `can_use_tool` | function | Interactive permission handler (see below) |

### Permission Modes

- `:default` - Ask for permission before using tools (interactive)
- `:accept_edits` - Automatically accept file edits
- `:bypass_permissions` - Skip all permission prompts (default)
- `:plan` - Planning mode, no tool execution
- `:dont_ask` - Don't ask for permissions, deny if not pre-approved

### Interactive Permission Handling (can_use_tool)

For full control over tool permissions, you can provide a `can_use_tool` callback function.
This mirrors the TypeScript SDK's `canUseTool` callback and is called whenever Claude wants
to use a tool.

```elixir
# Define a permission handler
handler = fn tool_name, tool_input, opts ->
  IO.puts("Claude wants to use: #{tool_name}")
  IO.inspect(tool_input, label: "Input")

  # opts contains additional context:
  # - :tool_use_id - unique identifier for this invocation
  # - :agent_id - agent identifier (for sub-agents)
  # - :blocked_path - path that would be affected (for file ops)
  # - :suggestions - suggested actions
  # - :decision_reason - why this check is happening

  case IO.gets("Allow? (y/n): ") |> String.trim() do
    "y" -> :allow
    _ -> {:deny, "User declined"}
  end
end

# Use with chat
{:ok, response} = ClaudeAgentSdkTs.chat(
  "Create a file called test.txt",
  can_use_tool: handler
)

# Or with streaming
ClaudeAgentSdkTs.stream("List files in current directory", [can_use_tool: handler], fn msg ->
  IO.inspect(msg)
end)
```

#### Handler Return Values

| Return | Effect |
|--------|--------|
| `:allow` | Approve the tool call |
| `{:allow, updated_input}` | Approve with modified input |
| `{:allow, updated_input, updated_permissions}` | Approve with modified input and permissions |
| `:deny` | Deny the tool call |
| `{:deny, message}` | Deny with a message (Claude sees the reason) |
| `{:deny, message, interrupt: true}` | Deny and stop the conversation |
| `:pending` | Defer the decision; respond later via `respond_to_permission/2` |

#### Async Permission Handling (Phoenix LiveView)

For interactive UIs like Phoenix LiveView, you can return `:pending` from your handler
and respond later when the user makes a decision:

```elixir
defmodule MyAppWeb.ChatLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    # Create a handler that defers decisions to the UI
    handler = fn tool_name, tool_input, opts ->
      # Send permission request to this LiveView process
      send(self(), {:permission_request, opts.request_id, tool_name, tool_input})
      :pending  # Tell SDK we'll respond later
    end

    {:ok, assign(socket, handler: handler, pending_permission: nil)}
  end

  # Handle incoming permission requests - show a modal
  def handle_info({:permission_request, request_id, tool_name, tool_input}, socket) do
    {:noreply, assign(socket,
      pending_permission: %{
        request_id: request_id,
        tool_name: tool_name,
        tool_input: tool_input
      }
    )}
  end

  # User clicked "Allow"
  def handle_event("allow_tool", _params, socket) do
    ClaudeAgentSdkTs.respond_to_permission(
      socket.assigns.pending_permission.request_id,
      :allow
    )
    {:noreply, assign(socket, pending_permission: nil)}
  end

  # User clicked "Deny"
  def handle_event("deny_tool", _params, socket) do
    ClaudeAgentSdkTs.respond_to_permission(
      socket.assigns.pending_permission.request_id,
      {:deny, "User declined"}
    )
    {:noreply, assign(socket, pending_permission: nil)}
  end
end
```

The `opts.request_id` is a unique identifier for each permission request. Store it
and pass it to `respond_to_permission/2` when the user makes their decision.

#### Example: Auto-approve Read, Confirm Write

```elixir
handler = fn tool_name, tool_input, _opts ->
  case tool_name do
    "Read" ->
      # Always allow reading files
      :allow

    "Write" ->
      path = tool_input["file_path"]
      IO.puts("Claude wants to write to: #{path}")

      if String.starts_with?(path, "/tmp/") do
        :allow
      else
        {:deny, "Only /tmp/ writes allowed"}
      end

    "Bash" ->
      # Inspect bash commands before allowing
      command = tool_input["command"]
      IO.puts("Bash command: #{command}")

      if String.contains?(command, "rm -rf") do
        {:deny, "Dangerous command blocked", interrupt: true}
      else
        :allow
      end

    _ ->
      # Default: deny unknown tools
      {:deny, "Unknown tool: #{tool_name}"}
  end
end
```

## Quick Start

### Simple Chat

```elixir
# Basic usage
{:ok, response} = ClaudeAgentSdkTs.chat("What is the capital of France?")
IO.puts(response)

# With options
{:ok, response} = ClaudeAgentSdkTs.chat("Explain quantum computing",
  model: "claude-sonnet-4-20250514",
  max_turns: 5
)

# Bang version that raises on error
response = ClaudeAgentSdkTs.chat!("Hello!")
```

### Streaming Responses

#### Callback-based streaming

```elixir
ClaudeAgentSdkTs.stream("Count to 5", [max_turns: 1], fn
  %{type: :chunk, content: text} -> IO.write(text)
  %{type: :end} -> IO.puts("\n---Done---")
  _ -> :ok
end)
```

#### Elixir Stream-based streaming

```elixir
ClaudeAgentSdkTs.stream!("Tell me a story")
|> Stream.each(&IO.write/1)
|> Stream.run()
```

### Working Directory

Set the working directory for file operations:

```elixir
# Create files in a specific directory
{:ok, response} = ClaudeAgentSdkTs.chat(
  "Create a file called hello.txt with 'Hello World!'",
  cwd: "/path/to/directory",
  max_turns: 3
)
```

### Sessions with Abort Support

Use `Session` for multi-turn conversations with the ability to abort in-flight requests:

```elixir
alias ClaudeAgentSdkTs.Session

# Start a session
{:ok, session} = Session.start_link()

# Start a long-running task in another process
task = Task.async(fn ->
  Session.chat(session, "Write a very detailed essay about climate change")
end)

# Abort after a few seconds if needed
Process.sleep(2000)
Session.abort(session)

# The task will return {:error, :aborted}
case Task.await(task) do
  {:ok, response} -> IO.puts(response)
  {:error, :aborted} -> IO.puts("Request was aborted")
end

# Sessions maintain conversation history
{:ok, _} = Session.chat(session, "My name is Alice")
{:ok, response} = Session.chat(session, "What's my name?")
# Claude will remember: "Your name is Alice"

# Clean up
Session.stop(session)
```

The `abort/1` function leverages the TypeScript SDK's `AbortController` to properly cancel the underlying HTTP request to the Claude API.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Elixir Application                    │
├─────────────────────────────────────────────────────────┤
│  ClaudeAgentSdkTs                                        │
│  - chat/2, stream/3, stream!/2                          │
├─────────────────────────────────────────────────────────┤
│  ClaudeAgentSdkTs.PortBridge (GenServer)                 │
│  - Erlang Port to Node.js                                │
│  - JSON message passing via stdin/stdout                 │
│  - TypeScript logs piped through Elixir Logger           │
├─────────────────────────────────────────────────────────┤
│  Node.js Bridge (priv/node_bridge)                       │
│  - Wraps @anthropic-ai/claude-agent-sdk                  │
│  - Handles streaming and tool calls                      │
└─────────────────────────────────────────────────────────┘
```

## AWS Credentials

The library automatically detects AWS credentials from standard locations:

1. **AWS config files** (`~/.aws/credentials` and `~/.aws/config`) - recommended
2. **Environment variables**:
   ```bash
   export AWS_ACCESS_KEY_ID=your_key
   export AWS_SECRET_ACCESS_KEY=your_secret
   export AWS_REGION=us-east-1
   ```
3. **IAM roles** (EC2, ECS, Lambda)

No additional configuration is needed if your AWS CLI is already configured.

## Development

### Running Tests

```bash
mix test
```

### Manual Node.js Setup

If you need to manually install Node.js dependencies:

```bash
mix node.install
```

### Building TypeScript

The TypeScript bridge is automatically rebuilt when source files change. To manually rebuild:

```bash
cd priv/node_bridge
npm run build
```

### Debug Logging

Enable debug logging to see communication between Elixir and Node.js:

```elixir
Logger.configure(level: :debug)
```

This will show:
- `[PortBridge]` - Elixir side logging
- `[Node]` - TypeScript bridge logging (piped through Elixir Logger)

## License

MIT License - see LICENSE file for details.
