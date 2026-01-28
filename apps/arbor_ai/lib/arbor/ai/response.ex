defmodule Arbor.AI.Response do
  @moduledoc """
  Unified response struct for all LLM backends.

  Uses `Arbor.Common.SafeAtom` for safe provider name conversion to prevent
  atom exhaustion attacks from untrusted input.

  This struct provides a consistent interface regardless of whether the response
  came from an API (via ReqLLM) or a CLI agent (claude, codex, gemini, etc.).

  ## Fields

  Required (all backends must provide):
  - `text` - The generated text content
  - `provider` - The backend that generated the response

  Optional (backends provide what they can):
  - `model` - The model that generated the response
  - `session_id` - For session resumption (CLI agents)
  - `usage` - Token usage information
  - `finish_reason` - Why generation stopped
  - `timing` - Performance metrics
  - `tool_stats` - Tool usage statistics (agentic backends)
  - `raw_response` - Original response for debugging

  ## Usage

      {:ok, response} = Arbor.AI.generate_text("Hello", backend: :cli)
      response.text
      #=> "Hello! How can I help you today?"

      response.provider
      #=> :anthropic

      response.usage
      #=> %{input_tokens: 5, output_tokens: 10, total_tokens: 15}
  """

  alias Arbor.Common.SafeAtom

  @type provider ::
          :anthropic
          | :openai
          | :gemini
          | :lmstudio
          | :qwen
          | :opencode

  @known_providers [:anthropic, :openai, :gemini, :lmstudio, :qwen, :opencode]

  @type finish_reason :: :stop | :max_tokens | :tool_use | :error | nil

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:cache_read_tokens) => non_neg_integer(),
          optional(:cache_creation_tokens) => non_neg_integer(),
          optional(:cached_tokens) => non_neg_integer(),
          optional(:cost_usd) => float()
        }

  @type timing :: %{
          optional(:duration_ms) => non_neg_integer(),
          optional(:duration_api_ms) => non_neg_integer(),
          optional(:latency_ms) => non_neg_integer()
        }

  @type tool_stats :: %{
          optional(:total_calls) => non_neg_integer(),
          optional(:total_success) => non_neg_integer(),
          optional(:total_fail) => non_neg_integer(),
          optional(:duration_ms) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          text: String.t(),
          provider: provider(),
          model: String.t() | nil,
          requested_model: String.t() | nil,
          session_id: String.t() | nil,
          usage: usage() | nil,
          finish_reason: finish_reason(),
          timing: timing() | nil,
          tool_stats: tool_stats() | nil,
          raw_response: term()
        }

  defstruct [
    :text,
    :provider,
    :model,
    :requested_model,
    :session_id,
    :usage,
    :finish_reason,
    :timing,
    :tool_stats,
    :raw_response
  ]

  @doc """
  Creates a new Response struct with the given attributes.

  ## Examples

      Response.new(text: "Hello", provider: :anthropic, model: "claude-opus-4-5")
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Creates a Response from a map (e.g., from JSON parsing).
  """
  @spec from_map(map()) :: t()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def from_map(map) when is_map(map) do
    %__MODULE__{
      text: map[:text] || map["text"] || "",
      provider: normalize_provider(map[:provider] || map["provider"]),
      model: map[:model] || map["model"],
      requested_model: map[:requested_model] || map["requested_model"],
      session_id: map[:session_id] || map["session_id"],
      usage: normalize_usage(map[:usage] || map["usage"]),
      finish_reason: normalize_finish_reason(map[:finish_reason] || map["finish_reason"]),
      timing: map[:timing] || map["timing"],
      tool_stats: map[:tool_stats] || map["tool_stats"],
      raw_response: map[:raw_response] || map["raw_response"]
    }
  end

  # Normalize provider to atom using SafeAtom with known providers list
  defp normalize_provider(nil), do: nil
  defp normalize_provider(p) when is_atom(p), do: p

  defp normalize_provider(p) when is_binary(p) do
    case SafeAtom.to_allowed(p, @known_providers) do
      {:ok, atom} -> atom
      # If unknown provider, return nil rather than creating arbitrary atoms
      {:error, _} -> nil
    end
  end

  # Normalize usage map
  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
      output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0,
      total_tokens: usage[:total_tokens] || usage["total_tokens"] || 0
    }
    |> maybe_add_cache_tokens(usage)
    |> maybe_add_cost(usage)
  end

  defp maybe_add_cache_tokens(normalized, usage) do
    cache_read = usage[:cache_read_tokens] || usage["cache_read_tokens"]
    cache_creation = usage[:cache_creation_tokens] || usage["cache_creation_tokens"]
    cached = usage[:cached_tokens] || usage["cached_tokens"]

    normalized
    |> maybe_put(:cache_read_tokens, cache_read)
    |> maybe_put(:cache_creation_tokens, cache_creation)
    |> maybe_put(:cached_tokens, cached)
  end

  defp maybe_add_cost(normalized, usage) do
    cost = usage[:cost_usd] || usage["cost_usd"]
    maybe_put(normalized, :cost_usd, cost)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Normalize finish reason
  defp normalize_finish_reason(nil), do: nil
  defp normalize_finish_reason(r) when r in [:stop, :max_tokens, :tool_use, :error], do: r
  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("end_turn"), do: :stop
  defp normalize_finish_reason("max_tokens"), do: :max_tokens
  defp normalize_finish_reason("length"), do: :max_tokens
  defp normalize_finish_reason("tool_use"), do: :tool_use
  defp normalize_finish_reason("tool_calls"), do: :tool_use
  defp normalize_finish_reason(_), do: nil
end
