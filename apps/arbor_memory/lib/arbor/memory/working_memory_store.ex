defmodule Arbor.Memory.WorkingMemoryStore do
  @moduledoc """
  ETS-backed storage for working memory with durable persistence and signal emission.

  Stateless module (not a GenServer) — the ETS table is created in
  `Application.start/2`. Handles ETS CRUD + MemoryStore persistence + signals.
  """

  alias Arbor.Memory.{MemoryStore, Signals, WorkingMemory}

  require Logger

  @working_memory_ets :arbor_working_memory

  @doc """
  Get working memory for an agent.

  Returns the current working memory or nil if not set.
  """
  @spec get_working_memory(String.t()) :: WorkingMemory.t() | nil
  def get_working_memory(agent_id) do
    case :ets.lookup(@working_memory_ets, agent_id) do
      [{^agent_id, wm}] -> wm
      [] -> nil
    end
  end

  @doc """
  Save working memory for an agent.

  Stores in ETS, persists async to Postgres, and emits signal.
  """
  @spec save_working_memory(String.t(), WorkingMemory.t()) :: :ok
  def save_working_memory(agent_id, working_memory) do
    :ets.insert(@working_memory_ets, {agent_id, working_memory})
    MemoryStore.persist_async("working_memory", agent_id, WorkingMemory.serialize(working_memory))
    Signals.emit_working_memory_saved(agent_id, WorkingMemory.stats(working_memory))
    :ok
  end

  @doc """
  Load working memory for an agent.

  Returns existing working memory or creates a new one if none exists.
  This is the primary entry point for session startup.
  """
  @spec load_working_memory(String.t(), keyword()) :: WorkingMemory.t()
  def load_working_memory(agent_id, opts \\ []) do
    case get_working_memory(agent_id) do
      nil ->
        # Try loading from Postgres before creating fresh
        case load_from_postgres(agent_id) do
          {:ok, wm} ->
            :ets.insert(@working_memory_ets, {agent_id, wm})
            Signals.emit_working_memory_loaded(agent_id, :restored)
            wm

          :not_found ->
            wm = WorkingMemory.new(agent_id, opts)
            save_working_memory(agent_id, wm)
            Signals.emit_working_memory_loaded(agent_id, :created)
            wm
        end

      wm ->
        # Don't emit signal on reads — only on creation.
        # Emitting here caused a feedback loop: MemoryLive subscribes to memory.*,
        # reloads tab data on any signal, which calls load_working_memory, which
        # emitted another signal → infinite loop at 131K signals/sec.
        wm
    end
  end

  @doc """
  Delete working memory for an agent.

  Called during cleanup.
  """
  @spec delete_working_memory(String.t()) :: :ok
  def delete_working_memory(agent_id) do
    :ets.delete(@working_memory_ets, agent_id)
    MemoryStore.delete("working_memory", agent_id)
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp load_from_postgres(agent_id) do
    case MemoryStore.load("working_memory", agent_id) do
      {:ok, data} when is_map(data) ->
        wm = WorkingMemory.deserialize(data)
        {:ok, wm}

      _ ->
        :not_found
    end
  rescue
    e ->
      Logger.warning("Failed to load working memory from Postgres for #{agent_id}: #{inspect(e)}")
      :not_found
  end
end
