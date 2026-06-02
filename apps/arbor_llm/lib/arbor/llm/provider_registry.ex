defmodule Arbor.LLM.ProviderRegistry do
  @moduledoc """
  Single source of truth for which providers Arbor knows about.

  Drives the env-var discovery in `Arbor.LLM.Client`, the model-spec
  translation in `Arbor.LLM.Adapter.ReqLLM`, and the capability catalog
  in `Arbor.LLM.ProviderCatalog`. Where information already lives in
  req_llm or llm_db, we read from there; only Arbor-specific
  information (historical naming aliases, local-LM probe URLs) lives
  here as a small map.

  ## What's hardcoded here vs. discovered

  | Concern | Source |
  |---|---|
  | List of cloud Arbor providers | `@aliases` (small alias map: Arbor's names) |
  | Local-LM providers (lm_studio, ollama) | `@local_providers` (Arbor-only; req_llm has no dedicated providers) |
  | Display name | `@display_names` (presentation, doesn't belong in req_llm) |
  | req_llm atom for a given Arbor provider | `@aliases` (the only real translation Arbor needs) |
  | env_key per cloud provider | req_llm provider module's `default_env_key/0` |
  | base_url per local-LM | `@local_providers` defaults + operator config override |
  | Capabilities per provider | aggregated from `LLMDB.models(provider)` |

  The two static maps are the irreducible Arbor surface — they exist
  because Arbor's external naming has historically been independent
  of req_llm's (`"gemini"` vs `:google`) and because req_llm doesn't
  model local-LM servers (we route them through `openai` + `base_url`).

  ## Capability aggregation

  llm_db carries detailed per-model capability flags. We aggregate up
  to per-provider with "any model supports it" semantics — matching
  what the legacy per-provider adapters' `runtime_contract/0`
  advertised by hand.
  """

  alias Arbor.Contracts.AI.Capabilities

  # Arbor provider name → req_llm provider atom. Only Arbor-side
  # alias for naming, plus the local-LM redirections.
  @aliases %{
    "openai" => :openai,
    "anthropic" => :anthropic,
    "gemini" => :google,
    "xai" => :xai,
    "openrouter" => :openrouter,
    "zai" => :zai,
    "zai_coding_plan" => :zai_coding_plan,
    "lm_studio" => :openai,
    "ollama" => :openai
  }

  # Local-LM defaults — these are Arbor-only providers since req_llm
  # has no dedicated `:lm_studio` or `:ollama`. Operator-overridable
  # via `config :arbor_orchestrator, <config_key>, base_url: "..."`.
  @local_providers %{
    "lm_studio" => %{config_key: :lm_studio, default_base_url: "http://localhost:1234/v1"},
    "ollama" => %{config_key: :ollama, default_base_url: "http://localhost:11434/v1"}
  }

  # Display names are a UI concern (dashboard's runtime panel,
  # `mix arbor.doctor` output) — neither req_llm nor llm_db carries
  # them in the shape we want here.
  @display_names %{
    "openai" => "OpenAI API",
    "anthropic" => "Anthropic API",
    "gemini" => "Google Gemini API",
    "xai" => "x.ai (Grok)",
    "openrouter" => "OpenRouter",
    "zai" => "Z.ai",
    "zai_coding_plan" => "Z.ai Coding Plan",
    "lm_studio" => "LM Studio",
    "ollama" => "Ollama"
  }

  # ── Listing ─────────────────────────────────────────────────────────

  @doc "All Arbor-known provider names, sorted."
  @spec list() :: [String.t()]
  def list, do: @aliases |> Map.keys() |> Enum.sort()

  @doc "Cloud (non-local) Arbor-known provider names, sorted."
  @spec list_cloud() :: [String.t()]
  def list_cloud, do: list() |> Enum.reject(&local?/1)

  @doc "Local-LM Arbor provider names, sorted."
  @spec list_local() :: [String.t()]
  def list_local, do: @local_providers |> Map.keys() |> Enum.sort()

  # ── Identity ────────────────────────────────────────────────────────

  @doc "True if `provider` is a local-LM Arbor provider."
  @spec local?(String.t()) :: boolean()
  def local?(provider), do: Map.has_key?(@local_providers, provider)

  @doc "True if `provider` is in the registry."
  @spec known?(String.t()) :: boolean()
  def known?(provider), do: Map.has_key?(@aliases, provider)

  @doc """
  Returns the req_llm provider atom for an Arbor provider.

  For cloud providers, this is the exact name req_llm uses in its
  registry. For local-LM providers (lm_studio, ollama), it returns
  `:openai` because that's the req_llm provider module that handles
  the OpenAI-compatible chat-completions and embeddings endpoints
  these servers expose.
  """
  @spec req_llm_atom(String.t()) :: atom() | nil
  def req_llm_atom(provider), do: Map.get(@aliases, provider)

  @doc "Human-readable display name for `mix arbor.doctor` etc."
  @spec display_name(String.t()) :: String.t()
  def display_name(provider), do: Map.get(@display_names, provider, provider)

  # ── Auth / Transport ────────────────────────────────────────────────

  @doc """
  The env var name carrying the API key for a cloud provider, or `nil`
  for local-LM and ACP providers (which don't auth via env keys).

  Read from the req_llm provider module's `default_env_key/0`, set in
  `use ReqLLM.Provider`. We never hardcode env-var names in Arbor.
  """
  @spec default_env_key(String.t()) :: String.t() | nil
  def default_env_key(provider) do
    cond do
      local?(provider) -> nil
      not known?(provider) -> nil
      true -> env_key_from_req_llm(req_llm_atom(provider))
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
  The base URL Arbor uses for a local-LM provider, honouring
  operator config overrides. Returns `nil` for cloud providers
  (req_llm's transport uses its own default).
  """
  @spec default_base_url(String.t()) :: String.t() | nil
  def default_base_url(provider) do
    case Map.fetch(@local_providers, provider) do
      {:ok, %{config_key: config_key, default_base_url: default}} ->
        config = Application.get_env(:arbor_orchestrator, config_key, [])
        Keyword.get(config, :base_url, default)

      :error ->
        nil
    end
  end

  # ── Availability ────────────────────────────────────────────────────

  @doc """
  True if a cloud provider's API key env var is set, or false for
  local-LM providers (whose availability is determined by an HTTP
  probe, not this function).
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
  @spec capabilities(String.t()) :: Capabilities.t()
  def capabilities(provider) do
    cond do
      provider == "ollama" ->
        Capabilities.new(streaming: true, tool_calls: true, embeddings: true)

      provider == "lm_studio" ->
        Capabilities.new(streaming: true, tool_calls: true, structured_output: true)

      true ->
        provider
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

  # Models with reasoning enabled support extended thinking semantics
  # (think-as-output). llm_db may omit token_budget for providers that
  # don't expose the knob; presence-of-reasoning is the right signal.
  defp extended_thinking?(%{reasoning: %{enabled: true}}), do: true
  defp extended_thinking?(_), do: false

  # llm_db models carry modalities at the top level, not inside caps.
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
