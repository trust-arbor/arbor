defmodule ArborComms.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_comms,
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
      mod: {Arbor.Comms.Application, []}
    ]
  end

  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Arbor.Comms",
      extras: ["README.md"]
    ]
  end
end
