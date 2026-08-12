defmodule Arbor.Memory.Application do
  @moduledoc false

  use Application

  @graph_ets :arbor_memory_graphs
  @working_memory_ets :arbor_working_memory
  @preferences_ets :arbor_preferences

  @impl true
  def start(_type, _args) do
    with {:ok, _fingerprint} <-
           Arbor.Memory.MutationAdmission.RuntimeIdentity.bootstrap() do
      children =
        if Application.get_env(:arbor_memory, :start_children, true) do
          # Create ETS tables eagerly to avoid race conditions.
          # Tables must be owned by a long-lived process (the Application starter),
          # not by transient test or request processes.
          # Note: :arbor_memory_proposals is intentionally not created — proposal
          # authority is the supervised Proposal.Store process map.
          ensure_ets(@graph_ets)
          ensure_ets(@working_memory_ets)
          ensure_ets(@preferences_ets)

          [
            {Arbor.Persistence.BufferedStore,
             name: :arbor_memory_durable,
             backend: Application.get_env(:arbor_memory, :persistence_backend),
             write_mode: :async},
            {Registry, keys: :unique, name: Arbor.Memory.Registry},
            {Registry, keys: :unique, name: Arbor.Memory.MutationAdmission.Registry},
            {Arbor.Memory.MutationAdmission.GuardianSupervisor, []},
            {Arbor.Memory.MutationAdmission, []},
            {Arbor.Memory.AsyncWriter.Supervisor, []},
            {Arbor.Memory.ArchiveCursorSigner, []},
            {Arbor.Memory.Provenance, []},
            {Arbor.Memory.Proposal.Store, []},
            {Arbor.Memory.KnowledgeGraphStore, []},
            {Arbor.Memory.IndexSupervisor, []},
            {Arbor.Persistence.EventLog.ETS, name: :memory_events},
            # Seed/Host Phase 3 stores
            {Arbor.Memory.GoalStore, []},
            {Arbor.Memory.IntentStore, []},
            {Arbor.Memory.Thinking, []},
            {Arbor.Memory.CodeStore, []},
            {Arbor.Memory.DistributedSync, []}
          ]
        else
          []
        end

      opts = [strategy: :one_for_one, name: Arbor.Memory.Supervisor]
      result = Supervisor.start_link(children, opts)

      # Restore persisted preferences into ETS after supervisor is up
      # (needs BufferedStore / MemoryStore running)
      if Application.get_env(:arbor_memory, :start_children, true) do
        Arbor.Memory.PreferencesStore.restore_from_store()
      end

      result
    end
  end

  defp ensure_ets(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end
end
