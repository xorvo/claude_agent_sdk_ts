defmodule ClaudeAgent.Response do
  @moduledoc """
  Represents a response from Claude.
  """

  @type message_type ::
          :text
          | :tool_use
          | :tool_result
          | :error
          | :end

  @type t :: %__MODULE__{
          type: message_type(),
          content: String.t() | nil,
          tool_name: String.t() | nil,
          tool_input: map() | nil,
          tool_use_id: String.t() | nil,
          error: String.t() | nil,
          raw: map() | nil
        }

  defstruct [
    :type,
    :content,
    :tool_name,
    :tool_input,
    :tool_use_id,
    :error,
    :raw
  ]

  @doc """
  Parses a JSON message from the Node bridge into a Response struct.
  """
  @spec parse(map()) :: t()
  def parse(%{"type" => "text", "content" => content} = raw) do
    %__MODULE__{type: :text, content: content, raw: raw}
  end

  def parse(%{"type" => "tool_use", "name" => name, "input" => input, "id" => id} = raw) do
    %__MODULE__{
      type: :tool_use,
      tool_name: name,
      tool_input: input,
      tool_use_id: id,
      raw: raw
    }
  end

  def parse(%{"type" => "tool_result"} = raw) do
    %__MODULE__{type: :tool_result, raw: raw}
  end

  def parse(%{"type" => "error", "message" => message} = raw) do
    %__MODULE__{type: :error, error: message, raw: raw}
  end

  def parse(%{"type" => "end"} = raw) do
    %__MODULE__{type: :end, raw: raw}
  end

  def parse(%{"type" => "chunk", "content" => content} = raw) do
    %__MODULE__{type: :text, content: content, raw: raw}
  end

  def parse(raw) when is_map(raw) do
    %__MODULE__{type: :text, content: raw["content"], raw: raw}
  end

  @doc """
  Returns true if this is the final response in a stream.
  """
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{type: :end}), do: true
  def final?(%__MODULE__{type: :error}), do: true
  def final?(_), do: false

  @doc """
  Returns true if this response requires tool execution.
  """
  @spec tool_use?(t()) :: boolean()
  def tool_use?(%__MODULE__{type: :tool_use}), do: true
  def tool_use?(_), do: false
end
