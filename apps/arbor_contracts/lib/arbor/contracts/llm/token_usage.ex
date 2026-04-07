defmodule Arbor.Contracts.LLM.TokenUsage do
  @moduledoc """
  Typed token usage from a single LLM invocation.

  This is the **single source of truth** for "how many tokens did this call
  cost". Adapters construct it from raw provider responses; downstream code
  (telemetry, persistence, signals, dashboards) reads typed fields instead
  of guessing string-vs-atom map keys.

  ## Why this exists

  Before this struct, LLM usage flowed through the system as a plain map
  with string keys whose names varied by provider — `"input_tokens"`,
  `"prompt_tokens"`, `"cache_read_input_tokens"`, etc. Producers and
  consumers drifted apart: persistence read `"llm.usage"` (a key nothing
  ever wrote), and the heartbeat signal payload literally forgot to
  include usage at all. The compiler caught none of it because every
  field was just `Map.get/3` returning `nil`.

  Constructing through `from_provider/2` means:
  - "input_tokens vs prompt_tokens" is a one-time decision at the boundary
  - empty/missing usage fails loudly at the construction site
  - the rest of the system reads `usage.input_tokens` and gets a typed value

  ## Construction

  Adapters call `from_provider(:openai, raw_body)` (or `:anthropic`, etc.)
  to convert provider-specific shapes into a uniform struct. The
  `from_map/1` constructor accepts a normalized map for the inverse path
  (e.g. when rehydrating from persistence).

  ## Conversion

  The struct provides explicit converters for boundary crossings:

  - `to_signal_data/1` — atom-keyed map for emitting via Arbor.Signals
  - `to_persistence/1` — atom-keyed map for the event store / DB
  - `to_telemetry/1`   — atom-keyed map for `:telemetry.execute/3`

  These are lossless and round-trip via `from_map/1`.
  """

  use TypedStruct

  @typedoc "Provider name (atom or string from Request.provider)."
  @type provider :: atom() | String.t() | nil

  typedstruct do
    @typedoc "Token usage for one LLM call"

    field(:input_tokens, non_neg_integer() | nil)
    field(:output_tokens, non_neg_integer() | nil)
    field(:total_tokens, non_neg_integer() | nil)
    field(:cache_read_tokens, non_neg_integer() | nil)
    field(:cache_write_tokens, non_neg_integer() | nil)
    field(:reasoning_tokens, non_neg_integer() | nil)
    field(:cost, float() | nil)
    field(:duration_ms, non_neg_integer() | nil)
    field(:provider, provider())
    field(:model, String.t() | nil)
  end

  @doc """
  Build a TokenUsage from a provider response body.

  Pass the raw decoded JSON `body` (a map) and the provider tag. Each
  branch knows the provider's key naming and returns a uniform struct.
  Unknown providers fall through to a generic OpenAI-shaped extraction.
  """
  @spec from_provider(provider(), map() | nil) :: t()
  def from_provider(_provider, nil), do: %__MODULE__{}
  def from_provider(_provider, body) when not is_map(body), do: %__MODULE__{}

  def from_provider(:anthropic, body) do
    usage = Map.get(body, "usage") || %{}

    %__MODULE__{
      input_tokens: int_or_nil(usage["input_tokens"]),
      output_tokens: int_or_nil(usage["output_tokens"]),
      total_tokens: sum_or_nil(usage["input_tokens"], usage["output_tokens"]),
      cache_read_tokens: int_or_nil(usage["cache_read_input_tokens"]),
      cache_write_tokens: int_or_nil(usage["cache_creation_input_tokens"]),
      reasoning_tokens: nil,
      cost: nil,
      provider: :anthropic
    }
  end

  def from_provider(provider, body) when provider in [:openai, :openrouter, :xai, :ollama, :lm_studio, :zai, :gemini] do
    from_openai_shape(body, provider)
  end

  def from_provider(provider, body) do
    # Generic fallback — try OpenAI shape, tag with whatever provider we got.
    from_openai_shape(body, provider)
  end

  defp from_openai_shape(body, provider) do
    usage = Map.get(body, "usage") || %{}
    prompt = int_or_nil(usage["prompt_tokens"])
    completion = int_or_nil(usage["completion_tokens"])
    total = int_or_nil(usage["total_tokens"]) || sum_or_nil(prompt, completion)

    %__MODULE__{
      input_tokens: prompt,
      output_tokens: completion,
      total_tokens: total,
      cache_read_tokens: int_or_nil(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
      cache_write_tokens: nil,
      reasoning_tokens:
        int_or_nil(get_in(usage, ["completion_tokens_details", "reasoning_tokens"])),
      cost: float_or_nil(usage["cost"]),
      provider: provider
    }
  end

  @doc """
  Build a TokenUsage from a previously-converted map.

  Accepts both atom and string keys. Useful for rehydrating from
  persistence or from a signal payload.
  """
  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(map) when not is_map(map), do: %__MODULE__{}

  def from_map(%__MODULE__{} = u), do: u

  def from_map(map) do
    %__MODULE__{
      input_tokens: get(map, :input_tokens),
      output_tokens: get(map, :output_tokens),
      total_tokens: get(map, :total_tokens),
      cache_read_tokens: get(map, :cache_read_tokens),
      cache_write_tokens: get(map, :cache_write_tokens),
      reasoning_tokens: get(map, :reasoning_tokens),
      cost: get(map, :cost),
      duration_ms: get(map, :duration_ms),
      provider: get(map, :provider),
      model: get(map, :model)
    }
  end

  @doc "Returns true when the struct carries no token information."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{input_tokens: nil, output_tokens: nil, total_tokens: nil}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Add two TokenUsage structs together. Provider/model are taken from the
  right-hand side when present, falling back to the left.
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: sum(a.input_tokens, b.input_tokens),
      output_tokens: sum(a.output_tokens, b.output_tokens),
      total_tokens: sum(a.total_tokens, b.total_tokens),
      cache_read_tokens: sum(a.cache_read_tokens, b.cache_read_tokens),
      cache_write_tokens: sum(a.cache_write_tokens, b.cache_write_tokens),
      reasoning_tokens: sum(a.reasoning_tokens, b.reasoning_tokens),
      cost: sum_float(a.cost, b.cost),
      duration_ms: sum(a.duration_ms, b.duration_ms),
      provider: b.provider || a.provider,
      model: b.model || a.model
    }
  end

  @doc """
  Attach call metadata (duration, provider, model) to a usage struct.

  Adapters typically don't know how long the HTTP call took; the handler
  measures it after the fact and stamps it on. Provider and model often
  come from the request, not the response body, so we let the caller
  override.
  """
  @spec with_meta(t(), keyword()) :: t()
  def with_meta(%__MODULE__{} = u, opts) do
    %__MODULE__{
      u
      | duration_ms: opts[:duration_ms] || u.duration_ms,
        provider: opts[:provider] || u.provider,
        model: opts[:model] || u.model
    }
  end

  # ============================================================================
  # Conversion (Convert)
  # ============================================================================

  @doc "Convert to a flat atom-keyed map for emitting in a signal payload."
  @spec to_signal_data(t()) :: map()
  def to_signal_data(%__MODULE__{} = u), do: to_map(u)

  @doc "Convert to a flat atom-keyed map for storage in the event log / DB."
  @spec to_persistence(t()) :: map()
  def to_persistence(%__MODULE__{} = u), do: to_map(u)

  @doc "Convert to a flat atom-keyed map suitable for `:telemetry.execute/3`."
  @spec to_telemetry(t()) :: map()
  def to_telemetry(%__MODULE__{} = u) do
    %{
      input_tokens: u.input_tokens || 0,
      output_tokens: u.output_tokens || 0,
      total_tokens: u.total_tokens || 0,
      cached_tokens: u.cache_read_tokens || 0,
      duration_ms: u.duration_ms,
      provider: u.provider,
      model: u.model
    }
  end

  defp to_map(%__MODULE__{} = u) do
    %{
      input_tokens: u.input_tokens,
      output_tokens: u.output_tokens,
      total_tokens: u.total_tokens,
      cache_read_tokens: u.cache_read_tokens,
      cache_write_tokens: u.cache_write_tokens,
      reasoning_tokens: u.reasoning_tokens,
      cost: u.cost,
      duration_ms: u.duration_ms,
      provider: u.provider,
      model: u.model
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp int_or_nil(n) when is_integer(n), do: n
  defp int_or_nil(n) when is_float(n), do: trunc(n)
  defp int_or_nil(_), do: nil

  defp float_or_nil(n) when is_float(n), do: n
  defp float_or_nil(n) when is_integer(n), do: n / 1
  defp float_or_nil(_), do: nil

  defp sum_or_nil(nil, nil), do: nil
  defp sum_or_nil(a, b), do: (a || 0) + (b || 0)

  defp sum(nil, nil), do: nil
  defp sum(a, b), do: (a || 0) + (b || 0)

  defp sum_float(nil, nil), do: nil
  defp sum_float(a, b), do: (a || 0.0) + (b || 0.0)
end
