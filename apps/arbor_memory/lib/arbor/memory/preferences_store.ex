defmodule Arbor.Memory.PreferencesStore do
  @moduledoc """
  ETS-backed storage for agent preferences with signal emission.

  Stateless module (not a GenServer) — the ETS table is created in
  `Application.start/2`. Owns the full CRUD + signal lifecycle.
  """

  alias Arbor.Memory.{Preferences, Signals}

  @preferences_ets :arbor_preferences

  # ============================================================================
  # Core CRUD
  # ============================================================================

  @doc """
  Get preferences for an agent. Returns nil if not set.
  """
  @spec get_preferences(String.t()) :: Preferences.t() | nil
  def get_preferences(agent_id) do
    case :ets.lookup(@preferences_ets, agent_id) do
      [{^agent_id, prefs}] -> prefs
      [] -> nil
    end
  end

  @doc """
  Save preferences for an agent.
  """
  @spec save_preferences(String.t(), Preferences.t()) :: :ok
  def save_preferences(agent_id, prefs) do
    :ets.insert(@preferences_ets, {agent_id, prefs})
    :ok
  end

  @doc """
  Get or create preferences for an agent.
  """
  @spec get_or_create(String.t()) :: Preferences.t()
  def get_or_create(agent_id) do
    case get_preferences(agent_id) do
      nil ->
        prefs = Preferences.new(agent_id)
        save_preferences(agent_id, prefs)
        prefs

      prefs ->
        prefs
    end
  end

  # ============================================================================
  # Preference Operations
  # ============================================================================

  @doc """
  Adjust a cognitive preference for an agent.

  ## Parameters

  - `:decay_rate` - 0.01 to 0.50 (narrower per trust tier)
  - `:max_pins` - 1 to 200 (narrower per trust tier)
  - `:retrieval_threshold` - 0.0 to 1.0
  - `:consolidation_interval` - 60,000ms to 3,600,000ms
  - `:attention_focus` - String or nil
  - `:type_quota` - Tuple of {type, quota}
  - `:context_preference` - Tuple of {key, value}

  ## Options

  - `:trust_tier` - Trust tier for tier-specific validation bounds
  """
  @spec adjust_preference(String.t(), atom(), term(), keyword()) ::
          {:ok, Preferences.t()} | {:error, term()}
  def adjust_preference(agent_id, param, value, opts \\ []) do
    prefs = get_or_create(agent_id)

    case Preferences.adjust(prefs, param, value, opts) do
      {:ok, updated_prefs} ->
        save_preferences(agent_id, updated_prefs)

        Signals.emit_cognitive_adjustment(agent_id, param, %{
          old_value: Map.get(prefs, param),
          new_value: value,
          trust_tier: Keyword.get(opts, :trust_tier)
        })

        {:ok, updated_prefs}

      error ->
        error
    end
  end

  @doc """
  Pin a memory to protect it from decay.
  """
  @spec pin_memory(String.t(), String.t(), keyword()) ::
          {:ok, Preferences.t()} | {:error, :max_pins_reached}
  def pin_memory(agent_id, memory_id, opts \\ []) do
    prefs = get_or_create(agent_id)

    case Preferences.pin(prefs, memory_id, opts) do
      {:error, _} = error ->
        error

      updated_prefs ->
        save_preferences(agent_id, updated_prefs)
        Signals.emit_cognitive_adjustment(agent_id, :pin_memory, %{memory_id: memory_id})
        {:ok, updated_prefs}
    end
  end

  @doc """
  Unpin a memory, allowing it to decay normally.
  """
  @spec unpin_memory(String.t(), String.t()) :: {:ok, Preferences.t()}
  def unpin_memory(agent_id, memory_id) do
    prefs = get_or_create(agent_id)
    updated_prefs = Preferences.unpin(prefs, memory_id)
    save_preferences(agent_id, updated_prefs)
    Signals.emit_cognitive_adjustment(agent_id, :unpin_memory, %{memory_id: memory_id})
    {:ok, updated_prefs}
  end

  @doc """
  Get a summary of current preferences and usage.
  """
  @spec inspect_preferences(String.t()) :: map()
  def inspect_preferences(agent_id) do
    case get_preferences(agent_id) do
      nil -> %{agent_id: agent_id, status: :not_initialized}
      prefs -> Preferences.inspect_preferences(prefs)
    end
  end

  @doc """
  Get a trust-aware introspection of current preferences.
  """
  @spec introspect_preferences(String.t(), atom()) :: map()
  def introspect_preferences(agent_id, trust_tier) do
    case get_preferences(agent_id) do
      nil -> %{agent_id: agent_id, status: :not_initialized}
      prefs -> Preferences.introspect(prefs, trust_tier)
    end
  end

  @doc """
  Set a context preference for prompt building.
  """
  @spec set_context_preference(String.t(), atom(), term()) :: {:ok, Preferences.t()}
  def set_context_preference(agent_id, key, value) do
    prefs = get_or_create(agent_id)
    {:ok, updated_prefs} = Preferences.set_context_preference(prefs, key, value)
    save_preferences(agent_id, updated_prefs)

    Signals.emit_cognitive_adjustment(agent_id, :context_preference, %{
      key: key,
      value: value
    })

    {:ok, updated_prefs}
  end

  @doc """
  Get a context preference value.
  """
  @spec get_context_preference(String.t(), atom(), term()) :: term()
  def get_context_preference(agent_id, key, default \\ nil) do
    case get_preferences(agent_id) do
      nil -> default
      prefs -> Preferences.get_context_preference(prefs, key, default)
    end
  end

  @doc """
  Save preferences for an agent (public wrapper for Seed restore).
  """
  @spec save_preferences_for_agent(String.t(), Preferences.t()) :: :ok
  def save_preferences_for_agent(agent_id, prefs) do
    save_preferences(agent_id, prefs)
  end
end
