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

  alias Arbor.Agent.RuntimeQuiescenceCore

  @table :arbor_agent_registry
  # Test-build-only raw-source seam consumed by observe_target/1 (see lookup_local_entry /
  # pg_raw_members). In a prod/dev build this is false and observe_target/1 always reads
  # the real global sources; the seam is unavailable in production and is not
  # caller-selectable via the future public reconciliation facade (Process.put by tests).
  @test_build Mix.env() == :test

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
    with_registry_table({:error, :not_found}, fn ->
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
    end)
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
    with_registry_table({:ok, []}, fn ->
      entries =
        :ets.tab2list(@table)
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.filter(fn entry -> Process.alive?(entry.pid) end)

      {:ok, entries}
    end)
  end

  @doc """
  Count the number of registered agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    with_registry_table(0, fn -> :ets.info(@table, :size) || 0 end)
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

  @doc """
  Exact-target runtime ownership observation carrying the confirmed local owner
  pid (Phase 4C C2B).

  This is the observation the quiescence shell binds the stop side effect to:
  `{:ok, pid}` is returned ONLY for a confirmed local owner (one live local
  `:pg` member exactly equal to the local ETS entry). Every other outcome is a
  typed non-success. Error results carry no pid/exception/backend detail (only
  the success result carries the pid, which is required to stop the exact owner).

  For the bare-atom public observation use `observe_target/1`.
  """
  @spec observe_target_owner(String.t()) ::
          {:ok, pid()}
          | {:error, :absent | :remote_owner | :ambiguous_ownership | :observation_unavailable}
  def observe_target_owner(agent_id) when is_binary(agent_id) do
    local_fact = observe_local_fact(agent_id)
    pg_fact = observe_pg_fact(agent_id)
    class = RuntimeQuiescenceCore.classify_ownership(local_fact, pg_fact)
    decorate_owner(class, local_fact)
  end

  @doc """
  Error-preserving exact-target runtime ownership observation (bare atoms).

  Distinguishes confirmed absence, one exact local owner, one remote owner,
  duplicate or inconsistent ownership, and observation unavailability — WITHOUT
  treating any source failure as absence. Reads the local ETS registry entry and
  the exact `:pg` group directly (not via the GenServer), so it does not serialize
  through the registry mailbox.

  A present-but-remote/dead/malformed local ETS entry yields
  `:ambiguous_ownership` or `:observation_unavailable`, never `:absent`. Absence
  requires positive empty observations from BOTH sources.

  Results are bare atoms only (no node/PID/exception/backend details). This is
  NOT `list_cluster/0`/`whereis_cluster/1` (whose pg/RPC failure paths collapse
  uncertainty) and does not alter them.
  """
  @spec observe_target(String.t()) ::
          {:ok, :absent}
          | {:ok, :local_owner}
          | {:ok, :remote_owner}
          | {:error, :ambiguous_ownership}
          | {:error, :observation_unavailable}
  def observe_target(agent_id) when is_binary(agent_id) do
    case observe_target_owner(agent_id) do
      {:ok, _pid} -> {:ok, :local_owner}
      {:error, :absent} -> {:ok, :absent}
      {:error, :remote_owner} -> {:ok, :remote_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Atomically remove the registry entry for `agent_id` ONLY IF its recorded owner
  pid exactly equals `observed_pid` (Phase 4C C2B exact-owner compare-delete).

  A single atomic `:ets.select_delete` removes `{agent_id, %{pid: ^observed_pid}}`
  — never a lookup followed by delete, so a concurrent re-registration pointing at a
  different pid cannot be deleted out from under a replacement owner.

  Returns `:ok` when the exact-owner row was removed, `{:error, :owner_replaced}`
  when the row is absent or its `:pid` no longer equals `observed_pid`, and
  `{:error, :observation_unavailable}` when the registry table is gone. A
  malformed (non-map / non-pid) row fails the guard and is treated as
  `:owner_replaced` (fail closed). `observe_target/1` and `observe_target_owner/1`
  error distinctions are unchanged.
  """
  @spec remove_owner_if_match(String.t(), pid()) ::
          :ok | {:error, :owner_replaced | :observation_unavailable}
  def remove_owner_if_match(agent_id, observed_pid)
      when is_binary(agent_id) and is_pid(observed_pid) do
    # Bind the entry map to $1, then guard that its :pid field equals the observed
    # owner pid. select_delete is atomic: only a row still owned by the exact
    # observed pid is removed. map_get/2 is a legal match-spec guard BIF.
    spec = [{{agent_id, :"$1"}, [{:==, {:map_get, :pid, :"$1"}, observed_pid}], [true]}]

    case :ets.select_delete(@table, spec) do
      1 -> :ok
      _ -> {:error, :owner_replaced}
    end
  rescue
    ArgumentError -> {:error, :observation_unavailable}
  catch
    :error, :badarg -> {:error, :observation_unavailable}
  end

  @doc """
  Strict variant of `list/0` for security-sensitive consumers.

  Returns `{:error, :observation_unavailable}` when the registry ETS table is not
  present, instead of the fail-open `{:ok, []}` that `list/0` returns. Existing
  `list/0`/`lookup/1`/`whereis/1` behavior is unchanged.
  """
  @spec list_strict() :: {:ok, [agent_entry()]} | {:error, :observation_unavailable}
  def list_strict do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :observation_unavailable}

      _ ->
        scan_strict()
    end
  rescue
    ArgumentError -> {:error, :observation_unavailable}
  catch
    :error, :badarg -> {:error, :observation_unavailable}
  end

  # Validates row/entry/local-pid shape. A malformed row/entry, a missing/non-pid
  # :pid, a missing :agent_id, or a remote pid in the LOCAL registry makes the
  # whole snapshot :observation_unavailable (fail closed). Process.alive?/1 runs
  # ONLY on a pid already proven local; a dead local entry is skipped (consistent
  # with list/0). KeyError / remote Process.alive? can never escape.
  defp scan_strict do
    case reduce_strict_rows(:ets.tab2list(@table), []) do
      :bad -> {:error, :observation_unavailable}
      entries -> {:ok, entries}
    end
  end

  defp reduce_strict_rows([], acc), do: Enum.reverse(acc)

  defp reduce_strict_rows([row | rest], acc) do
    case classify_strict_row(row) do
      {:ok, entry} -> reduce_strict_rows(rest, [entry | acc])
      :skip -> reduce_strict_rows(rest, acc)
      :bad -> :bad
    end
  end

  # The ETS key MUST equal entry.agent_id — a row whose key was overwritten
  # with a mismatched entry (e.g. a stale/corrupted row) is rejected (:bad),
  # never treated as a valid live entry.
  defp classify_strict_row({id, %{pid: pid, agent_id: aid} = entry})
       when is_binary(id) and is_pid(pid) and is_binary(aid) and id == aid do
    cond do
      node(pid) != node() -> :bad
      not Process.alive?(pid) -> :skip
      true -> {:ok, entry}
    end
  end

  defp classify_strict_row(_), do: :bad

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

  # ── Error-preserving observation helpers (C2B) ─────────────────────

  defp observe_local_fact(agent_id) do
    case test_local_fact() do
      nil -> agent_id |> lookup_local_entry() |> classify_local_entry()
      fact -> fact
    end
  end

  # A present-but-bad entry is :inconsistent/:unavailable, NEVER :absent, so a
  # pg-empty observation cannot falsely prove absence. Process.alive?/1 is called
  # ONLY on a pid already proven local by node()==node(); never on a remote pid.
  defp classify_local_entry(:table_undefined), do: :unavailable
  defp classify_local_entry(nil), do: :absent

  defp classify_local_entry(%{pid: pid}) do
    cond do
      not is_pid(pid) -> :unavailable
      node(pid) != node() -> :inconsistent
      not Process.alive?(pid) -> :inconsistent
      true -> {:ok, pid}
    end
  end

  defp classify_local_entry(_), do: :unavailable

  defp lookup_local_entry(agent_id) do
    case test_local_raw() do
      :real -> real_ets_lookup(agent_id)
      :table_undefined -> :table_undefined
      :no_entry -> nil
      {:entry, entry} -> entry
    end
  end

  defp test_local_raw do
    if @test_build do
      case Process.get({__MODULE__, :test_local_raw}) do
        nil -> :real
        other -> other
      end
    else
      :real
    end
  end

  # Test-build-only fact-level override (deterministic, consumed by arity-1
  # observe_target/1). See test_pg_fact/0.
  defp test_local_fact do
    if @test_build, do: Process.get({__MODULE__, :test_local_fact}), else: nil
  end

  defp real_ets_lookup(agent_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :table_undefined

      _ ->
        case :ets.lookup(@table, agent_id) do
          [{^agent_id, entry}] -> entry
          [] -> nil
        end
    end
  rescue
    ArgumentError -> :table_undefined
  catch
    :error, :badarg -> :table_undefined
  end

  # NO Process.alive? on members: :pg membership is the evidence. node()/1 is a
  # safe BIF (reads the pid's node component, no RPC).
  defp observe_pg_fact(agent_id) do
    case test_pg_fact() do
      nil ->
        case pg_raw_members(agent_id) do
          list when is_list(list) -> classify_pg_members(list)
          :pg_failed -> :unavailable
          :malformed -> :unavailable
          _ -> :unavailable
        end

      fact ->
        fact
    end
  end

  # Test-build-only fact-level override (deterministic, consumed by arity-1
  # observe_target/1). Used where a real remote pid cannot be fabricated without a
  # managed peer; the real classify_ownership/decorate still runs on the fact.
  defp test_pg_fact do
    if @test_build, do: Process.get({__MODULE__, :test_pg_fact}), else: nil
  end

  defp pg_raw_members(agent_id) do
    override = if @test_build, do: Process.get({__MODULE__, :test_pg_raw}), else: nil

    case override do
      nil -> real_pg_members(agent_id)
      {:members, list} -> list
      :pg_exit -> :pg_failed
      :pg_error -> :pg_failed
      :malformed -> :malformed
    end
  end

  defp real_pg_members(agent_id) do
    :pg.get_members(:arbor_agents, {:agent, agent_id})
  rescue
    _ -> :pg_failed
  catch
    # :pg failures are :exit (e.g. noproc on an unstarted scope); raised :error
    # values are already covered by `rescue _` above.
    :exit, _ -> :pg_failed
  end

  defp classify_pg_members(members) when is_list(members) do
    case Enum.split_with(members, &is_pid/1) do
      {pids, []} ->
        {locals, remotes} = Enum.split_with(pids, fn p -> node(p) == node() end)
        {:ok, {locals, length(remotes)}}

      _ ->
        :unavailable
    end
  end

  defp classify_pg_members(_), do: :unavailable

  defp decorate_owner(:local_owner, {:ok, pid}), do: {:ok, pid}
  defp decorate_owner(:local_owner, _), do: {:error, :ambiguous_ownership}
  defp decorate_owner(:absent, _), do: {:error, :absent}
  defp decorate_owner(:remote_owner, _), do: {:error, :remote_owner}
  defp decorate_owner(:ambiguous, _), do: {:error, :ambiguous_ownership}
  defp decorate_owner(:unavailable, _), do: {:error, :observation_unavailable}

  defp with_registry_table(default, fun) when is_function(fun, 0) do
    case :ets.whereis(@table) do
      :undefined ->
        default

      _table ->
        fun.()
    end
  rescue
    ArgumentError -> default
  catch
    :error, :badarg -> default
  end

  defp emit_agent_signal(type, data) do
    Arbor.Signals.durable_emit(:agent, type, data)
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
      with_registry_table(nil, fn ->
        case :ets.match_object(@table, {:_, %{pid: pid}}) do
          [{agent_id, _} | _] -> agent_id
          _ -> nil
        end
      end)
    else
      # Remote lookup via RPC
      case :rpc.call(node, :ets, :match_object, [@table, {:_, %{pid: pid}}], 5_000) do
        [{agent_id, _} | _] -> agent_id
        _ -> nil
      end
    end
  end
end
