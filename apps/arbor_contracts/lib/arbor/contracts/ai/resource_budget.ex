defmodule Arbor.Contracts.AI.ResourceBudget do
  @moduledoc """
  TypedStruct for per-session resource limits.

  Constrains how many resources a single session (or request chain) may consume.
  Any field set to `nil` means unlimited for that dimension.

  ## Billing Classes

  - `:free` — Route only to free-tier providers
  - `:paid` — Route only to paid providers
  - `:any` — No billing constraint

  ## Usage

      budget = ResourceBudget.free_tier()
      ResourceBudget.within_budget?(budget, %{llm_calls: 1, total_tokens: 3000})
      # => true

      ResourceBudget.within_budget?(budget, %{llm_calls: 2})
      # => false (free_tier allows max 1 LLM call)

      unlimited = ResourceBudget.unlimited()
      ResourceBudget.within_budget?(unlimited, %{llm_calls: 999_999})
      # => true (all limits are nil = unlimited)
  """

  use TypedStruct

  @valid_billing_classes [:free, :paid, :any]

  @derive {Jason.Encoder, except: []}
  typedstruct do
    @typedoc "Per-session resource budget with optional limits"

    field(:max_llm_calls, pos_integer() | nil)
    field(:max_tokens, pos_integer() | nil)
    field(:max_cost_usd, float() | nil)
    field(:max_tool_iterations, pos_integer() | nil)
    field(:max_duration_ms, pos_integer() | nil)
    field(:billing_class, :free | :paid | :any, default: :any)
  end

  @doc """
  Create a new resource budget with validation.

  Accepts keyword list or map. All limit fields default to `nil` (unlimited).
  `billing_class` defaults to `:any`.

  ## Options

  - `:max_llm_calls` — Maximum number of LLM API calls (positive integer or nil)
  - `:max_tokens` — Maximum total tokens consumed (positive integer or nil)
  - `:max_cost_usd` — Maximum cost in USD (non-negative float or nil)
  - `:max_tool_iterations` — Maximum tool loop iterations (positive integer or nil)
  - `:max_duration_ms` — Maximum wall-clock duration in ms (positive integer or nil)
  - `:billing_class` — Cost routing constraint (default: `:any`)

  ## Examples

      {:ok, budget} = ResourceBudget.new(max_llm_calls: 10, billing_class: :free)

      {:error, {:invalid_billing_class, :bogus}} = ResourceBudget.new(billing_class: :bogus)

      {:error, {:invalid_max_llm_calls, -1}} = ResourceBudget.new(max_llm_calls: -1)
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ [])

  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_pos_integer_or_nil(attrs, :max_llm_calls),
         :ok <- validate_pos_integer_or_nil(attrs, :max_tokens),
         :ok <- validate_non_neg_float_or_nil(attrs, :max_cost_usd),
         :ok <- validate_pos_integer_or_nil(attrs, :max_tool_iterations),
         :ok <- validate_pos_integer_or_nil(attrs, :max_duration_ms),
         :ok <- validate_billing_class(get_attr(attrs, :billing_class)) do
      budget = %__MODULE__{
        max_llm_calls: get_attr(attrs, :max_llm_calls),
        max_tokens: get_attr(attrs, :max_tokens),
        max_cost_usd: get_attr(attrs, :max_cost_usd),
        max_tool_iterations: get_attr(attrs, :max_tool_iterations),
        max_duration_ms: get_attr(attrs, :max_duration_ms),
        billing_class: get_attr(attrs, :billing_class) || :any
      }

      {:ok, budget}
    end
  end

  @doc """
  Returns a budget with all limits set to `nil` (unlimited).

  ## Examples

      budget = ResourceBudget.unlimited()
      budget.max_llm_calls  # => nil
      budget.billing_class  # => :any
  """
  @spec unlimited() :: t()
  def unlimited do
    %__MODULE__{
      max_llm_calls: nil,
      max_tokens: nil,
      max_cost_usd: nil,
      max_tool_iterations: nil,
      max_duration_ms: nil,
      billing_class: :any
    }
  end

  @doc """
  Returns a conservative budget suitable for free-tier providers.

  Limits: 1 LLM call, 4000 tokens, billing_class `:free`.

  ## Examples

      budget = ResourceBudget.free_tier()
      budget.max_llm_calls   # => 1
      budget.max_tokens       # => 4000
      budget.billing_class    # => :free
  """
  @spec free_tier() :: t()
  def free_tier do
    %__MODULE__{
      max_llm_calls: 1,
      max_tokens: 4000,
      max_cost_usd: nil,
      max_tool_iterations: nil,
      max_duration_ms: nil,
      billing_class: :free
    }
  end

  @doc """
  Checks whether the given usage is within budget limits.

  Compares each non-nil budget field against the corresponding key in the
  usage map. Missing keys in the usage map are treated as 0 (within budget).

  ## Usage Map Keys

  - `:llm_calls` — checked against `max_llm_calls`
  - `:total_tokens` — checked against `max_tokens`
  - `:cost_usd` — checked against `max_cost_usd`
  - `:tool_iterations` — checked against `max_tool_iterations`
  - `:duration_ms` — checked against `max_duration_ms`

  ## Examples

      budget = ResourceBudget.free_tier()

      ResourceBudget.within_budget?(budget, %{llm_calls: 1, total_tokens: 3000})
      # => true

      ResourceBudget.within_budget?(budget, %{llm_calls: 2})
      # => false

      ResourceBudget.within_budget?(ResourceBudget.unlimited(), %{llm_calls: 999_999})
      # => true
  """
  @spec within_budget?(t(), map()) :: boolean()
  def within_budget?(%__MODULE__{} = budget, usage) when is_map(usage) do
    check_limit(budget.max_llm_calls, Map.get(usage, :llm_calls, 0)) and
      check_limit(budget.max_tokens, Map.get(usage, :total_tokens, 0)) and
      check_limit(budget.max_cost_usd, Map.get(usage, :cost_usd, 0)) and
      check_limit(budget.max_tool_iterations, Map.get(usage, :tool_iterations, 0)) and
      check_limit(budget.max_duration_ms, Map.get(usage, :duration_ms, 0))
  end

  # ============================================================================
  # Private — Limit Check
  # ============================================================================

  defp check_limit(nil, _usage), do: true
  defp check_limit(max, usage), do: usage <= max

  # ============================================================================
  # Private — Validation
  # ============================================================================

  defp validate_pos_integer_or_nil(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      n when is_integer(n) and n > 0 -> :ok
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_non_neg_float_or_nil(attrs, key) do
    case get_attr(attrs, key) do
      nil -> :ok
      n when is_number(n) and n >= 0 -> :ok
      invalid -> {:error, {:"invalid_#{key}", invalid}}
    end
  end

  defp validate_billing_class(nil), do: :ok

  defp validate_billing_class(class) when class in @valid_billing_classes, do: :ok

  defp validate_billing_class(class), do: {:error, {:invalid_billing_class, class}}

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
