defmodule ClaudeAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Port bridge for Node.js communication
      ClaudeAgent.PortBridge,
      # Registry for named sessions
      {Registry, keys: :unique, name: ClaudeAgent.SessionRegistry},
      # Dynamic supervisor for session processes
      {DynamicSupervisor, strategy: :one_for_one, name: ClaudeAgent.SessionSupervisor}
    ]

    opts = [strategy: :one_for_one, name: ClaudeAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
