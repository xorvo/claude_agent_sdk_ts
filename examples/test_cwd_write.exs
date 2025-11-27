# Example: Test that cwd option works for file creation
#
# Run with: mix run examples/test_cwd_write.exs

IO.puts("=== Testing cwd option with file creation ===\n")

# Create a tmp directory if it doesn't exist
tmp_dir = Path.join(File.cwd!(), "tmp")
File.mkdir_p!(tmp_dir)

IO.puts("Setting cwd to: #{tmp_dir}\n")

result = ClaudeAgent.chat(
  "Create a file called hello.txt in the current directory with the content 'Hello from Claude!'. Then create another file called test.json with a simple JSON object containing your name. Finally, list the files you created.",
  cwd: tmp_dir,
  max_turns: 5
)

case result do
  {:ok, response} ->
    IO.puts("Response:\n#{response}\n")

    # Verify the files were created
    IO.puts("=== Verifying files in #{tmp_dir} ===")
    case File.ls(tmp_dir) do
      {:ok, files} ->
        IO.puts("Files found: #{inspect(files)}")

        # Show contents of created files
        Enum.each(files, fn file ->
          path = Path.join(tmp_dir, file)
          case File.read(path) do
            {:ok, content} ->
              IO.puts("\n--- #{file} ---")
              IO.puts(content)
            {:error, reason} ->
              IO.puts("Could not read #{file}: #{inspect(reason)}")
          end
        end)
      {:error, reason} ->
        IO.puts("Could not list directory: #{inspect(reason)}")
    end

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end
