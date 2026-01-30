defmodule Arbor.Historian.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_historian"

  def project do
    [
      app: :arbor_historian,
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
      test_coverage: [threshold: 90]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Historian.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_common, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4"},
      # Dev/test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Durable activity stream and audit log for the Arbor system.
    Bridges transient signals with permanent event storage, providing
    rich querying, timeline reconstruction, and causality tracing.
    """
  end

  defp package do
    [
      name: "arbor_historian",
      licenses: ["MIT"],
      links: %{"GitLab" => @source_url},
      maintainers: ["Trust Arbor Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Historian",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
