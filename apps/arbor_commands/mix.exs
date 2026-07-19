Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborCommands.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_commands,
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
      extra_applications: [:crypto, :logger],
      mod: {Arbor.Commands.Application, []}
    ]
  end

  # Level 2 — depends on arbor_orchestrator (Session) and arbor_agent
  # (Manager) for direct cross-library calls. arbor_common stays the
  # home of the command framework (Router, Intake, behaviour);
  # arbor_commands hosts the side-effecting Command implementations that
  # need to reach beyond Context.
  defp deps do
    [
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      {:arbor_agent, in_umbrella: true},
      {:arbor_orchestrator, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      # L1 signals facade — coding-benchmark approval accounting queries
      # interaction audit events by task correlation_id.
      {:arbor_signals, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
