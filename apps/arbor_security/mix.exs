defmodule ArborSecurity.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_security,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Security.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_common, in_umbrella: true},
      {:arbor_contracts, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Arbor.Security",
      extras: ["README.md"]
    ]
  end
end
