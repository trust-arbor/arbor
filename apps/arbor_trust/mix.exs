defmodule Arbor.Trust.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/arbor-framework/arbor_trust"

  def project do
    [
      app: :arbor_trust,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Hex.pm metadata
      description: description(),
      package: package(),
      docs: docs(),
      # Testing
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        threshold: 90,
        ignore_modules: [
          Arbor.Trust.TestHelpers
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Trust.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella dependencies
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},

      # Core dependencies
      {:telemetry, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},

      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp description do
    """
    Progressive trust and reputation system for the Arbor framework.
    Manages agent trust profiles, scoring, decay, and capability synchronization.
    """
  end

  defp package do
    [
      name: "arbor_trust",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Arbor Framework Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Trust",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
