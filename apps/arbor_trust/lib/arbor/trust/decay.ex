defmodule Arbor.Trust.Decay do
  @moduledoc """
  Trust decay management for inactive agents.

  This module implements the "use it or lose it" decay policy for
  trust scores. Agents that remain inactive gradually lose trust,
  encouraging regular activity and preventing stale trust profiles.

  ## Decay Policy

  - **Grace Period**: 7 days of inactivity before decay begins
  - **Decay Rate**: 1 point per day after grace period
  - **Floor**: Trust never decays below 10 (preserves minimal read access)

  ## Scheduled Decay

  The decay process runs daily at a configurable time (default: 3 AM UTC).
  It scans all trust profiles and applies decay to inactive agents.

  ## Usage

      # Start the decay scheduler
      {:ok, pid} = Trust.Decay.start_link(run_time: ~T[03:00:00])

      # Manually trigger decay check
      Trust.Decay.run_decay_check()

      # Calculate decay for a specific profile
      decayed_profile = Trust.Decay.apply_decay(profile, days_inactive)
  """

  use GenServer

  alias Arbor.Contracts.Trust.{Event, Profile}
  alias Arbor.Signals
  alias Arbor.Trust.{Config, Store, TierResolver}

  require Logger

  defstruct [
    :run_time,
    :grace_period_days,
    :decay_rate,
    :floor_score,
    :enabled
  ]

  # Client API

  @doc """
  Start the decay scheduler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a decay check.
  """
  @spec run_decay_check() :: :ok
  def run_decay_check do
    GenServer.cast(__MODULE__, :run_decay_check)
  end

  @doc """
  Apply decay to a trust profile.

  Pure function that calculates the decayed score based on days inactive.
  """
  @spec apply_decay(Profile.t(), non_neg_integer()) :: Profile.t()
  def apply_decay(%Profile{} = profile, days_inactive) do
    decay_config = Config.decay_config()

    apply_decay(profile, days_inactive, %{
      grace_period: Map.get(decay_config, :grace_period_days, 7),
      decay_rate: Map.get(decay_config, :decay_rate, 1),
      floor: Map.get(decay_config, :floor_score, 10)
    })
  end

  @doc """
  Apply decay with custom configuration.
  """
  @spec apply_decay(Profile.t(), non_neg_integer(), map()) :: Profile.t()
  def apply_decay(%Profile{} = profile, days_inactive, config) do
    grace_period = Map.get(config, :grace_period, 7)
    decay_rate = Map.get(config, :decay_rate, 1)
    floor = Map.get(config, :floor, 10)

    if days_inactive > grace_period do
      decay_days = days_inactive - grace_period
      decay_amount = decay_days * decay_rate
      new_score = max(floor, profile.trust_score - decay_amount)
      new_tier = TierResolver.resolve(new_score)

      %{profile | trust_score: new_score, tier: new_tier}
    else
      profile
    end
  end

  @doc """
  Calculate days since last activity.
  """
  @spec days_inactive(Profile.t()) :: non_neg_integer()
  def days_inactive(%Profile{last_activity_at: nil, created_at: created_at}) do
    DateTime.diff(DateTime.utc_now(), created_at, :day)
  end

  def days_inactive(%Profile{last_activity_at: last_activity}) do
    DateTime.diff(DateTime.utc_now(), last_activity, :day)
  end

  @doc """
  Get current configuration.
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Enable/disable decay.
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    decay_config = Config.decay_config()

    state = %__MODULE__{
      run_time: Keyword.get(opts, :run_time, Map.get(decay_config, :run_time, ~T[03:00:00])),
      grace_period_days:
        Keyword.get(opts, :grace_period_days, Map.get(decay_config, :grace_period_days, 7)),
      decay_rate: Keyword.get(opts, :decay_rate, Map.get(decay_config, :decay_rate, 1)),
      floor_score: Keyword.get(opts, :floor_score, Map.get(decay_config, :floor_score, 10)),
      enabled: Keyword.get(opts, :enabled, true)
    }

    # Schedule first run
    if state.enabled do
      schedule_next_run(state.run_time)
    end

    Logger.info("Trust.Decay scheduler started",
      run_time: state.run_time,
      enabled: state.enabled
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    config = %{
      run_time: state.run_time,
      grace_period_days: state.grace_period_days,
      decay_rate: state.decay_rate,
      floor_score: state.floor_score,
      enabled: state.enabled
    }

    {:reply, config, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    if enabled and not state.enabled do
      schedule_next_run(state.run_time)
    end

    {:reply, :ok, %{state | enabled: enabled}}
  end

  @impl true
  def handle_cast(:run_decay_check, state) do
    if state.enabled do
      run_decay_check_impl(state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_run, state) do
    if state.enabled do
      run_decay_check_impl(state)
      schedule_next_run(state.run_time)
    end

    {:noreply, state}
  end

  # Private functions

  defp run_decay_check_impl(state) do
    Logger.info("Running trust decay check")

    config = %{
      grace_period: state.grace_period_days,
      decay_rate: state.decay_rate,
      floor: state.floor_score
    }

    {:ok, profiles} = Store.list_profiles([])

    decayed_count =
      profiles
      |> Enum.map(fn profile ->
        days = days_inactive(profile)
        {profile, days, apply_decay(profile, days, config)}
      end)
      |> Enum.filter(fn {old, _days, new} ->
        old.trust_score != new.trust_score
      end)
      |> Enum.map(fn {old_profile, days, decayed_profile} ->
        Store.store_profile(decayed_profile)
        emit_decay_event(old_profile, decayed_profile, days)
        emit_decay_applied(decayed_profile.agent_id, old_profile.trust_score, decayed_profile.trust_score)
        1
      end)
      |> Enum.sum()

    Logger.info("Trust decay check complete",
      profiles_checked: length(profiles),
      profiles_decayed: decayed_count
    )
  end

  defp emit_decay_event(old_profile, new_profile, days_inactive) do
    {:ok, event} =
      Event.new(
        agent_id: new_profile.agent_id,
        event_type: :trust_decayed,
        previous_score: old_profile.trust_score,
        new_score: new_profile.trust_score,
        previous_tier: old_profile.tier,
        new_tier: new_profile.tier,
        metadata: %{days_inactive: days_inactive}
      )

    Store.store_event(event)

    Logger.debug("Trust decayed for agent #{new_profile.agent_id}",
      agent_id: new_profile.agent_id,
      days_inactive: days_inactive,
      old_score: old_profile.trust_score,
      new_score: new_profile.trust_score
    )
  end

  defp schedule_next_run(run_time) do
    now = DateTime.utc_now()
    today_run = DateTime.new!(Date.utc_today(), run_time, "Etc/UTC")

    next_run =
      if DateTime.compare(now, today_run) == :lt do
        today_run
      else
        DateTime.add(today_run, 1, :day)
      end

    delay_ms = DateTime.diff(next_run, now, :millisecond)
    Process.send_after(self(), :scheduled_run, delay_ms)

    Logger.debug("Next decay check scheduled for #{next_run}")
  end

  # Signal emission helper

  defp emit_decay_applied(agent_id, old_score, new_score) do
    Signals.emit(:trust, :decay_applied, %{
      agent_id: agent_id,
      old_score: old_score,
      new_score: new_score
    })
  end
end
