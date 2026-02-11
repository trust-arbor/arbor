defmodule Arbor.Contracts.Session.Turn do
  @moduledoc """
  TypedStruct for one completed turn in a session.

  A turn captures a single request-response cycle: user input, LLM response,
  any tool calls made, context at the time of the turn, thinking blocks,
  and token usage. Turns are the atomic unit of session history.

  ## Turn Hierarchy

  Turns can form a tree via `parent_turn_id`. This supports:
  - Tool loop sub-turns (child turns from tool execution)
  - Delegation turns (spawned from a parent session's turn)
  - Retry turns (re-attempt of a failed parent turn)

  ## Usage

      {:ok, turn} = Turn.new(
        turn_number: 0,
        input: "Hello, how are you?"
      )

      {:ok, completed} = Turn.complete(turn, %{
        response: "I'm doing well!",
        usage: %{input_tokens: 10, output_tokens: 8}
      })

      Turn.duration_ms(completed)  # => 42 (or nil if not yet completed)
  """

  use TypedStruct

  alias Arbor.Identifiers

  @derive {Jason.Encoder, except: []}
  typedstruct do
    @typedoc "A single completed turn in a session"

    field(:turn_id, String.t(), enforce: true)
    field(:parent_turn_id, String.t() | nil)
    field(:turn_number, non_neg_integer(), enforce: true)
    field(:input, String.t() | map(), enforce: true)
    field(:response, String.t() | nil)
    field(:tool_calls_made, [map()], default: [])
    field(:context_snapshot, map() | nil)
    field(:thinking, String.t() | nil)
    field(:usage, map() | nil)
    field(:started_at, DateTime.t(), enforce: true)
    field(:completed_at, DateTime.t() | nil)
    field(:metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new turn with a generated `turn_id` and `started_at` timestamp.

  Accepts a keyword list or map. The `turn_number` and `input` fields are
  required. `turn_id` and `started_at` are auto-generated if not provided.

  ## Required Fields

  - `:turn_number` — Zero-based index of this turn in the session
  - `:input` — User input (string or structured map)

  ## Optional Fields

  - `:turn_id` — Override the auto-generated turn ID
  - `:parent_turn_id` — ID of the parent turn (for sub-turns)
  - `:response` — LLM response text
  - `:tool_calls_made` — List of tool call maps (default: `[]`)
  - `:context_snapshot` — Snapshot of session context at turn start
  - `:thinking` — Model thinking/reasoning blocks
  - `:usage` — Token usage map
  - `:started_at` — Override the auto-generated timestamp
  - `:completed_at` — Completion timestamp
  - `:metadata` — Arbitrary metadata (default: `%{}`)

  ## Examples

      {:ok, turn} = Turn.new(turn_number: 0, input: "Hello!")

      {:ok, turn} = Turn.new(
        turn_number: 1,
        input: %{role: "user", content: "Search for elixir docs"},
        parent_turn_id: "turn_abc123"
      )

      {:error, {:missing_required, :input}} = Turn.new(turn_number: 0)

      {:error, {:invalid_turn_number, -1}} = Turn.new(turn_number: -1, input: "hi")
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_turn_number(get_attr(attrs, :turn_number)),
         :ok <- validate_input(get_attr(attrs, :input)),
         :ok <- validate_optional_string(attrs, :turn_id),
         :ok <- validate_optional_string(attrs, :parent_turn_id),
         :ok <- validate_optional_string(attrs, :response),
         :ok <- validate_tool_calls(get_attr(attrs, :tool_calls_made)),
         :ok <- validate_optional_map(attrs, :context_snapshot),
         :ok <- validate_optional_string(attrs, :thinking),
         :ok <- validate_optional_map(attrs, :usage),
         :ok <- validate_optional_map(attrs, :metadata) do
      now = DateTime.utc_now()

      turn = %__MODULE__{
        turn_id: get_attr(attrs, :turn_id) || Identifiers.generate_id("turn_"),
        parent_turn_id: get_attr(attrs, :parent_turn_id),
        turn_number: get_attr(attrs, :turn_number),
        input: get_attr(attrs, :input),
        response: get_attr(attrs, :response),
        tool_calls_made: get_attr(attrs, :tool_calls_made) || [],
        context_snapshot: get_attr(attrs, :context_snapshot),
        thinking: get_attr(attrs, :thinking),
        usage: get_attr(attrs, :usage),
        started_at: get_attr(attrs, :started_at) || now,
        completed_at: get_attr(attrs, :completed_at),
        metadata: get_attr(attrs, :metadata) || %{}
      }

      {:ok, turn}
    end
  end

  # ============================================================================
  # State Transitions
  # ============================================================================

  @doc """
  Mark a turn as completed with response data.

  Sets `completed_at` to `DateTime.utc_now/0` (unless provided in attrs)
  and merges any additional fields from the attrs map.

  ## Accepted Fields

  - `:response` — LLM response text
  - `:tool_calls_made` — Tool calls list
  - `:thinking` — Thinking blocks
  - `:usage` — Token usage map
  - `:context_snapshot` — Context at completion
  - `:completed_at` — Override completion timestamp
  - `:metadata` — Merged with existing metadata

  ## Examples

      {:ok, turn} = Turn.new(turn_number: 0, input: "Hello")
      {:ok, completed} = Turn.complete(turn, %{
        response: "Hi there!",
        usage: %{input_tokens: 5, output_tokens: 3}
      })
      completed.completed_at  # => %DateTime{...}

      {:error, :already_completed} = Turn.complete(completed, %{response: "again"})
  """
  @spec complete(t(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{completed_at: completed} = _turn, _attrs)
      when not is_nil(completed) do
    {:error, :already_completed}
  end

  def complete(%__MODULE__{} = turn, attrs) when is_list(attrs) do
    complete(turn, Map.new(attrs))
  end

  def complete(%__MODULE__{} = turn, attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    extra_metadata = get_attr(attrs, :metadata) || %{}

    completed = %{
      turn
      | response: get_attr(attrs, :response) || turn.response,
        tool_calls_made: get_attr(attrs, :tool_calls_made) || turn.tool_calls_made,
        thinking: get_attr(attrs, :thinking) || turn.thinking,
        usage: get_attr(attrs, :usage) || turn.usage,
        context_snapshot: get_attr(attrs, :context_snapshot) || turn.context_snapshot,
        completed_at: get_attr(attrs, :completed_at) || now,
        metadata: Map.merge(turn.metadata, extra_metadata)
    }

    {:ok, completed}
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Calculate the duration of a turn in milliseconds.

  Returns `nil` if the turn is not yet completed.

  ## Examples

      {:ok, turn} = Turn.new(turn_number: 0, input: "Hi")
      Turn.duration_ms(turn)  # => nil

      {:ok, completed} = Turn.complete(turn, %{response: "Hello"})
      Turn.duration_ms(completed)  # => non_neg_integer()
  """
  @spec duration_ms(t()) :: non_neg_integer() | nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  @doc """
  Returns `true` if the turn has been completed.

  ## Examples

      {:ok, turn} = Turn.new(turn_number: 0, input: "Hi")
      Turn.completed?(turn)  # => false
  """
  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{completed_at: nil}), do: false
  def completed?(%__MODULE__{}), do: true

  @doc """
  Returns `true` if the turn involved tool calls.

  ## Examples

      {:ok, turn} = Turn.new(turn_number: 0, input: "Search for X")
      Turn.has_tool_calls?(turn)  # => false
  """
  @spec has_tool_calls?(t()) :: boolean()
  def has_tool_calls?(%__MODULE__{tool_calls_made: calls}) do
    is_list(calls) and calls != []
  end

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_turn_number(nil), do: {:error, {:missing_required, :turn_number}}

  defp validate_turn_number(n) when is_integer(n) and n >= 0, do: :ok

  defp validate_turn_number(n), do: {:error, {:invalid_turn_number, n}}

  defp validate_input(nil), do: {:error, {:missing_required, :input}}

  defp validate_input(input) when is_binary(input), do: :ok

  defp validate_input(input) when is_map(input), do: :ok

  defp validate_input(input), do: {:error, {:invalid_input, input}}

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

  defp validate_tool_calls(nil), do: :ok

  defp validate_tool_calls(calls) when is_list(calls) do
    if Enum.all?(calls, &is_map/1) do
      :ok
    else
      {:error, {:invalid_tool_calls_made, :not_all_maps}}
    end
  end

  defp validate_tool_calls(_), do: {:error, {:invalid_tool_calls_made, :not_a_list}}

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
