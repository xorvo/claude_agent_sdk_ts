defmodule ClaudeAgentSdkTs.PortBridge do
  @moduledoc """
  Manages communication with the Node.js bridge process via Erlang ports.

  This module handles:
  - Spawning and managing the Node.js process
  - Sending JSON-encoded commands
  - Receiving and parsing JSON responses
  - Handling streaming responses

  ## Debug Logging

  Set the log level to :debug to see all communication:

      config :logger, level: :debug

  Or at runtime:

      Logger.configure(level: :debug)
  """

  use GenServer
  require Logger

  @type state :: %{
          port: port() | nil,
          pending: %{reference() => {pid(), any()}},
          buffer: String.t()
        }

  # Client API

  @doc """
  Starts the PortBridge GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a chat request to Claude and waits for the complete response.
  """
  @spec chat(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def chat(prompt, opts \\ %{}) do
    GenServer.call(__MODULE__, {:chat, prompt, opts}, opts[:timeout] || 300_000)
  end

  @doc """
  Sends a chat request and streams responses to the given callback or process.

  Uses an activity-based timeout that resets whenever data is received from the
  Claude API. This prevents false-positive timeouts during long-running but
  actively streaming sessions.

  ## Options

    * `:timeout` - Activity timeout in milliseconds (default: 300_000 / 5 minutes).
      The timeout resets each time a chunk, tool_use, or other message is received.
      Only triggers if there's no activity for the specified duration.

  """
  @spec stream(String.t(), map(), pid() | (map() -> any())) :: :ok | {:error, term()}
  def stream(prompt, opts \\ %{}, callback) do
    timeout = opts[:timeout] || 300_000
    ref = make_ref()
    caller = self()

    GenServer.cast(__MODULE__, {:stream, prompt, opts, callback, caller, ref})

    receive_with_activity_timeout(ref, timeout)
  end

  # Waits for stream completion with an activity-based timeout.
  # The timeout resets each time activity is received.
  defp receive_with_activity_timeout(ref, timeout) do
    receive do
      {:stream_activity, ^ref} ->
        # Activity received, reset timeout and continue waiting
        receive_with_activity_timeout(ref, timeout)

      {:stream_complete, ^ref, result} ->
        result

      {:stream_error, ^ref, error} ->
        {:error, error}
    after
      timeout ->
        # No activity for the timeout duration - truly stuck
        {:error, :activity_timeout}
    end
  end

  @doc """
  Sends a tool result back to an ongoing conversation.
  """
  @spec send_tool_result(String.t(), any()) :: :ok
  def send_tool_result(tool_use_id, result) do
    GenServer.cast(__MODULE__, {:tool_result, tool_use_id, result})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      pending: %{},
      buffer: ""
    }

    {:ok, state, {:continue, :start_port}}
  end

  @impl true
  def handle_continue(:start_port, state) do
    port = start_node_port()
    {:noreply, %{state | port: port}}
  end

  @impl true
  def handle_call({:chat, prompt, opts}, from, state) do
    ref = make_ref()

    command = %{
      type: "chat",
      id: inspect(ref),
      prompt: prompt,
      options: opts
    }

    send_command(state.port, command)
    pending = Map.put(state.pending, inspect(ref), {from, :chat, []})

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_cast({:stream, prompt, opts, callback, caller, ref}, state) do
    command = %{
      type: "stream",
      id: inspect(ref),
      prompt: prompt,
      options: opts
    }

    send_command(state.port, command)
    # Store caller pid and ref for activity signaling and completion notification
    pending = Map.put(state.pending, inspect(ref), {:stream, callback, caller, ref})

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_cast({:tool_result, tool_use_id, result}, state) do
    command = %{
      type: "tool_result",
      toolUseId: tool_use_id,
      result: result
    }

    send_command(state.port, command)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    # Handle combined stdout/stderr data (using :stderr_to_stdout)
    handle_stdout(data, state)
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_list(data) do
    # Handle charlist data
    handle_stdout(to_string(data), state)
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Node bridge exited with status #{status}, restarting...")

    # Reply to all pending requests with error
    for {_ref, pending_data} <- state.pending do
      case pending_data do
        {:stream, _callback, caller, ref} ->
          send(caller, {:stream_error, ref, :bridge_crashed})

        {from, :chat, _} ->
          GenServer.reply(from, {:error, :bridge_crashed})
      end
    end

    # Restart the port
    new_port = start_node_port()
    {:noreply, %{state | port: new_port, pending: %{}, buffer: ""}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helper for processing stdout/stderr data
  defp handle_stdout(data_str, state) do
    buffer = state.buffer <> data_str
    {messages, log_lines, remaining} = extract_lines(buffer)

    # Forward TypeScript logs through Elixir Logger
    Enum.each(log_lines, &log_bridge_message/1)

    # Process JSON messages
    state = %{state | buffer: remaining}

    state =
      Enum.reduce(messages, state, fn msg, acc ->
        Logger.debug("[PortBridge] Processing message: #{inspect(msg, limit: 200)}")
        handle_message(msg, acc)
      end)

    {:noreply, state}
  end

  defp log_bridge_message(line) do
    # Parse bridge log format: [timestamp] [Bridge] message
    case Regex.run(~r/^\[[\d\-T:.Z]+\] \[Bridge\] (.+)$/, line) do
      [_, message] ->
        Logger.debug("[Node] #{message}")

      nil ->
        # Log unparsed lines as-is (e.g., errors from Node.js itself)
        Logger.debug("[Node] #{line}")
    end
  end

  # Private Functions

  defp start_node_port do
    priv_dir = ClaudeAgentSdkTs.priv_path()
    bridge_path = Path.join([priv_dir, "dist", "bridge.js"])

    Logger.debug("[PortBridge] Starting Node.js bridge at #{bridge_path}")

    # Build environment: inherit all parent env vars and add debug flag
    env =
      System.get_env()
      |> Map.merge(%{"CLAUDE_AGENT_DEBUG" => "1"})
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, [bridge_path]},
        {:env, env},
        {:cd, priv_dir}
      ])

    Logger.debug("[PortBridge] Node.js bridge started, port: #{inspect(port)}")
    port
  end

  defp send_command(port, command) do
    json = Jason.encode!(command) <> "\n"
    Logger.debug("[PortBridge] Sending command: #{String.slice(json, 0, 500)}")
    Port.command(port, json)
  end

  defp extract_lines(buffer) do
    lines = String.split(buffer, "\n")

    case List.pop_at(lines, -1) do
      {remaining, complete} ->
        # Separate JSON messages from log lines
        {json_lines, log_lines} =
          complete
          |> Enum.reject(&(&1 == ""))
          |> Enum.split_with(&String.starts_with?(&1, "{"))

        messages =
          json_lines
          |> Enum.map(&parse_json/1)
          |> Enum.reject(&is_nil/1)

        {messages, log_lines, remaining || ""}
    end
  end

  defp parse_json(line) do
    case Jason.decode(line) do
      {:ok, json} ->
        json

      {:error, _} ->
        Logger.warning("[PortBridge] Failed to parse JSON: #{String.slice(line, 0, 100)}")
        nil
    end
  end

  defp handle_message(%{"id" => id, "type" => "complete", "content" => content}, state) do
    case Map.pop(state.pending, id) do
      {{from, :chat, _}, pending} ->
        GenServer.reply(from, {:ok, content})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "chunk", "content" => content}, state) do
    case Map.get(state.pending, id) do
      {:stream, callback, caller, ref} when is_function(callback) ->
        callback.(%{type: :chunk, content: content})
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      {:stream, pid, caller, ref} when is_pid(pid) ->
        send(pid, {:claude_chunk, content})
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      {from, :chat, chunks} ->
        pending = Map.put(state.pending, id, {from, :chat, [content | chunks]})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "end"}, state) do
    case Map.pop(state.pending, id) do
      {{:stream, callback, caller, ref}, pending} when is_function(callback) ->
        callback.(%{type: :end})
        # Signal completion to the caller's receive loop
        send(caller, {:stream_complete, ref, :ok})
        %{state | pending: pending}

      {{:stream, pid, caller, ref}, pending} when is_pid(pid) ->
        send(pid, :claude_end)
        # Signal completion to the caller's receive loop
        send(caller, {:stream_complete, ref, :ok})
        %{state | pending: pending}

      {{from, :chat, chunks}, pending} ->
        content = chunks |> Enum.reverse() |> Enum.join("")
        GenServer.reply(from, {:ok, content})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "tool_use"} = msg, state) do
    case Map.get(state.pending, id) do
      {:stream, callback, caller, ref} when is_function(callback) ->
        callback.(ClaudeAgentSdkTs.Response.parse(msg))
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      {:stream, pid, caller, ref} when is_pid(pid) ->
        send(pid, {:claude_tool_use, msg})
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "error", "message" => message}, state) do
    case Map.pop(state.pending, id) do
      {{:stream, _callback, caller, ref}, pending} ->
        # Signal error to the caller's receive loop
        send(caller, {:stream_error, ref, message})
        %{state | pending: pending}

      {{from, :chat, _}, pending} ->
        GenServer.reply(from, {:error, message})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(_msg, state), do: state
end
