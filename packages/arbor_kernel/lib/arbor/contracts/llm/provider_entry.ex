defmodule Arbor.Contracts.LLM.ProviderEntry do
  @moduledoc """
  One path by which a logical model can be reached.

  A `ProviderEntry` says: "model X is available via provider P at reference R,
  using auth method A, runnable via runtimes [...]." A single `ModelEntry`
  carries one or more of these — Claude Opus, for example, has six legal
  `(provider, runtime)` paths today (Anthropic direct, Bedrock, Vertex,
  OpenRouter, claude_subscription/arbor, claude_subscription/acp).

  ## Fields

  - `:id` — provider identifier atom. Conventional names: `:anthropic_direct`,
    `:openai`, `:bedrock`, `:vertex`, `:openrouter`, `:claude_subscription`,
    `:lm_studio`, `:ollama`, etc. Provider runtime config is keyed by this.
  - `:ref` — the model name as the provider expects it on the wire. May
    differ from the canonical id (e.g. Bedrock uses
    `"anthropic.claude-opus-4-8-v1:0"`, OpenRouter uses
    `"anthropic/claude-opus-4-8"`, Anthropic direct uses `"claude-opus-4-8"`).
  - `:auth` — how to authenticate. One of `:api_key | :oauth | :aws | :gcp |
    :none`. `:none` is for local servers (Ollama, LM Studio) and dev mocks.
  - `:runtimes` — list of runtime atoms that can drive turns for this
    `(model, provider)` pair. `:arbor` is the in-BEAM HTTP path through
    `arbor_llm`; `:acp` is the subprocess-via-CLI path. Most providers
    support only `[:arbor]`; subscription/CLI providers may also support
    `[:acp]`.
  - `:pricing` — optional pricing map. Keys: `:input_per_mtok`,
    `:output_per_mtok`, `:cache_read_per_mtok`, `:cache_write_per_mtok`.
    All values are USD per million tokens. Omitted for free providers and
    unknown-cost local servers.
  """

  use TypedStruct

  @typedoc "Authentication method the provider expects."
  @type auth :: :api_key | :oauth | :aws | :gcp | :none

  @typedoc "Pricing in USD per million tokens. All fields optional."
  @type pricing :: %{
          optional(:input_per_mtok) => float(),
          optional(:output_per_mtok) => float(),
          optional(:cache_read_per_mtok) => float(),
          optional(:cache_write_per_mtok) => float()
        }

  typedstruct enforce: true do
    @typedoc "One reachable path to a logical model."

    field(:id, atom())
    field(:ref, String.t())
    field(:auth, auth())
    field(:runtimes, [atom()])
    field(:pricing, pricing() | nil, enforce: false)
  end

  @doc """
  Construct a new `%ProviderEntry{}`. Validates required fields, defaults
  optional ones, and rejects unknown auth values.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Enum.into(attrs, %{}))

  def new(%{} = attrs) do
    with {:ok, id} <- fetch_atom(attrs, :id),
         {:ok, ref} <- fetch_string(attrs, :ref),
         {:ok, auth} <- fetch_auth(attrs),
         {:ok, runtimes} <- fetch_runtimes(attrs) do
      pricing = Map.get(attrs, :pricing) || Map.get(attrs, "pricing")

      {:ok,
       %__MODULE__{
         id: id,
         ref: ref,
         auth: auth,
         runtimes: runtimes,
         pricing: pricing
       }}
    end
  end

  defp fetch_atom(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      v when is_atom(v) and not is_nil(v) -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_auth(attrs) do
    case Map.get(attrs, :auth) || Map.get(attrs, "auth") do
      a when a in [:api_key, :oauth, :aws, :gcp, :none] -> {:ok, a}
      other -> {:error, {:invalid_auth, other}}
    end
  end

  defp fetch_runtimes(attrs) do
    case Map.get(attrs, :runtimes) || Map.get(attrs, "runtimes") do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &is_atom/1),
          do: {:ok, list},
          else: {:error, {:invalid_runtimes, list}}

      _ ->
        {:error, :runtimes_required}
    end
  end
end
