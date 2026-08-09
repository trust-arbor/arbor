defmodule Arbor.Agent.Application do
  @moduledoc false

  use Application

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
             name: :arbor_agent_task_control_recovery,
             backend: recovery_backend!(),
             backend_opts: [repo: Arbor.Persistence.Repo],
             write_mode: :sync,
             ack_mode: :backend,
             collection: "task_control_recovery"},
            id: :arbor_agent_task_control_recovery
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

    if is_nil(backend) do
      raise ArgumentError,
            "task-control recovery store requires a durable backend " <>
              "(ack_mode: :backend); cache-only/unbacked storage is forbidden"
    end

    backend
  end
end
