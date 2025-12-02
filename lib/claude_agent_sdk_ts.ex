defmodule ClaudeAgentSdkTs do
  @moduledoc """
  Elixir wrapper around the official TypeScript Claude Agent SDK.

  Provides a native Elixir interface for interacting with Claude via AWS Bedrock,
  with support for streaming responses, sessions, custom tools, and multimodal inputs.

  ## Quick Start

      # Simple chat
      {:ok, response} = ClaudeAgentSdkTs.chat("What is the capital of France?")

      # With options
      {:ok, response} = ClaudeAgentSdkTs.chat("Explain quantum computing",
        model: "claude-sonnet-4-20250514",
        max_tokens: 2000
      )

      # Streaming with callback
      ClaudeAgentSdkTs.stream("Write a haiku about Elixir", fn
        %{type: :chunk, content: text} -> IO.write(text)
        %{type: :end} -> IO.puts("\\n---Done---")
      end)

      # Streaming to an Elixir Stream
      ClaudeAgentSdkTs.stream!("Tell me a story")
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  ## Multimodal (Images)

  Claude supports vision - you can send images along with text:

      alias ClaudeAgentSdkTs.Content

      # Analyze an image file
      content = [
        Content.text("What's in this image?"),
        Content.image_file("screenshot.png")
      ]
      {:ok, response} = ClaudeAgentSdkTs.chat(%{content: content})

      # Image from URL
      content = [
        Content.text("Describe this photo:"),
        Content.image_url("https://example.com/photo.jpg")
      ]
      {:ok, response} = ClaudeAgentSdkTs.chat(%{content: content})

      # Compare multiple images
      content = Content.build([
        "Compare these two screenshots:",
        Content.image_file("before.png"),
        Content.image_file("after.png"),
        "What changed?"
      ])
      {:ok, response} = ClaudeAgentSdkTs.chat(%{content: content})

  ### Supported Image Formats

    - JPEG (`.jpg`, `.jpeg`)
    - PNG (`.png`)
    - GIF (`.gif`)
    - WebP (`.webp`)

  Note: PDFs are not directly supported. Convert PDF pages to images first.

  ## Configuration

  Configure in your `config.exs`:

      config :claude_agent_sdk_ts,
        model: "claude-sonnet-4-20250514",
        use_bedrock: true,
        aws_profile: "default",
        aws_region: "us-east-1",
        max_tokens: 4096,
        timeout: 300_000

  Or pass options directly to function calls.

  ## Tools

  Define custom tools that Claude can invoke:

      tool = %ClaudeAgentSdkTs.Tool{
        name: "calculate",
        description: "Perform a calculation",
        parameters: %{
          type: "object",
          properties: %{
            expression: %{type: "string", description: "Math expression"}
          },
          required: ["expression"]
        },
        handler: fn %{"expression" => expr} ->
          {result, _} = Code.eval_string(expr)
          {:ok, result}
        end
      }

      ClaudeAgentSdkTs.chat("What is 42 * 17?", tools: [tool])

  ## Node.js Dependencies

  This library requires Node.js >= 18.0.0 to be installed. On first use, it will
  automatically run `npm install` to fetch the Claude Agent SDK. You can also
  run `mix claude_agent_sdk_ts.install` to install dependencies manually.
  """

  require Logger
  alias ClaudeAgentSdkTs.{Config, PortBridge, Response, Tool}

  # Re-export Content module for convenience
  defdelegate text(text), to: ClaudeAgentSdkTs.Content
  defdelegate image_base64(data, media_type), to: ClaudeAgentSdkTs.Content
  defdelegate image_url(url), to: ClaudeAgentSdkTs.Content
  defdelegate image_file(path), to: ClaudeAgentSdkTs.Content
  defdelegate build_content(items), to: ClaudeAgentSdkTs.Content, as: :build

  @doc """
  Returns the path where node_modules are installed.

  This is in the `_build` directory, not in the dependency's priv folder,
  so it works correctly when used as a hex dependency.
  """
  @spec node_modules_path() :: String.t()
  def node_modules_path do
    if Code.ensure_loaded?(Mix.Project) do
      # Store in _build alongside other build artifacts
      Path.join(Path.dirname(Mix.Project.build_path()), "claude_agent_sdk_ts_deps")
    else
      # Fallback for runtime without Mix
      Path.expand("_build/claude_agent_sdk_ts_deps")
    end
  end

  @doc """
  Returns the path to the priv/node_bridge directory containing package.json and bridge.js.
  """
  @spec priv_path() :: String.t()
  def priv_path do
    :claude_agent_sdk_ts
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("node_bridge")
  end

  @doc """
  Checks if Node.js dependencies are installed.
  """
  @spec installed?() :: boolean()
  def installed? do
    # Check both the actual node_modules and the symlink in priv
    deps_modules = Path.join(node_modules_path(), "node_modules")
    priv_modules = Path.join(priv_path(), "node_modules")

    File.exists?(deps_modules) and File.exists?(priv_modules)
  end

  @doc """
  Installs Node.js dependencies if not already installed.

  This is called automatically when the application starts, but can also
  be called manually or via `mix claude_agent_sdk_ts.install`.
  """
  @spec install() :: :ok | {:error, String.t()}
  def install do
    deps_path = node_modules_path()
    node_modules = Path.join(deps_path, "node_modules")
    priv = priv_path()
    priv_node_modules = Path.join(priv, "node_modules")

    cond do
      not File.exists?(node_modules) ->
        # Need full install
        do_install(deps_path)

      not File.exists?(priv_node_modules) ->
        # node_modules installed but symlink missing (e.g., after clean rebuild)
        Logger.info("[ClaudeAgentSdkTs] Recreating node_modules symlink...")
        create_node_modules_symlink(priv, deps_path)
        :ok

      true ->
        # Everything is in place
        :ok
    end
  end

  @doc """
  Forces reinstallation of Node.js dependencies.
  """
  @spec install!(force: boolean()) :: :ok
  def install!(opts \\ []) do
    deps_path = node_modules_path()

    if Keyword.get(opts, :force, false) do
      File.rm_rf!(deps_path)
    end

    case do_install(deps_path) do
      :ok -> :ok
      {:error, msg} -> raise msg
    end
  end

  defp do_install(deps_path) do
    priv = priv_path()
    package_json = Path.join(priv, "package.json")

    unless File.exists?(package_json) do
      {:error, "package.json not found at #{package_json}"}
    else
      Logger.info("[ClaudeAgentSdkTs] Installing Node.js dependencies to #{deps_path}...")

      # Create the deps directory
      File.mkdir_p!(deps_path)

      # Copy package.json and package-lock.json to deps directory
      File.cp!(package_json, Path.join(deps_path, "package.json"))

      lock_file = Path.join(priv, "package-lock.json")
      if File.exists?(lock_file) do
        File.cp!(lock_file, Path.join(deps_path, "package-lock.json"))
      end

      # Run npm install in the deps directory
      case System.cmd("npm", ["install", "--production"], cd: deps_path, stderr_to_stdout: true) do
        {_, 0} ->
          Logger.info("[ClaudeAgentSdkTs] Node.js dependencies installed successfully")

          # Create symlink in priv directory so ES modules can find the packages
          # ES modules don't respect NODE_PATH, so we need node_modules in the import path
          create_node_modules_symlink(priv, deps_path)

          :ok

        {output, code} ->
          {:error, """
          Failed to install Node.js dependencies.

          npm install exited with code #{code}:
          #{output}

          Please ensure Node.js >= 18.0.0 is installed.
          """}
      end
    end
  end

  defp create_node_modules_symlink(priv_path, deps_path) do
    symlink_path = Path.join(priv_path, "node_modules")
    target_path = Path.join(deps_path, "node_modules")

    # Remove existing symlink or directory if present
    case File.read_link(symlink_path) do
      {:ok, _} -> File.rm!(symlink_path)
      {:error, :einval} -> File.rm_rf!(symlink_path)  # It's a regular file/dir
      {:error, :enoent} -> :ok  # Doesn't exist, that's fine
    end

    # Create symlink
    case File.ln_s(target_path, symlink_path) do
      :ok ->
        Logger.debug("[ClaudeAgentSdkTs] Created symlink: #{symlink_path} -> #{target_path}")

      {:error, reason} ->
        Logger.warning("[ClaudeAgentSdkTs] Failed to create symlink (#{reason}), copying instead")
        # Fallback: copy node_modules if symlink fails (e.g., on some Windows configs)
        File.cp_r!(target_path, symlink_path)
    end
  end

  @type permission_handler ::
          (tool_name :: String.t(), tool_input :: map(), opts :: map() ->
             :allow
             | {:allow, updated_input :: map()}
             | {:allow, updated_input :: map(), updated_permissions :: map()}
             | :deny
             | {:deny, message :: String.t()}
             | {:deny, message :: String.t(), [interrupt: boolean()]}
             | :pending)

  @type chat_opts :: [
          model: String.t(),
          max_tokens: pos_integer(),
          system_prompt: String.t(),
          timeout: pos_integer(),
          tools: [Tool.t()],
          cwd: String.t(),
          can_use_tool: permission_handler()
        ]

  @type stream_callback :: (Response.t() | map() -> any())

  @doc """
  Sends a chat message to Claude and waits for the complete response.

  ## Arguments

  The first argument can be either:
    - A string for simple text prompts
    - A map with `:content` key containing a list of content blocks for multimodal inputs

  ## Options

    * `:model` - The Claude model to use
    * `:max_tokens` - Maximum tokens in the response
    * `:system_prompt` - System prompt to set context
    * `:timeout` - Request timeout in milliseconds (default: 300_000)
    * `:tools` - List of `ClaudeAgentSdkTs.Tool` structs Claude can invoke
    * `:cwd` - Working directory for file operations
    * `:can_use_tool` - Permission handler function for interactive tool approval (see below)

  ## Interactive Permission Handling

  The `:can_use_tool` option enables interactive approval of tool usage. When provided,
  Claude will ask for permission before executing tools. This mirrors the TypeScript SDK's
  `canUseTool` callback.

  The handler receives `(tool_name, tool_input, opts)` and should return one of:

    * `:allow` - Approve the tool call
    * `{:allow, updated_input}` - Approve with modified input
    * `{:allow, updated_input, updated_permissions}` - Approve with modified input and permissions
    * `:deny` - Deny the tool call
    * `{:deny, message}` - Deny with a message (Claude sees the reason)
    * `{:deny, message, interrupt: true}` - Deny and stop the conversation
    * `:pending` - Defer the decision; respond later via `respond_to_permission/2`

  The `opts` map contains:
    * `:request_id` - Unique identifier for this permission request (use with `respond_to_permission/2`)
    * `:tool_use_id` - Unique identifier for this tool invocation
    * `:agent_id` - Agent identifier (if using sub-agents)
    * `:suggestions` - Suggested next actions
    * `:blocked_path` - Path that would be affected (for file operations)
    * `:decision_reason` - Why this permission check is happening

  ## Examples

      # Simple text
      {:ok, response} = ClaudeAgentSdkTs.chat("Hello!")
      {:ok, response} = ClaudeAgentSdkTs.chat("Explain OTP", model: "claude-sonnet-4-20250514")

      # Multimodal with image
      alias ClaudeAgentSdkTs.Content
      content = [
        Content.text("What's in this image?"),
        Content.image_file("photo.png")
      ]
      {:ok, response} = ClaudeAgentSdkTs.chat(%{content: content})

      # With interactive permission handling
      handler = fn tool_name, tool_input, _opts ->
        IO.puts("Claude wants to use: \#{tool_name}")
        IO.inspect(tool_input, label: "Input")

        case IO.gets("Allow? (y/n): ") |> String.trim() do
          "y" -> :allow
          _ -> {:deny, "User declined"}
        end
      end

      {:ok, response} = ClaudeAgentSdkTs.chat(
        "Create a file called test.txt with 'Hello World'",
        can_use_tool: handler
      )
  """
  @spec chat(String.t() | %{content: list()}, chat_opts()) :: {:ok, String.t()} | {:error, term()}
  def chat(prompt, opts \\ []) do
    config = Config.new(opts)
    bridge_opts = Config.to_bridge_opts(config)

    # Add tool definitions if provided
    bridge_opts =
      case Keyword.get(opts, :tools) do
        nil -> bridge_opts
        tools -> Map.put(bridge_opts, "tools", Enum.map(tools, &Tool.to_definition/1))
      end

    # Add permission handler if provided
    bridge_opts =
      case Keyword.get(opts, :can_use_tool) do
        nil -> bridge_opts
        handler when is_function(handler) -> Map.put(bridge_opts, :can_use_tool, handler)
      end

    PortBridge.chat(prompt, bridge_opts)
  end

  @doc """
  Same as `chat/2` but raises on error.
  """
  @spec chat!(String.t() | %{content: list()}, chat_opts()) :: String.t()
  def chat!(prompt, opts \\ []) do
    case chat(prompt, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "ClaudeAgentSdkTs.chat failed: #{inspect(reason)}"
    end
  end

  @doc """
  Sends a chat message to Claude and streams the response via a callback function.

  The first argument can be either:
    - A string for simple text prompts
    - A map with `:content` key containing a list of content blocks for multimodal inputs

  The callback receives maps with `:type` and `:content` keys:

    * `%{type: :chunk, content: "text"}` - A chunk of the response
    * `%{type: :tool_use, ...}` - Claude wants to use a tool
    * `%{type: :end}` - Stream has ended

  ## Options

  See `chat/2` for all available options including `:can_use_tool` for interactive
  permission handling.

  ## Examples

      # Text prompt
      ClaudeAgentSdkTs.stream("Write a poem", fn
        %{type: :chunk, content: text} -> IO.write(text)
        %{type: :end} -> IO.puts("")
        _ -> :ok
      end)

      # Multimodal
      alias ClaudeAgentSdkTs.Content
      content = [Content.text("Describe this"), Content.image_file("photo.png")]
      ClaudeAgentSdkTs.stream(%{content: content}, fn msg -> IO.inspect(msg) end)

      # With permission handling
      handler = fn tool_name, _input, _opts ->
        IO.puts("Tool: \#{tool_name}")
        :allow
      end
      ClaudeAgentSdkTs.stream("List files", [can_use_tool: handler], &IO.inspect/1)
  """
  @spec stream(String.t() | %{content: list()}, chat_opts(), stream_callback()) :: :ok | {:error, term()}
  def stream(prompt, opts \\ [], callback) when is_function(callback, 1) do
    config = Config.new(opts)
    bridge_opts = Config.to_bridge_opts(config)

    # Add permission handler if provided
    bridge_opts =
      case Keyword.get(opts, :can_use_tool) do
        nil -> bridge_opts
        handler when is_function(handler) -> Map.put(bridge_opts, :can_use_tool, handler)
      end

    PortBridge.stream(prompt, bridge_opts, callback)
  end

  @doc """
  Sends a chat message and returns an Elixir Stream of response chunks.

  The first argument can be either:
    - A string for simple text prompts
    - A map with `:content` key containing a list of content blocks for multimodal inputs

  ## Examples

      ClaudeAgentSdkTs.stream!("Tell me about Erlang")
      |> Enum.each(&IO.write/1)

      # Multimodal
      alias ClaudeAgentSdkTs.Content
      content = [Content.text("What's this?"), Content.image_file("photo.png")]
      ClaudeAgentSdkTs.stream!(%{content: content})
      |> Enum.each(&IO.write/1)
  """
  @spec stream!(String.t() | %{content: list()}, chat_opts()) :: Enumerable.t()
  def stream!(prompt, opts \\ []) do
    Stream.resource(
      fn ->
        parent = self()
        ref = make_ref()

        spawn_link(fn ->
          stream(prompt, opts, fn
            %{type: :chunk, content: content} ->
              send(parent, {ref, {:chunk, content}})

            %{type: :end} ->
              send(parent, {ref, :done})

            %{type: :error} = error ->
              send(parent, {ref, {:error, error}})

            _other ->
              :ok
          end)
        end)

        ref
      end,
      fn ref ->
        receive do
          {^ref, {:chunk, content}} -> {[content], ref}
          {^ref, :done} -> {:halt, ref}
          {^ref, {:error, error}} -> raise "Stream error: #{inspect(error)}"
        after
          300_000 -> raise "Stream timeout"
        end
      end,
      fn _ref -> :ok end
    )
  end

  @doc """
  Starts a new supervised session for multi-turn conversations.

  Sessions maintain conversation context across multiple messages.

  ## Examples

      {:ok, session} = ClaudeAgentSdkTs.start_session()
      {:ok, response1} = ClaudeAgentSdkTs.Session.chat(session, "My name is Alice")
      {:ok, response2} = ClaudeAgentSdkTs.Session.chat(session, "What's my name?")
      # response2 will know the name is Alice
  """
  @spec start_session(chat_opts()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    ClaudeAgentSdkTs.Session.start_link(opts)
  end

  @doc """
  Responds to a pending permission request.

  Use this when your `can_use_tool` handler returns `:pending` to defer the decision.
  This is particularly useful for interactive UIs like Phoenix LiveView where you need
  to show a modal and wait for user input.

  See `ClaudeAgentSdkTs.PortBridge.respond_to_permission/2` for full documentation.

  ## Example: Phoenix LiveView

      # In your chat component's mount or handle_params
      def mount(_params, _session, socket) do
        handler = fn tool_name, tool_input, opts ->
          # Send permission request to LiveView process
          send(self(), {:permission_request, opts.request_id, tool_name, tool_input})
          :pending  # Tell SDK we'll respond later
        end

        {:ok, assign(socket, can_use_tool: handler, pending_permission: nil)}
      end

      # Handle incoming permission requests
      def handle_info({:permission_request, request_id, tool_name, tool_input}, socket) do
        {:noreply, assign(socket,
          pending_permission: %{
            request_id: request_id,
            tool_name: tool_name,
            tool_input: tool_input
          }
        )}
      end

      # Handle user clicking "Allow"
      def handle_event("allow_tool", _params, socket) do
        ClaudeAgentSdkTs.respond_to_permission(socket.assigns.pending_permission.request_id, :allow)
        {:noreply, assign(socket, pending_permission: nil)}
      end

      # Handle user clicking "Deny"
      def handle_event("deny_tool", _params, socket) do
        ClaudeAgentSdkTs.respond_to_permission(
          socket.assigns.pending_permission.request_id,
          {:deny, "User declined"}
        )
        {:noreply, assign(socket, pending_permission: nil)}
      end
  """
  @spec respond_to_permission(String.t(), term()) :: :ok
  defdelegate respond_to_permission(request_id, decision), to: PortBridge
end
