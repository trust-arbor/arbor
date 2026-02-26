defmodule Arbor.Orchestrator.MixProject do
  use Mix.Project

  @version "2.0.0-dev"

  def project do
    [
      app: :arbor_orchestrator,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Orchestrator.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:arbor_common, in_umbrella: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Spec-conformant orchestration runtime for autonomous workflows.
    """
  end

  defp docs do
    [
      main: "Arbor.Orchestrator",
      extras: ["README.md"]
    ]
  end
end
