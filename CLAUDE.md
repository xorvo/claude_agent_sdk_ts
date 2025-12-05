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

## Development Workflow

### 1. Check GitHub Issues First

Before starting work, check for open issues:
```bash
gh api repos/xorvo/claude_agent_sdk_ts/issues --jq '.[] | "\(.number): \(.title)"'
```

For issue details and comments:
```bash
gh api repos/xorvo/claude_agent_sdk_ts/issues/NUMBER
gh api repos/xorvo/claude_agent_sdk_ts/issues/NUMBER/comments
```

### 2. Making Code Changes

When adding new features or fixing bugs:

1. **Update the relevant module** - Add/modify code in `lib/claude_agent_sdk_ts/`
2. **Update module documentation** - Add `@moduledoc` and `@doc` with examples:
   ```elixir
   @doc """
   Description of the function.

   ## Options

     * `:option_name` - Description of option

   ## Examples

       {:ok, result} = MyModule.function("arg", option: value)
   """
   ```
3. **Update `Config` module** if adding new options - includes type specs, defaults, and `to_bridge_opts/1`
4. **Update `bridge.js`** if the option needs to pass through to the TypeScript SDK

### 3. Running Tests

Always run tests after changes:
```bash
mix test
```

### 4. Updating Documentation

For every user-facing change, update these files:

#### README.md
- Add new options to the "Available Options" table
- Add new sections with code examples for new features
- Keep examples practical and copy-pasteable

#### CHANGELOG.md
- Add entries under `## [Unreleased]` during development
- Use format: `- **Feature name** - Brief description`
- Include sub-bullets for implementation details
- Reference GitHub issues: `([#4](https://github.com/xorvo/claude_agent_sdk_ts/issues/4))`

#### Config module (`lib/claude_agent_sdk_ts/config.ex`)
- Update `@moduledoc` with new options documentation
- Add examples in the moduledoc

### 5. Releasing a New Version

When ready to release:

1. **Update version in `mix.exs`**:
   ```elixir
   @version "X.Y.Z"
   ```

2. **Update CHANGELOG.md** - Change `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`

3. **Publish to Hex** (done by maintainer):
   ```bash
   mix hex.publish
   ```

4. **Commit and tag**:
   ```bash
   git add -A
   git commit -m "release vX.Y.Z: Summary of changes"
   git tag vX.Y.Z
   git push origin main
   git push origin vX.Y.Z
   ```

### 6. Code Style Guidelines

- **Elixir conventions** - Follow standard Elixir formatting (`mix format`)
- **Option naming** - Use `snake_case` in Elixir, convert to `camelCase` for JS bridge
- **Error handling** - Return `{:ok, result}` or `{:error, reason}` tuples
- **Documentation** - Every public function should have `@doc` with examples

### Common Development Tasks

#### Adding a New Option

1. Add to `Config` struct, type, and defaults
2. Add conversion in `to_bridge_opts/1` if needed
3. Add to `buildOptions()` in `bridge.js`
4. Update README options table
5. Add example in README
6. Update CHANGELOG

#### Fixing a Bug from GitHub Issue

1. Read the issue and comments: `gh api repos/xorvo/claude_agent_sdk_ts/issues/N/comments`
2. Reproduce and understand root cause
3. Implement fix
4. Run tests
5. Update CHANGELOG with issue reference

### File Locations

| Purpose | File |
|---------|------|
| Main API | `lib/claude_agent_sdk_ts.ex` |
| Configuration | `lib/claude_agent_sdk_ts/config.ex` |
| Port communication | `lib/claude_agent_sdk_ts/port_bridge.ex` |
| Sessions | `lib/claude_agent_sdk_ts/session.ex` |
| Node.js bridge | `priv/node_bridge/dist/bridge.js` |
| Tests | `test/` |

### Node.js Bridge

The bridge is pre-compiled JavaScript in `priv/node_bridge/dist/bridge.js`. Edit the JS file directly when needed (no TypeScript source is maintained).
