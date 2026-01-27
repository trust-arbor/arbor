defmodule Arbor.Security.TrustStore do
  @moduledoc """
  In-memory storage for trust profiles.

  Stores and manages trust profiles for agents, handling
  trust score calculations and tier transitions.
  """

  use GenServer

  alias Arbor.Contracts.Trust.Profile, as: TrustProfile

  # Client API

  @doc """
  Start the trust store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new trust profile for an agent.
  """
  @spec create(String.t()) :: {:ok, TrustProfile.t()} | {:error, :already_exists}
  def create(agent_id) do
    GenServer.call(__MODULE__, {:create, agent_id})
  end

  @doc """
  Get a trust profile by agent ID.
  """
  @spec get(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def get(agent_id) do
    GenServer.call(__MODULE__, {:get, agent_id})
  end

  @doc """
  Get the trust tier for an agent.
  """
  @spec get_tier(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_tier(agent_id) do
    GenServer.call(__MODULE__, {:get_tier, agent_id})
  end

  @doc """
  Update a trust profile.
  """
  @spec update(String.t(), (TrustProfile.t() -> TrustProfile.t())) ::
          {:ok, TrustProfile.t()} | {:error, :not_found}
  def update(agent_id, update_fn) when is_function(update_fn, 1) do
    GenServer.call(__MODULE__, {:update, agent_id, update_fn})
  end

  @doc """
  Record a successful action for an agent.
  """
  @spec record_success(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def record_success(agent_id) do
    update(agent_id, fn profile ->
      profile
      |> TrustProfile.record_action_success()
      |> TrustProfile.recalculate()
    end)
  end

  @doc """
  Record a failed action for an agent.
  """
  @spec record_failure(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def record_failure(agent_id) do
    update(agent_id, fn profile ->
      profile
      |> TrustProfile.record_action_failure()
      |> TrustProfile.recalculate()
    end)
  end

  @doc """
  Record a security violation for an agent.
  """
  @spec record_violation(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def record_violation(agent_id) do
    update(agent_id, fn profile ->
      profile
      |> TrustProfile.record_security_violation()
      |> TrustProfile.recalculate()
    end)
  end

  @doc """
  Freeze an agent's trust.
  """
  @spec freeze(String.t(), atom()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def freeze(agent_id, reason) do
    update(agent_id, fn profile ->
      TrustProfile.freeze(profile, reason)
    end)
  end

  @doc """
  Unfreeze an agent's trust.
  """
  @spec unfreeze(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def unfreeze(agent_id) do
    update(agent_id, &TrustProfile.unfreeze/1)
  end

  @doc """
  Delete a trust profile.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(agent_id) do
    GenServer.call(__MODULE__, {:delete, agent_id})
  end

  @doc """
  List all trust profiles.
  """
  @spec list(keyword()) :: {:ok, [TrustProfile.t()]}
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc """
  Get store statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{profiles: %{}}}
  end

  @impl true
  def handle_call({:create, agent_id}, _from, state) do
    if Map.has_key?(state.profiles, agent_id) do
      {:reply, {:error, :already_exists}, state}
    else
      case TrustProfile.new(agent_id) do
        {:ok, profile} ->
          state = put_in(state, [:profiles, agent_id], profile)
          {:reply, {:ok, profile}, state}

        error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:get, agent_id}, _from, state) do
    result =
      case Map.get(state.profiles, agent_id) do
        nil -> {:error, :not_found}
        profile -> {:ok, profile}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_tier, agent_id}, _from, state) do
    result =
      case Map.get(state.profiles, agent_id) do
        nil -> {:error, :not_found}
        profile -> {:ok, profile.tier}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update, agent_id, update_fn}, _from, state) do
    case Map.get(state.profiles, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      profile ->
        updated = update_fn.(profile)
        state = put_in(state, [:profiles, agent_id], updated)
        {:reply, {:ok, updated}, state}
    end
  end

  @impl true
  def handle_call({:delete, agent_id}, _from, state) do
    if Map.has_key?(state.profiles, agent_id) do
      state = update_in(state, [:profiles], &Map.delete(&1, agent_id))
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    tier_filter = Keyword.get(opts, :tier)
    frozen_filter = Keyword.get(opts, :frozen)
    limit = Keyword.get(opts, :limit, 100)

    profiles =
      state.profiles
      |> Map.values()
      |> maybe_filter_tier(tier_filter)
      |> maybe_filter_frozen(frozen_filter)
      |> Enum.take(limit)

    {:reply, {:ok, profiles}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    profiles = Map.values(state.profiles)

    tier_counts =
      profiles
      |> Enum.group_by(& &1.tier)
      |> Map.new(fn {tier, list} -> {tier, length(list)} end)

    stats = %{
      total_profiles: map_size(state.profiles),
      frozen_count: Enum.count(profiles, & &1.frozen),
      tier_distribution: tier_counts
    }

    {:reply, stats, state}
  end

  # Private functions

  defp maybe_filter_tier(profiles, nil), do: profiles
  defp maybe_filter_tier(profiles, tier), do: Enum.filter(profiles, &(&1.tier == tier))

  defp maybe_filter_frozen(profiles, nil), do: profiles
  defp maybe_filter_frozen(profiles, frozen), do: Enum.filter(profiles, &(&1.frozen == frozen))
end
