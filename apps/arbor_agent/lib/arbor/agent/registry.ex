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

  @doc """
  List all agents across the cluster via `:pg` process groups.

  Returns `{:ok, [{agent_id, pid, node}]}` for all agents on all nodes.
  """
  @spec list_cluster() :: {:ok, [{String.t(), pid(), node()}]}
  def list_cluster do
    members = pg_get_members(:all_agents)

    entries =
      members
      |> Enum.map(fn pid ->
        agent_id = find_agent_id_for_pid(pid)
        {agent_id, pid, node(pid)}
      end)
      |> Enum.reject(fn {id, _, _} -> is_nil(id) end)

    {:ok, entries}
  end

  @doc """
  Find a specific agent across the cluster by agent_id.

  Returns `{:ok, pid}` or `{:error, :not_found}`.
  """
  @spec whereis_cluster(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis_cluster(agent_id) do
    case pg_get_members({:agent, agent_id}) do
      [pid | _] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
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
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Clean up entries for dead processes
    case :ets.match_object(@table, {:_, %{pid: pid}}) do
      entries when is_list(entries) ->
        for {agent_id, entry} <- entries do
          :ets.delete(@table, agent_id)
          Logger.debug("Registry cleaned up dead agent: #{agent_id}")

          # Emit crash signal for non-normal shutdowns
          unless reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
            emit_agent_signal(:process_crashed, %{
              agent_id: agent_id,
              reason: sanitize_crash_reason(reason),
              module: Map.get(entry, :module),
              registered_at: Map.get(entry, :registered_at)
            })
          end
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

    # Join pg groups for cluster-wide discovery
    pg_join(:all_agents, pid)
    pg_join({:agent, agent_id}, pid)
  end

  # ── pg helpers ────────────────────────────────────────────────────

  defp pg_join(group, pid) do
    try do
      :pg.join(:arbor_agents, group, pid)
    rescue
      e ->
        Logger.debug("[Registry] pg_join failed for #{inspect(group)}: #{Exception.message(e)}")
        :ok
    catch
      :exit, reason ->
        Logger.debug("[Registry] pg_join exited for #{inspect(group)}: #{inspect(reason)}")
        :ok
    end
  end

  defp pg_get_members(group) do
    try do
      :pg.get_members(:arbor_agents, group)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp emit_agent_signal(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :durable_emit, 3) do
      apply(Arbor.Signals, :durable_emit, [:agent, type, data])
    end
  rescue
    _ -> :ok
  end

  defp sanitize_crash_reason({error_type, _stacktrace}) when is_atom(error_type) do
    Atom.to_string(error_type)
  end

  defp sanitize_crash_reason({%{__struct__: struct_mod}, _stacktrace}) do
    inspect(struct_mod)
  end

  defp sanitize_crash_reason(reason) when is_atom(reason) do
    Atom.to_string(reason)
  end

  defp sanitize_crash_reason(_reason), do: "unknown"

  defp find_agent_id_for_pid(pid) do
    # Query the local or remote registry for this pid's agent_id
    node = node(pid)

    if node == Node.self() do
      # Local lookup via ETS
      case :ets.match_object(@table, {:_, %{pid: pid}}) do
        [{agent_id, _} | _] -> agent_id
        _ -> nil
      end
    else
      # Remote lookup via RPC
      case :rpc.call(node, :ets, :match_object, [@table, {:_, %{pid: pid}}], 5_000) do
        [{agent_id, _} | _] -> agent_id
        _ -> nil
      end
    end
  end
end
