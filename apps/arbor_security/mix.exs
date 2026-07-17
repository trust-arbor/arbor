Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborSecurity.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_security,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
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
      {:telemetry, "~> 1.0"},
      {:plug_crypto, "~> 2.0"},
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.6"},
      {:req, "~> 0.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Arbor.Security",
      extras: ["README.md"]
    ]
  end
end
