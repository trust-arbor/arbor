defmodule Arbor.Agent.Registry do
  @moduledoc """
  ETS-backed agent registry for discovery and lookup.

  Provides a centralized registry of running agents with metadata tracking.
  This is the single-node implementation. For distributed deployments,
  this can be replaced with a Horde-based registry.

  ## Usage

      # Lookup happens automatically via Agent.Server registration
      {:ok, entry} = Arbor.Agent.Registry.lookup("agent_001")

      # List all registered agents
      {:ok, agents} = Arbor.Agent.Registry.list()

      # Count registered agents
      count = Arbor.Agent.Registry.count()
  """

  use GenServer

  require Logger

  @table :arbor_agent_registry

  @type agent_entry :: %{
          agent_id: String.t(),
          pid: pid(),
          module: module(),
          metadata: map(),
          registered_at: integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the registry process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register an agent in the registry.

  ## Parameters
  - `agent_id` - Unique identifier for the agent
  - `pid` - The agent's process ID
  - `metadata` - Additional metadata (module, type, etc.)

  ## Returns
  - `:ok` on success
  - `{:error, :already_registered}` if the agent ID is taken by a live process
  """
  @spec register(String.t(), pid(), map()) :: :ok | {:error, :already_registered}
  def register(agent_id, pid, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register, agent_id, pid, metadata})
  end

  @doc """
  Unregister an agent from the registry.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(agent_id) do
    GenServer.call(__MODULE__, {:unregister, agent_id})
  end

  @doc """
  Look up an agent by ID.

  ## Returns
  - `{:ok, entry}` with agent entry map
  - `{:error, :not_found}` if not registered
  """
  @spec lookup(String.t()) :: {:ok, agent_entry()} | {:error, :not_found}
  def lookup(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, entry}] ->
        if Process.alive?(entry.pid) do
          {:ok, entry}
        else
          # Stale entry - clean it up
          :ets.delete(@table, agent_id)
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the PID of a registered agent.

  ## Returns
  - `{:ok, pid}` if found and alive
  - `{:error, :not_found}` otherwise
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(agent_id) do
    case lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.pid}
      error -> error
    end
  end

  @doc """
  List all registered agents.

  Returns only agents with live processes (stale entries are cleaned up).
  """
  @spec list() :: {:ok, [agent_entry()]}
  def list do
    entries =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(fn entry -> Process.alive?(entry.pid) end)

    {:ok, entries}
  end

  @doc """
  Count the number of registered agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc """
  Find agents matching a filter function.

  ## Examples

      # Find all agents of a specific module
      {:ok, agents} = Registry.find(fn entry -> entry.module == MyAgent end)
  """
  @spec find((agent_entry() -> boolean())) :: {:ok, [agent_entry()]}
  def find(filter_fn) when is_function(filter_fn, 1) do
    {:ok, all} = list()
    {:ok, Enum.filter(all, filter_fn)}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:register, agent_id, pid, metadata}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, existing}] when is_map(existing) ->
        if Process.alive?(existing.pid) do
          {:reply, {:error, :already_registered}, state}
        else
          # Previous process is dead, allow re-registration
          do_register(agent_id, pid, metadata)
          {:reply, :ok, state}
        end

      [] ->
        do_register(agent_id, pid, metadata)
        {:reply, :ok, state}
    end
  end

  def handle_call({:unregister, agent_id}, _from, state) do
    :ets.delete(@table, agent_id)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up entries for dead processes
    case :ets.match_object(@table, {:_, %{pid: pid}}) do
      entries when is_list(entries) ->
        for {agent_id, _entry} <- entries do
          :ets.delete(@table, agent_id)
          Logger.debug("Registry cleaned up dead agent: #{agent_id}")
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Private
  # ============================================================================

  defp do_register(agent_id, pid, metadata) do
    Process.monitor(pid)

    entry = %{
      agent_id: agent_id,
      pid: pid,
      module: Map.get(metadata, :module),
      metadata: metadata,
      registered_at: System.system_time(:millisecond)
    }

    :ets.insert(@table, {agent_id, entry})
  end
end
