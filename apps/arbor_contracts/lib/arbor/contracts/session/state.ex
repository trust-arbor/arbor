defmodule Arbor.Contracts.Session.State do
  @moduledoc """
  TypedStruct for mutable session state.

  Tracks all per-turn and per-session mutable data. Paired with
  `Arbor.Contracts.Session.Config`, which holds the immutable configuration.
  Config is set once at session start; State changes on every turn.

  ## Phases

  - `:idle` — Waiting for input (default)
  - `:receiving` — Input received, not yet processed
  - `:processing` — LLM call or tool execution in progress
  - `:acting` — Executing actions from LLM response
  - `:finalizing` — Persisting results, emitting signals
  - `:error` — Recoverable error state
  - `:terminated` — Session ended

  ## Usage

      {:ok, state} = State.new()

      state = state
        |> State.touch()
        |> State.increment_turn()

      State.idle?(state)  # => false (phase is still :idle only if not touched with phase change)
  """

  use TypedStruct

  @valid_phases [:idle, :receiving, :processing, :acting, :finalizing, :error, :terminated]

  @derive {Jason.Encoder, except: []}
  typedstruct do
    @typedoc "Mutable session state, updated on every turn"

    field(:phase, atom(), default: :idle)
    field(:messages, [map()], default: [])
    field(:working_memory, map(), default: %{})
    field(:goals, [map()], default: [])
    field(:cognitive_mode, atom(), default: :reflection)
    field(:turn_count, non_neg_integer(), default: 0)
    field(:trace_id, String.t() | nil)
    field(:started_at, DateTime.t(), enforce: true)
    field(:last_activity_at, DateTime.t(), enforce: true)
    field(:error_count, non_neg_integer(), default: 0)
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new session state.

  Sets `started_at` and `last_activity_at` to `DateTime.utc_now/0` if not
  provided. All other fields use their defaults.

  ## Options

  - `:phase` — Initial phase (default: `:idle`)
  - `:messages` — Initial message list (default: `[]`)
  - `:working_memory` — Initial working memory (default: `%{}`)
  - `:goals` — Initial goals (default: `[]`)
  - `:cognitive_mode` — Initial cognitive mode (default: `:reflection`)
  - `:turn_count` — Initial turn count (default: `0`)
  - `:trace_id` — Distributed trace ID
  - `:started_at` — Override start timestamp (default: `DateTime.utc_now/0`)
  - `:last_activity_at` — Override activity timestamp (default: `DateTime.utc_now/0`)
  - `:error_count` — Initial error count (default: `0`)
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, state} = State.new()

      {:ok, state} = State.new(phase: :processing, trace_id: "trace_abc")

      {:error, {:invalid_phase, :bogus}} = State.new(phase: :bogus)
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ [])

  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    with :ok <- validate_phase(get_attr(attrs, :phase)),
         :ok <- validate_list(attrs, :messages),
         :ok <- validate_map(attrs, :working_memory),
         :ok <- validate_list(attrs, :goals),
         :ok <- validate_atom(attrs, :cognitive_mode),
         :ok <- validate_non_neg_integer(attrs, :turn_count),
         :ok <- validate_non_neg_integer(attrs, :error_count),
         :ok <- validate_optional_string(attrs, :trace_id),
         :ok <- validate_map(attrs, :metadata) do
      state = %__MODULE__{
        phase: get_attr(attrs, :phase) || :idle,
        messages: get_attr(attrs, :messages) || [],
        working_memory: get_attr(attrs, :working_memory) || %{},
        goals: get_attr(attrs, :goals) || [],
        cognitive_mode: get_attr(attrs, :cognitive_mode) || :reflection,
        turn_count: get_attr(attrs, :turn_count) || 0,
        trace_id: get_attr(attrs, :trace_id),
        started_at: get_attr(attrs, :started_at) || now,
        last_activity_at: get_attr(attrs, :last_activity_at) || now,
        error_count: get_attr(attrs, :error_count) || 0,
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, state}
    end
  end

  # ============================================================================
  # State Transitions
  # ============================================================================

  @doc """
  Update `last_activity_at` to the current UTC time.

  ## Examples

      state = State.touch(state)
      # state.last_activity_at is now DateTime.utc_now()
  """
  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = state) do
    %{state | last_activity_at: DateTime.utc_now()}
  end

  @doc """
  Increment the turn count by 1 and touch the timestamp.

  ## Examples

      state = State.increment_turn(state)
      # state.turn_count increased by 1
  """
  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{turn_count: count} = state) do
    %{state | turn_count: count + 1, last_activity_at: DateTime.utc_now()}
  end

  @doc """
  Increment the error count by 1 and touch the timestamp.

  ## Examples

      state = State.increment_errors(state)
      # state.error_count increased by 1
  """
  @spec increment_errors(t()) :: t()
  def increment_errors(%__MODULE__{error_count: count} = state) do
    %{state | error_count: count + 1, last_activity_at: DateTime.utc_now()}
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Returns `true` if the session is in the `:idle` phase.

  ## Examples

      {:ok, state} = State.new()
      State.idle?(state)  # => true

      {:ok, state} = State.new(phase: :processing)
      State.idle?(state)  # => false
  """
  @spec idle?(t()) :: boolean()
  def idle?(%__MODULE__{phase: :idle}), do: true
  def idle?(%__MODULE__{}), do: false

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_phase(nil), do: :ok

  defp validate_phase(phase) when phase in @valid_phases, do: :ok

  defp validate_phase(phase), do: {:error, {:invalid_phase, phase}}

  defp validate_list(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_list(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_map(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_map(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_atom(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_atom(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_non_neg_integer(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_integer(val) and val >= 0 -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_optional_string(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      val when is_binary(val) -> :ok
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

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
