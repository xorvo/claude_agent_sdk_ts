defmodule Mix.Tasks.ClaudeAgentSdkTs.Install do
  @moduledoc """
  Installs Node.js dependencies for ClaudeAgentSdkTs.

  This task is called automatically when the application starts if dependencies
  are not already installed. You can also run it manually:

      mix claude_agent_sdk_ts.install

  ## Options

    * `--if-missing` - Only install if not already installed (default behavior)
    * `--force` - Force reinstallation even if already installed

  ## Requirements

  - Node.js >= 18.0.0
  - npm
  """

  use Mix.Task

  @shortdoc "Installs Node.js dependencies for ClaudeAgentSdkTs"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [force: :boolean, if_missing: :boolean])

    # Start required apps for HTTP/SSL if needed
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    # Check Node.js is available
    case System.cmd("node", ["--version"], stderr_to_stdout: true) do
      {version, 0} ->
        Mix.shell().info("Found Node.js #{String.trim(version)}")

      {_, _} ->
        Mix.raise("Node.js is required but not found. Please install Node.js >= 18.0.0")
    end

    force? = Keyword.get(opts, :force, false)
    if_missing? = Keyword.get(opts, :if_missing, false)

    if if_missing? and ClaudeAgentSdkTs.installed?() do
      Mix.shell().info("Node.js dependencies already installed")
    else
      if force? do
        Mix.shell().info("Force reinstalling Node.js dependencies...")
        ClaudeAgentSdkTs.install!(force: true)
      else
        case ClaudeAgentSdkTs.install() do
          :ok ->
            Mix.shell().info("Node.js dependencies installed successfully")

          {:error, msg} ->
            Mix.raise(msg)
        end
      end
    end

    deps_path = ClaudeAgentSdkTs.node_modules_path()
    Mix.shell().info("Dependencies installed to: #{deps_path}")
  end
end
