# Example: Count to 5 with streaming
#
# Run with: mix run examples/count_to_5.exs

IO.puts("=== Streaming Example: Count to 5 ===\n")

ClaudeAgent.stream("Count to 5", [max_turns: 1], fn
  %{type: :chunk, content: text} ->
    IO.write(text)

  %{type: :end} ->
    IO.puts("\n\n=== Stream ended ===")

  other ->
    IO.puts("\n[Other message: #{inspect(other)}]")
end)
