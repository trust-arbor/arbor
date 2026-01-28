defmodule Arbor.Persistence.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :arbor_persistence,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Persistence.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.18"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "Arbor.Persistence",
      extras: ["README.md"]
    ]
  end
end
