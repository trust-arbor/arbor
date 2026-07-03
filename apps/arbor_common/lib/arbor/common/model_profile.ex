defmodule Arbor.Common.ModelProfile do
  @moduledoc """
  Centralized model metadata registry.

  Provides model context sizes, effective window percentages, and output limits
  at Level 0.5 (arbor_common), so both `arbor_agent` and `arbor_memory` can
  access them without runtime bridges.

  ## Model ID Formats

  Supports multiple model ID formats:

  - OpenRouter: `"openai/gpt-oss-120b:free"`, `"anthropic/claude-sonnet-4"`
  - Provider-prefixed: `"anthropic:claude-3-5-sonnet-20241022"`, `"openai:gpt-4o"`
  - Bare: `"claude-sonnet-4"`, `"gpt-4o"`, `"gemini-2.0-flash"`

  Unknown models are matched by family patterns (e.g., contains "claude" → 200K context).

  ## Effective Window

  The `effective_window_pct` is the percentage of context window at which
  compaction should trigger. Default is 0.75 (75%). Can be overridden per
  model once empirical data from `mix arbor.eval.window` is available.

  ## Usage

      ModelProfile.context_size("anthropic/claude-sonnet-4")
      # => 200_000

      ModelProfile.effective_window_pct("openai/gpt-oss-120b:free")
      # => 0.75

      ModelProfile.get("openai:gpt-4o")
      # => %{context_size: 128_000, effective_window_pct: 0.75, max_output_tokens: 16_384, ...}
  """

  @type model_id :: String.t()

  @type profile :: %{
          context_size: non_neg_integer(),
          effective_window_pct: float(),
          max_output_tokens: non_neg_integer(),
          family: atom()
        }

  @default_context_size 100_000
  @default_effective_window_pct 0.75
  @default_max_output 4_096

  # -- Static Registry --
  # Keys support all formats: provider:model, org/model, bare model name

  @profiles %{
    # ===== Anthropic Claude =====
    # Claude 4.5/4.6
    "claude-opus-4-6" => %{context_size: 200_000, max_output_tokens: 32_000, family: :claude},
    "claude-sonnet-4-6" => %{context_size: 200_000, max_output_tokens: 64_000, family: :claude},
    "claude-opus-4-5-20251101" => %{
      context_size: 200_000,
      max_output_tokens: 32_000,
      family: :claude
    },
    "claude-sonnet-4-5-20250514" => %{
      context_size: 200_000,
      max_output_tokens: 64_000,
      family: :claude
    },
    "claude-haiku-4-5-20251001" => %{
      context_size: 200_000,
      max_output_tokens: 8_192,
      family: :claude
    },
    # Claude 3.5
    "claude-3-5-sonnet-20241022" => %{
      context_size: 200_000,
      max_output_tokens: 8_192,
      family: :claude
    },
    "claude-3-5-haiku-20241022" => %{
      context_size: 200_000,
      max_output_tokens: 8_192,
      family: :claude
    },
    # Claude 3
    "claude-3-opus-20240229" => %{
      context_size: 200_000,
      max_output_tokens: 4_096,
      family: :claude
    },
    "claude-3-sonnet-20240229" => %{
      context_size: 200_000,
      max_output_tokens: 4_096,
      family: :claude
    },
    "claude-3-haiku-20240307" => %{
      context_size: 200_000,
      max_output_tokens: 4_096,
      family: :claude
    },

    # ===== OpenAI =====
    "gpt-4o" => %{context_size: 128_000, max_output_tokens: 16_384, family: :gpt},
    "gpt-4o-mini" => %{context_size: 128_000, max_output_tokens: 16_384, family: :gpt},
    "gpt-4-turbo" => %{context_size: 128_000, max_output_tokens: 4_096, family: :gpt},
    "gpt-4" => %{context_size: 8_192, max_output_tokens: 4_096, family: :gpt},
    "gpt-3.5-turbo" => %{context_size: 16_385, max_output_tokens: 4_096, family: :gpt},
    "gpt-5-nano" => %{context_size: 128_000, max_output_tokens: 16_384, family: :gpt},

    # ===== Google Gemini =====
    "gemini-1.5-pro" => %{context_size: 2_000_000, max_output_tokens: 8_192, family: :gemini},
    "gemini-1.5-flash" => %{context_size: 1_000_000, max_output_tokens: 8_192, family: :gemini},
    "gemini-2.0-flash" => %{context_size: 1_000_000, max_output_tokens: 8_192, family: :gemini},
    "gemini-3-flash-preview" => %{
      context_size: 1_000_000,
      max_output_tokens: 8_192,
      family: :gemini
    },

    # ===== OpenRouter Free Models =====
    # NOTE: arcee trinity-large-preview was retired by OpenRouter 2026-04-22;
    # gpt-oss-120b:free / gpt-oss-20b:free are its successors (below).
    # See .arbor/roadmap/0-inbox/aggregator-provider-model-availability.md
    # for the broader pattern of tracking aggregator-served models.
    "openai/gpt-oss-120b:free" => %{
      context_size: 131_072,
      max_output_tokens: 4_096,
      family: :openrouter_free
    },
    "openai/gpt-oss-20b:free" => %{
      context_size: 131_072,
      max_output_tokens: 4_096,
      family: :openrouter_free
    },
    "arcee-ai/trinity-mini-preview:free" => %{
      context_size: 131_072,
      max_output_tokens: 4_096,
      family: :openrouter_free
    },

    # ===== DeepSeek =====
    "deepseek-chat" => %{context_size: 128_000, max_output_tokens: 8_192, family: :deepseek},
    "deepseek-coder" => %{context_size: 128_000, max_output_tokens: 8_192, family: :deepseek},

    # ===== Kimi =====
    # k2.7-code / k2.6 / k2.5 default max_tokens is 32k (Moonshot docs). These are THINKING
    # models by default and REJECT custom temperature/top_p/penalties (fixed values — any
    # other value errors), so callers should omit those knobs for kimi.
    "moonshotai/kimi-k2.5" => %{context_size: 128_000, max_output_tokens: 32_768, family: :kimi},
    "kimi-k2.7-code:cloud" => %{context_size: 128_000, max_output_tokens: 32_768, family: :kimi},
    "kimi-k2.7-code" => %{context_size: 128_000, max_output_tokens: 32_768, family: :kimi},

    # ===== Local Models =====
    "llama3.2" => %{context_size: 128_000, max_output_tokens: 4_096, family: :llama},
    "qwen3-coder-next" => %{context_size: 32_768, max_output_tokens: 4_096, family: :qwen},
    "mistral" => %{context_size: 32_000, max_output_tokens: 4_096, family: :mistral},
    "mixtral" => %{context_size: 32_000, max_output_tokens: 4_096, family: :mixtral}
  }

  # Family-based defaults for pattern matching
  @family_defaults %{
    claude: %{context_size: 200_000, max_output_tokens: 8_192},
    gpt: %{context_size: 128_000, max_output_tokens: 16_384},
    gemini: %{context_size: 1_000_000, max_output_tokens: 8_192},
    deepseek: %{context_size: 128_000, max_output_tokens: 8_192},
    llama: %{context_size: 128_000, max_output_tokens: 4_096},
    qwen: %{context_size: 32_768, max_output_tokens: 4_096},
    mistral: %{context_size: 32_000, max_output_tokens: 4_096}
  }

  # Pattern matching rules: {pattern, family}
  @family_patterns [
    {"claude", :claude},
    {"gpt-4", :gpt},
    {"gpt-3", :gpt},
    {"gpt-5", :gpt},
    {"gemini", :gemini},
    {"deepseek", :deepseek},
    {"llama", :llama},
    {"qwen", :qwen},
    {"mistral", :mistral},
    {"mixtral", :mixtral},
    {"trinity", :openrouter_free}
  ]

  # -- ModelEntry resolution (Phase 1 of item 9) --
  #
  # `entry/1` reads model metadata from llm_db (the source of truth) and
  # constructs a `%Arbor.Contracts.LLM.ModelEntry{}`. The only Arbor-side
  # data that gets layered on top is what llm_db doesn't model:
  #
  #   * `:acp` runtime support for specific `(provider, model)` pairs —
  #     Arbor knows it ships a Claude CLI / ACP harness for the Claude
  #     subscription provider; llm_db doesn't model "this Arbor deployment
  #     can also reach this provider via a subprocess CLI."
  #   * `effective_window_pct` overrides — currently universal at 0.75.
  #   * Arbor-deployment-specific caveats — none today.
  #
  # When llm_db has no record for a model (e.g. very new local-LM IDs the
  # operator hasn't pulled, or OpenRouter free-tier listings that change
  # weekly), `entry/1` falls back to synthesizing a `%ModelEntry{}` from
  # the legacy `@profiles` short-form below — same single-provider
  # `id: :legacy` shape as before. That preserves backwards-compat
  # without lying about provider/pricing.

  # Arbor-deployment-specific runtime overlay. Keyed by `{provider, model_id}`
  # (as llm_db keys models) with a list of extra runtime atoms beyond `:arbor`
  # (which is always supported via the in-BEAM HTTP path through arbor_llm).
  #
  # Only `(provider, model)` pairs Arbor actually ships a non-arbor runtime
  # adapter for go in here — adding an entry without the corresponding
  # adapter would mean `Arbor.AI.Runtime.execute/3` raises at dispatch.
  defp arbor_runtime_overlay do
    %{
      # Claude CLI via ACP. arbor_ai's AcpSession + Adapters.Acp ship the
      # subprocess harness. `claude_subscription` is llm_db's atom for
      # the OAuth/subscription provider.
      {:anthropic, "claude-opus-4-6"} => [:acp],
      {:anthropic, "claude-sonnet-4-6"} => [:acp],
      {:anthropic, "claude-haiku-4-5-20251001"} => [:acp]
    }
  end

  # Family inference when llm_db's `family` field is nil. Uses the same
  # patterns as the legacy short-form fallback.
  defp infer_family(model_id) when is_binary(model_id) do
    downcased = String.downcase(model_id)

    case Enum.find(@family_patterns, fn {pattern, _family} ->
           String.contains?(downcased, pattern)
         end) do
      {_pattern, family} -> family
      nil -> :unknown
    end
  end

  # Translate llm_db's capability schema to Arbor's atom set. llm_db uses
  # boolean flags and structured maps (e.g. `tools: %{enabled: true,
  # streaming: true}`); Arbor consumers want a flat list of atoms.
  defp arbor_capabilities_from_llmdb(%{} = caps) do
    [
      {:chat, :chat},
      {:tools, :tool_use},
      {:embeddings, :embedding},
      {:json, :json_mode},
      {:streaming, :streaming},
      {:reasoning, :reasoning_content},
      {:caching, :prompt_cache}
    ]
    |> Enum.flat_map(fn {llmdb_key, arbor_atom} ->
      if cap_enabled?(Map.get(caps, llmdb_key)), do: [arbor_atom], else: []
    end)
  end

  defp arbor_capabilities_from_llmdb(_), do: []

  defp cap_enabled?(true), do: true
  defp cap_enabled?(%{enabled: true}), do: true
  defp cap_enabled?(%{} = m) when map_size(m) > 0, do: not Map.get(m, :enabled, true) == false
  defp cap_enabled?(_), do: false

  # Translate llm_db's `cost` map (per million tokens) to Arbor's
  # ProviderEntry pricing shape. `cost` keys are `:input`, `:output`,
  # `:cache_read`, `:cache_write` and values are numbers.
  defp pricing_from_llmdb(%{} = cost) do
    [
      {:input, :input_per_mtok},
      {:output, :output_per_mtok},
      {:cache_read, :cache_read_per_mtok},
      {:cache_write, :cache_write_per_mtok}
    ]
    |> Enum.reduce(%{}, fn {llmdb_key, arbor_key}, acc ->
      case Map.get(cost, llmdb_key) do
        v when is_number(v) -> Map.put(acc, arbor_key, v * 1.0)
        _ -> acc
      end
    end)
    |> case do
      m when map_size(m) == 0 -> nil
      m -> m
    end
  end

  defp pricing_from_llmdb(_), do: nil

  # -- Public API --

  @doc """
  Get the full profile for a model.

  Tries exact match first, then strips provider prefix, then pattern-matches
  by model family. Returns sensible defaults for unknown models.
  """
  @spec get(model_id()) :: profile()
  def get(model_id) when is_binary(model_id) do
    base = lookup(model_id)

    %{
      context_size: base[:context_size] || @default_context_size,
      effective_window_pct: base[:effective_window_pct] || @default_effective_window_pct,
      max_output_tokens: base[:max_output_tokens] || @default_max_output,
      family: base[:family] || :unknown
    }
  end

  @doc """
  Return a `%Arbor.Contracts.LLM.ModelEntry{}` for `model_id`.

  Resolves through llm_db (the canonical model catalog) when available,
  layering Arbor-deployment-specific data (additional runtime adapters,
  `effective_window_pct` tunables, Arbor caveats) on top. Falls back to
  the legacy short-form `@profiles` map only when llm_db has no record
  for the model.

  `model_id` accepts the same formats as `get/1`:

    * `"provider:model"` — e.g. `"anthropic:claude-opus-4-6"`
    * `"org/model"` — e.g. `"anthropic/claude-opus-4-6"`,
      `"openai/gpt-oss-120b:free"`
    * bare model id — e.g. `"claude-opus-4-6"`, `"gpt-5-nano"`

  ## What this is NOT

  Phase 1 returns a single-provider entry: the one matching the queried
  `model_id`. It does NOT aggregate all providers that serve the same
  logical model. Multi-provider aggregation belongs to Phase 2's runtime
  selection chain, which can scan llm_db across providers when it has a
  reason to.
  """
  @spec entry(model_id()) :: Arbor.Contracts.LLM.ModelEntry.t()
  def entry(model_id) when is_binary(model_id) do
    case llmdb_lookup(model_id) do
      {:ok, llmdb_model} ->
        from_llmdb(llmdb_model)

      :miss ->
        synthesize_entry(model_id)
    end
  end

  # llm_db module reference — declared here so refresh/1 (defined below
  # in this section) and the lookup helpers (further down) can both use
  # it. Module attributes have to be in scope at point of use; can't
  # forward-reference.
  @llmdb_module LLMDB

  @doc """
  Reload the llm_db catalog and report what changed.

  `LLMDB.load/1` is idempotent — same opts as the prior load is a
  no-op — so this is safe to call repeatedly. Returns `{:ok, summary}`
  with before/after model counts so operators can see if a refresh
  actually picked up new entries.

  Emits `[:arbor, :model_registry, :refreshed]` telemetry with the
  same summary plus `:duration_ms`.

  ## Options

  Pass anything `LLMDB.load/1` accepts: `:allow`, `:deny`, `:prefer`,
  `:custom`. When `opts` is `[]`, the load uses the existing
  `config :llm_db, ...` settings — i.e. just rebuilds from the
  packaged snapshot.

  Returns `{:error, :llm_db_unavailable}` if `LLMDB` isn't loaded
  (unit tests without the dep). Wraps `LLMDB.load/1` errors as
  `{:error, {:llm_db_error, reason}}` so the failure shape is
  caller-friendly.
  """
  @spec refresh(keyword()) ::
          {:ok, %{before: non_neg_integer(), after: non_neg_integer(), duration_ms: integer()}}
          | {:error, term()}
  def refresh(opts \\ []) do
    if llmdb_available?() do
      before_count = safe_model_count()
      started_at = System.monotonic_time(:millisecond)

      case apply(@llmdb_module, :load, [opts]) do
        {:ok, _snapshot} ->
          after_count = safe_model_count()
          duration_ms = System.monotonic_time(:millisecond) - started_at

          summary = %{
            before: before_count,
            after: after_count,
            duration_ms: duration_ms
          }

          safe_telemetry([:arbor, :model_registry, :refreshed], %{count: 1}, summary)
          {:ok, summary}

        {:error, reason} ->
          {:error, {:llm_db_error, reason}}
      end
    else
      {:error, :llm_db_unavailable}
    end
  end

  # `LLMDB.models/0` returns a list when loaded; some test fixtures may
  # not implement it. Fall back to 0 rather than crashing the refresh
  # path with metric collection.
  defp safe_model_count do
    if function_exported?(@llmdb_module, :models, 0) do
      try do
        apply(@llmdb_module, :models, []) |> length()
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end
    else
      0
    end
  end

  defp safe_telemetry(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # llm_db is a transitive dep via req_llm — not a compile-time dep of
  # arbor_common, so use apply/3 to keep the compiler quiet. Matches the
  # pattern in arbor_llm/lib/arbor/llm/client.ex. (@llmdb_module is
  # declared earlier in the file so refresh/1 above can also use it.)

  defp llmdb_available?, do: Code.ensure_loaded?(@llmdb_module)

  # Try llm_db with the model_id verbatim, then with reasonable splits.
  # `LLMDB.model/1` accepts `"provider:model"` directly; for bare ids we
  # try to derive the provider from the family pattern. llm_db is loaded
  # by `:llm_db` at application start; if it's absent (e.g. unit tests
  # without it), this returns `:miss` and the caller falls back.
  defp llmdb_lookup(model_id) do
    cond do
      not llmdb_available?() ->
        :miss

      String.contains?(model_id, ":") ->
        llmdb_try(model_id)

      true ->
        # Bare id — guess the provider from the family.
        case infer_family(model_id) do
          :claude -> llmdb_try("anthropic:" <> model_id)
          :gpt -> llmdb_try("openai:" <> model_id)
          :gemini -> llmdb_try("google:" <> model_id)
          _ -> :miss
        end
    end
  end

  defp llmdb_try(spec) do
    case apply(@llmdb_module, :model, [spec]) do
      {:ok, model} -> {:ok, model}
      {:error, _} -> :miss
    end
  rescue
    _ -> :miss
  catch
    :exit, _ -> :miss
  end

  # Construct a ModelEntry from a %LLMDB.Model{}.
  defp from_llmdb(%{__struct__: _} = m) do
    family =
      case m.family do
        f when is_atom(f) and not is_nil(f) -> f
        f when is_binary(f) and f != "" -> safe_family_atom(f, m.id)
        _ -> infer_family(m.id)
      end

    base_runtimes = [:arbor]
    extra_runtimes = Map.get(arbor_runtime_overlay(), {m.provider, m.id}, [])
    runtimes = base_runtimes ++ extra_runtimes

    provider_attrs = %{
      id: m.provider,
      ref: m.id,
      auth: auth_for_provider(m.provider),
      runtimes: runtimes,
      pricing: pricing_from_llmdb(m.cost)
    }

    context = get_in(m.limits, [:context]) || @default_context_size
    output = get_in(m.limits, [:output]) || @default_max_output

    attrs = %{
      canonical_id: m.id,
      family: family,
      context_window: context,
      max_output_tokens: output,
      effective_window_pct: @default_effective_window_pct,
      capabilities: arbor_capabilities_from_llmdb(m.capabilities || %{}),
      caveats: [],
      providers: [provider_attrs]
    }

    {:ok, entry} = Arbor.Contracts.LLM.ModelEntry.new(attrs)
    entry
  end

  # Convert llm_db's family string to an atom only if we already recognize
  # it — otherwise fall back to the family-pattern inference. Avoids
  # arbitrary atom creation from a downstream-controlled string.
  defp safe_family_atom(family_str, model_id) do
    known = [:claude, :gpt, :gemini, :deepseek, :llama, :qwen, :mistral, :mixtral]
    candidate = String.to_existing_atom(family_str)
    if candidate in known, do: candidate, else: infer_family(model_id)
  rescue
    ArgumentError -> infer_family(model_id)
  end

  # Default auth method per provider atom. Drawn from llm_db's known
  # provider list. New providers get :api_key as the safe default; the
  # runtime adapter checks the actual credential shape.
  defp auth_for_provider(:bedrock), do: :aws
  defp auth_for_provider(:vertex), do: :gcp
  defp auth_for_provider(:claude_subscription), do: :oauth
  defp auth_for_provider(:lmstudio), do: :none
  defp auth_for_provider(:ollama), do: :none
  defp auth_for_provider(:ollama_cloud), do: :none
  defp auth_for_provider(_), do: :api_key

  defp synthesize_entry(model_id) do
    profile = get(model_id)

    {:ok, entry} =
      Arbor.Contracts.LLM.ModelEntry.new(%{
        canonical_id: model_id,
        family: profile.family,
        context_window: profile.context_size,
        max_output_tokens: profile.max_output_tokens,
        effective_window_pct: profile.effective_window_pct,
        capabilities: [],
        caveats: [
          "Synthesized from legacy ModelProfile — llm_db has no record for #{model_id}"
        ],
        providers: [
          %{
            id: :legacy,
            ref: model_id,
            auth: :api_key,
            runtimes: [:arbor]
          }
        ]
      })

    entry
  end

  @doc """
  Get the context window size for a model (in tokens).

      iex> Arbor.Common.ModelProfile.context_size("claude-sonnet-4-6")
      200_000

      iex> Arbor.Common.ModelProfile.context_size("unknown-model")
      100_000
  """
  @spec context_size(model_id()) :: non_neg_integer()
  def context_size(model_id) when is_binary(model_id) do
    get(model_id).context_size
  end

  @doc """
  Get the effective window percentage for a model.

  This is the percentage of context window at which compaction should trigger.
  Default is 0.75 (75%). Override per model as empirical eval data arrives.

      iex> Arbor.Common.ModelProfile.effective_window_pct("claude-sonnet-4-6")
      0.75
  """
  @spec effective_window_pct(model_id()) :: float()
  def effective_window_pct(model_id) when is_binary(model_id) do
    get(model_id).effective_window_pct
  end

  @doc """
  Get the compaction trigger point for a model (in tokens).

  This is `context_size * effective_window_pct` — the single threshold at which
  compaction should begin.

      iex> Arbor.Common.ModelProfile.effective_window(\"claude-sonnet-4-6\")
      150_000
  """
  @spec effective_window(model_id()) :: non_neg_integer()
  def effective_window(model_id) when is_binary(model_id) do
    profile = get(model_id)
    trunc(profile.context_size * profile.effective_window_pct)
  end

  @doc """
  Get the maximum output tokens for a model.
  """
  @spec max_output_tokens(model_id()) :: non_neg_integer()
  def max_output_tokens(model_id) when is_binary(model_id) do
    get(model_id).max_output_tokens
  end

  @doc """
  Get the model family atom.
  """
  @spec family(model_id()) :: atom()
  def family(model_id) when is_binary(model_id) do
    get(model_id).family
  end

  @doc """
  List all known model profiles.
  """
  @spec known_models() :: [{model_id(), profile()}]
  def known_models do
    @profiles
    |> Enum.map(fn {id, base} ->
      {id,
       %{
         context_size: base[:context_size] || @default_context_size,
         effective_window_pct: base[:effective_window_pct] || @default_effective_window_pct,
         max_output_tokens: base[:max_output_tokens] || @default_max_output,
         family: base[:family] || :unknown
       }}
    end)
    |> Enum.sort_by(fn {_, p} -> -p.context_size end)
  end

  @doc "Default context size for unknown models."
  @spec default_context_size() :: non_neg_integer()
  def default_context_size, do: @default_context_size

  @doc "Default effective window percentage."
  @spec default_effective_window_pct() :: float()
  def default_effective_window_pct, do: @default_effective_window_pct

  # -- Private --

  defp lookup(model_id) do
    # 1. Exact match
    case Map.get(@profiles, model_id) do
      nil -> lookup_stripped(model_id)
      profile -> profile
    end
  end

  defp lookup_stripped(model_id) do
    # 2. Strip provider prefix (e.g., "anthropic:claude-..." → "claude-...")
    stripped =
      case String.split(model_id, ":", parts: 2) do
        [_provider, model] -> model
        _ -> nil
      end

    case stripped && Map.get(@profiles, stripped) do
      nil -> lookup_by_family(model_id)
      profile -> profile
    end
  end

  defp lookup_by_family(model_id) do
    # 3. Pattern match by model family
    downcased = String.downcase(model_id)

    case Enum.find(@family_patterns, fn {pattern, _family} ->
           String.contains?(downcased, pattern)
         end) do
      {_pattern, family} ->
        defaults = Map.get(@family_defaults, family, %{})
        Map.put(defaults, :family, family)

      nil ->
        %{family: :unknown}
    end
  end
end
