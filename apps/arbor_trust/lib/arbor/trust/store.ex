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

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Authority

  require Logger

  @table_name :trust_profile_cache
  @failed_deletion_key {__MODULE__, :failed_durable_deletions}

  defstruct [
    :profiles_table,
    :persistence_mode,
    :durable_backend,
    :durable_backend_opts,
    :durable_collection,
    :cache_stats
  ]

  @type state :: %__MODULE__{
          profiles_table: :ets.table(),
          persistence_mode: :durable | :memory,
          durable_backend: module() | nil,
          durable_backend_opts: keyword(),
          durable_collection: String.t(),
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

    persistence_mode = Keyword.get(opts, :persistence, :memory)

    unless persistence_mode in [:durable, :memory] do
      raise ArgumentError, "persistence must be :durable or :memory"
    end

    state = %__MODULE__{
      profiles_table: profiles_table,
      persistence_mode: persistence_mode,
      durable_backend: Keyword.get(opts, :durable_backend),
      durable_backend_opts: Keyword.get(opts, :durable_backend_opts, []),
      durable_collection: Keyword.get(opts, :durable_collection, "trust_profiles"),
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
    case persist_profile(profile, state) do
      :ok ->
        :ok = put_profile_in_cache(profile, state)
        clear_failed_deletion(profile.agent_id)
        emit_distributed_signal(:profile_updated, profile.agent_id)

        # Sync capabilities to match the new trust profile rules
        sync_capabilities_async(profile.agent_id)

        new_stats = update_stats(state.cache_stats, :writes, 1)
        {:reply, :ok, %{state | cache_stats: new_stats}}

      {:error, _} = error ->
        {:reply, error, state}
    end
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
    profile =
      case get_profile_from_cache(agent_id, state) do
        {:ok, existing} -> existing
        {:error, :not_found} -> Authority.new_profile(agent_id)
      end

    tombstone = disabled_profile(profile)

    case delete_persisted_profile(agent_id, state) do
      :ok ->
        :ets.delete(state.profiles_table, agent_id)
        clear_failed_deletion(agent_id)
        emit_distributed_signal(:profile_deleted, agent_id)
        new_stats = update_stats(state.cache_stats, :deletes, 1)
        {:reply, :ok, %{state | cache_stats: new_stats}}

      {:error, _} = error ->
        # Durable deletion failed. Deny locally and notify current peers; a
        # full node loss still relies on Lifecycle's identity/capability gates.
        :ok = put_profile_in_cache(tombstone, state)
        remember_failed_deletion(agent_id)
        emit_distributed_signal(:profile_disabled, agent_id)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update_profile, agent_id, update_fn}, _from, state) do
    case get_profile_from_cache(agent_id, state) do
      {:ok, profile} ->
        updated = update_fn.(profile)
        updated = %{updated | updated_at: DateTime.utc_now()}

        case persist_profile(updated, state) do
          :ok ->
            :ok = put_profile_in_cache(updated, state)
            clear_failed_deletion(agent_id)
            emit_distributed_signal(:profile_updated, agent_id)

            # Sync policy-minted capabilities if authorization standing changed.
            if profile.rules != updated.rules or profile.baseline != updated.baseline do
              sync_capabilities_async(agent_id)
            end

            new_stats = update_stats(state.cache_stats, :writes, 1)
            {:reply, {:ok, updated}, %{state | cache_stats: new_stats}}

          {:error, _} = error ->
            {:reply, error, state}
        end

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
      |> Enum.sort_by(& &1.agent_id)
      |> Enum.take(limit)

    {:reply, {:ok, profiles}, state}
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

        Logger.debug(
          "[Trust.Store] Invalidated profile cache for #{agent_id} from #{data.origin_node}"
        )

      :profile_deleted ->
        :ets.delete(state.profiles_table, agent_id)
        clear_failed_deletion(agent_id)

        Logger.debug(
          "[Trust.Store] Deleted profile cache for #{agent_id} from #{data.origin_node}"
        )

      :profile_disabled ->
        :ok = put_profile_in_cache(disabled_profile(Authority.new_profile(agent_id)), state)
        remember_failed_deletion(agent_id)

        Logger.warning(
          "[Trust.Store] Installed fail-closed profile tombstone for #{agent_id} from #{data.origin_node}"
        )

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

  defp disabled_profile(profile) do
    now = DateTime.utc_now()

    %{
      profile
      | frozen: true,
        frozen_reason: :profile_deleted,
        frozen_at: now,
        baseline: :block,
        rules: %{},
        model_constraints: %{},
        egress_modes:
          Map.new(Arbor.Contracts.Security.Classification.egress_tiers(), &{&1, :block}),
        updated_at: now
    }
  end

  defp maybe_filter_by_tier(profiles, nil), do: profiles

  defp maybe_filter_by_tier(profiles, tier) do
    Enum.filter(profiles, &(&1.tier == tier))
  end

  # Async capability sync — revokes stale capabilities after trust profile changes.
  # Runs in a Task to avoid blocking the GenServer.
  defp sync_capabilities_async(agent_id) do
    Task.start(fn ->
      Arbor.Trust.PolicyEnforcer.sync_capabilities(agent_id)
    end)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp load_persisted_profiles(%{persistence_mode: :memory}), do: 0

  defp load_persisted_profiles(state) do
    list_and_load_profiles(state)
  rescue
    e ->
      Logger.warning("[Trust.Store] load_persisted_profiles crashed: #{inspect(e)}")
      0
  end

  defp list_and_load_profiles(state) do
    case durable_list(state) do
      {:ok, keys} ->
        Logger.info("[Trust.Store] Loading #{length(keys)} persisted profiles from BufferedStore")
        Enum.count(keys, &load_one_profile(&1, state))

      other ->
        Logger.warning(
          "[Trust.Store] Unexpected list result from BufferedStore: #{inspect(other)}"
        )

        0
    end
  end

  defp load_one_profile(key, state) do
    result =
      if failed_deletion?(key) do
        {:ok, disabled_profile(Authority.new_profile(key))}
      else
        load_profile_from_db(key, state)
      end

    case result do
      {:ok, profile} ->
        put_profile_in_cache(profile, state)
        true

      other ->
        Logger.warning("[Trust.Store] Failed to load profile #{key}: #{inspect(other)}")
        false
    end
  end

  defp persist_profile(_profile, %{persistence_mode: :memory}), do: :ok

  defp persist_profile(profile, state) do
    record = %Arbor.Contracts.Persistence.Record{
      id: profile.agent_id,
      key: profile.agent_id,
      data: serialize_profile(profile),
      metadata: %{}
    }

    durable_put(profile.agent_id, record, state)
  end

  defp delete_persisted_profile(_agent_id, %{persistence_mode: :memory}), do: :ok

  defp delete_persisted_profile(agent_id, state), do: durable_delete(agent_id, state)

  defp load_profile_from_db(_agent_id, %{persistence_mode: :memory}),
    do: {:error, :not_found}

  defp load_profile_from_db(agent_id, state) do
    if failed_deletion?(agent_id) do
      {:ok, disabled_profile(Authority.new_profile(agent_id))}
    else
      case durable_get(agent_id, state) do
        {:ok, raw} ->
          raw
          |> unwrap_record()
          |> deserialize_profile()

        {:error, _reason} ->
          {:error, :not_found}
      end
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp unwrap_record(%Arbor.Contracts.Persistence.Record{data: data}), do: data
  defp unwrap_record(%{} = data), do: data

  defp failed_deletion?(agent_id) do
    @failed_deletion_key
    |> :persistent_term.get(MapSet.new())
    |> MapSet.member?(agent_id)
  end

  defp remember_failed_deletion(agent_id) do
    failed = :persistent_term.get(@failed_deletion_key, MapSet.new())
    :persistent_term.put(@failed_deletion_key, MapSet.put(failed, agent_id))
  end

  defp clear_failed_deletion(agent_id) do
    failed = :persistent_term.get(@failed_deletion_key, MapSet.new())
    :persistent_term.put(@failed_deletion_key, MapSet.delete(failed, agent_id))
  end

  # BufferedStore intentionally keeps accepting writes when its backend is
  # unavailable. Trust profiles carry authorization policy, so durable mode
  # cannot use that best-effort acknowledgement path. The supervisor still
  # starts BufferedStore first for compatibility with the shared persistence
  # topology; this store calls the configured backend directly and caches only
  # after the backend acknowledges the record.
  defp durable_put(_key, _record, %{durable_backend: nil}),
    do: {:error, :trust_profile_persistence_unavailable}

  defp durable_put(key, record, state) do
    durable_call(state, :put, [key, record])
  end

  defp durable_get(_key, %{durable_backend: nil}),
    do: {:error, :trust_profile_persistence_unavailable}

  defp durable_get(key, state) do
    durable_call(state, :get, [key])
  end

  defp durable_list(%{durable_backend: nil}),
    do: {:error, :trust_profile_persistence_unavailable}

  defp durable_list(state), do: durable_call(state, :list, [])

  defp durable_delete(_key, %{durable_backend: nil}),
    do: {:error, :trust_profile_persistence_unavailable}

  defp durable_delete(key, state), do: durable_call(state, :delete, [key])

  defp durable_call(state, operation, args) do
    opts = Keyword.put(state.durable_backend_opts, :name, state.durable_collection)

    case apply(state.durable_backend, operation, args ++ [opts]) do
      :ok when operation in [:put, :delete] -> :ok
      {:ok, _value} = ok -> ok
      {:error, reason} -> {:error, {:trust_profile_persist_failed, reason}}
      other -> {:error, {:unexpected_trust_profile_persist_result, other}}
    end
  rescue
    error -> {:error, {:trust_profile_persist_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:trust_profile_persist_exit, reason}}
    kind, reason -> {:error, {:trust_profile_persist_failure, kind, reason}}
  end

  # Profile serialization lives on Authority — single source of truth so the
  # encoding can't drift between Store and any future persistence layers.
  defp serialize_profile(%Profile{} = profile), do: Authority.for_persistence(profile)
  defp deserialize_profile(data), do: Authority.from_persistence(data)

  defp emit_distributed_signal(type, agent_id) do
    Arbor.Signals.durable_emit(
      :trust,
      type,
      %{
        agent_id: agent_id,
        origin_node: node()
      },
      stream_id: "trust:events"
    )

    :ok
  catch
    _, _ -> :ok
  end

  defp subscribe_to_distributed_signals do
    if Process.whereis(Arbor.Signals.Bus) do
      me = self()

      for type <- ~w(profile_updated profile_deleted profile_disabled) do
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
end
