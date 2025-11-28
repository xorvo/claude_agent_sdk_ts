defmodule ClaudeAgentSdkTs.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Install Node.js dependencies if not already installed
    case ClaudeAgentSdkTs.install() do
      :ok -> :ok
      {:error, msg} -> raise msg
    end

    children = [
      # Port bridge for Node.js communication
      ClaudeAgentSdkTs.PortBridge,
      # Registry for named sessions
      {Registry, keys: :unique, name: ClaudeAgentSdkTs.SessionRegistry},
      # Dynamic supervisor for session processes
      {DynamicSupervisor, strategy: :one_for_one, name: ClaudeAgentSdkTs.SessionSupervisor}
    ]

    opts = [strategy: :one_for_one, name: ClaudeAgentSdkTs.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
