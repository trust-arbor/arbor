defmodule Arbor.Memory.TokenBudget do
  @moduledoc """
  Token budget management for memory operations.

  Provides percentage-based budget allocation across model context window sizes.
  This is how the memory system right-sizes its sections for different models.

  ## Budget Types

  - `:fixed` - Exact token count
  - `:percentage` - Percentage of model's context window
  - `:min_max` - Percentage with floor and ceiling

  ## Examples

      # Fixed budget
      iex> Arbor.Memory.TokenBudget.resolve({:fixed, 1000}, 100_000)
      1000

      # Percentage budget
      iex> Arbor.Memory.TokenBudget.resolve({:percentage, 0.10}, 100_000)
      10_000

      # Percentage with bounds
      iex> Arbor.Memory.TokenBudget.resolve({:min_max, 500, 5000, 0.10}, 100_000)
      5000  # Capped at max

      iex> Arbor.Memory.TokenBudget.resolve({:min_max, 500, 5000, 0.10}, 1000)
      500   # Floor at min
  """

  @type budget ::
          {:fixed, non_neg_integer()}
          | {:percentage, float()}
          | {:min_max, non_neg_integer(), non_neg_integer(), float()}

  @type model_id :: String.t()

  # Model context sizes (tokens)
  # https://docs.anthropic.com/en/docs/about-claude/models
  @model_context_sizes %{
    # Anthropic Claude 4.5
    "anthropic:claude-opus-4-5-20251101" => 200_000,
    "anthropic:claude-sonnet-4-5-20250514" => 200_000,
    # Anthropic Claude 3.5
    "anthropic:claude-3-5-sonnet-20241022" => 200_000,
    "anthropic:claude-3-5-haiku-20241022" => 200_000,
    # Anthropic Claude 3
    "anthropic:claude-3-opus-20240229" => 200_000,
    "anthropic:claude-3-sonnet-20240229" => 200_000,
    "anthropic:claude-3-haiku-20240307" => 200_000,
    # OpenAI GPT-4
    "openai:gpt-4o" => 128_000,
    "openai:gpt-4o-mini" => 128_000,
    "openai:gpt-4-turbo" => 128_000,
    "openai:gpt-4" => 8_192,
    # OpenAI GPT-3.5
    "openai:gpt-3.5-turbo" => 16_385,
    # Google Gemini
    "google:gemini-1.5-pro" => 2_000_000,
    "google:gemini-1.5-flash" => 1_000_000,
    "google:gemini-2.0-flash" => 1_000_000,
    # Local models (conservative defaults)
    "ollama:llama3.2" => 128_000,
    "ollama:mistral" => 32_000,
    "ollama:mixtral" => 32_000,
    "lmstudio:default" => 32_000
  }

  @default_context_size 100_000
  @chars_per_token 4

  @doc """
  Resolve a budget specification to an exact token count.

  ## Examples

      iex> Arbor.Memory.TokenBudget.resolve({:fixed, 1000}, 100_000)
      1000

      iex> Arbor.Memory.TokenBudget.resolve({:percentage, 0.10}, 100_000)
      10000

      iex> Arbor.Memory.TokenBudget.resolve({:min_max, 500, 5000, 0.10}, 100_000)
      5000
  """
  @spec resolve(budget(), non_neg_integer()) :: non_neg_integer()
  def resolve({:fixed, count}, _context_size) when is_integer(count) and count >= 0 do
    count
  end

  def resolve({:percentage, pct}, context_size)
      when is_number(pct) and pct >= 0 and pct <= 1 do
    trunc(context_size * pct)
  end

  def resolve({:min_max, min, max, pct}, context_size)
      when is_integer(min) and is_integer(max) and is_number(pct) do
    calculated = trunc(context_size * pct)
    calculated |> max(min) |> min(max)
  end

  @doc """
  Resolve a budget for a specific model.

  Looks up the model's context size and then resolves the budget.

  ## Examples

      iex> Arbor.Memory.TokenBudget.resolve_for_model({:percentage, 0.10}, "anthropic:claude-3-5-sonnet-20241022")
      20000
  """
  @spec resolve_for_model(budget(), model_id()) :: non_neg_integer()
  def resolve_for_model(budget, model_id) do
    context_size = model_context_size(model_id)
    resolve(budget, context_size)
  end

  @doc """
  Estimate token count for a piece of text.

  Uses a simple character-based estimation (approximately 4 characters per token
  for English text). For more accurate counts, use a proper tokenizer.

  ## Examples

      iex> Arbor.Memory.TokenBudget.estimate_tokens("Hello, world!")
      4
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 characters per token for English
    # This is a conservative estimate; actual may vary by model
    max(1, div(String.length(text), @chars_per_token))
  end

  @doc """
  Get the context window size for a model.

  Returns the default size for unknown models.

  ## Examples

      iex> Arbor.Memory.TokenBudget.model_context_size("anthropic:claude-3-5-sonnet-20241022")
      200000

      iex> Arbor.Memory.TokenBudget.model_context_size("unknown:model")
      100000
  """
  @spec model_context_size(model_id()) :: non_neg_integer()
  def model_context_size(model_id) when is_binary(model_id) do
    Map.get(@model_context_sizes, model_id, @default_context_size)
  end

  @doc """
  Check if text fits within a budget for a given model.

  ## Examples

      iex> Arbor.Memory.TokenBudget.fits?("Hello", {:fixed, 100}, "anthropic:claude-3-5-sonnet-20241022")
      true

      iex> Arbor.Memory.TokenBudget.fits?(String.duplicate("x", 1000), {:fixed, 10}, "anthropic:claude-3-5-sonnet-20241022")
      false
  """
  @spec fits?(String.t(), budget(), model_id()) :: boolean()
  def fits?(text, budget, model_id) when is_binary(text) do
    estimated = estimate_tokens(text)
    allowed = resolve_for_model(budget, model_id)
    estimated <= allowed
  end

  @doc """
  List all known models and their context sizes.

  ## Examples

      iex> models = Arbor.Memory.TokenBudget.known_models()
      iex> is_list(models)
      true
  """
  @spec known_models() :: [{model_id(), non_neg_integer()}]
  def known_models do
    @model_context_sizes |> Map.to_list() |> Enum.sort_by(fn {_, size} -> -size end)
  end

  @doc """
  Get the default context size used for unknown models.
  """
  @spec default_context_size() :: non_neg_integer()
  def default_context_size, do: @default_context_size

  @doc """
  Allocate a total token budget across multiple sections.

  Takes a map of section names to budget specs and returns a map
  of section names to resolved token counts.

  ## Examples

      iex> allocations = %{
      ...>   system: {:percentage, 0.05},
      ...>   memory: {:percentage, 0.15},
      ...>   context: {:percentage, 0.70},
      ...>   response: {:percentage, 0.10}
      ...> }
      iex> result = Arbor.Memory.TokenBudget.allocate(allocations, 100_000)
      iex> result.system
      5000
  """
  @spec allocate(%{atom() => budget()}, non_neg_integer()) :: %{atom() => non_neg_integer()}
  def allocate(allocations, context_size) when is_map(allocations) do
    Map.new(allocations, fn {section, budget} ->
      {section, resolve(budget, context_size)}
    end)
  end

  @doc """
  Allocate budgets for a specific model.

  ## Examples

      iex> allocations = %{memory: {:percentage, 0.10}}
      iex> result = Arbor.Memory.TokenBudget.allocate_for_model(allocations, "anthropic:claude-3-5-sonnet-20241022")
      iex> result.memory
      20000
  """
  @spec allocate_for_model(%{atom() => budget()}, model_id()) :: %{atom() => non_neg_integer()}
  def allocate_for_model(allocations, model_id) do
    context_size = model_context_size(model_id)
    allocate(allocations, context_size)
  end

  @doc """
  Truncate text to fit within a token budget.

  Truncates from the end and adds an ellipsis indicator.

  ## Examples

      iex> text = String.duplicate("word ", 100)
      iex> truncated = Arbor.Memory.TokenBudget.truncate(text, {:fixed, 10})
      iex> String.ends_with?(truncated, "...")
      true
  """
  @spec truncate(String.t(), budget(), non_neg_integer()) :: String.t()
  def truncate(text, budget, context_size \\ @default_context_size) when is_binary(text) do
    max_tokens = resolve(budget, context_size)
    max_chars = max_tokens * @chars_per_token

    if String.length(text) <= max_chars do
      text
    else
      # Leave room for ellipsis
      truncated_length = max(0, max_chars - 3)
      String.slice(text, 0, truncated_length) <> "..."
    end
  end
end
