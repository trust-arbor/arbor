defmodule ArborAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_ai,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.AI.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:jason, "~> 1.4"},
      # jido_ai and req_llm come from root mix.exs path deps
      {:jido_ai, path: "../../../jido_ai", override: true},
      {:req_llm, git: "https://github.com/agentjido/req_llm.git", branch: "main", override: true}
    ]
  end
end
