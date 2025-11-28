defmodule ClaudeAgentSdkTs.MixProject do
  use Mix.Project

  @version "1.0.1"
  @source_url "https://github.com/xorvo/claude_agent_sdk_ts"

  def project do
    [
      app: :claude_agent_sdk_ts,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ClaudeAgentSdkTs",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ClaudeAgentSdkTs.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    []
  end

  defp description do
    "Elixir wrapper around the official TypeScript Claude Agent SDK (@anthropic-ai/claude-agent-sdk)."
  end

  defp package do
    [
      name: "claude_agent_sdk_ts",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files:
        ~w(lib priv/node_bridge/package.json priv/node_bridge/package-lock.json priv/node_bridge/dist mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
