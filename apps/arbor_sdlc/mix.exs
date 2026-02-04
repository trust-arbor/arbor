defmodule Arbor.SDLC.MixProject do
  use Mix.Project

  @version "2.0.0-dev"

  def project do
    [
      app: :arbor_sdlc,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support/]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.SDLC.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Level 2 library - depends on contracts, flow, signals, ai, consensus, security, persistence
  defp deps do
    [
      # Level 0 - core dependencies
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_flow, in_umbrella: true},

      # Level 1 - infrastructure
      {:arbor_signals, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_consensus, in_umbrella: true},

      # Level 2 - AI integration
      {:arbor_ai, in_umbrella: true},

      # External deps
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    SDLC automation library for Arbor. Provides automated pipeline processing
    for roadmap items including expansion, deliberation via consensus council,
    and consistency checking.
    """
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
