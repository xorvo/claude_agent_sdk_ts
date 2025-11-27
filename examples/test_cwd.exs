# Example: Test that cwd option works
#
# Run with: mix run examples/test_cwd.exs

IO.puts("=== Testing cwd option ===\n")

# Set cwd to the project root and ask Claude to list files
project_root = File.cwd!()
IO.puts("Setting cwd to: #{project_root}\n")

result = ClaudeAgent.chat(
  "List the files in the current directory. Just give me a simple list, nothing else.",
  cwd: project_root,
  max_turns: 3
)

case result do
  {:ok, response} ->
    IO.puts("Response:\n#{response}")
  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end
