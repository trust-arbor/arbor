defmodule Arbor.Memory.IndexSupervisor do
  @moduledoc """
  Dynamic supervisor for per-agent memory indexes.

  Manages the lifecycle of memory indexes, ensuring each agent gets its own
  isolated index. Indexes are started on demand and can be stopped when
  no longer needed.

  ## Features

  - Per-agent isolation via Registry
  - Dynamic supervision (indexes started/stopped at runtime)
  - Index lookup by agent_id

  ## Examples

      # Start an index for an agent
      {:ok, pid} = Arbor.Memory.IndexSupervisor.start_index("agent_001")

      # Get the index for an agent
      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index("agent_001")

      # Stop an agent's index
      :ok = Arbor.Memory.IndexSupervisor.stop_index("agent_001")
  """

  use DynamicSupervisor

  require Logger

  @doc """
  Start the IndexSupervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an index for an agent.

  If an index already exists for this agent, returns the existing pid.

  ## Options

  - `:max_entries` - Max entries before LRU eviction
  - `:threshold` - Default similarity threshold for recall

  ## Examples

      {:ok, pid} = Arbor.Memory.IndexSupervisor.start_index("agent_001")
      {:ok, pid} = Arbor.Memory.IndexSupervisor.start_index("agent_001", max_entries: 5000)
  """
  @spec start_index(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_index(agent_id, opts \\ []) do
    case get_index(agent_id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # Stale Registry entry — wait for cleanup and start fresh
          wait_for_registry_cleanup(agent_id)
          do_start_child(agent_id, opts)
        end

      {:error, :not_found} ->
        do_start_child(agent_id, opts)
    end
  end

  defp do_start_child(agent_id, opts) do
    child_spec = {Arbor.Memory.Index, Keyword.put(opts, :agent_id, agent_id)}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.debug("Started memory index for agent #{agent_id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "Failed to start memory index for agent #{agent_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Registry monitors processes and removes entries on death, but the
  # DOWN message processing is async. Wait briefly for it to complete.
  defp wait_for_registry_cleanup(agent_id, attempts \\ 5) do
    case Registry.lookup(Arbor.Memory.Registry, {:index, agent_id}) do
      [] ->
        :ok

      [{pid, _}] when attempts > 0 ->
        if Process.alive?(pid) do
          # Process is actually alive, nothing to wait for
          :ok
        else
          Process.sleep(5)
          wait_for_registry_cleanup(agent_id, attempts - 1)
        end

      _ ->
        # Give up waiting — start_child will handle the conflict
        :ok
    end
  end

  @doc """
  Stop an agent's index.

  ## Examples

      :ok = Arbor.Memory.IndexSupervisor.stop_index("agent_001")
  """
  @spec stop_index(String.t()) :: :ok | {:error, :not_found}
  def stop_index(agent_id) do
    case get_index(agent_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Logger.debug("Stopped memory index for agent #{agent_id}")
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the index pid for an agent.

  Returns `{:error, :not_found}` if no index exists for this agent.

  ## Examples

      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index("agent_001")
      {:error, :not_found} = Arbor.Memory.IndexSupervisor.get_index("unknown_agent")
  """
  @spec get_index(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_index(agent_id) do
    case Registry.lookup(Arbor.Memory.Registry, {:index, agent_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if an agent has an active index.

  ## Examples

      true = Arbor.Memory.IndexSupervisor.has_index?("agent_001")
      false = Arbor.Memory.IndexSupervisor.has_index?("unknown_agent")
  """
  @spec has_index?(String.t()) :: boolean()
  def has_index?(agent_id) do
    case get_index(agent_id) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, :not_found} -> false
    end
  end

  @doc """
  List all agent IDs with active indexes.

  ## Examples

      agent_ids = Arbor.Memory.IndexSupervisor.list_agents()
      #=> ["agent_001", "agent_002"]
  """
  @spec list_agents() :: [String.t()]
  def list_agents do
    Registry.select(Arbor.Memory.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(fn
      {:index, _agent_id} -> true
      _ -> false
    end)
    |> Enum.map(fn {:index, agent_id} -> agent_id end)
  end

  @doc """
  Get the count of active indexes.

  ## Examples

      count = Arbor.Memory.IndexSupervisor.count()
      #=> 2
  """
  @spec count() :: non_neg_integer()
  def count do
    DynamicSupervisor.count_children(__MODULE__)[:active]
  end
end
