# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2025-12-05

### Added

- **MCP (Model Context Protocol) server support** - Connect external tool servers to Claude
  - New `:mcp_servers` option for `chat/2`, `stream/3`, `Session.chat/3`, and `Session.stream/4`
  - Supports stdio, SSE, and HTTP server types
  - Pass custom tool servers that Claude can use during conversations

## [1.3.0] - 2025-12-05

### Added

- **Abort/interrupt support for running sessions** - Cancel in-flight requests at any time
  - New `Session.abort/1` function to abort the current chat or stream request
  - Leverages TypeScript SDK's `AbortController` to properly cancel HTTP requests
  - Aborted requests return `{:error, :aborted}`
  - New `PortBridge.abort/1` for low-level abort control
  - New `PortBridge.chat_async/2` and `PortBridge.stream_async/3` for async operations with abort support
  - Node.js bridge updated to track and abort requests via `AbortController`

### Changed

- `Session.chat/3` and `Session.stream/4` now use async operations internally to support abort
- Session state now tracks `current_request_ref` for abort functionality

### Fixed

- **Session GenServer crash on PortBridge messages** ([#4](https://github.com/xorvo/claude_agent_sdk_ts/issues/4))
  - Root cause: `chat_async/2` and `stream_async/3` captured the calling process (`self()`) as the
    message recipient, but Session called these from the GenServer and spawned separate Tasks to
    wait for results. PortBridge sent messages to Session, which had no handlers for them.
  - Fix: Added `:caller` option to `chat_async/2` and `stream_async/3` to specify which process
    should receive messages. Session now spawns the Task first and passes its PID as the caller.
  - `Session.stream/4` and `Session.chat/3` no longer crash during async operations

## [1.2.0] - 2025-12-02

### Added

- **Interactive permission handling (`can_use_tool`)** - Full control over tool permissions
  - New `:can_use_tool` option for `chat/2`, `stream/3`, `Session.chat/3`, and `Session.stream/4`
  - Mirrors TypeScript SDK's `canUseTool` callback for compatibility
  - Handler receives `(tool_name, tool_input, opts)` with rich context including `request_id`
  - Supports multiple return values:
    - `:allow` / `{:allow, updated_input}` - Approve tool calls
    - `:deny` / `{:deny, message}` - Deny with optional message
    - `{:deny, message, interrupt: true}` - Deny and stop conversation
    - `:pending` - Defer decision for async/interactive UIs
  - New `respond_to_permission/2` function for async permission handling
  - Perfect for Phoenix LiveView: return `:pending`, show modal, respond when user decides
  - Bidirectional JSON messaging between Elixir and Node.js bridge
  - Permission requests are processed asynchronously to prevent GenServer blocking
  - Session module properly passes permission handler while maintaining conversation context

## [1.1.0] - 2025-12-01

### Added

- **Multimodal support (images)** - Claude can now analyze images along with text
  - New `ClaudeAgentSdkTs.Content` module with helper functions:
    - `Content.text/1` - Create text content blocks
    - `Content.image_base64/2` - Create image blocks from base64 data
    - `Content.image_url/1` - Create image blocks from URLs
    - `Content.image_file/1` - Create image blocks from local files (auto-detects media type)
    - `Content.build/1` - Convenience function to mix strings and content blocks
  - `chat/2`, `stream/3`, and `stream!/2` now accept `%{content: [...]}` for multimodal inputs
  - Supported image formats: JPEG, PNG, GIF, WebP
  - Note: PDFs are not directly supported; convert to images first

### Fixed

- **Session module crash with multimodal content** ([#2](https://github.com/xorvo/claude_agent_sdk_ts/issues/2))
  - `Session.chat/3` and `Session.stream/4` now properly handle multimodal content
  - `build_prompt_with_history/2` extracts text from multimodal content blocks for history context
  - Follow-up messages after multimodal content no longer crash with `Protocol.UndefinedError`

## [1.0.3] - 2025-12-01

### Changed

- **Activity-based timeout for streaming operations** ([#1](https://github.com/xorvo/claude_agent_sdk_ts/issues/1))
  - `PortBridge.stream/3` now uses an activity-based timeout instead of a wall-clock timeout
  - The timeout resets whenever data (chunks, tool_use, etc.) is received from the Claude API
  - This prevents false-positive timeouts during long-running but actively streaming sessions
  - An agent can now run for hours as long as it's actively producing output
  - The timeout only triggers if there's no activity for the specified duration (default: 5 minutes)

### Fixed

- **Auto-recreate node_modules symlink after clean rebuild**
  - The `install/0` function now checks if the symlink in `priv_path` exists
  - If `node_modules` was installed but the symlink is missing (e.g., after `mix clean`), it recreates the symlink
  - This fixes "Cannot find package '@anthropic-ai/claude-agent-sdk'" errors after rebuilding the consumer app

## [1.0.2] - 2025-11-30

### Fixed

- Restored node_bridge files required for Hex package

## [1.0.1] - 2025-11-30

### Changed

- Updated README version from 0.1.0 to 1.0

## [1.0.0] - 2025-11-30

### Added

- Initial release
- Elixir wrapper for Claude Agent SDK (TypeScript)
- `PortBridge` for communication with Node.js bridge process
- `Session` module for managing agent sessions
- `Config`, `Tool`, and `Response` modules
- Streaming support with callbacks
- Custom tool definitions and execution
