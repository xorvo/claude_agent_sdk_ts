# ClaudeAgentSdkTs

An Elixir wrapper around the official [TypeScript Claude Agent SDK](https://platform.claude.com/docs/en/agent-sdk/typescript) (`@anthropic-ai/claude-agent-sdk`).

This library provides a native Elixir interface for interacting with Claude, with support for streaming responses and working directory configuration.

## Features

- **Native Elixir API** - Idiomatic Elixir functions and patterns
- **AWS Bedrock Support** - Automatic credential detection from `~/.aws` config
- **Streaming** - Both callback-based and Elixir Stream-based streaming
- **Session Management** - Resume, continue, or fork conversations via SDK session IDs
- **Slash Commands** - Query available slash commands from the SDK
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
| `mcp_servers` | map | MCP servers configuration (see below) |
| `use_bedrock` | boolean | Use AWS Bedrock for authentication |
| `aws_profile` | string | AWS profile name |
| `aws_region` | string | AWS region (e.g., "us-east-1") |
| `api_key` | string | Anthropic API key |
| `resume` | string | Session ID to resume a previous conversation |
| `continue` | boolean | Continue the last session in the CWD |
| `fork_session` | boolean | Fork from an existing session |
| `resume_session_at` | string | Resume at a specific point in the session |

### Permission Modes

- `:default` - Ask for permission before using tools (interactive)
- `:accept_edits` - Automatically accept file edits
- `:bypass_permissions` - Skip all permission prompts (default)
- `:plan` - Planning mode, no tool execution
- `:dont_ask` - Don't ask for permissions, deny if not pre-approved

### MCP Servers

Connect MCP (Model Context Protocol) servers to provide additional tools to Claude:

```elixir
# stdio server (runs a command)
{:ok, response} = ClaudeAgentSdkTs.chat(
  "Use the weather tool to check the forecast",
  mcp_servers: %{
    "weather" => %{
      type: "stdio",
      command: "python3",
      args: ["weather_server.py"]
    }
  }
)

# HTTP server
{:ok, response} = ClaudeAgentSdkTs.chat(
  "Query the database",
  mcp_servers: %{
    "db" => %{
      type: "http",
      url: "http://localhost:8080/mcp"
    }
  }
)

# Multiple servers
{:ok, response} = ClaudeAgentSdkTs.chat(
  "Check weather and query database",
  mcp_servers: %{
    "weather" => %{type: "stdio", command: "weather_server"},
    "db" => %{type: "http", url: "http://localhost:8080/mcp"}
  }
)
```

Supported server types:
- `"stdio"` - Server communicates via stdin/stdout (requires `command`, optionally `args`)
- `"sse"` - Server-Sent Events (requires `url`)
- `"http"` - HTTP transport (requires `url`)

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

### Slash Commands

Query available slash commands from the Claude Agent SDK:

```elixir
# Get all available commands
{:ok, commands} = ClaudeAgentSdkTs.supported_commands()

# Each command has name, description, and argument_hint
Enum.each(commands, fn cmd ->
  IO.puts("#{cmd.name} - #{cmd.description}")
end)

# Example output:
# /help - Get help with using Claude Code
# /model - Select AI model
# /clear - Clear conversation history
# ...

# Find a specific command
help_cmd = Enum.find(commands, & &1.name == "/help")

# Bang version that raises on error
commands = ClaudeAgentSdkTs.supported_commands!()
```

## Quick Start

### Simple Chat

```elixir
# Basic usage - returns {response, session_id}
{:ok, response, session_id} = ClaudeAgentSdkTs.chat("What is the capital of France?")
IO.puts(response)

# With options
{:ok, response, session_id} = ClaudeAgentSdkTs.chat("Explain quantum computing",
  model: "claude-sonnet-4-20250514",
  max_turns: 5
)

# Bang version returns {response, session_id}
{response, session_id} = ClaudeAgentSdkTs.chat!("Hello!")
```

### Session Resumption

The SDK now returns a `session_id` that you can use to resume conversations:

```elixir
# First chat returns a session_id
{:ok, response1, session_id} = ClaudeAgentSdkTs.chat("My name is Alice")
IO.puts("Session: #{session_id}")

# Resume that session later - Claude remembers the context!
{:ok, response2, _} = ClaudeAgentSdkTs.chat("What's my name?", resume: session_id)
# Claude will respond "Your name is Alice"

# Continue the last session in the current working directory
{:ok, response, _} = ClaudeAgentSdkTs.chat("Continue our conversation", continue: true)

# Fork a session to branch the conversation
{:ok, response, new_session_id} = ClaudeAgentSdkTs.chat(
  "Let's try a different approach",
  resume: session_id,
  fork_session: true
)
```

### Streaming Responses

#### Callback-based streaming

```elixir
# Stream returns {:ok, session_id} on completion
# Note: session_id is only available when the turn ends (in the :end callback or return value)
{:ok, session_id} = ClaudeAgentSdkTs.stream("Count to 5", [max_turns: 1], fn
  %{type: :chunk, content: text} -> IO.write(text)
  %{type: :end, session_id: sid} -> IO.puts("\n---Done (session: #{sid})---")
  _ -> :ok
end)

# session_id is also available from the return value
IO.puts("Can resume with: #{session_id}")
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

# Sessions use SDK session management for conversation context
{:ok, _} = Session.chat(session, "My name is Alice")
{:ok, response} = Session.chat(session, "What's my name?")
# Claude will remember: "Your name is Alice"

# Get the current session ID
session_id = Session.get_session_id(session)

# Reset to start a fresh conversation
Session.reset(session)

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

## Authentication

The SDK supports multiple authentication methods. You can configure authentication via **Elixir config** (recommended) or **environment variables**.

### Option 1: AWS Bedrock (Recommended)

Configure in your `config/config.exs`:

```elixir
config :claude_agent_sdk_ts,
  use_bedrock: true,
  aws_profile: "your-aws-profile",
  aws_region: "us-east-1"
```

Or via environment variables:

```bash
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_PROFILE=your-aws-profile
export AWS_REGION=us-east-1
```

AWS credentials are detected from standard locations:
1. **AWS config files** (`~/.aws/credentials` and `~/.aws/config`)
2. **Environment variables** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
3. **IAM roles** (EC2, ECS, Lambda)

### Option 2: API Key

Configure in your `config/config.exs`:

```elixir
config :claude_agent_sdk_ts,
  api_key: "sk-ant-..."
```

Or via environment variable:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

### Option 3: OAuth (Claude Code CLI)

Without Bedrock or API key config, the SDK uses OAuth tokens from Claude Code CLI.

1. Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
2. Authenticate: `claude /login`
3. Tokens are stored in `~/.claude/.credentials.json`

**Note:** OAuth tokens expire periodically. If you get a `401 authentication_error`, run `claude /login` to refresh.

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
