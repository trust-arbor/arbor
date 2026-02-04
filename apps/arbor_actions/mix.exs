defmodule Arbor.Actions.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_actions,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support/]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Actions.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_common, in_umbrella: true},
      {:arbor_contracts, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_sandbox, in_umbrella: true},
      {:arbor_historian, in_umbrella: true},
      {:arbor_consensus, in_umbrella: true},
      {:jido_action, path: "../../../jido_action", override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
