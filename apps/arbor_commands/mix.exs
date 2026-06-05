defmodule ArborCommands.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_commands,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
