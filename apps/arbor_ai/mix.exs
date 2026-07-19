Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborAi.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_ai,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
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
      {:arbor_common, in_umbrella: true},
      {:arbor_llm, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # jido_ai and req_llm versions pinned in root mix.exs
      {:jido_ai, "~> 2.0.0-rc.0", override: true},
      {:req_llm, "~> 1.6", override: true},
      {:ex_mcp, "1.0.0-rc.4", override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
