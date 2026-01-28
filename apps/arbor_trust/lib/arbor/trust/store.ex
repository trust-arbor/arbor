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
  alias Arbor.Trust.{Calculator, Config}

  require Logger

  @table_name :trust_profile_cache
  @events_table :trust_events_cache
  # 1 hour TTL for cached profiles
  @cache_ttl_seconds 3600

  defstruct [
    :profiles_table,
    :events_table,
    :db_module,
    :cache_stats
  ]

  @type state :: %__MODULE__{
          profiles_table: :ets.table(),
          events_table: :ets.table(),
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
  """
  @spec get_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_profile(agent_id) do
    GenServer.call(__MODULE__, {:get_profile, agent_id})
  end

  @doc """
  Check if a profile exists.
  """
  @spec profile_exists?(String.t()) :: boolean()
  def profile_exists?(agent_id) do
    GenServer.call(__MODULE__, {:profile_exists, agent_id})
  end

  @doc """
  Delete a trust profile.
  """
  @spec delete_profile(String.t()) :: :ok | {:error, term()}
  def delete_profile(agent_id) do
    GenServer.call(__MODULE__, {:delete_profile, agent_id})
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
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_action_success()
      |> Profile.recalculate()
    end)
  end

  @doc """
  Record a failed action for an agent.
  """
  @spec record_action_failure(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_action_failure(agent_id) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_action_failure()
      |> Profile.recalculate()
    end)
  end

  @doc """
  Record a security violation for an agent.
  """
  @spec record_security_violation(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_security_violation(agent_id) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_security_violation()
      |> Profile.recalculate()
    end)
  end

  @doc """
  Record a test result for an agent.
  """
  @spec record_test_result(String.t(), :passed | :failed) ::
          {:ok, Profile.t()} | {:error, term()}
  def record_test_result(agent_id, result) when result in [:passed, :failed] do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_test_result(result)
      |> Profile.recalculate()
    end)
  end

  @doc """
  Record a rollback for an agent.
  """
  @spec record_rollback(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_rollback(agent_id) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_rollback()
      |> Profile.recalculate()
    end)
  end

  @doc """
  Record an improvement being applied.
  """
  @spec record_improvement(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_improvement(agent_id) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_improvement()
      |> Profile.recalculate()
    end)
  end

  # Council-based trust earning functions

  @doc """
  Record a proposal submission.
  """
  @spec record_proposal_submitted(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_proposal_submitted(agent_id) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_proposal_submitted()
      |> recalculate_with_points(profile)
    end)
  end

  @doc """
  Record a proposal being approved by council.
  """
  @spec record_proposal_approved(String.t(), atom()) :: {:ok, Profile.t()} | {:error, term()}
  def record_proposal_approved(agent_id, impact \\ :medium) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_proposal_approved(impact)
      |> recalculate_with_points(profile)
    end)
  end

  @doc """
  Record a successful installation.
  """
  @spec record_installation_success(String.t(), atom()) ::
          {:ok, Profile.t()} | {:error, term()}
  def record_installation_success(agent_id, impact \\ :medium) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_installation_success(impact)
      |> recalculate_with_points(profile)
    end)
  end

  @doc """
  Record an installation rollback.
  """
  @spec record_installation_rollback(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def record_installation_rollback(agent_id) do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.record_installation_rollback()
      |> recalculate_with_points(profile)
    end)
  end

  @doc """
  Award trust points directly (for special cases).
  """
  @spec award_trust_points(String.t(), non_neg_integer()) ::
          {:ok, Profile.t()} | {:error, term()}
  def award_trust_points(agent_id, points) when points >= 0 do
    update_profile(agent_id, fn profile ->
      updated = %{profile | trust_points: profile.trust_points + points}
      recalculate_with_points(updated, profile)
    end)
  end

  @doc """
  Deduct trust points (for abuse or violations).
  """
  @spec deduct_trust_points(String.t(), non_neg_integer(), atom()) ::
          {:ok, Profile.t()} | {:error, term()}
  def deduct_trust_points(agent_id, points, reason) when points >= 0 do
    update_profile(agent_id, fn profile ->
      profile
      |> Profile.deduct_trust_points(points, reason)
      |> recalculate_with_points(profile)
    end)
  end

  # Helper to recalculate trust score incorporating trust points
  defp recalculate_with_points(profile, _old_profile) do
    # Recalculate the weighted score first
    recalculated = Profile.recalculate(profile)

    # The tier is now determined by the higher of:
    # 1. The weighted component score
    # 2. The trust points tier
    weighted_tier = recalculated.tier
    points_tier = Profile.points_to_tier(recalculated.trust_points)

    # Use the higher tier (trust points can boost tier, but not lower it)
    final_tier = higher_tier(weighted_tier, points_tier)

    %{recalculated | tier: final_tier}
  end

  defp higher_tier(tier1, tier2) do
    tier_order = Config.tiers()
    idx1 = Enum.find_index(tier_order, &(&1 == tier1)) || 0
    idx2 = Enum.find_index(tier_order, &(&1 == tier2)) || 0
    Enum.at(tier_order, max(idx1, idx2))
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
  Store a trust event.
  """
  @spec store_event(Event.t()) :: :ok
  def store_event(%Event{} = event) do
    GenServer.call(__MODULE__, {:store_event, event})
  end

  @doc """
  Get recent events for an agent.
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [Event.t()]}
  def get_events(agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_events, agent_id, opts})
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
        :protected,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    events_table =
      :ets.new(@events_table, [
        :ordered_set,
        :protected,
        :named_table,
        {:read_concurrency, true}
      ])

    # Optional PostgreSQL persistence module
    db_module = opts[:db_module]

    state = %__MODULE__{
      profiles_table: profiles_table,
      events_table: events_table,
      db_module: db_module,
      cache_stats: %{hits: 0, misses: 0, writes: 0, deletes: 0, events: 0}
    }

    Logger.info("Trust.Store started with ETS tables")

    {:ok, state}
  end

  @impl true
  def handle_call({:store_profile, profile}, _from, state) do
    :ok = put_profile_in_cache(profile, state)
    persist_profile(profile, state)

    new_stats = update_stats(state.cache_stats, :writes, 1)
    {:reply, :ok, %{state | cache_stats: new_stats}}
  end

  @impl true
  def handle_call({:get_profile, agent_id}, _from, state) do
    case get_profile_from_cache(agent_id, state) do
      {:ok, profile} ->
        new_stats = update_stats(state.cache_stats, :hits, 1)
        {:reply, {:ok, profile}, %{state | cache_stats: new_stats}}

      {:error, :not_found} ->
        # Try DB fallback if available
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
  end

  @impl true
  def handle_call({:profile_exists, agent_id}, _from, state) do
    exists = :ets.member(state.profiles_table, agent_id)
    {:reply, exists, state}
  end

  @impl true
  def handle_call({:delete_profile, agent_id}, _from, state) do
    :ets.delete(state.profiles_table, agent_id)
    delete_profile_from_db(agent_id, state)

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

        new_stats = update_stats(state.cache_stats, :writes, 1)
        {:reply, {:ok, updated}, %{state | cache_stats: new_stats}}

      {:error, :not_found} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:store_event, event}, _from, state) do
    # Use timestamp + id as key for ordering
    key = {event.timestamp, event.id}
    :ets.insert(state.events_table, {{event.agent_id, key}, event})

    new_stats = update_stats(state.cache_stats, :events, 1)
    {:reply, :ok, %{state | cache_stats: new_stats}}
  end

  @impl true
  def handle_call({:get_events, agent_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)

    # Get all events for this agent
    events =
      :ets.match_object(state.events_table, {{agent_id, :_}, :_})
      |> Enum.map(fn {_key, event} -> event end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, {:ok, events}, state}
  end

  @impl true
  def handle_call({:list_profiles, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    tier_filter = Keyword.get(opts, :tier)

    profiles =
      :ets.tab2list(state.profiles_table)
      |> Enum.map(fn {_key, {profile, _expiry}} -> profile end)
      |> maybe_filter_by_tier(tier_filter)
      |> Enum.sort_by(& &1.trust_score, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, profiles}, state}
  end

  @impl true
  def handle_call(:recalculate_all, _from, state) do
    now = DateTime.utc_now()

    :ets.tab2list(state.profiles_table)
    |> Enum.each(fn {_agent_id, {profile, _expiry}} ->
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
          profiles_memory: :ets.info(state.profiles_table, :memory),
          events_size: :ets.info(state.events_table, :size),
          events_memory: :ets.info(state.events_table, :memory)
        }
      rescue
        _ -> %{profiles_size: 0, profiles_memory: 0, events_size: 0, events_memory: 0}
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

    if :ets.info(state.events_table) != :undefined do
      :ets.delete(state.events_table)
    end

    :ok
  end

  # Private functions

  defp put_profile_in_cache(profile, state) do
    cache_entry = {profile, cache_expiry()}
    :ets.insert(state.profiles_table, {profile.agent_id, cache_entry})
    :ok
  end

  defp get_profile_from_cache(agent_id, state) do
    case :ets.lookup(state.profiles_table, agent_id) do
      [{^agent_id, {profile, expiry}}] ->
        if DateTime.compare(DateTime.utc_now(), expiry) == :lt do
          {:ok, profile}
        else
          # Expired, but still return it (soft expiry)
          # A background job should refresh stale entries
          {:ok, profile}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp cache_expiry do
    DateTime.add(DateTime.utc_now(), @cache_ttl_seconds, :second)
  end

  defp update_stats(stats, key, increment) do
    Map.update(stats, key, increment, &(&1 + increment))
  end

  defp maybe_filter_by_tier(profiles, nil), do: profiles

  defp maybe_filter_by_tier(profiles, tier) do
    Enum.filter(profiles, &(&1.tier == tier))
  end

  defp persist_profile(_profile, %{db_module: nil}), do: :ok

  defp persist_profile(profile, %{db_module: db_module}) do
    Task.start(fn ->
      case db_module.upsert_trust_profile(profile) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Failed to persist trust profile: #{inspect(reason)}")
      end
    end)
  end

  defp load_profile_from_db(_agent_id, %{db_module: nil}), do: {:error, :not_found}

  defp load_profile_from_db(agent_id, %{db_module: db_module}) do
    db_module.get_trust_profile(agent_id)
  end

  defp delete_profile_from_db(_agent_id, %{db_module: nil}), do: :ok

  defp delete_profile_from_db(agent_id, %{db_module: db_module}) do
    Task.start(fn ->
      db_module.delete_trust_profile(agent_id)
    end)
  end

  defp emit_tier_change_event(old_profile, new_profile, state) do
    {:ok, event} =
      Event.tier_change_event(
        new_profile.agent_id,
        old_profile.tier,
        new_profile.tier,
        previous_score: old_profile.trust_score,
        new_score: new_profile.trust_score
      )

    # Store the event
    key = {event.timestamp, event.id}
    :ets.insert(state.events_table, {{event.agent_id, key}, event})

    # Broadcast via PubSub if available
    try do
      Phoenix.PubSub.broadcast(
        Config.pubsub(),
        "trust:#{new_profile.agent_id}",
        {:tier_changed, new_profile.agent_id, old_profile.tier, new_profile.tier}
      )
    rescue
      _ -> :ok
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
