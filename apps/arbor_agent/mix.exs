Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule ArborAgent.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_agent,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r/test\/support/]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Agent.Application, []},
      env: [
        arbor_feature: Arbor.Agent.Feature,
        arbor_feature_metadata: %{
          id: :agent,
          requires: [:core],
          dependency_role: :fixed_host_prerequisite,
          contribution_scope: :direct_application_entrypoint,
          snapshot_required_keys: [:start_children],
          snapshot_conditional_required_keys: %{
            start_children: %{
              true => [
                :profile_backend,
                :user_config_backend,
                :recovery_backend,
                :recovery_durability,
                :reconciliation_backend,
                :reconciliation_durability,
                :system_lifecycle_token
              ],
              false => []
            }
          },
          public_child_ids: [
            :arbor_agents_pg,
            Arbor.Agent.ExecutorRegistry,
            Arbor.Agent.ReasoningLoopRegistry,
            Arbor.Agent.MonitorLoopRegistry,
            Arbor.Agent.ActionCycleRegistry,
            Arbor.Agent.MaintenanceRegistry,
            Arbor.Agent.RuntimeAdmissionRegistry,
            Arbor.Agent.RuntimeAdmission.Supervisor,
            :arbor_agent_profiles,
            Arbor.Agent.ProfileAuthorityOwner,
            :arbor_user_config,
            Arbor.Agent.Registry,
            Arbor.Agent.SummaryCache,
            Arbor.Agent.Fitness,
            Arbor.Agent.SessionManager,
            Arbor.Agent.Orchestration.TaskSupervisor,
            :arbor_agent_task_control_recovery,
            :arbor_agent_template_authority_reconciliation,
            Arbor.Agent.Orchestration.TaskStore,
            Arbor.Agent.Orchestration.LeaseGrantOwner,
            Arbor.Agent.ActionCycleSupervisor,
            Arbor.Agent.MaintenanceSupervisor,
            Arbor.Agent.Supervisor,
            Arbor.Agent.UserSupervisor,
            Arbor.Agent.SystemLifecycleAuthority,
            Arbor.Agent.Bootstrap,
            Arbor.Agent.Reconciler
          ],
          sources: %{
            application: Arbor.Agent.Application,
            action_catalog: :no_additional_direct_global_contribution_declared,
            uri_provider: :no_additional_direct_global_contribution_declared,
            startup_effects: [
              :identity_alias_resolver_registration,
              :lifecycle_reference_creation,
              :post_start_migration,
              :post_start_template_warmup
            ]
          }
        }
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_capabilities, "~> 0.1.0-dev",
       path: "../../packages/arbor_capabilities", runtime: false, env: Mix.env()},
      {:arbor_support, "~> 0.1.0-dev", path: "../../packages/arbor_support", env: Mix.env()},
      {:arbor_persistence, path: "../../packages/arbor_persistence", env: Mix.env()},
      {:arbor_persistence_sql, path: "../../packages/arbor_persistence_sql", env: Mix.env()},
      {:arbor_persistence_eventstore,
       path: "../../packages/arbor_persistence_eventstore", env: Mix.env()},
      {:arbor_signals, path: "../../packages/arbor_signals", runtime: false, env: Mix.env()},
      {:arbor_kernel_runtime, in_umbrella: true},
      {:arbor_security, in_umbrella: true},
      {:arbor_persistence_host, in_umbrella: true},
      # L4 public conversation admission/replay facade; Agent remains L7.
      {:arbor_comms, in_umbrella: true},
      {:arbor_memory, in_umbrella: true},
      {:arbor_trust, "~> 0.1.0",
       path: "../../packages/arbor_trust", runtime: false, env: Mix.env()},
      {:arbor_trust_host, in_umbrella: true},
      {:arbor_consensus, in_umbrella: true},
      {:arbor_historian, "~> 0.1.0",
       path: "../../packages/arbor_historian", runtime: false, env: Mix.env()},
      {:arbor_historian_host, in_umbrella: true},
      {:arbor_actions, in_umbrella: true},
      # L3 — public spawn-capable timeout ceiling for legacy coding envelope bounds.
      {:arbor_shell, in_umbrella: true},
      {:arbor_ai, in_umbrella: true},
      {:arbor_llm, "~> 0.1.0", path: "../../packages/arbor_llm", env: Mix.env()},
      {:yaml_elixir, "~> 2.0"},
      {:jido, override: true},
      {:jido_action, override: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
