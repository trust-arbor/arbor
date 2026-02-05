defmodule Arbor.Dashboard.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :arbor_dashboard,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [threshold: 80]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Dashboard.Application, []},
      env: [start_children: Mix.env() != :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella dependencies (Level 0-1)
      {:arbor_contracts, in_umbrella: true},
      {:arbor_web, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},

      # Standalone
      {:arbor_eval, in_umbrella: true},

      # Phoenix stack (via arbor_web, but needed for endpoint)
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},

      # Dev/test
      {:tidewave, "~> 0.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:floki, "~> 0.37", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
