defmodule Arbor.Contracts.Signal.Event do
  @moduledoc """
  TypedStruct for signal events with privacy classification.

  Signal events are the atomic unit of the Arbor signal bus. Each event carries
  a namespaced type, privacy classification, and optional correlation/tracing
  metadata for distributed observability.

  ## Privacy Model

  Every event has a **privacy floor** — the minimum classification that can
  never be downgraded. An optional **privacy escalation** can raise the
  effective privacy above the floor (e.g., when a `:public` event accumulates
  `:sensitive` metadata during processing).

  | Level | Ord | Description |
  |-------|-----|-------------|
  | `:public` | 0 | No sensitive data, safe to log/export |
  | `:internal` | 1 | Internal context, not for external consumption |
  | `:sensitive` | 2 | PII, credentials, or user-specific data |
  | `:restricted` | 3 | Highest classification, on-premise only |

  The effective privacy is always `max(floor, escalation)`.

  ## Coalescing

  Events with the same `coalescing_key` may be merged by downstream consumers
  (e.g., debouncing rapid signal emissions). A `nil` coalescing key means the
  event is never coalesced.

  ## Sensitive Fields

  The `sensitive_fields` list names fields within `metadata` that contain
  classified data. Consumers use this to selectively redact or encrypt
  specific fields rather than dropping the entire event.

  ## Usage

      {:ok, event} = Event.new(
        type: "session.turn_completed",
        privacy_floor: :internal
      )

      Event.effective_privacy(event)  # => :internal

      {:ok, escalated} = Event.escalate(event, :sensitive)
      Event.effective_privacy(escalated)  # => :sensitive

      # Can't escalate down
      {:error, :cannot_downgrade} = Event.escalate(escalated, :public)

  @version "1.0.0"
  """

  use TypedStruct

  @privacy_levels [:public, :internal, :sensitive, :restricted]

  @derive {Jason.Encoder, except: []}
  typedstruct enforce: true do
    @typedoc "A signal event with privacy classification"

    # Event identification
    field(:type, String.t())
    field(:privacy_floor, :public | :internal | :sensitive | :restricted)

    # Privacy escalation (can only go up, never down)
    field(:privacy_escalation, :public | :internal | :sensitive | :restricted | nil,
      enforce: false,
      default: nil
    )

    # Distributed tracing
    field(:correlation_id, String.t() | nil, enforce: false)
    field(:trace_id, String.t() | nil, enforce: false)
    field(:causality_chain, [String.t()], default: [])

    # Privacy metadata
    field(:sensitive_fields, [String.t()], default: [])

    # Coalescing
    field(:coalescing_key, String.t() | nil, enforce: false)

    # Extensible metadata
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new signal event with validation.

  Accepts a keyword list or map. The `type` and `privacy_floor` fields are
  required.

  ## Required Fields

  - `:type` — Namespaced event type (e.g. `"session.turn_completed"`)
  - `:privacy_floor` — Static minimum privacy level, never downgraded

  ## Optional Fields

  - `:privacy_escalation` — Raised privacy level (must be >= floor)
  - `:correlation_id` — Correlation ID for request tracing
  - `:trace_id` — Distributed trace ID
  - `:causality_chain` — List of upstream event IDs (default: `[]`)
  - `:sensitive_fields` — Field names in metadata that are classified (default: `[]`)
  - `:coalescing_key` — Key for event deduplication/merging
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, event} = Event.new(
        type: "session.turn_completed",
        privacy_floor: :internal,
        correlation_id: "corr_abc123",
        metadata: %{turn_number: 5}
      )

      {:error, {:missing_required, :type}} = Event.new(privacy_floor: :public)

      {:error, {:invalid_privacy_floor, :unknown}} = Event.new(
        type: "test.event",
        privacy_floor: :unknown
      )
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_type(get_attr(attrs, :type)),
         :ok <- validate_privacy_level(get_attr(attrs, :privacy_floor), :privacy_floor),
         :ok <- validate_optional_privacy(get_attr(attrs, :privacy_escalation)),
         :ok <- validate_escalation_direction(get_attr(attrs, :privacy_floor), get_attr(attrs, :privacy_escalation)),
         :ok <- validate_optional_string(attrs, :correlation_id),
         :ok <- validate_optional_string(attrs, :trace_id),
         :ok <- validate_string_list(get_attr(attrs, :causality_chain), :causality_chain),
         :ok <- validate_string_list(get_attr(attrs, :sensitive_fields), :sensitive_fields),
         :ok <- validate_optional_string(attrs, :coalescing_key),
         :ok <- validate_optional_map(attrs, :metadata) do
      event = %__MODULE__{
        type: get_attr(attrs, :type),
        privacy_floor: get_attr(attrs, :privacy_floor),
        privacy_escalation: get_attr(attrs, :privacy_escalation),
        correlation_id: get_attr(attrs, :correlation_id),
        trace_id: get_attr(attrs, :trace_id),
        causality_chain: get_attr(attrs, :causality_chain) || [],
        sensitive_fields: get_attr(attrs, :sensitive_fields) || [],
        coalescing_key: get_attr(attrs, :coalescing_key),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, event}
    end
  end

  # ============================================================================
  # Privacy Queries
  # ============================================================================

  @doc """
  Returns the effective privacy level — the maximum of floor and escalation.

  If no escalation is set, returns the floor.

  ## Examples

      {:ok, event} = Event.new(type: "a.b", privacy_floor: :internal)
      Event.effective_privacy(event)  # => :internal

      {:ok, esc} = Event.escalate(event, :sensitive)
      Event.effective_privacy(esc)  # => :sensitive
  """
  @spec effective_privacy(t()) :: :public | :internal | :sensitive | :restricted
  def effective_privacy(%__MODULE__{privacy_floor: floor, privacy_escalation: nil}), do: floor

  def effective_privacy(%__MODULE__{privacy_floor: floor, privacy_escalation: escalation}) do
    if privacy_ord(escalation) > privacy_ord(floor), do: escalation, else: floor
  end

  @doc """
  Escalate the privacy level. Only moves up, never down.

  Returns `{:error, :cannot_downgrade}` if the requested level is below the
  current effective privacy.

  ## Examples

      {:ok, event} = Event.new(type: "a.b", privacy_floor: :internal)
      {:ok, escalated} = Event.escalate(event, :sensitive)
      Event.effective_privacy(escalated)  # => :sensitive

      {:error, :cannot_downgrade} = Event.escalate(escalated, :public)
  """
  @spec escalate(t(), :public | :internal | :sensitive | :restricted) ::
          {:ok, t()} | {:error, :cannot_downgrade | {:invalid_privacy_level, term()}}
  def escalate(%__MODULE__{} = event, level) when level in @privacy_levels do
    current = effective_privacy(event)

    if privacy_ord(level) >= privacy_ord(current) do
      {:ok, %{event | privacy_escalation: level}}
    else
      {:error, :cannot_downgrade}
    end
  end

  def escalate(%__MODULE__{}, level) do
    {:error, {:invalid_privacy_level, level}}
  end

  @doc """
  Returns `true` if the effective privacy is `:public`.

  ## Examples

      {:ok, event} = Event.new(type: "a.b", privacy_floor: :public)
      Event.public?(event)  # => true
  """
  @spec public?(t()) :: boolean()
  def public?(%__MODULE__{} = event), do: effective_privacy(event) == :public

  @doc """
  Returns `true` if the effective privacy is `:internal`.

  ## Examples

      {:ok, event} = Event.new(type: "a.b", privacy_floor: :internal)
      Event.internal?(event)  # => true
  """
  @spec internal?(t()) :: boolean()
  def internal?(%__MODULE__{} = event), do: effective_privacy(event) == :internal

  @doc """
  Returns `true` if the effective privacy is `:sensitive`.

  ## Examples

      {:ok, event} = Event.new(type: "a.b", privacy_floor: :sensitive)
      Event.sensitive?(event)  # => true
  """
  @spec sensitive?(t()) :: boolean()
  def sensitive?(%__MODULE__{} = event), do: effective_privacy(event) == :sensitive

  @doc """
  Returns `true` if the effective privacy is `:restricted`.

  ## Examples

      {:ok, event} = Event.new(type: "a.b", privacy_floor: :restricted)
      Event.restricted?(event)  # => true
  """
  @spec restricted?(t()) :: boolean()
  def restricted?(%__MODULE__{} = event), do: effective_privacy(event) == :restricted

  @doc """
  Returns the numeric ordinal for a privacy level.

  Used for comparison operations. Higher ordinal = more restricted.

  | Level | Ordinal |
  |-------|---------|
  | `:public` | 0 |
  | `:internal` | 1 |
  | `:sensitive` | 2 |
  | `:restricted` | 3 |

  ## Examples

      Event.privacy_ord(:public)      # => 0
      Event.privacy_ord(:restricted)  # => 3
  """
  @spec privacy_ord(:public | :internal | :sensitive | :restricted) :: 0 | 1 | 2 | 3
  def privacy_ord(:public), do: 0
  def privacy_ord(:internal), do: 1
  def privacy_ord(:sensitive), do: 2
  def privacy_ord(:restricted), do: 3

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_type(nil), do: {:error, {:missing_required, :type}}
  defp validate_type(type) when is_binary(type) and byte_size(type) > 0, do: :ok
  defp validate_type(type), do: {:error, {:invalid_type, type}}

  defp validate_privacy_level(nil, field), do: {:error, {:missing_required, field}}

  defp validate_privacy_level(level, _field) when level in @privacy_levels, do: :ok

  defp validate_privacy_level(level, field), do: {:error, {:"invalid_#{field}", level}}

  defp validate_optional_privacy(nil), do: :ok
  defp validate_optional_privacy(level) when level in @privacy_levels, do: :ok
  defp validate_optional_privacy(level), do: {:error, {:invalid_privacy_escalation, level}}

  defp validate_escalation_direction(_floor, nil), do: :ok

  defp validate_escalation_direction(floor, escalation)
       when floor in @privacy_levels and escalation in @privacy_levels do
    if privacy_ord(escalation) >= privacy_ord(floor) do
      :ok
    else
      {:error, :cannot_downgrade}
    end
  end

  defp validate_escalation_direction(_floor, _escalation), do: :ok

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_map(val) -> :ok
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_string_list(nil, _field), do: :ok

  defp validate_string_list(list, field) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      :ok
    else
      {:error, {:"invalid_#{field}", :not_all_strings}}
    end
  end

  defp validate_string_list(_, field), do: {:error, {:"invalid_#{field}", :not_a_list}}

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  # Supports both atom and string keys in attrs map
  defp get_attr(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, Atom.to_string(key))
      value -> value
    end
  end
end
