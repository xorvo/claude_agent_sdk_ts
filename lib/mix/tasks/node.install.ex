defmodule Mix.Tasks.Node.Install do
  @moduledoc """
  Installs Node.js dependencies for the ClaudeAgent bridge.

  This task runs automatically after `mix deps.get` and can also be run manually.

  ## Usage

      mix node.install

  ## Requirements

  - Node.js >= 18.0.0
  - npm or yarn
  """

  use Mix.Task

  @shortdoc "Installs Node.js dependencies for ClaudeAgent"

  @impl Mix.Task
  def run(_args) do
    node_bridge_path = node_bridge_path()

    Mix.shell().info("Installing Node.js dependencies for ClaudeAgent...")

    # Check Node.js is available
    case System.cmd("node", ["--version"], stderr_to_stdout: true) do
      {version, 0} ->
        Mix.shell().info("Found Node.js #{String.trim(version)}")

      {_, _} ->
        Mix.raise("Node.js is required but not found. Please install Node.js >= 18.0.0")
    end

    # Install npm dependencies
    Mix.shell().info("Running npm install in #{node_bridge_path}...")

    case System.cmd("npm", ["install"], cd: node_bridge_path, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.shell().info("✓ npm dependencies installed")

      {output, code} ->
        Mix.raise("npm install failed with exit code #{code}:\n#{output}")
    end

    # Build TypeScript
    Mix.shell().info("Building TypeScript bridge...")

    case System.cmd("npm", ["run", "build"], cd: node_bridge_path, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.shell().info("✓ TypeScript bridge built successfully")

      {output, code} ->
        Mix.raise("TypeScript build failed with exit code #{code}:\n#{output}")
    end

    Mix.shell().info("✓ ClaudeAgent Node.js bridge is ready!")
  end

  defp node_bridge_path do
    # During development, use the local priv directory
    # After compilation, use :code.priv_dir
    case :code.priv_dir(:claude_agent) do
      {:error, :bad_name} ->
        Path.join([File.cwd!(), "priv", "node_bridge"])

      priv_dir ->
        Path.join(to_string(priv_dir), "node_bridge")
    end
  end
end
