defmodule Arbor.Trust.Store do
  @moduledoc """
  Trust profile storage backend using ETS caching.

  This module provides storage for trust profiles with fast in-memory
  caching. It implements a write-through cache pattern similar to
  CapabilityStore:

  - All writes go to ETS (and optionally PostgreSQL for persistence)
  - Reads from ETS cache
  - Cache entries have TTL for freshness

  The ETS cache provides sub-millisecond read performance for trust
  checks during authorization decisions.

  ## Usage

      # Store a trust profile
      :ok = Trust.Store.store_profile(profile)

      # Get a profile
      {:ok, profile} = Trust.Store.get_profile("agent_123")

      # Update profile counters
      {:ok, profile} = Trust.Store.record_action_success("agent_123")
  """

  use GenServer

  alias Arbor.Contracts.Trust.{Event, Profile}
  alias Arbor.Trust.{Authority, Calculator, Config}

  require Logger

  @table_name :trust_profile_cache

  defstruct [
    :profiles_table,
    :db_module,
    :cache_stats
  ]

  @type state :: %__MODULE__{
          profiles_table: :ets.table(),
          db_module: module() | nil,
          cache_stats: map()
        }

  # Client API

  @doc """
  Start the trust store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a trust profile.
  """
  @spec store_profile(Profile.t()) :: :ok | {:error, term()}
  def store_profile(%Profile{} = profile) do
    GenServer.call(__MODULE__, {:store_profile, profile})
  end

  @doc """
  Get a trust profile by agent ID.

  Reads directly from ETS for sub-microsecond latency on the authorization
  hot path. Falls back to GenServer (DB lookup) on cache miss.
  """
  @spec get_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_profile(agent_id) do
    case :ets.lookup(@table_name, agent_id) do
      [{^agent_id, profile}] ->
        {:ok, profile}

      [] ->
        # Cache miss — try DB fallback via GenServer
        GenServer.call(__MODULE__, {:get_profile_from_db, agent_id})
    end
  rescue
    ArgumentError ->
      # ETS table not yet created
      {:error, :not_found}
  end

  @doc """
  Check if a profile exists.
  """
  @spec profile_exists?(String.t()) :: boolean()
  def profile_exists?(agent_id) do
    :ets.member(@table_name, agent_id)
  rescue
    ArgumentError -> false
  end

  @doc """
  Delete a trust profile.
  """
  @spec delete_profile(String.t()) :: :ok | {:error, term()}
  def delete_profile(agent_id) do
    GenServer.call(__MODULE__, {:delete_profile, agent_id})
  end

  @doc """
  Promote a URI prefix to :auto in an agent's trust profile.

  Used by "Always Allow" in the approval UI to permanently auto-authorize
  a specific resource URI prefix for an agent.
  """
  @spec always_allow(String.t(), String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def always_allow(agent_id, resource_uri) do
    # Find the best matching prefix to use as the rule key
    uri_prefix = best_rule_prefix(resource_uri)

    update_profile(agent_id, fn profile ->
      %{profile | rules: Map.put(profile.rules || %{}, uri_prefix, :auto)}
    end)
  end

  @doc """
  Demote a URI prefix back to :ask in an agent's trust profile.
  """
  @spec revoke_always_allow(String.t(), String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def revoke_always_allow(agent_id, resource_uri) do
    uri_prefix = best_rule_prefix(resource_uri)

    update_profile(agent_id, fn profile ->
      %{profile | rules: Map.put(profile.rules || %{}, uri_prefix, :ask)}
    end)
  end

  # Extract a reasonable rule prefix from a full resource URI.
  # e.g., "arbor://fs/read/workspace/file.ex" → "arbor://fs/read"
  #        "arbor://memory/recall" → "arbor://memory"
  defp best_rule_prefix(uri) do
    case String.split(uri, "/") do
      ["arbor:", "", domain, operation | _] -> "arbor://#{domain}/#{operation}"
      ["arbor:", "", domain | _] -> "arbor://#{domain}"
      _ -> uri
    end
  end

  @doc """
  Update a profile with a function.
  """
  @spec update_profile(String.t(), (Profile.t() -> Profile.t())) ::
          {:ok, Profile.t()} | {:error, :not_found | term()}
  def update_profile(agent_id, update_fn) when is_function(update_fn, 1) do
    GenServer.call(__MODULE__, {:update_profile, agent_id, update_fn})
  end

  @doc """
  Record a successful action for an agent.
  """
  @spec record_action_success(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_action_success(agent_id) do
    update_profile(agent_id, &Authority.record_action_success/1)
  end

  @doc """
  Record a failed action for an agent.
  """
  @spec record_action_failure(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_action_failure(agent_id) do
    update_profile(agent_id, &Authority.record_action_failure/1)
  end

  @doc """
  Record a security violation for an agent.
  """
  @spec record_security_violation(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_security_violation(agent_id) do
    update_profile(agent_id, &Authority.record_security_violation/1)
  end

  @doc """
  Record a test result for an agent.
  """
  @spec record_test_result(String.t(), :passed | :failed) ::
          {:ok, Profile.t()} | {:error, term()}
  def record_test_result(agent_id, result) when result in [:passed, :failed] do
    update_profile(agent_id, &Authority.record_test_result(&1, result))
  end

  @doc """
  Record a rollback for an agent.
  """
  @spec record_rollback(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_rollback(agent_id) do
    update_profile(agent_id, &Authority.record_rollback/1)
  end

  @doc """
  Record an improvement being applied.
  """
  @spec record_improvement(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_improvement(agent_id) do
    update_profile(agent_id, &Authority.record_improvement/1)
  end

  # Council-based trust earning functions

  @doc """
  Record a proposal submission.
  """
  @spec record_proposal_submitted(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_proposal_submitted(agent_id) do
    update_profile(agent_id, &Authority.record_proposal_submitted/1)
  end

  @doc """
  Record a proposal being approved by council.
  """
  @spec record_proposal_approved(String.t(), atom()) :: {:ok, Profile.t()} | {:error, term()}
  def record_proposal_approved(agent_id, impact \\ :medium) do
    update_profile(agent_id, &Authority.record_proposal_approved(&1, impact))
  end

  @doc """
  Record a successful installation.
  """
  @spec record_installation_success(String.t(), atom()) ::
          {:ok, Profile.t()} | {:error, term()}
  def record_installation_success(agent_id, impact \\ :medium) do
    update_profile(agent_id, &Authority.record_installation_success(&1, impact))
  end

  @doc """
  Record an installation rollback.
  """
  @spec record_installation_rollback(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_installation_rollback(agent_id) do
    update_profile(agent_id, &Authority.record_installation_rollback/1)
  end

  @doc """
  Award trust points directly (for special cases).
  """
  @spec award_trust_points(String.t(), non_neg_integer()) ::
          {:ok, Profile.t()} | {:error, term()}
  def award_trust_points(agent_id, points) when points >= 0 do
    update_profile(agent_id, &Authority.award_trust_points(&1, points))
  end

  @doc """
  Deduct trust points (for abuse or violations).
  """
  @spec deduct_trust_points(String.t(), non_neg_integer(), atom()) ::
          {:ok, Profile.t()} | {:error, term()}
  def deduct_trust_points(agent_id, points, reason) when points >= 0 do
    update_profile(agent_id, &Authority.deduct_trust_points(&1, points, reason))
  end

  @doc """
  Freeze a trust profile.
  """
  @spec freeze_profile(String.t(), atom()) :: {:ok, Profile.t()} | {:error, term()}
  def freeze_profile(agent_id, reason) do
    update_profile(agent_id, fn profile ->
      Profile.freeze(profile, reason)
    end)
  end

  @doc """
  Unfreeze a trust profile.
  """
  @spec unfreeze_profile(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def unfreeze_profile(agent_id) do
    update_profile(agent_id, fn profile ->
      Profile.unfreeze(profile)
    end)
  end

  @doc """
  List all profiles (for admin/debugging).
  """
  @spec list_profiles(keyword()) :: {:ok, [Profile.t()]}
  def list_profiles(opts \\ []) do
    GenServer.call(__MODULE__, {:list_profiles, opts})
  end

  @doc """
  Recalculate all profiles (e.g., for uptime score refresh).
  """
  @spec recalculate_all() :: :ok
  def recalculate_all do
    GenServer.call(__MODULE__, :recalculate_all)
  end

  @doc """
  Get cache statistics.
  """
  @spec get_cache_stats() :: map()
  def get_cache_stats do
    GenServer.call(__MODULE__, :get_cache_stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Create ETS tables
    profiles_table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Optional PostgreSQL persistence module
    db_module = opts[:db_module]

    state = %__MODULE__{
      profiles_table: profiles_table,
      db_module: db_module,
      cache_stats: %{hits: 0, misses: 0, writes: 0, deletes: 0}
    }

    subscribe_to_distributed_signals()

    # Load persisted profiles into ETS cache
    loaded = load_persisted_profiles(state)

    Logger.info("Trust.Store started with ETS tables (loaded #{loaded} persisted profiles)")

    {:ok, state}
  end

  @impl true
  def handle_call({:store_profile, profile}, _from, state) do
    :ok = put_profile_in_cache(profile, state)
    persist_profile(profile, state)
    emit_distributed_signal(:profile_updated, profile.agent_id)

    # Sync capabilities to match the new trust profile rules
    sync_capabilities_async(profile.agent_id)

    new_stats = update_stats(state.cache_stats, :writes, 1)
    {:reply, :ok, %{state | cache_stats: new_stats}}
  end

  @impl true
  def handle_call({:get_profile_from_db, agent_id}, _from, state) do
    case load_profile_from_db(agent_id, state) do
      {:ok, profile} ->
        put_profile_in_cache(profile, state)
        new_stats = update_stats(state.cache_stats, :misses, 1)
        {:reply, {:ok, profile}, %{state | cache_stats: new_stats}}

      {:error, :not_found} ->
        new_stats = update_stats(state.cache_stats, :misses, 1)
        {:reply, {:error, :not_found}, %{state | cache_stats: new_stats}}
    end
  end

  @impl true
  def handle_call({:delete_profile, agent_id}, _from, state) do
    :ets.delete(state.profiles_table, agent_id)
    delete_profile_from_db(agent_id, state)
    emit_distributed_signal(:profile_deleted, agent_id)

    new_stats = update_stats(state.cache_stats, :deletes, 1)
    {:reply, :ok, %{state | cache_stats: new_stats}}
  end

  @impl true
  def handle_call({:update_profile, agent_id, update_fn}, _from, state) do
    case get_profile_from_cache(agent_id, state) do
      {:ok, profile} ->
        updated = update_fn.(profile)
        updated = %{updated | updated_at: DateTime.utc_now()}
        :ok = put_profile_in_cache(updated, state)
        persist_profile(updated, state)

        # Check for tier changes
        if profile.tier != updated.tier do
          emit_tier_change_event(profile, updated, state)
        end

        emit_distributed_signal(:profile_updated, agent_id)

        # Sync capabilities if rules changed
        if profile.rules != updated.rules do
          sync_capabilities_async(agent_id)
        end

        new_stats = update_stats(state.cache_stats, :writes, 1)
        {:reply, {:ok, updated}, %{state | cache_stats: new_stats}}

      {:error, :not_found} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_profiles, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    tier_filter = Keyword.get(opts, :tier)

    profiles =
      :ets.tab2list(state.profiles_table)
      |> Enum.map(fn {_key, profile} -> profile end)
      |> maybe_filter_by_tier(tier_filter)
      |> Enum.sort_by(& &1.trust_score, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, profiles}, state}
  end

  @impl true
  def handle_call(:recalculate_all, _from, state) do
    now = DateTime.utc_now()

    :ets.tab2list(state.profiles_table)
    |> Enum.each(fn {_agent_id, profile} ->
      updated = Calculator.recalculate_profile(profile, now)
      put_profile_in_cache(updated, state)
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_cache_stats, _from, state) do
    table_info =
      try do
        %{
          profiles_size: :ets.info(state.profiles_table, :size),
          profiles_memory: :ets.info(state.profiles_table, :memory)
        }
      rescue
        _ -> %{profiles_size: 0, profiles_memory: 0}
      end

    stats = Map.merge(state.cache_stats, table_info)
    {:reply, stats, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Trust.Store terminating: #{inspect(reason)}")

    if :ets.info(state.profiles_table) != :undefined do
      :ets.delete(state.profiles_table)
    end

    :ok
  end

  @impl true
  def handle_info({:signal_received, %{data: %{origin_node: origin}}}, state)
      when origin == node() do
    {:noreply, state}
  end

  @impl true
  def handle_info({:signal_received, %{type: type, data: data}}, state) do
    agent_id = Map.get(data, :agent_id)

    case type do
      :profile_updated ->
        # Invalidate cache — next get will reload from DB
        :ets.delete(state.profiles_table, agent_id)
        Logger.debug("[Trust.Store] Invalidated profile cache for #{agent_id} from #{data.origin_node}")

      :profile_deleted ->
        :ets.delete(state.profiles_table, agent_id)
        Logger.debug("[Trust.Store] Deleted profile cache for #{agent_id} from #{data.origin_node}")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private functions

  defp put_profile_in_cache(profile, state) do
    :ets.insert(state.profiles_table, {profile.agent_id, profile})
    :ok
  end

  defp get_profile_from_cache(agent_id, state) do
    case :ets.lookup(state.profiles_table, agent_id) do
      [{^agent_id, profile}] ->
        {:ok, profile}

      [] ->
        {:error, :not_found}
    end
  end

  defp update_stats(stats, key, increment) do
    Map.update(stats, key, increment, &(&1 + increment))
  end

  defp maybe_filter_by_tier(profiles, nil), do: profiles

  defp maybe_filter_by_tier(profiles, tier) do
    Enum.filter(profiles, &(&1.tier == tier))
  end

  # Async capability sync — revokes stale capabilities after trust profile changes.
  # Runs in a Task to avoid blocking the GenServer.
  defp sync_capabilities_async(agent_id) do
    enforcer = Arbor.Security.PolicyEnforcer

    if Code.ensure_loaded?(enforcer) and function_exported?(enforcer, :sync_capabilities, 1) do
      Task.start(fn ->
        apply(enforcer, :sync_capabilities, [agent_id])
      end)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @buffered_store :arbor_trust_profiles

  defp load_persisted_profiles(state) do
    if buffered_store_running?() do
      list_and_load_profiles(state)
    else
      Logger.warning("[Trust.Store] BufferedStore :arbor_trust_profiles not running on init")
      0
    end
  rescue
    e ->
      Logger.warning("[Trust.Store] load_persisted_profiles crashed: #{inspect(e)}")
      0
  end

  defp buffered_store_running?, do: Process.whereis(@buffered_store) != nil

  defp list_and_load_profiles(state) do
    case Arbor.Persistence.BufferedStore.list(name: @buffered_store) do
      {:ok, keys} ->
        Logger.info("[Trust.Store] Loading #{length(keys)} persisted profiles from BufferedStore")
        Enum.count(keys, &load_one_profile(&1, state))

      other ->
        Logger.warning("[Trust.Store] Unexpected list result from BufferedStore: #{inspect(other)}")
        0
    end
  end

  defp load_one_profile(key, state) do
    case load_profile_from_db(key, state) do
      {:ok, profile} ->
        put_profile_in_cache(profile, state)
        true

      other ->
        Logger.warning("[Trust.Store] Failed to load profile #{key}: #{inspect(other)}")
        false
    end
  end

  defp persist_profile(profile, _state) do
    if Process.whereis(@buffered_store) do
      record = %Arbor.Contracts.Persistence.Record{
        id: profile.agent_id,
        key: profile.agent_id,
        data: serialize_profile(profile),
        metadata: %{}
      }

      case Arbor.Persistence.BufferedStore.put(profile.agent_id, record, name: @buffered_store) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[Trust.Store] persist failed: #{inspect(reason)}")
        other -> Logger.warning("[Trust.Store] persist unexpected: #{inspect(other)}")
      end
    else
      Logger.warning("[Trust.Store] BufferedStore :arbor_trust_profiles not running, skipping persist")
    end
  rescue
    e ->
      Logger.warning("[Trust.Store] persist_profile crashed: #{inspect(e)}")
  end

  defp load_profile_from_db(agent_id, _state) do
    if Process.whereis(@buffered_store) do
      case Arbor.Persistence.BufferedStore.get(agent_id, name: @buffered_store) do
        {:ok, raw} ->
          data = unwrap_record(raw)
          deserialize_profile(data)

        {:error, :not_found} ->
          {:error, :not_found}

        _ ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp delete_profile_from_db(agent_id, _state) do
    if Process.whereis(@buffered_store) do
      Arbor.Persistence.BufferedStore.delete(agent_id, name: @buffered_store)
    end
  rescue
    _ -> :ok
  end

  defp unwrap_record(%Arbor.Contracts.Persistence.Record{data: data}), do: data
  defp unwrap_record(%{} = data), do: data

  # Profile serialization lives on Authority — single source of truth so the
  # encoding can't drift between Store and any future persistence layers.
  defp serialize_profile(%Profile{} = profile), do: Authority.for_persistence(profile)
  defp deserialize_profile(data), do: Authority.from_persistence(data)

  defp emit_distributed_signal(type, agent_id) do
    if Code.ensure_loaded?(Arbor.Signals) do
      if function_exported?(Arbor.Signals, :durable_emit, 4) do
        Arbor.Signals.durable_emit(:trust, type, %{
          agent_id: agent_id,
          origin_node: node()
        }, stream_id: "trust:events")
      else
        Arbor.Signals.emit(:trust, type, %{
          agent_id: agent_id,
          origin_node: node()
        }, scope: :cluster)
      end
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp subscribe_to_distributed_signals do
    bus = Arbor.Signals.Bus

    if Code.ensure_loaded?(bus) and Process.whereis(bus) do
      me = self()

      for type <- ~w(profile_updated profile_deleted) do
        Arbor.Signals.subscribe("trust.#{type}", fn signal ->
          send(me, {:signal_received, signal})
          :ok
        end)
      end

      Logger.info("[Trust.Store] Subscribed to distributed trust signals")
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp emit_tier_change_event(old_profile, new_profile, _state) do
    {:ok, event} =
      Event.tier_change_event(
        new_profile.agent_id,
        old_profile.tier,
        new_profile.tier,
        previous_score: old_profile.trust_score,
        new_score: new_profile.trust_score
      )

    # Persist to EventStore
    if Code.ensure_loaded?(Arbor.Trust.EventStore) and Process.whereis(Arbor.Trust.EventStore) do
      Arbor.Trust.EventStore.record_event(event)
    end

    # Broadcast via PubSub for real-time LiveView updates
    try do
      Phoenix.PubSub.broadcast(
        Config.pubsub(),
        "trust:#{new_profile.agent_id}",
        {:tier_changed, new_profile.agent_id, old_profile.tier, new_profile.tier}
      )
    rescue
      _ -> :ok
    end

    # Signal for queryable history via Historian (durable for audit trail)
    if function_exported?(Arbor.Signals, :durable_emit, 4) do
      Arbor.Signals.durable_emit(:trust, :tier_changed, %{
        agent_id: new_profile.agent_id,
        old_tier: old_profile.tier,
        new_tier: new_profile.tier,
        old_score: old_profile.trust_score,
        new_score: new_profile.trust_score
      }, stream_id: "trust:events")
    else
      Arbor.Signals.emit(:trust, :tier_changed, %{
        agent_id: new_profile.agent_id,
        old_tier: old_profile.tier,
        new_tier: new_profile.tier,
        old_score: old_profile.trust_score,
        new_score: new_profile.trust_score
      })
    end

    Logger.info(
      "Trust tier changed for #{new_profile.agent_id}: #{old_profile.tier} -> #{new_profile.tier}",
      agent_id: new_profile.agent_id,
      old_tier: old_profile.tier,
      new_tier: new_profile.tier,
      old_score: old_profile.trust_score,
      new_score: new_profile.trust_score
    )
  end
end
