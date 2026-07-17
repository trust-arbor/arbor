Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborAgent.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_agent,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support/]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Agent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      {:arbor_trust, in_umbrella: true},
      {:arbor_monitor, in_umbrella: true},
      {:arbor_consensus, in_umbrella: true},
      {:arbor_historian, in_umbrella: true},
      {:arbor_actions, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_llm, in_umbrella: true},
      {:yaml_elixir, "~> 2.0"},
      {:jido, override: true},
      {:jido_action, override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
