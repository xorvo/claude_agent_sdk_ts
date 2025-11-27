defmodule ClaudeAgent.Session do
  @moduledoc """
  A GenServer that manages a stateful conversation session with Claude.

  Sessions maintain conversation history, allowing for multi-turn conversations
  where Claude remembers previous context.

  ## Usage

      {:ok, session} = ClaudeAgent.Session.start_link()

      # First message
      {:ok, response1} = ClaudeAgent.Session.chat(session, "My favorite color is blue")

      # Claude will remember the context
      {:ok, response2} = ClaudeAgent.Session.chat(session, "What's my favorite color?")

      # Reset conversation history
      ClaudeAgent.Session.reset(session)

      # Stop the session
      ClaudeAgent.Session.stop(session)
  """

  use GenServer
  require Logger

  alias ClaudeAgent.{Config, Tool}

  @type state :: %{
          config: Config.t(),
          history: list(map()),
          tools: list(Tool.t())
        }

  # Client API

  @doc """
  Starts a new session process.

  ## Options

  Same options as `ClaudeAgent.chat/2`, plus:
    * `:tools` - List of tools available for the entire session
    * `:name` - Optional name to register the process

  ## Examples

      {:ok, session} = ClaudeAgent.Session.start_link()
      {:ok, session} = ClaudeAgent.Session.start_link(name: :my_session)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts a session under the ClaudeAgent.SessionSupervisor.
  """
  @spec start_supervised(keyword()) :: DynamicSupervisor.on_start_child()
  def start_supervised(opts \\ []) do
    DynamicSupervisor.start_child(ClaudeAgent.SessionSupervisor, {__MODULE__, opts})
  end

  @doc """
  Sends a message in the session and waits for the response.

  The conversation history is automatically maintained.
  """
  @spec chat(GenServer.server(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(session, message, opts \\ []) do
    GenServer.call(session, {:chat, message, opts}, opts[:timeout] || 300_000)
  end

  @doc """
  Same as `chat/3` but raises on error.
  """
  @spec chat!(GenServer.server(), String.t(), keyword()) :: String.t()
  def chat!(session, message, opts \\ []) do
    case chat(session, message, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "Session chat failed: #{inspect(reason)}"
    end
  end

  @doc """
  Streams a message response via callback.
  """
  @spec stream(GenServer.server(), String.t(), keyword(), function()) ::
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

  # Server Callbacks

  @impl true
  def init(opts) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    config = Config.new(opts)

    state = %{
      config: config,
      history: [],
      tools: tools
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:chat, message, opts}, _from, state) do
    config = merge_config(state.config, opts)
    bridge_opts = build_bridge_opts(config, state)

    # Add conversation history context to the prompt
    prompt = build_prompt_with_history(message, state.history)

    case ClaudeAgent.PortBridge.chat(prompt, bridge_opts) do
      {:ok, response} ->
        # Update history with the new exchange
        history =
          state.history ++
            [
              %{role: "user", content: message},
              %{role: "assistant", content: response}
            ]

        {:reply, {:ok, response}, %{state | history: history}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stream, message, opts, callback}, from, state) do
    config = merge_config(state.config, opts)
    bridge_opts = build_bridge_opts(config, state)
    prompt = build_prompt_with_history(message, state.history)

    # Collect chunks to update history after streaming completes
    chunks = []

    wrapped_callback = fn
      %{type: :chunk, content: content} = msg ->
        callback.(msg)
        {:collect, content}

      %{type: :end} = msg ->
        callback.(msg)
        :done

      other ->
        callback.(other)
        :ok
    end

    # Spawn a task to handle streaming
    parent = self()

    Task.start(fn ->
      result =
        stream_and_collect(prompt, bridge_opts, wrapped_callback, chunks, fn collected ->
          # Send collected content back to update history
          send(parent, {:stream_complete, from, message, collected})
        end)

      case result do
        :ok -> :ok
        {:error, _} = error -> GenServer.reply(from, error)
      end
    end)

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
  def handle_info({:stream_complete, from, message, collected}, state) do
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
        %{role: "user", content: content} -> "Human: #{content}"
        %{role: "assistant", content: content} -> "Assistant: #{content}"
      end)
      |> Enum.join("\n\n")

    """
    Previous conversation:
    #{context}

    Current message:
    Human: #{message}
    """
  end

  defp stream_and_collect(prompt, bridge_opts, callback, chunks, on_complete) do
    collected = Agent.start_link(fn -> [] end)

    result =
      ClaudeAgent.PortBridge.stream(prompt, bridge_opts, fn msg ->
        case callback.(msg) do
          {:collect, content} ->
            case collected do
              {:ok, agent} -> Agent.update(agent, fn c -> c ++ [content] end)
              _ -> :ok
            end

          :done ->
            case collected do
              {:ok, agent} ->
                final = Agent.get(agent, & &1)
                Agent.stop(agent)
                on_complete.(final)

              _ ->
                on_complete.(chunks)
            end

          _ ->
            :ok
        end
      end)

    result
  end
end
