defmodule Arbor.Agent.Application do
  @moduledoc false

  use Application

  @task_control_recovery_store :arbor_agent_task_control_recovery
  @template_authority_reconciliation_store :arbor_agent_template_authority_reconciliation

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_agent, :start_children, true) do
        profile_backend = profile_backend()

        [
          # Process groups for cluster-wide agent discovery
          %{id: :arbor_agents_pg, start: {:pg, :start_link, [:arbor_agents]}},
          # Registries (must start before supervisors that use them)
          {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.MonitorLoopRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.ActionCycleRegistry},
          {Registry, keys: :unique, name: Arbor.Agent.MaintenanceRegistry},
          # Runtime-admission intent owners (Phase 4C C3C1a0). Registry + supervisor
          # must start before TaskStore so restart inventory can rebind live owners.
          {Registry, keys: :unique, name: Arbor.Agent.RuntimeAdmissionRegistry},
          Arbor.Agent.RuntimeAdmission.Supervisor,
          # Profile store (must start before lifecycle operations)
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: :arbor_agent_profiles,
             backend: profile_backend,
             backend_opts: [repo: Arbor.Persistence.Repo],
             write_mode: :sync,
             ack_mode: profile_ack_mode(profile_backend),
             collection: "agent_profiles"},
            id: :arbor_agent_profiles
          ),
          # User config store (per-user settings, API keys, preferences)
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: :arbor_user_config,
             backend: profile_backend(),
             backend_opts: [repo: Arbor.Persistence.Repo],
             write_mode: :sync,
             collection: "user_config"},
            id: :arbor_user_config
          ),
          # Named processes
          Arbor.Agent.Registry,
          Arbor.Agent.SummaryCache,
          Arbor.Agent.Fitness,
          Arbor.Agent.SessionManager,
          {Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor},
          # Durable task-control recovery markers (capability-ID-free). Must start
          # before TaskStore so startup replay can list/ack through the facade.
          # write_mode: :sync + ack_mode: :backend only — never cache-only.
          # recovery_backend!/0 fails closed when no durable backend is configured.
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: @task_control_recovery_store,
             backend: recovery_backend!(),
             backend_opts: [repo: Arbor.Persistence.Repo],
             write_mode: :sync,
             ack_mode: :backend,
             collection: "task_control_recovery"},
            id: :arbor_agent_task_control_recovery
          ),
          # Durable template-authority reconciliation operation records
          # (Phase 4C C1B). One Record slot per target_agent_id, fenced on
          # structured generation+revision. Must start before TaskStore so C2/C3
          # startup seeding can read the outstanding inventory. write_mode: :sync
          # + ack_mode: :backend only — never cache-only.
          # reconciliation_backend!/0 fails closed unless the backend attests
          # :node_restart.
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: @template_authority_reconciliation_store,
             backend: reconciliation_backend!(),
             backend_opts: [repo: Arbor.Persistence.Repo],
             write_mode: :sync,
             ack_mode: :backend,
             collection: "template_authority_reconciliation"},
            id: :arbor_agent_template_authority_reconciliation
          ),
          Arbor.Agent.Orchestration.TaskStore,
          # Dynamic supervisors (Phase 3: three-loop architecture)
          Arbor.Agent.ActionCycleSupervisor,
          Arbor.Agent.MaintenanceSupervisor,
          # Agent supervisors (global + per-user)
          Arbor.Agent.Supervisor,
          Arbor.Agent.UserSupervisor,
          # Bootstrap (self-defers via Process.send_after, must be after Supervisor)
          Arbor.Agent.Bootstrap,
          # Reconciler — Bootstrap's continuous generalization (periodic
          # desired-vs-actual reconcile: reap identity-gone zombies, restart
          # absent auto_start agents). Self-defers via Process.send_after.
          Arbor.Agent.Reconciler
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Agent.AppSupervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        schedule_json_migration()
        schedule_template_seeding()
        {:ok, pid}

      error ->
        error
    end
  end

  # Migrate legacy JSON profiles into the BufferedStore after a short delay.
  # This avoids slowing down startup and ensures the store is ready.
  defp schedule_json_migration do
    Task.start(fn ->
      Process.sleep(1_000)

      try do
        Arbor.Agent.ProfileStore.migrate_json_profiles()
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Builtins ship as `.md` files in priv/templates/ (data-first migration), so
  # there is nothing to seed at boot. We still warm the ETS cache from the
  # shipped/user/legacy layers so the first resolve doesn't pay the disk cost.
  defp schedule_template_seeding do
    Task.start(fn ->
      Process.sleep(500)

      try do
        Arbor.Agent.TemplateStore.reload()
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp profile_backend do
    Application.get_env(:arbor_agent, :profile_storage_backend, default_profile_backend())
  end

  defp default_profile_backend do
    Arbor.Persistence.QueryableStore.Postgres
  end

  defp profile_ack_mode(nil), do: :cache
  defp profile_ack_mode(_backend), do: :backend

  # Recovery markers protect authority: never start with cache-only/unbacked storage.
  defp recovery_backend! do
    backend =
      Application.get_env(
        :arbor_agent,
        :task_control_recovery_backend,
        profile_backend()
      )

    case backend do
      nil ->
        raise ArgumentError,
              "task-control recovery store requires a durable backend " <>
                "(ack_mode: :backend); cache-only/unbacked storage is forbidden"

      backend ->
        case Arbor.Persistence.durability_class(
               @task_control_recovery_store,
               backend,
               repo: Arbor.Persistence.Repo
             ) do
          {:ok, :node_restart} ->
            backend

          {:ok, class} ->
            raise ArgumentError,
                  "task-control recovery backend is not crash-durable: #{inspect(class)}"

          {:error, reason} ->
            raise ArgumentError,
                  "task-control recovery backend cannot attest durability: #{inspect(reason)}"
        end
    end
  end

  # Template-authority reconciliation operations protect authority: never start
  # with cache-only/unbacked/non-node-restart storage. Same fail-closed
  # attestation contract as recovery_backend!/0 — the backend module must
  # attest :node_restart before the supervised BufferedStore is allowed to start.
  #
  # Startup errors are generic and redacted: they never inspect or interpolate
  # backend classes, reasons, records, or exception text (mirrors the bounded
  # redaction contract of Arbor.Agent.TemplateAuthorityReconciliationStore).
  defp reconciliation_backend! do
    backend =
      Application.get_env(
        :arbor_agent,
        :template_authority_reconciliation_backend,
        profile_backend()
      )

    case backend do
      nil ->
        raise ArgumentError, generic_reconciliation_startup_error()

      backend ->
        case Arbor.Persistence.durability_class(
               @template_authority_reconciliation_store,
               backend,
               repo: Arbor.Persistence.Repo
             ) do
          {:ok, :node_restart} ->
            backend

          {:ok, _not_crash_durable} ->
            raise ArgumentError, generic_reconciliation_startup_error()

          {:error, _reason} ->
            raise ArgumentError, generic_reconciliation_startup_error()
        end
    end
  end

  # Single constant message — no backend class, reason, record, or exception
  # text is ever interpolated into a reconciliation-durability startup error.
  defp generic_reconciliation_startup_error do
    "template-authority reconciliation store requires an attested node_restart backend"
  end
end
