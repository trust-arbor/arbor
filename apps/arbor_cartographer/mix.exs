defmodule Arbor.Cartographer.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/arbor-framework/arbor_cartographer"

  def project do
    [
      app: :arbor_cartographer,
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
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Cartographer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella dependencies
      {:arbor_contracts, in_umbrella: true},

      # Core dependencies
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},

      # Mesh for capability-based routing (uncomment when ready)
      # {:mesh, github: "eigr/mesh"},

      # Note: arbor_security and arbor_signals integrations will be added
      # during implementation phase when those libraries are ready

      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp description do
    """
    Hardware capability-aware scheduling for distributed Arbor agents.
    Built on eigr/mesh for capability-based process routing.
    """
  end

  defp package do
    [
      name: "arbor_cartographer",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Arbor Framework Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Cartographer",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
