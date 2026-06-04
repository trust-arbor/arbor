defmodule Arbor.Common.ModelProfile do
  @moduledoc """
  Centralized model metadata registry.

  Provides model context sizes, effective window percentages, and output limits
  at Level 0.5 (arbor_common), so both `arbor_agent` and `arbor_memory` can
  access them without runtime bridges.

  ## Model ID Formats

  Supports multiple model ID formats:

  - OpenRouter: `"arcee-ai/trinity-large-preview:free"`, `"anthropic/claude-sonnet-4"`
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

      ModelProfile.effective_window_pct("arcee-ai/trinity-large-preview:free")
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
    # trinity-large-preview retired April 22 2026 — successors below.
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
    "moonshotai/kimi-k2.5" => %{context_size: 128_000, max_output_tokens: 8_192, family: :kimi},

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

  # -- ModelEntry registry (Phase 1) --
  # Exemplar entries migrated to the full `Arbor.Contracts.LLM.ModelEntry`
  # shape. Unmigrated models still resolve through the legacy short-form
  # `@profiles` map below — `entry/1` synthesizes a `%ModelEntry{}` from
  # the short shape so callers can use the new API uniformly during the
  # migration window. One exemplar per family covers the variation.

  defp model_entries do
    %{
      "claude-opus-4-6" => %{
        canonical_id: "claude-opus-4-6",
        family: :claude,
        context_window: 200_000,
        max_output_tokens: 32_000,
        effective_window_pct: 0.75,
        capabilities: [
          :tool_use,
          :vision,
          :prompt_cache,
          :extended_thinking,
          :json_mode,
          :streaming,
          :reasoning_content
        ],
        caveats: [],
        providers: [
          %{
            id: :anthropic_direct,
            ref: "claude-opus-4-6",
            auth: :api_key,
            runtimes: [:arbor],
            pricing: %{
              input_per_mtok: 15.00,
              output_per_mtok: 75.00,
              cache_read_per_mtok: 1.50,
              cache_write_per_mtok: 18.75
            }
          },
          %{
            id: :openrouter,
            ref: "anthropic/claude-opus-4-6",
            auth: :api_key,
            runtimes: [:arbor]
          },
          %{
            id: :claude_subscription,
            ref: "opus",
            auth: :oauth,
            runtimes: [:arbor, :acp]
          }
        ]
      },
      "claude-sonnet-4-6" => %{
        canonical_id: "claude-sonnet-4-6",
        family: :claude,
        context_window: 200_000,
        max_output_tokens: 64_000,
        effective_window_pct: 0.75,
        capabilities: [
          :tool_use,
          :vision,
          :prompt_cache,
          :extended_thinking,
          :json_mode,
          :streaming,
          :reasoning_content
        ],
        caveats: [],
        providers: [
          %{
            id: :anthropic_direct,
            ref: "claude-sonnet-4-6",
            auth: :api_key,
            runtimes: [:arbor],
            pricing: %{
              input_per_mtok: 3.00,
              output_per_mtok: 15.00,
              cache_read_per_mtok: 0.30,
              cache_write_per_mtok: 3.75
            }
          },
          %{
            id: :openrouter,
            ref: "anthropic/claude-sonnet-4-6",
            auth: :api_key,
            runtimes: [:arbor]
          },
          %{
            id: :claude_subscription,
            ref: "sonnet",
            auth: :oauth,
            runtimes: [:arbor, :acp]
          }
        ]
      },
      "gpt-5-nano" => %{
        canonical_id: "gpt-5-nano",
        family: :gpt,
        context_window: 128_000,
        max_output_tokens: 16_384,
        effective_window_pct: 0.75,
        capabilities: [:tool_use, :vision, :json_mode, :streaming],
        caveats: [],
        providers: [
          %{
            id: :openai,
            ref: "gpt-5-nano",
            auth: :api_key,
            runtimes: [:arbor]
          },
          %{
            id: :openrouter,
            ref: "openai/gpt-5-nano",
            auth: :api_key,
            runtimes: [:arbor]
          }
        ]
      },
      "gemini-2.0-flash" => %{
        canonical_id: "gemini-2.0-flash",
        family: :gemini,
        context_window: 1_000_000,
        max_output_tokens: 8_192,
        effective_window_pct: 0.75,
        capabilities: [:tool_use, :vision, :json_mode, :streaming],
        caveats: [],
        providers: [
          %{
            id: :gemini,
            ref: "gemini-2.0-flash",
            auth: :api_key,
            runtimes: [:arbor]
          },
          %{
            id: :vertex,
            ref: "gemini-2.0-flash-001",
            auth: :gcp,
            runtimes: [:arbor]
          },
          %{
            id: :openrouter,
            ref: "google/gemini-2.0-flash-exp",
            auth: :api_key,
            runtimes: [:arbor]
          }
        ]
      },
      "openai/gpt-oss-120b:free" => %{
        canonical_id: "openai/gpt-oss-120b:free",
        family: :openrouter_free,
        context_window: 131_072,
        max_output_tokens: 8_192,
        effective_window_pct: 0.75,
        capabilities: [:tool_use, :json_mode, :streaming],
        caveats: ["OpenRouter free tier — rate limits and provider availability vary"],
        providers: [
          %{
            id: :openrouter,
            ref: "openai/gpt-oss-120b:free",
            auth: :api_key,
            runtimes: [:arbor]
          }
        ]
      }
    }
  end

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
  Return the full `%Arbor.Contracts.LLM.ModelEntry{}` for `model_id`.

  Phase 1 (item 9): for the five migrated exemplars, returns the registered
  entry with full provider list, capabilities, and caveats. For everything
  else, synthesizes a single-provider entry from the legacy short-form
  profile so callers can use the new API uniformly during migration.

  Synthesized entries have a synthetic `:legacy` provider with
  `auth: :api_key, runtimes: [:arbor]` and no pricing — that's the best
  guess from the legacy short shape. Migrate the entry to the full
  `ModelEntry` shape above to get accurate provider+pricing info.
  """
  @spec entry(model_id()) :: Arbor.Contracts.LLM.ModelEntry.t()
  def entry(model_id) when is_binary(model_id) do
    case lookup_entry(model_id) do
      {:ok, %Arbor.Contracts.LLM.ModelEntry{} = e} ->
        e

      :not_migrated ->
        synthesize_entry(model_id)
    end
  end

  defp lookup_entry(model_id) do
    case Map.get(model_entries(), model_id) do
      nil ->
        case String.split(model_id, ":", parts: 2) do
          [_provider, stripped] ->
            case Map.get(model_entries(), stripped) do
              nil -> :not_migrated
              attrs -> build_entry(attrs)
            end

          _ ->
            :not_migrated
        end

      attrs ->
        build_entry(attrs)
    end
  end

  defp build_entry(attrs) do
    case Arbor.Contracts.LLM.ModelEntry.new(attrs) do
      {:ok, e} -> {:ok, e}
      # If a migrated entry fails validation it's a code bug — surface it
      # via the synthesized fallback rather than crashing the caller, but
      # the test suite will catch a malformed registered entry.
      {:error, _} -> :not_migrated
    end
  end

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
          "Synthesized from legacy ModelProfile — migrate to full ModelEntry for accurate provider/pricing info"
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
