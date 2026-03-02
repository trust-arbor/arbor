defmodule Arbor.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_agent, :start_children, true) do
        [
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
             backend: profile_backend(),
             backend_opts: [repo: Arbor.Persistence.Repo],
             write_mode: :sync,
             collection: "agent_profiles"},
            id: :arbor_agent_profiles
          ),
          # Named processes
          Arbor.Agent.Registry,
          Arbor.Agent.SummaryCache,
          Arbor.Agent.Fitness,
          Arbor.Agent.SessionManager,
          # Dynamic supervisors (Phase 3: three-loop architecture)
          Arbor.Agent.ActionCycleSupervisor,
          Arbor.Agent.MaintenanceSupervisor,
          # Agent supervisor
          Arbor.Agent.Supervisor,
          # Bootstrap (self-defers via Process.send_after, must be after Supervisor)
          Arbor.Agent.Bootstrap
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

  defp schedule_template_seeding do
    Task.start(fn ->
      Process.sleep(500)

      try do
        Arbor.Agent.TemplateStore.seed_builtins()
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
    if Code.ensure_loaded?(Arbor.Persistence.QueryableStore.Postgres) do
      Arbor.Persistence.QueryableStore.Postgres
    else
      nil
    end
  end
end
