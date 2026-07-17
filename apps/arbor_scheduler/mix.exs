Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Scheduler.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_scheduler,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Scheduler.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Umbrella deps
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_trust, in_umbrella: true},

      # Oban — PostgreSQL-backed durable job queue with cron support.
      # We use it as the scheduling substrate; the Arbor.Scheduler facade
      # is what the rest of the codebase calls.
      {:oban, "~> 2.23"},
      {:jason, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
