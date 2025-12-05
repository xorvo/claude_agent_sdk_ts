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

  The prompt can be either:
    - A string for simple text prompts
    - A map with `:content` key containing a list of content blocks for multimodal inputs

  ## Multimodal Content Blocks

      # Image from base64
      content = [
        %{type: "text", text: "What's in this image?"},
        %{type: "image", source: %{type: "base64", media_type: "image/png", data: "..."}}
      ]
      PortBridge.chat(%{content: content}, opts)

      # Image from URL
      content = [
        %{type: "text", text: "Describe this:"},
        %{type: "image", source: %{type: "url", url: "https://..."}}
      ]
      PortBridge.chat(%{content: content}, opts)
  """
  @spec chat(String.t() | %{content: list()}, map()) :: {:ok, String.t()} | {:error, term()}
  def chat(prompt, opts \\ %{}) do
    GenServer.call(__MODULE__, {:chat, prompt, opts}, opts[:timeout] || 300_000)
  end

  @doc """
  Like `chat/2`, but returns the request reference immediately for abort support.

  Returns `{ref, result_fun}` where:
    - `ref` is the request reference that can be passed to `abort/1`
    - `result_fun` is a 0-arity function that blocks until the response is ready

  ## Options

    * `:timeout` - Request timeout in milliseconds (default: 300_000)
    * `:caller` - Process to receive result messages (default: `self()`).
      The `wait_fn` must be called from this process.

  ## Example

      {ref, wait} = PortBridge.chat_async("Long task", %{})

      # In another process/later:
      PortBridge.abort(ref)

      # Get the result (will be {:error, :aborted} if aborted)
      result = wait.()

  ## Example with explicit caller

      # In a GenServer that spawns a Task:
      task_pid = spawn(fn ->
        receive do
          {:go, ref, wait_fn} ->
            result = wait_fn.()
            # handle result
        end
      end)

      {ref, wait_fn} = PortBridge.chat_async("Long task", %{caller: task_pid})
      send(task_pid, {:go, ref, wait_fn})
  """
  @spec chat_async(String.t() | %{content: list()}, map()) ::
          {reference(), (-> {:ok, String.t()} | {:error, term()})}
  def chat_async(prompt, opts \\ %{}) do
    timeout = opts[:timeout] || 300_000
    caller = opts[:caller] || self()
    ref = make_ref()

    # Remove :caller from opts before passing to GenServer (it's not a bridge option)
    bridge_opts = Map.drop(opts, [:caller, :timeout])

    GenServer.cast(__MODULE__, {:chat_async, prompt, bridge_opts, caller, ref})

    wait_fn = fn ->
      receive do
        {:chat_complete, ^ref, result} -> result
        {:chat_error, ^ref, error} -> {:error, error}
        {:chat_aborted, ^ref} -> {:error, :aborted}
      after
        timeout -> {:error, :timeout}
      end
    end

    {ref, wait_fn}
  end

  @doc """
  Sends a chat request and streams responses to the given callback or process.

  The prompt can be either:
    - A string for simple text prompts
    - A map with `:content` key containing a list of content blocks for multimodal inputs

  Uses an activity-based timeout that resets whenever data is received from the
  Claude API. This prevents false-positive timeouts during long-running but
  actively streaming sessions.

  ## Options

    * `:timeout` - Activity timeout in milliseconds (default: 300_000 / 5 minutes).
      The timeout resets each time a chunk, tool_use, or other message is received.
      Only triggers if there's no activity for the specified duration.

  ## Multimodal Content Blocks

  See `chat/2` for examples of multimodal content blocks.
  """
  @spec stream(String.t() | %{content: list()}, map(), pid() | (map() -> any())) :: :ok | {:error, term()}
  def stream(prompt, opts \\ %{}, callback) do
    timeout = opts[:timeout] || 300_000
    ref = make_ref()
    caller = self()

    GenServer.cast(__MODULE__, {:stream, prompt, opts, callback, caller, ref})

    receive_with_activity_timeout(ref, timeout)
  end

  @doc """
  Like `stream/3`, but returns the request reference immediately for abort support.

  Returns `{ref, result_fun}` where:
    - `ref` is the request reference that can be passed to `abort/1`
    - `result_fun` is a 0-arity function that blocks until completion

  ## Options

    * `:timeout` - Activity timeout in milliseconds (default: 300_000)
    * `:caller` - Process to receive activity/completion messages (default: `self()`).
      The `wait_fn` must be called from this process.

  ## Example

      {ref, wait} = PortBridge.stream_async("Long task", %{}, fn msg -> IO.inspect(msg) end)

      # In another process/later:
      PortBridge.abort(ref)

      # Get the result (will be {:error, :aborted} if aborted)
      result = wait.()

  ## Example with explicit caller

      # In a GenServer that spawns a Task to handle streaming:
      task_pid = spawn(fn ->
        receive do
          {:go, wait_fn} -> wait_fn.()
        end
      end)

      {ref, wait_fn} = PortBridge.stream_async("Task", %{caller: task_pid}, callback)
      send(task_pid, {:go, wait_fn})
  """
  @spec stream_async(String.t() | %{content: list()}, map(), pid() | (map() -> any())) ::
          {reference(), (-> :ok | {:error, term()})}
  def stream_async(prompt, opts \\ %{}, callback) do
    timeout = opts[:timeout] || 300_000
    caller = opts[:caller] || self()
    ref = make_ref()

    # Remove :caller from opts before passing to GenServer (it's not a bridge option)
    bridge_opts = Map.drop(opts, [:caller, :timeout])

    GenServer.cast(__MODULE__, {:stream, prompt, bridge_opts, callback, caller, ref})

    wait_fn = fn -> receive_with_activity_timeout(ref, timeout) end
    {ref, wait_fn}
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

      {:stream_aborted, ^ref} ->
        {:error, :aborted}
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

  @doc """
  Aborts an in-flight chat or stream request.

  This sends an abort signal to the Node.js bridge, which will cancel the
  underlying Claude API request using AbortController.

  ## Arguments

    * `request_id` - The request ID (reference) to abort. This is the same
      reference used internally when starting the request.

  ## Returns

    * `:ok` - The abort command was sent (doesn't guarantee the request was found)

  ## Example

      # Start a streaming request
      ref = make_ref()
      PortBridge.stream("Long task", %{}, fn msg -> IO.inspect(msg) end)

      # Later, abort it
      PortBridge.abort(ref)
  """
  @spec abort(reference() | String.t()) :: :ok
  def abort(request_id) do
    GenServer.cast(__MODULE__, {:abort, request_id})
  end

  @doc """
  Sends a permission response back to the bridge.

  This is used internally when a `can_use_tool` callback returns a decision.
  """
  @spec send_permission_response(String.t(), map()) :: :ok
  def send_permission_response(request_id, response) do
    GenServer.cast(__MODULE__, {:permission_response, request_id, response})
  end

  @doc """
  Responds to a pending permission request.

  Use this when your `can_use_tool` handler returns `:pending` to defer the decision.
  This is particularly useful for interactive UIs like Phoenix LiveView where you need
  to show a modal and wait for user input.

  ## Arguments

    * `request_id` - The request ID from `opts.request_id` in the handler
    * `decision` - One of the standard permission responses:
      * `:allow` - Approve the tool call
      * `{:allow, updated_input}` - Approve with modified input
      * `{:allow, updated_input, updated_permissions}` - Approve with modified input and permissions
      * `:deny` - Deny the tool call
      * `{:deny, message}` - Deny with a message
      * `{:deny, message, interrupt: true}` - Deny and stop the conversation

  ## Example

      # In your permission handler, return :pending and notify the UI
      handler = fn tool_name, tool_input, opts ->
        send(liveview_pid, {:permission_request, opts.request_id, tool_name, tool_input})
        :pending
      end

      # Later, when the user clicks "Allow" or "Deny" in the UI
      def handle_event("allow_tool", %{"request_id" => request_id}, socket) do
        ClaudeAgentSdkTs.PortBridge.respond_to_permission(request_id, :allow)
        {:noreply, socket}
      end

      def handle_event("deny_tool", %{"request_id" => request_id}, socket) do
        ClaudeAgentSdkTs.PortBridge.respond_to_permission(request_id, {:deny, "User declined"})
        {:noreply, socket}
      end
  """
  @spec respond_to_permission(String.t(), term()) :: :ok
  def respond_to_permission(request_id, decision) do
    response = build_permission_response_public(decision)
    send_permission_response(request_id, response)
  end

  # Public version of build_permission_response for respond_to_permission
  defp build_permission_response_public({:allow, updated_input}) do
    %{behavior: "allow", updatedInput: updated_input}
  end

  defp build_permission_response_public({:allow, updated_input, updated_permissions}) do
    %{behavior: "allow", updatedInput: updated_input, updatedPermissions: updated_permissions}
  end

  defp build_permission_response_public(:allow) do
    %{behavior: "allow", updatedInput: %{}}
  end

  defp build_permission_response_public({:deny, message}) do
    %{behavior: "deny", message: message, interrupt: false}
  end

  defp build_permission_response_public({:deny, message, opts}) when is_list(opts) do
    %{
      behavior: "deny",
      message: message,
      interrupt: Keyword.get(opts, :interrupt, false)
    }
  end

  defp build_permission_response_public(:deny) do
    %{behavior: "deny", message: "Permission denied", interrupt: false}
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

    # Extract permission handler from opts (if provided)
    {permission_handler, bridge_opts} = extract_permission_handler(opts)

    command =
      case prompt do
        %{content: content} when is_list(content) ->
          %{
            type: "chat",
            id: inspect(ref),
            content: content,
            options: bridge_opts
          }

        prompt when is_binary(prompt) ->
          %{
            type: "chat",
            id: inspect(ref),
            prompt: prompt,
            options: bridge_opts
          }
      end

    send_command(state.port, command)
    pending = Map.put(state.pending, inspect(ref), {from, :chat, [], permission_handler})

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_cast({:chat_async, prompt, opts, caller, ref}, state) do
    # Extract permission handler from opts (if provided)
    {permission_handler, bridge_opts} = extract_permission_handler(opts)

    command =
      case prompt do
        %{content: content} when is_list(content) ->
          %{
            type: "chat",
            id: inspect(ref),
            content: content,
            options: bridge_opts
          }

        prompt when is_binary(prompt) ->
          %{
            type: "chat",
            id: inspect(ref),
            prompt: prompt,
            options: bridge_opts
          }
      end

    send_command(state.port, command)
    # Store as :chat_async to distinguish from sync chat
    pending = Map.put(state.pending, inspect(ref), {:chat_async, caller, ref, permission_handler})

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_cast({:stream, prompt, opts, callback, caller, ref}, state) do
    # Extract permission handler from opts (if provided)
    {permission_handler, bridge_opts} = extract_permission_handler(opts)

    command =
      case prompt do
        %{content: content} when is_list(content) ->
          %{
            type: "stream",
            id: inspect(ref),
            content: content,
            options: bridge_opts
          }

        prompt when is_binary(prompt) ->
          %{
            type: "stream",
            id: inspect(ref),
            prompt: prompt,
            options: bridge_opts
          }
      end

    send_command(state.port, command)
    # Store caller pid and ref for activity signaling and completion notification
    pending = Map.put(state.pending, inspect(ref), {:stream, callback, caller, ref, permission_handler})

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
  def handle_cast({:abort, request_id}, state) do
    # Convert reference to string if needed (to match how we store IDs)
    id =
      case request_id do
        ref when is_reference(ref) -> inspect(ref)
        str when is_binary(str) -> str
      end

    command = %{
      type: "abort",
      id: id
    }

    send_command(state.port, command)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:permission_response, request_id, response}, state) do
    command =
      Map.merge(
        %{
          type: "permission_response",
          requestId: request_id
        },
        response
      )

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
      {{from, :chat, _, _handler}, pending} ->
        GenServer.reply(from, {:ok, content})
        %{state | pending: pending}

      {{:chat_async, caller, ref, _handler}, pending} ->
        send(caller, {:chat_complete, ref, {:ok, content}})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "chunk", "content" => content}, state) do
    case Map.get(state.pending, id) do
      {:stream, callback, caller, ref, _handler} when is_function(callback) ->
        callback.(%{type: :chunk, content: content})
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      {:stream, pid, caller, ref, _handler} when is_pid(pid) ->
        send(pid, {:claude_chunk, content})
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      {from, :chat, chunks, handler} ->
        pending = Map.put(state.pending, id, {from, :chat, [content | chunks], handler})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "end"}, state) do
    case Map.pop(state.pending, id) do
      {{:stream, callback, caller, ref, _handler}, pending} when is_function(callback) ->
        callback.(%{type: :end})
        # Signal completion to the caller's receive loop
        send(caller, {:stream_complete, ref, :ok})
        %{state | pending: pending}

      {{:stream, pid, caller, ref, _handler}, pending} when is_pid(pid) ->
        send(pid, :claude_end)
        # Signal completion to the caller's receive loop
        send(caller, {:stream_complete, ref, :ok})
        %{state | pending: pending}

      {{from, :chat, chunks, _handler}, pending} ->
        content = chunks |> Enum.reverse() |> Enum.join("")
        GenServer.reply(from, {:ok, content})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "tool_use"} = msg, state) do
    case Map.get(state.pending, id) do
      {:stream, callback, caller, ref, _handler} when is_function(callback) ->
        callback.(ClaudeAgentSdkTs.Response.parse(msg))
        # Signal activity to reset the caller's timeout
        send(caller, {:stream_activity, ref})
        state

      {:stream, pid, caller, ref, _handler} when is_pid(pid) ->
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
      {{:stream, _callback, caller, ref, _handler}, pending} ->
        # Signal error to the caller's receive loop
        send(caller, {:stream_error, ref, message})
        %{state | pending: pending}

      {{from, :chat, _, _handler}, pending} ->
        GenServer.reply(from, {:error, message})
        %{state | pending: pending}

      {{:chat_async, caller, ref, _handler}, pending} ->
        send(caller, {:chat_error, ref, message})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "aborted"}, state) do
    case Map.pop(state.pending, id) do
      {{:stream, callback, caller, ref, _handler}, pending} when is_function(callback) ->
        # Notify via callback
        callback.(%{type: :aborted})
        # Signal abort to the caller's receive loop
        send(caller, {:stream_aborted, ref})
        %{state | pending: pending}

      {{:stream, pid, caller, ref, _handler}, pending} when is_pid(pid) ->
        send(pid, :claude_aborted)
        send(caller, {:stream_aborted, ref})
        %{state | pending: pending}

      {{from, :chat, _, _handler}, pending} ->
        GenServer.reply(from, {:error, :aborted})
        %{state | pending: pending}

      {{:chat_async, caller, ref, _handler}, pending} ->
        send(caller, {:chat_aborted, ref})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_message(%{"id" => id, "type" => "abort_ack"}, state) do
    # Acknowledgment that abort was processed (request may have already completed)
    Logger.debug("[PortBridge] Abort acknowledged for #{id}")
    state
  end

  defp handle_message(
         %{
           "id" => id,
           "type" => "permission_request",
           "requestId" => request_id,
           "toolName" => tool_name,
           "toolInput" => tool_input
         } = msg,
         state
       ) do
    # Get the permission handler from pending state (last element of tuple)
    permission_handler =
      case Map.get(state.pending, id) do
        {:stream, _callback, _caller, _ref, handler} when is_function(handler) -> handler
        {_from, :chat, _chunks, handler} when is_function(handler) -> handler
        _ -> nil
      end

    if permission_handler do
      # Build options map matching the TypeScript SDK signature
      # Include request_id so handlers can return :pending and respond later
      opts = %{
        request_id: request_id,
        suggestions: msg["suggestions"] || [],
        blocked_path: msg["blockedPath"],
        decision_reason: msg["decisionReason"],
        tool_use_id: msg["toolUseId"],
        agent_id: msg["agentId"]
      }

      # Spawn a task to handle the permission callback asynchronously
      # This prevents blocking the GenServer
      Task.start(fn ->
        try do
          result = permission_handler.(tool_name, tool_input, opts)

          # Handle :pending - the handler will call respond_to_permission later
          case result do
            :pending ->
              Logger.debug("[PortBridge] Permission handler returned :pending for #{request_id}")
              :ok

            _ ->
              response = build_permission_response(result)
              send_permission_response(request_id, response)
          end
        rescue
          e ->
            Logger.error("[PortBridge] Permission handler error: #{inspect(e)}")

            send_permission_response(request_id, %{
              behavior: "deny",
              message: "Permission handler error: #{inspect(e)}",
              interrupt: true
            })
        end
      end)
    else
      # No permission handler - deny by default
      Logger.warning("[PortBridge] No permission handler for request #{request_id}")

      send_permission_response(request_id, %{
        behavior: "deny",
        message: "No permission handler configured",
        interrupt: true
      })
    end

    state
  end

  defp handle_message(_msg, state), do: state

  # Convert Elixir permission result to bridge format
  defp build_permission_response({:allow, updated_input}) do
    %{behavior: "allow", updatedInput: updated_input}
  end

  defp build_permission_response({:allow, updated_input, updated_permissions}) do
    %{behavior: "allow", updatedInput: updated_input, updatedPermissions: updated_permissions}
  end

  defp build_permission_response(:allow) do
    %{behavior: "allow", updatedInput: %{}}
  end

  defp build_permission_response({:deny, message}) do
    %{behavior: "deny", message: message, interrupt: false}
  end

  defp build_permission_response({:deny, message, opts}) do
    %{
      behavior: "deny",
      message: message,
      interrupt: Keyword.get(opts, :interrupt, false)
    }
  end

  defp build_permission_response(:deny) do
    %{behavior: "deny", message: "Permission denied", interrupt: false}
  end

  # Extract can_use_tool handler from opts and prepare bridge options
  defp extract_permission_handler(opts) when is_map(opts) do
    {handler, rest} = Map.pop(opts, :can_use_tool)

    bridge_opts =
      if is_function(handler) do
        Map.put(rest, :interactivePermissions, true)
      else
        rest
      end

    {handler, bridge_opts}
  end

  defp extract_permission_handler(opts), do: {nil, opts}
end
