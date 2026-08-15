defmodule Arbor.Contracts.LLM.ModelEntry do
  @moduledoc """
  Logical-model registry entry.

  Centralizes everything Arbor knows about a model: the canonical id, the
  set of `ProviderEntry` paths that reach it, context window, capabilities,
  and caveats. Replaces the legacy `%{context_size, effective_window_pct,
  max_output_tokens, family}` map shape used by `Arbor.Common.ModelProfile`
  for the entries that have been migrated; the legacy shape remains the
  fallback for unmigrated entries.

  ## Fields

  - `:canonical_id` — Arbor's stable name for the model. Provider-specific
    refs (`anthropic.claude-opus-4-8-v1:0`, `anthropic/claude-opus-4-8`,
    `claude-opus-4-8`) all normalize to this. Conventional form is the
    bare provider-native name when one provider is the obvious source
    of truth (`claude-opus-4-8`, `gpt-5-nano`); else namespaced
    (`openai/gpt-oss-120b:free`).
  - `:providers` — non-empty list of `ProviderEntry` structs. Order is
    informational; provider priority is a runtime selection concern.
  - `:family` — coarse grouping atom (`:claude`, `:gpt`, `:gemini`,
    `:llama`, `:openrouter_free`, `:unknown`). Used by family-pattern
    fallback for unmigrated entries.
  - `:context_window` — total context window in tokens.
  - `:max_output_tokens` — maximum output tokens the model will emit in
    one turn.
  - `:effective_window_pct` — fraction of context window at which
    compaction should trigger. Default 0.75. Override per model once
    empirical eval data lands.
  - `:capabilities` — list of capability atoms. Conventional set:
    `:tool_use`, `:vision`, `:prompt_cache`, `:extended_thinking`,
    `:json_mode`, `:streaming`, `:embedding`, `:reasoning_content`.
    Used by Phase 2's runtime compatibility contract.
  - `:caveats` — list of human-readable strings noting known issues
    or restrictions (e.g. "Bedrock variant lacks prompt cache in
    eu-west regions"). Shown by `mix arbor.doctor`.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ProviderEntry

  @type capability ::
          :tool_use
          | :vision
          | :prompt_cache
          | :extended_thinking
          | :json_mode
          | :streaming
          | :embedding
          | :reasoning_content

  typedstruct enforce: true do
    @typedoc "Full registry entry for a logical model."

    field(:canonical_id, String.t())
    field(:providers, [ProviderEntry.t()])
    field(:family, atom())
    field(:context_window, non_neg_integer())
    field(:max_output_tokens, non_neg_integer())
    field(:effective_window_pct, float(), default: 0.75)
    field(:capabilities, [capability()], default: [])
    field(:caveats, [String.t()], default: [])
  end

  @doc """
  Construct a new `%ModelEntry{}`. Validates required fields, coerces
  provider list entries from maps if needed, and defaults
  `effective_window_pct` / `capabilities` / `caveats` when omitted.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Enum.into(attrs, %{}))

  def new(%{} = attrs) do
    with {:ok, canonical_id} <- fetch_string(attrs, :canonical_id),
         {:ok, providers} <- fetch_providers(attrs),
         {:ok, family} <- fetch_atom(attrs, :family),
         {:ok, context_window} <- fetch_pos_int(attrs, :context_window),
         {:ok, max_output_tokens} <- fetch_pos_int(attrs, :max_output_tokens) do
      {:ok,
       %__MODULE__{
         canonical_id: canonical_id,
         providers: providers,
         family: family,
         context_window: context_window,
         max_output_tokens: max_output_tokens,
         effective_window_pct: pick(attrs, :effective_window_pct) || 0.75,
         capabilities: pick(attrs, :capabilities) || [],
         caveats: pick(attrs, :caveats) || []
       }}
    end
  end

  @doc """
  Compaction trigger point in tokens: `context_window * effective_window_pct`.
  """
  @spec effective_window(t()) :: non_neg_integer()
  def effective_window(%__MODULE__{} = entry) do
    trunc(entry.context_window * entry.effective_window_pct)
  end

  @doc """
  Does this entry have the given capability?
  """
  @spec capable?(t(), capability()) :: boolean()
  def capable?(%__MODULE__{capabilities: caps}, capability) do
    capability in caps
  end

  @doc """
  Return the first `ProviderEntry` whose id matches `provider_id`, or `nil`.
  """
  @spec provider(t(), atom()) :: ProviderEntry.t() | nil
  def provider(%__MODULE__{providers: providers}, provider_id) when is_atom(provider_id) do
    Enum.find(providers, fn p -> p.id == provider_id end)
  end

  defp pick(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp fetch_string(attrs, key) do
    case pick(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_atom(attrs, key) do
    case pick(attrs, key) do
      v when is_atom(v) and not is_nil(v) -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_pos_int(attrs, key) do
    case pick(attrs, key) do
      v when is_integer(v) and v > 0 -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_providers(attrs) do
    case pick(attrs, :providers) do
      list when is_list(list) and list != [] ->
        coerce_providers(list, [])

      _ ->
        {:error, :providers_required}
    end
  end

  defp coerce_providers([], acc), do: {:ok, Enum.reverse(acc)}

  defp coerce_providers([%ProviderEntry{} = p | rest], acc) do
    coerce_providers(rest, [p | acc])
  end

  defp coerce_providers([attrs | rest], acc) when is_map(attrs) or is_list(attrs) do
    case ProviderEntry.new(attrs) do
      {:ok, p} -> coerce_providers(rest, [p | acc])
      {:error, reason} -> {:error, {:invalid_provider, reason}}
    end
  end

  defp coerce_providers([other | _], _acc) do
    {:error, {:invalid_provider, other}}
  end
end
