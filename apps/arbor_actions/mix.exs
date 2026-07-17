Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Actions.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_actions,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support/]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Actions.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_common, in_umbrella: true},
      {:arbor_contracts, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_signals, in_umbrella: true},
      {:arbor_trust, in_umbrella: true},
      {:arbor_shell, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},
      # L2 — public LLM eval-subject catalog (`Arbor.LLM.eval_subject/1`).
      # Legal: actions (L6) may depend only downward.
      {:arbor_llm, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_sandbox, in_umbrella: true},
      {:arbor_historian, in_umbrella: true},
      {:arbor_consensus, in_umbrella: true},
      # L4 — public HITL facade (`Arbor.Comms.await_interaction_response/3`).
      # Legal: actions (L6) may depend on lower levels only.
      {:arbor_comms, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      # jido_action version pinned in root mix.exs
      {:jido_action, "~> 2.0", override: true},
      {:jido_browser, "~> 1.0"},
      {:zoi, "~> 0.17"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
