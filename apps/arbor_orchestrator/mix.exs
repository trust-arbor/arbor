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
      {:telemetry, "~> 1.0"},
      # Level 0 shared types (contract-first). Already used pervasively
      # (Session.*, Security.{Taint,AuthContext,SignedRequest}, CapabilityDescriptor,
      # ...) — declared explicitly here instead of leaning on the transitive path
      # through arbor_signals. arbor_contracts has zero in-umbrella deps, so this
      # introduces no cycle.
      {:arbor_contracts, in_umbrella: true},
      {:arbor_common, in_umbrella: true},
      # arbor_actions is a hard dep: the orchestrator executes Jido actions
      # (syscalls) via Arbor.Actions directly. arbor_actions does NOT depend on
      # arbor_orchestrator (verified acyclic), and only arbor_commands +
      # arbor_dashboard depend on the orchestrator, so this introduces no cycle.
      {:arbor_actions, in_umbrella: true},
      # arbor_security/ai/memory/trust/shell are hard runtime deps, declared
      # explicitly here. The orchestrator authorizes capabilities and egress
      # (Arbor.Security), routes/calls LLMs and resolves ACP + backend trust
      # (Arbor.AI), reads agent goals/working-memory/percepts (Arbor.Memory),
      # reads trust policy (Arbor.Trust.Policy), and runs sandboxed shell
      # (Arbor.Shell). These were previously reached via Code.ensure_loaded?/
      # apply stale-avoidance bridges; converted to direct calls (2026-06-17).
      # None of these apps depend on arbor_orchestrator (verified acyclic —
      # only arbor_commands + arbor_dashboard depend on it; all five sit at a
      # lower hierarchy level), so this introduces no cycle.
      {:arbor_security, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      {:arbor_trust, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      {:arbor_llm, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
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
