defmodule ClaudeAgent do
  @moduledoc """
  Elixir wrapper around the official TypeScript Claude Agent SDK.

  Provides a native Elixir interface for interacting with Claude via AWS Bedrock,
  with support for streaming responses, sessions, and custom tools.

  ## Quick Start

      # Simple chat
      {:ok, response} = ClaudeAgent.chat("What is the capital of France?")

      # With options
      {:ok, response} = ClaudeAgent.chat("Explain quantum computing",
        model: "claude-sonnet-4-20250514",
        max_tokens: 2000
      )

      # Streaming with callback
      ClaudeAgent.stream("Write a haiku about Elixir", fn
        %{type: :chunk, content: text} -> IO.write(text)
        %{type: :end} -> IO.puts("\\n---Done---")
      end)

      # Streaming to an Elixir Stream
      ClaudeAgent.stream!("Tell me a story")
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  ## Configuration

  Configure in your `config.exs`:

      config :claude_agent,
        model: "claude-sonnet-4-20250514",
        use_bedrock: true,
        aws_profile: "default",
        aws_region: "us-east-1",
        max_tokens: 4096,
        timeout: 300_000

  Or pass options directly to function calls.

  ## Tools

  Define custom tools that Claude can invoke:

      tool = %ClaudeAgent.Tool{
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

      ClaudeAgent.chat("What is 42 * 17?", tools: [tool])
  """

  alias ClaudeAgent.{Config, PortBridge, Response, Tool}

  @type chat_opts :: [
          model: String.t(),
          max_tokens: pos_integer(),
          system_prompt: String.t(),
          timeout: pos_integer(),
          tools: [Tool.t()],
          cwd: String.t()
        ]

  @type stream_callback :: (Response.t() | map() -> any())

  @doc """
  Sends a chat message to Claude and waits for the complete response.

  ## Options

    * `:model` - The Claude model to use
    * `:max_tokens` - Maximum tokens in the response
    * `:system_prompt` - System prompt to set context
    * `:timeout` - Request timeout in milliseconds (default: 300_000)
    * `:tools` - List of `ClaudeAgent.Tool` structs Claude can invoke
    * `:cwd` - Working directory for file operations

  ## Examples

      {:ok, response} = ClaudeAgent.chat("Hello!")
      {:ok, response} = ClaudeAgent.chat("Explain OTP", model: "claude-sonnet-4-20250514")
  """
  @spec chat(String.t(), chat_opts()) :: {:ok, String.t()} | {:error, term()}
  def chat(prompt, opts \\ []) do
    config = Config.new(opts)
    bridge_opts = Config.to_bridge_opts(config)

    # Add tool definitions if provided
    bridge_opts =
      case Keyword.get(opts, :tools) do
        nil -> bridge_opts
        tools -> Map.put(bridge_opts, "tools", Enum.map(tools, &Tool.to_definition/1))
      end

    PortBridge.chat(prompt, bridge_opts)
  end

  @doc """
  Same as `chat/2` but raises on error.
  """
  @spec chat!(String.t(), chat_opts()) :: String.t()
  def chat!(prompt, opts \\ []) do
    case chat(prompt, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise "ClaudeAgent.chat failed: #{inspect(reason)}"
    end
  end

  @doc """
  Sends a chat message to Claude and streams the response via a callback function.

  The callback receives maps with `:type` and `:content` keys:

    * `%{type: :chunk, content: "text"}` - A chunk of the response
    * `%{type: :tool_use, ...}` - Claude wants to use a tool
    * `%{type: :end}` - Stream has ended

  ## Examples

      ClaudeAgent.stream("Write a poem", fn
        %{type: :chunk, content: text} -> IO.write(text)
        %{type: :end} -> IO.puts("")
        _ -> :ok
      end)
  """
  @spec stream(String.t(), chat_opts(), stream_callback()) :: :ok | {:error, term()}
  def stream(prompt, opts \\ [], callback) when is_function(callback, 1) do
    config = Config.new(opts)
    bridge_opts = Config.to_bridge_opts(config)

    PortBridge.stream(prompt, bridge_opts, callback)
  end

  @doc """
  Sends a chat message and returns an Elixir Stream of response chunks.

  ## Examples

      ClaudeAgent.stream!("Tell me about Erlang")
      |> Enum.each(&IO.write/1)
  """
  @spec stream!(String.t(), chat_opts()) :: Enumerable.t()
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

      {:ok, session} = ClaudeAgent.start_session()
      {:ok, response1} = ClaudeAgent.Session.chat(session, "My name is Alice")
      {:ok, response2} = ClaudeAgent.Session.chat(session, "What's my name?")
      # response2 will know the name is Alice
  """
  @spec start_session(chat_opts()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    ClaudeAgent.Session.start_link(opts)
  end
end
