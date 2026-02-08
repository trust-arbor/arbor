defmodule Arbor.Memory.Preferences do
  @moduledoc """
  Agent-controlled cognitive tuning parameters.

  Preferences allows agents to tune their own cognitive behavior, including:
  - Memory decay rate
  - Per-type memory quotas
  - Memory pinning (protection from decay)
  - Attention focus areas
  - Retrieval threshold
  - Consolidation interval
  - Context preferences (what to include in context windows)

  All parameters are validated to stay within safe ranges. When a trust tier
  is provided, tier-specific bounds are used for validation.

  ## Usage

      prefs = Preferences.new("agent_001")
      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15)
      prefs = Preferences.pin(prefs, "important_memory_id")

  ## Trust-Aware Usage

      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15, trust_tier: :trusted)
      prefs = Preferences.pin(prefs, "memory_id", trust_tier: :trusted)
      report = Preferences.introspect(prefs, :trusted)
  """

  @type t :: %__MODULE__{
          agent_id: String.t(),
          decay_rate: float(),
          type_quotas: %{atom() => pos_integer() | :unlimited},
          pinned_memories: [String.t()],
          max_pins: pos_integer(),
          attention_focus: String.t() | nil,
          retrieval_threshold: float(),
          consolidation_interval: pos_integer(),
          context_preferences: map(),
          last_adjusted_at: DateTime.t() | nil,
          adjustment_count: non_neg_integer()
        }

  @enforce_keys [:agent_id]
  defstruct [
    :agent_id,
    decay_rate: 0.10,
    type_quotas: %{
      fact: 500,
      experience: 200,
      skill: 100,
      insight: 100,
      relationship: :unlimited
    },
    pinned_memories: [],
    max_pins: 50,
    attention_focus: nil,
    retrieval_threshold: 0.3,
    consolidation_interval: 1_800_000,
    context_preferences: %{
      include_goals: true,
      include_relationships: true,
      include_recent_facts: true,
      include_self_insights: true,
      max_context_nodes: 50
    },
    last_adjusted_at: nil,
    adjustment_count: 0
  ]

  # Global validation ranges (used when no trust tier is provided)
  @decay_rate_min 0.01
  @decay_rate_max 0.50
  @max_pins_min 1
  @max_pins_max 200
  @retrieval_threshold_min 0.0
  @retrieval_threshold_max 1.0
  @consolidation_interval_min 60_000
  @consolidation_interval_max 3_600_000

  @default_context_preferences %{
    include_goals: true,
    include_relationships: true,
    include_recent_facts: true,
    include_self_insights: true,
    max_context_nodes: 50
  }

  # Per-tier cognitive bounds (self-contained, no external dependency)
  @tier_cognitive_bounds %{
    untrusted: %{
      decay_range: {0.10, 0.10},
      quota_range: {20, 20},
      max_pins: 0,
      can_adjust: false,
      can_pin: false
    },
    probationary: %{
      decay_range: {0.08, 0.12},
      quota_range: {15, 25},
      max_pins: 5,
      can_adjust: true,
      can_pin: true
    },
    trusted: %{
      decay_range: {0.05, 0.15},
      quota_range: {10, 35},
      max_pins: 15,
      can_adjust: true,
      can_pin: true
    },
    veteran: %{
      decay_range: {0.03, 0.20},
      quota_range: {5, 50},
      max_pins: 30,
      can_adjust: true,
      can_pin: true
    },
    autonomous: %{
      decay_range: {0.01, 0.25},
      quota_range: {5, 60},
      max_pins: 50,
      can_adjust: true,
      can_pin: true
    }
  }

  @valid_tiers Map.keys(@tier_cognitive_bounds)

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new Preferences struct for an agent.

  ## Options

  - `:decay_rate` - Initial decay rate (default: 0.10)
  - `:type_quotas` - Initial type quotas map
  - `:max_pins` - Maximum pinned memories (default: 50)
  - `:retrieval_threshold` - Minimum similarity for recall (default: 0.3)
  - `:consolidation_interval` - Time between consolidations in ms (default: 30 min)
  - `:context_preferences` - Context inclusion preferences map
  - `:attention_focus` - Initial attention focus string

  ## Examples

      prefs = Preferences.new("agent_001")
      prefs = Preferences.new("agent_001", decay_rate: 0.15, max_pins: 100)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    %__MODULE__{
      agent_id: agent_id,
      decay_rate: Keyword.get(opts, :decay_rate, 0.10),
      type_quotas:
        Keyword.get(opts, :type_quotas, %{
          fact: 500,
          experience: 200,
          skill: 100,
          insight: 100,
          relationship: :unlimited
        }),
      pinned_memories: Keyword.get(opts, :pinned_memories, []),
      max_pins: Keyword.get(opts, :max_pins, 50),
      attention_focus: Keyword.get(opts, :attention_focus),
      retrieval_threshold: Keyword.get(opts, :retrieval_threshold, 0.3),
      consolidation_interval: Keyword.get(opts, :consolidation_interval, 1_800_000),
      context_preferences:
        Keyword.get(opts, :context_preferences, @default_context_preferences),
      last_adjusted_at: nil,
      adjustment_count: 0
    }
  end

  # ============================================================================
  # Memory Pinning
  # ============================================================================

  @doc """
  Pin a memory to protect it from decay.

  Returns error if max_pins limit would be exceeded.
  When `trust_tier:` is provided, uses tier-specific pin limits.

  ## Examples

      prefs = Preferences.pin(prefs, "memory_123")
      prefs = Preferences.pin(prefs, "memory_123", trust_tier: :trusted)
  """
  @spec pin(t(), String.t(), keyword()) :: t() | {:error, :max_pins_reached}
  def pin(%__MODULE__{} = prefs, memory_id, opts \\ []) do
    max = tier_max_pins(opts, prefs.max_pins)

    cond do
      memory_id in prefs.pinned_memories ->
        # Already pinned
        prefs

      length(prefs.pinned_memories) >= max ->
        {:error, :max_pins_reached}

      true ->
        %{prefs | pinned_memories: [memory_id | prefs.pinned_memories]}
        |> touch_adjusted()
    end
  end

  @doc """
  Unpin a memory, allowing it to decay normally.

  ## Examples

      prefs = Preferences.unpin(prefs, "memory_123")
  """
  @spec unpin(t(), String.t()) :: t()
  def unpin(%__MODULE__{} = prefs, memory_id) do
    %{prefs | pinned_memories: List.delete(prefs.pinned_memories, memory_id)}
    |> touch_adjusted()
  end

  @doc """
  Check if a memory is pinned.

  ## Examples

      true = Preferences.pinned?(prefs, "memory_123")
  """
  @spec pinned?(t(), String.t()) :: boolean()
  def pinned?(%__MODULE__{} = prefs, memory_id) do
    memory_id in prefs.pinned_memories
  end

  # ============================================================================
  # Context Preferences
  # ============================================================================

  @doc """
  Update a context preference for prompt building.

  ## Examples

      {:ok, prefs} = Preferences.set_context_preference(prefs, :include_goals, false)
      {:ok, prefs} = Preferences.set_context_preference(prefs, :max_context_nodes, 30)
  """
  @spec set_context_preference(t(), atom(), term()) :: {:ok, t()}
  def set_context_preference(%__MODULE__{} = prefs, key, value) do
    new_context_prefs = Map.put(prefs.context_preferences, key, value)
    {:ok, %{prefs | context_preferences: new_context_prefs} |> touch_adjusted()}
  end

  @doc """
  Get a context preference value.

  ## Examples

      true = Preferences.get_context_preference(prefs, :include_goals)
      50 = Preferences.get_context_preference(prefs, :max_context_nodes)
  """
  @spec get_context_preference(t(), atom(), term()) :: term()
  def get_context_preference(%__MODULE__{} = prefs, key, default \\ nil) do
    Map.get(prefs.context_preferences, key, default)
  end

  # ============================================================================
  # Cognitive Adjustment
  # ============================================================================

  @doc """
  Adjust a cognitive parameter.

  All adjustments are validated against safe ranges. When `trust_tier:` is
  provided in opts, uses tier-specific bounds for validation.

  ## Parameters

  - `:decay_rate` - 0.01 to 0.50 (narrower per trust tier)
  - `:max_pins` - 1 to 200 (narrower per trust tier)
  - `:retrieval_threshold` - 0.0 to 1.0
  - `:consolidation_interval` - 60,000ms (1 min) to 3,600,000ms (1 hour)
  - `:attention_focus` - String or nil
  - `:type_quota` - Tuple of {type, quota} where quota is positive integer or :unlimited
  - `:context_preference` - Tuple of {key, value} for context preferences

  ## Options

  - `:trust_tier` - Trust tier atom for tier-specific validation bounds

  ## Examples

      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15)
      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.10, trust_tier: :trusted)
      {:ok, prefs} = Preferences.adjust(prefs, :type_quota, {:fact, 1000})
  """
  @spec adjust(t(), atom(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def adjust(prefs, param, value, opts \\ [])

  def adjust(%__MODULE__{} = prefs, :decay_rate, value, opts) when is_number(value) do
    {min, max} = decay_range_for(opts)

    if value >= min and value <= max do
      {:ok, %{prefs | decay_rate: Float.round(value * 1.0, 4)} |> touch_adjusted()}
    else
      {:error, {:out_of_range, :decay_rate, {min, max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :max_pins, value, opts) when is_integer(value) do
    {min, max} = max_pins_range_for(opts)

    if value >= min and value <= max do
      # Truncate pinned_memories if new limit is lower
      pinned =
        if length(prefs.pinned_memories) > value do
          Enum.take(prefs.pinned_memories, value)
        else
          prefs.pinned_memories
        end

      {:ok, %{prefs | max_pins: value, pinned_memories: pinned} |> touch_adjusted()}
    else
      {:error, {:out_of_range, :max_pins, {min, max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :retrieval_threshold, value, _opts) when is_number(value) do
    if value >= @retrieval_threshold_min and value <= @retrieval_threshold_max do
      {:ok, %{prefs | retrieval_threshold: Float.round(value * 1.0, 4)} |> touch_adjusted()}
    else
      {:error,
       {:out_of_range, :retrieval_threshold,
        {@retrieval_threshold_min, @retrieval_threshold_max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :consolidation_interval, value, _opts)
      when is_integer(value) do
    if value >= @consolidation_interval_min and value <= @consolidation_interval_max do
      {:ok, %{prefs | consolidation_interval: value} |> touch_adjusted()}
    else
      {:error,
       {:out_of_range, :consolidation_interval,
        {@consolidation_interval_min, @consolidation_interval_max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :attention_focus, value, _opts)
      when is_binary(value) or is_nil(value) do
    {:ok, %{prefs | attention_focus: value} |> touch_adjusted()}
  end

  def adjust(%__MODULE__{} = prefs, :type_quota, {type, quota}, opts)
      when is_atom(type) and (is_integer(quota) or quota == :unlimited) do
    with :ok <- validate_quota(quota, type, opts) do
      {:ok, %{prefs | type_quotas: Map.put(prefs.type_quotas, type, quota)} |> touch_adjusted()}
    end
  end

  def adjust(%__MODULE__{} = prefs, :context_preference, {key, value}, _opts)
      when is_atom(key) do
    set_context_preference(prefs, key, value)
  end

  def adjust(_prefs, param, _value, _opts) do
    {:error, {:invalid_param, param}}
  end

  # ============================================================================
  # Trust Tier Bounds
  # ============================================================================

  @doc """
  Get cognitive bounds for a trust tier.

  Returns the bounds map for the given tier, or nil for unknown tiers.

  ## Examples

      bounds = Preferences.bounds_for_tier(:trusted)
      # => %{decay_range: {0.05, 0.15}, quota_range: {10, 35}, max_pins: 15, ...}
  """
  @spec bounds_for_tier(atom()) :: map() | nil
  def bounds_for_tier(tier) when tier in @valid_tiers do
    Map.fetch!(@tier_cognitive_bounds, tier)
  end

  def bounds_for_tier(_), do: nil

  @doc """
  Returns all valid trust tier atoms.
  """
  @spec valid_tiers() :: [atom()]
  def valid_tiers, do: @valid_tiers

  # ============================================================================
  # Introspection
  # ============================================================================

  @doc """
  Get a summary of current preferences and usage.

  Returns a map with current settings and usage statistics.

  ## Examples

      info = Preferences.inspect_preferences(prefs)
      # => %{decay_rate: 0.1, pinned_count: 5, max_pins: 50, ...}
  """
  @spec inspect_preferences(t()) :: map()
  def inspect_preferences(%__MODULE__{} = prefs) do
    %{
      agent_id: prefs.agent_id,
      decay_rate: prefs.decay_rate,
      decay_interpretation: decay_interpretation(prefs.decay_rate),
      type_quotas: prefs.type_quotas,
      pinned_count: length(prefs.pinned_memories),
      max_pins: prefs.max_pins,
      pins_available: prefs.max_pins - length(prefs.pinned_memories),
      attention_focus: prefs.attention_focus,
      retrieval_threshold: prefs.retrieval_threshold,
      consolidation_interval_minutes: div(prefs.consolidation_interval, 60_000),
      context_preferences: prefs.context_preferences,
      last_adjusted_at: prefs.last_adjusted_at,
      adjustment_count: prefs.adjustment_count
    }
  end

  @doc """
  Generate a trust-aware introspection report of cognitive preferences.

  Includes allowed ranges and capability flags for the given trust tier.

  ## Examples

      report = Preferences.introspect(prefs, :trusted)
  """
  @spec introspect(t(), atom()) :: map()
  def introspect(%__MODULE__{} = prefs, trust_tier) when trust_tier in @valid_tiers do
    bounds = Map.fetch!(@tier_cognitive_bounds, trust_tier)
    {min_quota, max_quota} = bounds.quota_range
    {min_decay, max_decay} = bounds.decay_range

    %{
      agent_id: prefs.agent_id,
      type_quotas: %{
        current: prefs.type_quotas,
        allowed_range: {min_quota, max_quota},
        can_adjust: bounds.can_adjust
      },
      decay_rate: %{
        current: prefs.decay_rate,
        allowed_range: {min_decay, max_decay},
        interpretation: decay_interpretation(prefs.decay_rate)
      },
      pinned_memories: %{
        count: length(prefs.pinned_memories),
        max_allowed: bounds.max_pins,
        ids: prefs.pinned_memories,
        can_pin: bounds.can_pin
      },
      context_preferences: prefs.context_preferences,
      attention_focus: prefs.attention_focus,
      retrieval_threshold: prefs.retrieval_threshold,
      consolidation_interval_minutes: div(prefs.consolidation_interval, 60_000),
      metadata: %{
        last_adjusted_at: prefs.last_adjusted_at,
        adjustment_count: prefs.adjustment_count,
        trust_tier: trust_tier
      }
    }
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc """
  Serialize preferences to a map for persistence.

  ## Examples

      data = Preferences.serialize(prefs)
  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = prefs) do
    %{
      agent_id: prefs.agent_id,
      decay_rate: prefs.decay_rate,
      type_quotas:
        Map.new(prefs.type_quotas, fn {k, v} ->
          {to_string(k), serialize_quota(v)}
        end),
      pinned_memories: prefs.pinned_memories,
      max_pins: prefs.max_pins,
      attention_focus: prefs.attention_focus,
      retrieval_threshold: prefs.retrieval_threshold,
      consolidation_interval: prefs.consolidation_interval,
      context_preferences:
        Map.new(prefs.context_preferences, fn {k, v} ->
          {to_string(k), v}
        end),
      last_adjusted_at: format_datetime(prefs.last_adjusted_at),
      adjustment_count: prefs.adjustment_count
    }
  end

  @doc """
  Deserialize a map back to a Preferences struct.

  Uses SafeAtom for atom conversion to prevent atom exhaustion.
  Handles backward compatibility with data missing newer fields.

  ## Examples

      prefs = Preferences.deserialize(data)
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) do
    %__MODULE__{
      agent_id: get_field(data, "agent_id", nil),
      decay_rate: get_field(data, "decay_rate", 0.10) * 1.0,
      type_quotas: deserialize_type_quotas(get_field(data, "type_quotas", %{})),
      pinned_memories: get_field(data, "pinned_memories", []),
      max_pins: get_field(data, "max_pins", 50),
      attention_focus: get_field(data, "attention_focus", nil),
      retrieval_threshold: get_field(data, "retrieval_threshold", 0.3) * 1.0,
      consolidation_interval: get_field(data, "consolidation_interval", 1_800_000),
      context_preferences:
        deserialize_context_preferences(
          get_field(data, "context_preferences", @default_context_preferences)
        ),
      last_adjusted_at: parse_datetime(get_field(data, "last_adjusted_at", nil)),
      adjustment_count: get_field(data, "adjustment_count", 0)
    }
  end

  # ============================================================================
  # Deserialization Helpers
  # ============================================================================

  defp get_field(data, string_key, default) do
    case data[string_key] do
      nil ->
        atom_key = String.to_existing_atom(string_key)
        data[atom_key] || default

      value ->
        value
    end
  end

  @known_quota_types [:fact, :experience, :skill, :insight, :relationship]

  defp deserialize_type_quotas(quotas) do
    alias Arbor.Common.SafeAtom

    quotas
    |> Enum.map(fn {k, v} ->
      key =
        case SafeAtom.to_allowed(to_string(k), @known_quota_types) do
          {:ok, atom} -> atom
          {:error, _} -> String.to_existing_atom(to_string(k))
        end

      {key, deserialize_quota(v)}
    end)
    |> Map.new()
  end

  @known_context_keys [
    :include_goals,
    :include_relationships,
    :include_recent_facts,
    :include_self_insights,
    :max_context_nodes
  ]

  defp deserialize_context_preferences(prefs) when is_map(prefs) do
    Map.new(prefs, fn {k, v} -> {deserialize_context_key(k), v} end)
  end

  defp deserialize_context_preferences(_), do: @default_context_preferences

  defp deserialize_context_key(k) when is_atom(k), do: k

  defp deserialize_context_key(k) do
    alias Arbor.Common.SafeAtom

    case SafeAtom.to_allowed(to_string(k), @known_context_keys) do
      {:ok, atom} -> atom
      {:error, _} -> String.to_existing_atom(to_string(k))
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp touch_adjusted(%__MODULE__{} = prefs) do
    %{prefs | last_adjusted_at: DateTime.utc_now(), adjustment_count: prefs.adjustment_count + 1}
  end

  defp decay_interpretation(rate) when rate <= 0.05, do: "Very slow (long retention)"
  defp decay_interpretation(rate) when rate <= 0.10, do: "Normal (balanced retention)"
  defp decay_interpretation(rate) when rate <= 0.15, do: "Moderate (faster cycling)"
  defp decay_interpretation(_rate), do: "Fast (rapid cycling)"

  defp decay_range_for(opts) do
    case Keyword.get(opts, :trust_tier) do
      nil ->
        {@decay_rate_min, @decay_rate_max}

      tier when tier in @valid_tiers ->
        Map.fetch!(@tier_cognitive_bounds, tier).decay_range
    end
  end

  defp max_pins_range_for(opts) do
    case Keyword.get(opts, :trust_tier) do
      nil ->
        {@max_pins_min, @max_pins_max}

      tier when tier in @valid_tiers ->
        bounds = Map.fetch!(@tier_cognitive_bounds, tier)
        {1, bounds.max_pins}
    end
  end

  defp validate_quota(quota, _type, _opts) when is_integer(quota) and quota <= 0 do
    {:error, {:invalid_quota, :must_be_positive_or_unlimited}}
  end

  defp validate_quota(:unlimited, _type, _opts), do: :ok

  defp validate_quota(quota, type, opts) when is_integer(quota) do
    case quota_range_for(opts) do
      nil -> :ok
      {min, max} when quota >= min and quota <= max -> :ok
      {_min, max} when quota > max -> {:error, {:exceeds_max_quota, type}}
      {_min, _max} -> {:error, {:below_min_quota, type}}
    end
  end

  defp quota_range_for(opts) do
    case Keyword.get(opts, :trust_tier) do
      nil ->
        nil

      tier when tier in @valid_tiers ->
        Map.fetch!(@tier_cognitive_bounds, tier).quota_range
    end
  end

  defp tier_max_pins(opts, default) do
    case Keyword.get(opts, :trust_tier) do
      nil -> default
      tier when tier in @valid_tiers -> Map.fetch!(@tier_cognitive_bounds, tier).max_pins
    end
  end

  defp serialize_quota(:unlimited), do: "unlimited"
  defp serialize_quota(n) when is_integer(n), do: n

  defp deserialize_quota("unlimited"), do: :unlimited
  defp deserialize_quota(:unlimited), do: :unlimited
  defp deserialize_quota(n) when is_integer(n), do: n

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_datetime(nil), do: nil
  defp parse_datetime(dt) when is_struct(dt, DateTime), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
