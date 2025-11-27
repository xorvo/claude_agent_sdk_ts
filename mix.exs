defmodule ClaudeAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/horvohaoriwa/claude_agent"

  def project do
    [
      app: :claude_agent,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ClaudeAgent",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ClaudeAgent.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "deps.get": ["deps.get", "node.install"]
    ]
  end

  defp description do
    "Elixir wrapper around the official TypeScript Claude Agent SDK (@anthropic-ai/claude-agent-sdk)."
  end

  defp package do
    [
      name: "claude_agent",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib priv/node_bridge/package.json priv/node_bridge/src priv/node_bridge/tsconfig.json mix.exs README.md LICENSE)
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
