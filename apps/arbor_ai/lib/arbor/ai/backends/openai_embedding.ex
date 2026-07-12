defmodule Arbor.AI.Backends.OpenAIEmbedding do
  @moduledoc """
  Compatibility facade for OpenAI-compatible embeddings.

  Transport, endpoint authorization, response budgets, deadlines, and input
  association validation are owned by `Arbor.LLM.embed_batch/4`.
  """

  @behaviour Arbor.Contracts.API.Embedding

  @default_openai_url "https://api.openai.com/v1"
  @default_lmstudio_url "http://localhost:1234/v1"
  @default_openai_model "text-embedding-3-small"
  @default_lmstudio_model "text-embedding"

  @impl true
  @spec embed(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.result()} | {:error, term()}
  def embed(text, opts \\ []) do
    with {:ok, result} <- embed_batch([text], opts),
         [embedding] <- result.embeddings do
      {:ok,
       %{
         embedding: embedding,
         model: result.model,
         provider: result.provider,
         usage: result.usage,
         dimensions: result.dimensions
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_single_embedding_result}
    end
  end

  @impl true
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.batch_result()} | {:error, term()}
  def embed_batch(texts, opts \\ [])

  def embed_batch(texts, opts) when is_list(texts) and is_list(opts) do
    provider = Keyword.get(opts, :provider, :openai)
    {canonical, default_model, default_url} = provider_config(provider)
    model = Keyword.get(opts, :model, default_model)

    transport_opts =
      opts
      |> Keyword.delete(:provider)
      |> Keyword.put(:base_url, normalized_base_url(Keyword.get(opts, :base_url, default_url)))
      |> maybe_put_api_key(provider)

    case Arbor.LLM.embed_batch(canonical, model, texts, transport_opts) do
      {:ok, result} ->
        {:ok, Map.put(result, :provider, provider)}

      {:error, reason} ->
        {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  rescue
    exception -> {:error, {:embedding_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:embedding_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  def embed_batch(_texts, _opts), do: {:error, :invalid_embedding_request}

  defp provider_config(:lmstudio),
    do: {"lm_studio", @default_lmstudio_model, configured_url(:lmstudio, @default_lmstudio_url)}

  defp provider_config(:lm_studio),
    do: {"lm_studio", @default_lmstudio_model, configured_url(:lmstudio, @default_lmstudio_url)}

  defp provider_config("lmstudio"), do: provider_config(:lmstudio)
  defp provider_config("lm_studio"), do: provider_config(:lmstudio)

  defp provider_config(provider) do
    canonical = Arbor.LLM.ProviderRegistry.normalize(provider)
    {canonical, @default_openai_model, configured_url(:openai, @default_openai_url)}
  end

  defp configured_url(key, default) do
    case Application.get_env(:arbor_ai, key) do
      config when is_list(config) -> Keyword.get(config, :base_url, default)
      _other -> default
    end
  end

  defp normalized_base_url(value) when is_binary(value) do
    value = String.trim_trailing(value, "/")
    if String.ends_with?(value, "/v1"), do: value, else: value <> "/v1"
  end

  defp normalized_base_url(value), do: value

  defp maybe_put_api_key(opts, provider) do
    config_key =
      if provider in [:lmstudio, :lm_studio, "lmstudio", "lm_studio"],
        do: :lmstudio,
        else: :openai

    case Application.get_env(:arbor_ai, config_key) do
      config when is_list(config) ->
        env = Keyword.get(config, :api_key_env)

        case is_binary(env) && System.get_env(env) do
          key when is_binary(key) and key != "" -> Keyword.put_new(opts, :api_key, key)
          _missing -> opts
        end

      _other ->
        opts
    end
  end
end
