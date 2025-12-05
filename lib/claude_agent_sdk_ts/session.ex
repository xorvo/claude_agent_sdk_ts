defmodule ClaudeAgentSdkTs.Session do
  @moduledoc """
  A GenServer that manages a stateful conversation session with Claude.

  Sessions maintain conversation history, allowing for multi-turn conversations
  where Claude remembers previous context.

  ## Usage

      {:ok, session} = ClaudeAgentSdkTs.Session.start_link()

      # First message
      {:ok, response1} = ClaudeAgentSdkTs.Session.chat(session, "My favorite color is blue")

      # Claude will remember the context
      {:ok, response2} = ClaudeAgentSdkTs.Session.chat(session, "What's my favorite color?")

      # Reset conversation history
      ClaudeAgentSdkTs.Session.reset(session)

      # Stop the session
      ClaudeAgentSdkTs.Session.stop(session)

  ## Aborting Requests

  You can abort an in-flight `chat/3` or `stream/4` request using `abort/1`:

      # Start a long-running task in another process
      task = Task.async(fn ->
        Session.chat(session, "Write a very long story")
      end)

      # Abort after a few seconds
      Process.sleep(2000)
      Session.abort(session)

      # The task will return {:error, :aborted}
      {:error, :aborted} = Task.await(task)

  Note: `abort/1` sends an abort signal to the underlying Claude API request.
  If no request is currently in progress, it has no effect.
  """

  use GenServer
  require Logger

  alias ClaudeAgentSdkTs.{Config, Tool}

  @type state :: %{
          config: Config.t(),
          history: list(map()),
          tools: list(Tool.t()),
          current_request_ref: reference() | nil
        }

  # Client API

  @doc """
  Starts a new session process.

  ## Options

  Same options as `ClaudeAgentSdkTs.chat/2`, plus:
    * `:tools` - List of tools available for the entire session
    * `:name` - Optional name to register the process

  ## Examples

      {:ok, session} = ClaudeAgentSdkTs.Session.start_link()
      {:ok, session} = ClaudeAgentSdkTs.Session.start_link(name: :my_session)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts a session under the ClaudeAgentSdkTs.SessionSupervisor.
  """
  @spec start_supervised(keyword()) :: DynamicSupervisor.on_start_child()
  def start_supervised(opts \\ []) do
    DynamicSupervisor.start_child(ClaudeAgentSdkTs.SessionSupervisor, {__MODULE__, opts})
  end

  @doc """
  Sends a message in the session and waits for the response.

  The conversation history is automatically maintained.

  The message can be either:
    - A string for simple text prompts
    - A map with `:content` key containing a list of content blocks for multimodal inputs

  ## Options

  Accepts all options from `ClaudeAgentSdkTs.chat/2`, including:
    * `:can_use_tool` - Permission handler function for interactive tool approval

  ## Examples

      # Text message
      {:ok, response} = Session.chat(session, "Hello!")

      # Multimodal message with image
      alias ClaudeAgentSdkTs.Content
      content = [Content.text("What's in this image?"), Content.image_file("photo.png")]
      {:ok, response} = Session.chat(session, %{content: content})

      # With permission handling
      handler = fn tool_name, _input, _opts ->
        IO.puts("Tool: \#{tool_name}")
        :allow
      end
      {:ok, response} = Session.chat(session, "List files", can_use_tool: handler)
  """
  @spec chat(GenServer.server(), String.t() | %{content: list()}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def chat(session, message, opts \\ []) do
    GenServer.call(session, {:chat, message, opts}, opts[:timeout] || 300_000)
  end

  @doc """
  Same as `chat/3` but raises on error.
  """
  @spec chat!(GenServer.server(), String.t() | %{content: list()}, keyword()) :: String.t()
  def chat!(session, message, opts \\ []) do
    case chat(session, message, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "Session chat failed: #{inspect(reason)}"
    end
  end

  @doc """
  Streams a message response via callback.

  The message can be either a string or a map with `:content` for multimodal inputs.
  See `chat/3` for details on message formats and options.

  ## Options

  Accepts all options from `ClaudeAgentSdkTs.chat/2`, including:
    * `:can_use_tool` - Permission handler function for interactive tool approval

  ## Examples

      # Basic streaming
      Session.stream(session, "Tell me a story", [], fn
        %{type: :chunk, content: text} -> IO.write(text)
        %{type: :end} -> IO.puts("")
        _ -> :ok
      end)

      # With permission handling
      handler = fn tool_name, _input, _opts -> :allow end
      Session.stream(session, "List files", [can_use_tool: handler], &IO.inspect/1)
  """
  @spec stream(GenServer.server(), String.t() | %{content: list()}, keyword(), function()) ::
          :ok | {:error, term()}
  def stream(session, message, opts \\ [], callback) when is_function(callback, 1) do
    GenServer.call(session, {:stream, message, opts, callback}, opts[:timeout] || 300_000)
  end

  @doc """
  Gets the current conversation history.
  """
  @spec get_history(GenServer.server()) :: list(map())
  def get_history(session) do
    GenServer.call(session, :get_history)
  end

  @doc """
  Resets the conversation history.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(session) do
    GenServer.call(session, :reset)
  end

  @doc """
  Adds a tool to the session.
  """
  @spec add_tool(GenServer.server(), Tool.t()) :: :ok
  def add_tool(session, %Tool{} = tool) do
    GenServer.call(session, {:add_tool, tool})
  end

  @doc """
  Stops the session.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(session) do
    GenServer.stop(session)
  end

  @doc """
  Aborts the current in-flight request, if any.

  This sends an abort signal to the underlying Claude API request, causing it
  to be cancelled. The `chat/3` or `stream/4` call that initiated the request
  will return `{:error, :aborted}`.

  If no request is currently in progress, this function has no effect.

  ## Examples

      # Start a long-running task in another process
      task = Task.async(fn ->
        Session.chat(session, "Write a very long story")
      end)

      # Abort after a few seconds
      Process.sleep(2000)
      Session.abort(session)

      # The task will return {:error, :aborted}
      {:error, :aborted} = Task.await(task)
  """
  @spec abort(GenServer.server()) :: :ok
  def abort(session) do
    GenServer.cast(session, :abort)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    config = Config.new(opts)

    state = %{
      config: config,
      history: [],
      tools: tools,
      current_request_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:chat, message, opts}, from, state) do
    # Extract permission handler before merging config
    {permission_handler, opts} = Keyword.pop(opts, :can_use_tool)

    config = merge_config(state.config, opts)
    bridge_opts = build_bridge_opts(config, state)

    # Add permission handler if provided
    bridge_opts =
      if is_function(permission_handler) do
        Map.put(bridge_opts, :can_use_tool, permission_handler)
      else
        bridge_opts
      end

    # Add conversation history context to the prompt
    prompt = build_prompt_with_history(message, state.history)

    # Spawn a task first to get its PID, then start the async chat with task as caller
    parent = self()

    {:ok, task_pid} =
      Task.start(fn ->
        # Wait for the wait_fn to be sent to us
        receive do
          {:start, wait_fn} ->
            result = wait_fn.()
            send(parent, {:chat_result, from, message, result})
        end
      end)

    # Start chat_async with the task as the caller so messages go to the task
    {bridge_ref, wait_fn} =
      ClaudeAgentSdkTs.PortBridge.chat_async(prompt, Map.put(bridge_opts, :caller, task_pid))

    # Send wait_fn to the task to start processing
    send(task_pid, {:start, wait_fn})

    # Store the bridge ref so abort can find it
    state = %{state | current_request_ref: bridge_ref}

    {:noreply, state}
  end

  @impl true
  def handle_call({:stream, message, opts, callback}, from, state) do
    # Extract permission handler before merging config
    {permission_handler, opts} = Keyword.pop(opts, :can_use_tool)

    config = merge_config(state.config, opts)
    bridge_opts = build_bridge_opts(config, state)

    # Add permission handler if provided
    bridge_opts =
      if is_function(permission_handler) do
        Map.put(bridge_opts, :can_use_tool, permission_handler)
      else
        bridge_opts
      end

    prompt = build_prompt_with_history(message, state.history)

    # Use an Agent to collect chunks across callback invocations
    {:ok, collector} = Agent.start_link(fn -> [] end)

    wrapped_callback = fn
      %{type: :chunk, content: content} = msg ->
        callback.(msg)
        Agent.update(collector, fn chunks -> [content | chunks] end)

      %{type: :end} = msg ->
        callback.(msg)

      %{type: :aborted} = msg ->
        callback.(msg)

      other ->
        callback.(other)
    end

    # Spawn a task first to get its PID, then start the async stream with task as caller
    parent = self()

    {:ok, task_pid} =
      Task.start(fn ->
        # Wait for the wait_fn to be sent to us
        receive do
          {:start, wait_fn} ->
            result = wait_fn.()

            case result do
              :ok ->
                # Get collected chunks and send to parent for history update
                collected = Agent.get(collector, & &1) |> Enum.reverse()
                Agent.stop(collector)
                send(parent, {:stream_complete, from, message, collected})

              {:error, _} = error ->
                Agent.stop(collector)
                GenServer.reply(from, error)
            end
        end
      end)

    # Start stream_async with the task as the caller so messages go to the task
    {bridge_ref, wait_fn} =
      ClaudeAgentSdkTs.PortBridge.stream_async(
        prompt,
        Map.put(bridge_opts, :caller, task_pid),
        wrapped_callback
      )

    # Send wait_fn to the task to start processing
    send(task_pid, {:start, wait_fn})

    # Store the bridge ref so abort can find it
    state = %{state | current_request_ref: bridge_ref}

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | history: []}}
  end

  @impl true
  def handle_call({:add_tool, tool}, _from, state) do
    {:reply, :ok, %{state | tools: [tool | state.tools]}}
  end

  @impl true
  def handle_cast(:abort, state) do
    case state.current_request_ref do
      nil ->
        # No active request to abort
        {:noreply, state}

      ref ->
        # Send abort to the PortBridge
        ClaudeAgentSdkTs.PortBridge.abort(ref)
        # Clear the ref (the result handler will still run and handle the error)
        {:noreply, %{state | current_request_ref: nil}}
    end
  end

  @impl true
  def handle_info({:chat_result, from, message, result}, state) do
    # Clear the request ref
    state = %{state | current_request_ref: nil}

    case result do
      {:ok, response} ->
        # Update history with the new exchange
        history =
          state.history ++
            [
              %{role: "user", content: message},
              %{role: "assistant", content: response}
            ]

        GenServer.reply(from, {:ok, response})
        {:noreply, %{state | history: history}}

      {:error, _} = error ->
        GenServer.reply(from, error)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stream_complete, from, message, collected}, state) do
    # Clear the request ref
    state = %{state | current_request_ref: nil}

    response = Enum.join(collected)

    history =
      state.history ++
        [
          %{role: "user", content: message},
          %{role: "assistant", content: response}
        ]

    GenServer.reply(from, :ok)
    {:noreply, %{state | history: history}}
  end

  # Private Functions

  defp merge_config(%Config{} = base, opts) do
    opts_map = Map.new(opts)

    base
    |> Map.from_struct()
    |> Map.merge(opts_map)
    |> then(&struct(Config, &1))
  end

  defp build_bridge_opts(%Config{} = config, state) do
    bridge_opts = Config.to_bridge_opts(config)

    case state.tools do
      [] -> bridge_opts
      tools -> Map.put(bridge_opts, "tools", Enum.map(tools, &Tool.to_definition/1))
    end
  end

  defp build_prompt_with_history(message, []) do
    message
  end

  defp build_prompt_with_history(message, history) do
    context =
      history
      |> Enum.map(fn
        %{role: "user", content: content} -> "Human: #{extract_text_content(content)}"
        %{role: "assistant", content: content} -> "Assistant: #{content}"
      end)
      |> Enum.join("\n\n")

    # For multimodal messages, we need to prepend history context
    # but keep the multimodal structure intact
    case message do
      %{content: content_blocks} when is_list(content_blocks) ->
        # Prepend history as a text block to the multimodal content
        history_block = %{
          type: "text",
          text: """
          Previous conversation:
          #{context}

          Current message:
          """
        }

        %{content: [history_block | content_blocks]}

      text when is_binary(text) ->
        """
        Previous conversation:
        #{context}

        Current message:
        Human: #{text}
        """
    end
  end

  # Extract text from content that may be a string, a list of content blocks, or a map
  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{type: "text"} -> true
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map(fn
      %{text: text} -> text
      %{"text" => text} -> text
    end)
    |> Enum.join(" ")
  end

  defp extract_text_content(%{content: blocks}) when is_list(blocks) do
    extract_text_content(blocks)
  end

  defp extract_text_content(_), do: "[non-text content]"
end
