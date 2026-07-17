Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Sandbox.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_sandbox,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Sandbox.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:dune, "~> 0.3.15"},
      # Pinned to an immutable ref (not branch: main) — see root mix.exs.
      {:jido_sandbox,
       git: "https://github.com/agentjido/jido_sandbox.git",
       ref: "7fc90881d3c8ca49e769413cc8217344f2b4c29a",
       override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
