defmodule ClaudeAgentSdkTs.Tool do
  @moduledoc """
  Defines a tool that Claude can invoke during a conversation.

  Tools allow Claude to perform actions in your Elixir application,
  such as querying databases, calling APIs, or performing calculations.

  ## Example

      weather_tool = %ClaudeAgentSdkTs.Tool{
        name: "get_weather",
        description: "Get the current weather for a given city",
        parameters: %{
          type: "object",
          properties: %{
            city: %{type: "string", description: "The city name"},
            unit: %{type: "string", enum: ["celsius", "fahrenheit"], default: "celsius"}
          },
          required: ["city"]
        },
        handler: fn params ->
          city = params["city"]
          unit = params["unit"] || "celsius"
          {:ok, WeatherAPI.get_weather(city, unit)}
        end
      }

      ClaudeAgentSdkTs.chat("What's the weather in Tokyo?", tools: [weather_tool])
  """

  @type handler :: (map() -> {:ok, any()} | {:error, String.t()})

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          handler: handler()
        }

  @enforce_keys [:name, :description, :handler]
  defstruct [
    :name,
    :description,
    :handler,
    parameters: %{type: "object", properties: %{}, required: []}
  ]

  @doc """
  Creates a new tool with the given attributes.
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Converts a tool to a JSON-serializable map for the Node bridge.
  The handler is not included as it stays in Elixir.
  """
  @spec to_definition(t()) :: map()
  def to_definition(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end

  @doc """
  Executes a tool's handler with the given parameters.
  """
  @spec execute(t(), map()) :: {:ok, any()} | {:error, String.t()}
  def execute(%__MODULE__{handler: handler}, params) when is_function(handler, 1) do
    try do
      case handler.(params) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        result -> {:ok, result}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
