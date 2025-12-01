# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
