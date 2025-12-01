# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.3] - 2025-12-01

### Changed

- **Activity-based timeout for streaming operations** ([#1](https://github.com/xorvo/claude_agent_sdk_ts/issues/1))
  - `PortBridge.stream/3` now uses an activity-based timeout instead of a wall-clock timeout
  - The timeout resets whenever data (chunks, tool_use, etc.) is received from the Claude API
  - This prevents false-positive timeouts during long-running but actively streaming sessions
  - An agent can now run for hours as long as it's actively producing output
  - The timeout only triggers if there's no activity for the specified duration (default: 5 minutes)

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
