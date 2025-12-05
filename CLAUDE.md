# Claude Code Project Context

This is an Elixir wrapper for the official Claude Agent SDK (TypeScript).

## Project Overview

This library provides an Elixir interface to the `@anthropic-ai/claude-agent-sdk` npm package via a Node.js bridge process communicating over stdin/stdout with JSON messages.

## Key Architecture

- **PortBridge** (`lib/claude_agent_sdk_ts/port_bridge.ex`) - GenServer managing the Node.js bridge process
- **Session** (`lib/claude_agent_sdk_ts/session.ex`) - Stateful conversation sessions with history
- **Node Bridge** (`priv/node_bridge/dist/bridge.js`) - JavaScript bridge wrapping the TypeScript SDK

## Reference Documentation

- **TypeScript SDK Documentation**: https://platform.claude.com/docs/en/agent-sdk/typescript
- **npm package**: `@anthropic-ai/claude-agent-sdk`

## Key SDK Features Wrapped

- `query()` - Main function for sending prompts to Claude
- `AbortController` support - For cancelling in-flight requests
- `canUseTool` callback - Interactive permission handling
- Streaming responses with `includePartialMessages`
- Multimodal inputs (images via base64 or URL)

## Development Notes

### Running Tests
```bash
mix test
```

### Compiling
```bash
mix compile
```

### Node.js Bridge
The bridge is pre-compiled JavaScript in `priv/node_bridge/dist/bridge.js`. If you need to modify it, edit the JS file directly (no TypeScript source is maintained in this repo).
