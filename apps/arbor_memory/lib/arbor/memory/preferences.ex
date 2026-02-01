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

  All parameters are validated to stay within safe ranges.

  ## Usage

      prefs = Preferences.new("agent_001")
      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15)
      prefs = Preferences.pin(prefs, "important_memory_id")
  """

  @type t :: %__MODULE__{
          agent_id: String.t(),
          decay_rate: float(),
          type_quotas: %{atom() => pos_integer() | :unlimited},
          pinned_memories: [String.t()],
          max_pins: pos_integer(),
          attention_focus: String.t() | nil,
          retrieval_threshold: float(),
          consolidation_interval: pos_integer()
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
    consolidation_interval: 1_800_000
  ]

  # Validation ranges
  @decay_rate_min 0.01
  @decay_rate_max 0.50
  @max_pins_min 1
  @max_pins_max 200
  @retrieval_threshold_min 0.0
  @retrieval_threshold_max 1.0
  @consolidation_interval_min 60_000
  @consolidation_interval_max 3_600_000

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
      consolidation_interval: Keyword.get(opts, :consolidation_interval, 1_800_000)
    }
  end

  # ============================================================================
  # Memory Pinning
  # ============================================================================

  @doc """
  Pin a memory to protect it from decay.

  Returns error if max_pins limit would be exceeded.

  ## Examples

      prefs = Preferences.pin(prefs, "memory_123")
  """
  @spec pin(t(), String.t()) :: t() | {:error, :max_pins_reached}
  def pin(%__MODULE__{} = prefs, memory_id) do
    cond do
      memory_id in prefs.pinned_memories ->
        # Already pinned
        prefs

      length(prefs.pinned_memories) >= prefs.max_pins ->
        {:error, :max_pins_reached}

      true ->
        %{prefs | pinned_memories: [memory_id | prefs.pinned_memories]}
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
  # Cognitive Adjustment
  # ============================================================================

  @doc """
  Adjust a cognitive parameter.

  All adjustments are validated against safe ranges.

  ## Parameters

  - `:decay_rate` - 0.01 to 0.50
  - `:max_pins` - 1 to 200
  - `:retrieval_threshold` - 0.0 to 1.0
  - `:consolidation_interval` - 60,000ms (1 min) to 3,600,000ms (1 hour)
  - `:attention_focus` - String or nil
  - `:type_quota` - Tuple of {type, quota} where quota is positive integer or :unlimited

  ## Examples

      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15)
      {:ok, prefs} = Preferences.adjust(prefs, :type_quota, {:fact, 1000})
      {:error, {:out_of_range, :decay_rate, {0.01, 0.50}}} = Preferences.adjust(prefs, :decay_rate, 0.001)
  """
  @spec adjust(t(), atom(), term()) :: {:ok, t()} | {:error, term()}
  def adjust(%__MODULE__{} = prefs, :decay_rate, value) when is_number(value) do
    if value >= @decay_rate_min and value <= @decay_rate_max do
      {:ok, %{prefs | decay_rate: Float.round(value * 1.0, 4)}}
    else
      {:error, {:out_of_range, :decay_rate, {@decay_rate_min, @decay_rate_max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :max_pins, value) when is_integer(value) do
    if value >= @max_pins_min and value <= @max_pins_max do
      # Truncate pinned_memories if new limit is lower
      pinned =
        if length(prefs.pinned_memories) > value do
          Enum.take(prefs.pinned_memories, value)
        else
          prefs.pinned_memories
        end

      {:ok, %{prefs | max_pins: value, pinned_memories: pinned}}
    else
      {:error, {:out_of_range, :max_pins, {@max_pins_min, @max_pins_max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :retrieval_threshold, value) when is_number(value) do
    if value >= @retrieval_threshold_min and value <= @retrieval_threshold_max do
      {:ok, %{prefs | retrieval_threshold: Float.round(value * 1.0, 4)}}
    else
      {:error, {:out_of_range, :retrieval_threshold, {@retrieval_threshold_min, @retrieval_threshold_max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :consolidation_interval, value) when is_integer(value) do
    if value >= @consolidation_interval_min and value <= @consolidation_interval_max do
      {:ok, %{prefs | consolidation_interval: value}}
    else
      {:error,
       {:out_of_range, :consolidation_interval,
        {@consolidation_interval_min, @consolidation_interval_max}}}
    end
  end

  def adjust(%__MODULE__{} = prefs, :attention_focus, value)
      when is_binary(value) or is_nil(value) do
    {:ok, %{prefs | attention_focus: value}}
  end

  def adjust(%__MODULE__{} = prefs, :type_quota, {type, quota})
      when is_atom(type) and (is_integer(quota) or quota == :unlimited) do
    if is_integer(quota) and quota <= 0 do
      {:error, {:invalid_quota, :must_be_positive_or_unlimited}}
    else
      updated_quotas = Map.put(prefs.type_quotas, type, quota)
      {:ok, %{prefs | type_quotas: updated_quotas}}
    end
  end

  def adjust(_prefs, param, _value) do
    {:error, {:invalid_param, param}}
  end

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
      type_quotas: prefs.type_quotas,
      pinned_count: length(prefs.pinned_memories),
      max_pins: prefs.max_pins,
      pins_available: prefs.max_pins - length(prefs.pinned_memories),
      attention_focus: prefs.attention_focus,
      retrieval_threshold: prefs.retrieval_threshold,
      consolidation_interval_minutes: div(prefs.consolidation_interval, 60_000)
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
      consolidation_interval: prefs.consolidation_interval
    }
  end

  @doc """
  Deserialize a map back to a Preferences struct.

  Uses SafeAtom for atom conversion to prevent atom exhaustion.

  ## Examples

      prefs = Preferences.deserialize(data)
  """
  @spec deserialize(map()) :: t()
  def deserialize(data) do
    alias Arbor.Common.SafeAtom

    # Known quota types that are safe to convert
    known_types = [:fact, :experience, :skill, :insight, :relationship]

    type_quotas =
      (data["type_quotas"] || data[:type_quotas] || %{})
      |> Enum.map(fn {k, v} ->
        key =
          case SafeAtom.to_allowed(to_string(k), known_types) do
            {:ok, atom} -> atom
            {:error, _} -> String.to_existing_atom(to_string(k))
          end

        {key, deserialize_quota(v)}
      end)
      |> Map.new()

    %__MODULE__{
      agent_id: data["agent_id"] || data[:agent_id],
      decay_rate: (data["decay_rate"] || data[:decay_rate] || 0.10) * 1.0,
      type_quotas: type_quotas,
      pinned_memories: data["pinned_memories"] || data[:pinned_memories] || [],
      max_pins: data["max_pins"] || data[:max_pins] || 50,
      attention_focus: data["attention_focus"] || data[:attention_focus],
      retrieval_threshold: (data["retrieval_threshold"] || data[:retrieval_threshold] || 0.3) * 1.0,
      consolidation_interval: data["consolidation_interval"] || data[:consolidation_interval] || 1_800_000
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp serialize_quota(:unlimited), do: "unlimited"
  defp serialize_quota(n) when is_integer(n), do: n

  defp deserialize_quota("unlimited"), do: :unlimited
  defp deserialize_quota(:unlimited), do: :unlimited
  defp deserialize_quota(n) when is_integer(n), do: n
end
