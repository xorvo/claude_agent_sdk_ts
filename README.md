# ClaudeAgent

An Elixir wrapper around the official TypeScript Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`).

This library provides a native Elixir interface for interacting with Claude, with support for streaming responses and working directory configuration.

## Features

- **Native Elixir API** - Idiomatic Elixir functions and patterns
- **AWS Bedrock Support** - Automatic credential detection from `~/.aws` config
- **Streaming** - Both callback-based and Elixir Stream-based streaming
- **Working Directory** - Configure `cwd` for file operations
- **Permission Modes** - Control tool permissions (bypass, accept edits, etc.)
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
    {:claude_agent_sdk_ts, "~> 0.1.0"}
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
config :claude_agent,
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

### Permission Modes

- `:default` - Ask for permission before using tools (interactive)
- `:accept_edits` - Automatically accept file edits
- `:bypass_permissions` - Skip all permission prompts (default)
- `:plan` - Planning mode, no tool execution
- `:dont_ask` - Don't ask for permissions, deny if not pre-approved

## Quick Start

### Simple Chat

```elixir
# Basic usage
{:ok, response} = ClaudeAgent.chat("What is the capital of France?")
IO.puts(response)

# With options
{:ok, response} = ClaudeAgent.chat("Explain quantum computing",
  model: "claude-sonnet-4-20250514",
  max_turns: 5
)

# Bang version that raises on error
response = ClaudeAgent.chat!("Hello!")
```

### Streaming Responses

#### Callback-based streaming

```elixir
ClaudeAgent.stream("Count to 5", [max_turns: 1], fn
  %{type: :chunk, content: text} -> IO.write(text)
  %{type: :end} -> IO.puts("\n---Done---")
  _ -> :ok
end)
```

#### Elixir Stream-based streaming

```elixir
ClaudeAgent.stream!("Tell me a story")
|> Stream.each(&IO.write/1)
|> Stream.run()
```

### Working Directory

Set the working directory for file operations:

```elixir
# Create files in a specific directory
{:ok, response} = ClaudeAgent.chat(
  "Create a file called hello.txt with 'Hello World!'",
  cwd: "/path/to/directory",
  max_turns: 3
)
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Elixir Application                    │
├─────────────────────────────────────────────────────────┤
│  ClaudeAgent                                             │
│  - chat/2, stream/3, stream!/2                          │
├─────────────────────────────────────────────────────────┤
│  ClaudeAgent.PortBridge (GenServer)                      │
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
