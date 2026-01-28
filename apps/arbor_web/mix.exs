defmodule Arbor.Web.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/arbor-framework/arbor_web"

  def project do
    [
      app: :arbor_web,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella dependencies
      {:arbor_contracts, in_umbrella: true},

      # Phoenix stack
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.4"},

      # Telemetry
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},

      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:floki, "~> 0.37", only: :test}
    ]
  end

  defp description do
    """
    Phoenix LiveView foundation kit for Arbor dashboards.
    Provides shared components, theme system, layout macros, JS hooks,
    and endpoint/router boilerplate that individual apps compose on top of.
    """
  end

  defp package do
    [
      name: "arbor_web",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Arbor Framework Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Web",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
