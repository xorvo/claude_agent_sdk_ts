defmodule Mix.Compilers.NodeDeps do
  @moduledoc false

  # Custom compiler that ensures Node.js dependencies are installed
  # This runs as part of the compilation process

  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    node_bridge_path = node_bridge_path()
    node_modules_path = Path.join(node_bridge_path, "node_modules")
    dist_path = Path.join(node_bridge_path, "dist")

    cond do
      # If node_modules doesn't exist, we need to install
      not File.exists?(node_modules_path) ->
        Mix.shell().info("Node modules not found, running node.install...")
        Mix.Task.run("node.install")
        {:ok, []}

      # If dist doesn't exist, we need to build
      not File.exists?(dist_path) ->
        Mix.shell().info("TypeScript build not found, running node.install...")
        Mix.Task.run("node.install")
        {:ok, []}

      # Check if source files are newer than built files
      needs_rebuild?(node_bridge_path) ->
        Mix.shell().info("TypeScript sources changed, rebuilding...")
        rebuild(node_bridge_path)
        {:ok, []}

      true ->
        {:noop, []}
    end
  end

  defp node_bridge_path do
    case :code.priv_dir(:claude_agent) do
      {:error, :bad_name} ->
        Path.join([File.cwd!(), "priv", "node_bridge"])

      priv_dir ->
        Path.join(to_string(priv_dir), "node_bridge")
    end
  end

  defp needs_rebuild?(node_bridge_path) do
    src_path = Path.join(node_bridge_path, "src")
    dist_path = Path.join(node_bridge_path, "dist")

    if File.exists?(src_path) and File.exists?(dist_path) do
      src_mtime = get_latest_mtime(src_path, "*.ts")
      dist_mtime = get_latest_mtime(dist_path, "*.js")

      src_mtime && dist_mtime && src_mtime > dist_mtime
    else
      false
    end
  end

  defp get_latest_mtime(dir, pattern) do
    dir
    |> Path.join("**/" <> pattern)
    |> Path.wildcard()
    |> Enum.map(&File.stat!(&1).mtime)
    |> Enum.max(fn -> nil end)
  end

  defp rebuild(node_bridge_path) do
    case System.cmd("npm", ["run", "build"], cd: node_bridge_path, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("✓ TypeScript bridge rebuilt")

      {output, code} ->
        Mix.shell().error("TypeScript rebuild failed (exit code #{code}):\n#{output}")
    end
  end
end
