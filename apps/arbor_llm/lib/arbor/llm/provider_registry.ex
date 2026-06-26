defmodule Arbor.LLM.ProviderRegistry do
  @moduledoc """
  Single source of truth for which providers Arbor knows about.

  Cloud providers come from `ReqLLM.Providers.list/0`. Local-LM
  providers (`lm_studio`, `ollama`) are Arbor-only concepts since
  req_llm has no dedicated modules for them — they route through
  `:openai` with a `base_url` override (req_llm's openai
  chat-completions/embeddings are OpenAI-spec compliant, which is what
  these local servers serve).

  ## What's hardcoded here vs. discovered

  | Concern | Source |
  |---|---|
  | List of cloud providers | `ReqLLM.Providers.list/0` |
  | req_llm atom for a cloud provider | the provider string IS the atom name |
  | env_key per cloud provider | provider module's `default_env_key/0` |
  | Local-LM list | `@local_providers` (Arbor-only) |
  | Local-LM base_url | `@local_providers` defaults + operator config override |
  | Local-LM routing target | `@local_providers` (all → `:openai`) |
  | Display name | `@display_overrides` for special-cased names, otherwise computed |
  | Capabilities per provider | aggregated from `LLMDB.models(provider)` |

  ## Naming convention

  Arbor uses req_llm's provider names directly — `"google"` rather
  than the historical `"gemini"`, etc. The 9-entry alias map that
  Session 6.5 introduced was dropped in Session 6.6 after the user
  observed that maintaining duplicate naming creates inevitable drift.
  Callers that historically used `"gemini"` should switch to
  `"google"`; the migration touched ~10 files across arbor_ai,
  arbor_orchestrator, arbor_common, and arbor_agent.

  ## Capability aggregation

  llm_db carries detailed per-model capability flags. We aggregate up
  to per-provider with "any model supports it" semantics — matching
  what the legacy per-provider adapters' `runtime_contract/0`
  advertised by hand.
  """

  alias Arbor.Contracts.AI.Capabilities

  # Local-LM Arbor providers. req_llm has no dedicated modules; we
  # route through `:openai` with a base_url override.
  # Operator-overridable via
  # `config :arbor_orchestrator, <config_key>, base_url: "..."`.
  @local_providers %{
    "lm_studio" => %{config_key: :lm_studio, default_base_url: "http://localhost:1234/v1"},
    "ollama" => %{config_key: :ollama, default_base_url: "http://localhost:11434/v1"}
  }

  # Provider-name aliases. The same physical provider has historically
  # been spelled different ways across Arbor's layers — arbor_ai uses
  # the atom `:lmstudio` (no underscore), arbor_orchestrator's
  # preprocessor uses `:lm_studio` (underscore), `mix arbor.agent`
  # accepts either string. To keep that a non-footgun, every spelling
  # is folded onto the one canonical Arbor provider string here. Add a
  # new alias here rather than special-casing it at a call site.
  #
  # Keys are the alias spellings (as strings); the value is the
  # canonical provider string in `@local_providers` / `list/0`.
  @aliases %{
    "lmstudio" => "lm_studio",
    "lm-studio" => "lm_studio"
  }

  # Display name overrides for providers where titlecasing the atom
  # doesn't read well. Anything not listed gets a sensible default
  # via `compute_display_name/1`.
  @display_overrides %{
    "openai" => "OpenAI",
    "xai" => "x.ai (Grok)",
    "openrouter" => "OpenRouter",
    "lm_studio" => "LM Studio",
    "google" => "Google Gemini",
    "google_vertex" => "Google Vertex AI",
    "amazon_bedrock" => "Amazon Bedrock",
    "zai" => "Z.ai",
    "zai_coding_plan" => "Z.ai Coding Plan",
    "zai_coder" => "Z.ai Coder"
  }

  # ── Listing ─────────────────────────────────────────────────────────

  @doc "All Arbor-known provider names, sorted."
  @spec list() :: [String.t()]
  def list, do: (list_cloud() ++ list_local()) |> Enum.sort()

  @doc """
  Cloud (non-local) provider names, sorted.

  Read from `ReqLLM.Providers.list/0` so any provider req_llm
  supports — anthropic, openai, google, amazon_bedrock, azure,
  cerebras, groq, meta, vllm, openrouter, xai, zai, zai_coding_plan,
  zenmux, etc. — is auto-discovered without us maintaining a separate
  list. Result is provider strings (Atom.to_string of each atom).
  """
  @spec list_cloud() :: [String.t()]
  def list_cloud do
    ReqLLM.Providers.list()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  @doc "Local-LM Arbor provider names, sorted."
  @spec list_local() :: [String.t()]
  def list_local, do: @local_providers |> Map.keys() |> Enum.sort()

  # ── Identity ────────────────────────────────────────────────────────

  @doc """
  Fold any accepted spelling of a provider onto its canonical Arbor
  provider string.

  Accepts an atom or a string in any of the historical spellings — for
  LM Studio that's `:lmstudio | "lmstudio" | :lm_studio | "lm_studio"`,
  all of which resolve to `"lm_studio"`. Cloud providers and unknown
  names pass through as their string form unchanged.

  This is the single seam that closes the cross-layer provider-name
  footgun: every other identity function in this module funnels through
  it, so the registry treats all spellings of one provider as the same
  provider.
  """
  @spec normalize(atom() | String.t()) :: String.t()
  def normalize(provider) when is_atom(provider), do: normalize(Atom.to_string(provider))

  def normalize(provider) when is_binary(provider),
    do: Map.get(@aliases, provider, provider)

  @doc "True if `provider` (any spelling) is a local-LM Arbor provider."
  @spec local?(atom() | String.t()) :: boolean()
  def local?(provider), do: Map.has_key?(@local_providers, normalize(provider))

  @doc "True if `provider` (any spelling) is in the registry (cloud or local)."
  @spec known?(atom() | String.t()) :: boolean()
  def known?(provider) do
    canonical = normalize(provider)
    canonical in list_cloud() or Map.has_key?(@local_providers, canonical)
  end

  @doc """
  Returns the req_llm provider atom for an Arbor provider.

  For cloud providers, the Arbor name IS the req_llm name — we just
  do `String.to_existing_atom/1` (req_llm pre-registers its provider
  atoms, so the atom always exists). For local-LM providers
  (lm_studio, ollama), returns `:openai` because that's the req_llm
  provider module that handles the OpenAI-compatible endpoints these
  servers expose.

  Returns `nil` for unknown providers.
  """
  @spec req_llm_atom(atom() | String.t()) :: atom() | nil
  def req_llm_atom(provider) when is_atom(provider) or is_binary(provider) do
    canonical = normalize(provider)

    cond do
      Map.has_key?(@local_providers, canonical) -> :openai
      canonical in list_cloud() -> String.to_existing_atom(canonical)
      true -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Human-readable display name for `mix arbor.doctor` etc."
  @spec display_name(atom() | String.t()) :: String.t()
  def display_name(provider) when is_atom(provider) or is_binary(provider) do
    canonical = normalize(provider)
    Map.get_lazy(@display_overrides, canonical, fn -> compute_display_name(canonical) end)
  end

  defp compute_display_name(provider) do
    provider
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # ── Auth / Transport ────────────────────────────────────────────────

  @doc """
  The env var name carrying the API key for a cloud provider, or `nil`
  for local-LM providers (no auth) and unknown providers.

  Read from the req_llm provider module's `default_env_key/0`, set in
  `use ReqLLM.Provider`. Arbor doesn't hardcode env-var names.
  """
  @spec default_env_key(atom() | String.t()) :: String.t() | nil
  def default_env_key(provider) do
    canonical = normalize(provider)

    cond do
      Map.has_key?(@local_providers, canonical) -> nil
      not known?(canonical) -> nil
      true -> env_key_from_req_llm(req_llm_atom(canonical))
    end
  end

  defp env_key_from_req_llm(nil), do: nil

  defp env_key_from_req_llm(atom) do
    case ReqLLM.provider(atom) do
      {:ok, mod} ->
        if function_exported?(mod, :default_env_key, 0) do
          apply(mod, :default_env_key, [])
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The base URL Arbor uses for a local-LM provider, honouring operator
  config overrides. Returns `nil` for cloud providers (req_llm's
  transport uses its own default).
  """
  @spec default_base_url(atom() | String.t()) :: String.t() | nil
  def default_base_url(provider) do
    case Map.fetch(@local_providers, normalize(provider)) do
      {:ok, %{config_key: config_key, default_base_url: default}} ->
        config = Application.get_env(:arbor_orchestrator, config_key, [])
        Keyword.get(config, :base_url, default)

      :error ->
        nil
    end
  end

  # ── Availability ────────────────────────────────────────────────────

  @doc """
  True if a cloud provider's API key env var is set, false otherwise.
  Local-LM providers always return false here (their availability is
  determined by an HTTP probe, not env-var presence).
  """
  @spec env_available?(String.t()) :: boolean()
  def env_available?(provider) do
    case default_env_key(provider) do
      nil -> false
      key -> not blank?(System.get_env(key))
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ── Capabilities ────────────────────────────────────────────────────

  @doc """
  Aggregated capabilities for a provider — the union of per-model
  flags from `LLMDB.models(req_llm_atom)`. Returns Arbor's
  `Capabilities` struct with the flags the legacy per-provider
  adapters used to advertise by hand.

  For local-LM providers we can't know which models the operator
  pulled, so we advertise the union the OpenAI-spec
  `/v1/chat/completions` and `/v1/embeddings` endpoints support
  (streaming, tool calls, embeddings).
  """
  @spec capabilities(atom() | String.t()) :: Capabilities.t()
  def capabilities(provider) do
    canonical = normalize(provider)

    cond do
      canonical == "ollama" ->
        Capabilities.new(streaming: true, tool_calls: true, embeddings: true)

      canonical == "lm_studio" ->
        Capabilities.new(streaming: true, tool_calls: true, structured_output: true)

      true ->
        canonical
        |> req_llm_atom()
        |> case do
          nil ->
            Capabilities.new()

          atom ->
            atom
            |> models_for()
            |> aggregate_capabilities()
        end
    end
  end

  defp models_for(atom) do
    LLMDB.models(atom)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp aggregate_capabilities([]), do: Capabilities.new()

  defp aggregate_capabilities(models) do
    Enum.reduce(models, Capabilities.new(), fn model, acc ->
      caps = model.capabilities || %{}

      %Capabilities{
        streaming: acc.streaming or streaming?(caps),
        tool_calls: acc.tool_calls or tool_calls?(caps),
        thinking: acc.thinking or thinking?(caps),
        extended_thinking: acc.extended_thinking or extended_thinking?(caps),
        vision: acc.vision or vision?(model),
        structured_output: acc.structured_output or structured_output?(caps),
        embeddings: acc.embeddings or embeddings?(caps),
        multi_turn: acc.multi_turn
      }
    end)
  end

  # llm_db's streaming schema defaults `text` to true; data often omits
  # the field explicitly, so we treat anything other than explicit
  # `text: false` as supported.
  defp streaming?(%{streaming: %{text: false}}), do: false
  defp streaming?(%{streaming: streaming}) when is_map(streaming), do: true
  defp streaming?(_), do: false

  defp tool_calls?(%{tools: %{enabled: true}}), do: true
  defp tool_calls?(_), do: false

  defp thinking?(%{reasoning: %{enabled: true}}), do: true
  defp thinking?(_), do: false

  defp extended_thinking?(%{reasoning: %{enabled: true}}), do: true
  defp extended_thinking?(_), do: false

  defp vision?(%LLMDB.Model{modalities: %{input: input}}) when is_list(input),
    do: :image in input

  defp vision?(_), do: false

  defp structured_output?(%{json: %{native: true}}), do: true
  defp structured_output?(%{json: %{schema: true}}), do: true
  defp structured_output?(_), do: false

  defp embeddings?(%{embeddings: false}), do: false
  defp embeddings?(%{embeddings: nil}), do: false
  defp embeddings?(%{embeddings: _}), do: true
  defp embeddings?(_), do: false
end
