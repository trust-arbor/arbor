defmodule Arbor.AI.Backends.OpenAIEmbedding do
  @moduledoc """
  OpenAI-compatible embedding provider.

  Supports both OpenAI and LMStudio (same API format). The provider is
  determined by the `:provider` option:

  - `:openai` — `api.openai.com/v1/embeddings` + Bearer token from `OPENAI_API_KEY`
  - `:lmstudio` — `localhost:1234/v1/embeddings` + no auth

  ## Configuration

      config :arbor_ai, :openai,
        base_url: "https://api.openai.com"   # default for :openai
        api_key_env: "OPENAI_API_KEY"         # env var for API key

      config :arbor_ai, :lmstudio,
        base_url: "http://localhost:1234"     # default for :lmstudio
  """

  @behaviour Arbor.Contracts.API.Embedding

  require Logger

  @default_openai_url "https://api.openai.com"
  @default_lmstudio_url "http://localhost:1234"
  @default_openai_model "text-embedding-3-small"
  @default_lmstudio_model "text-embedding"
  @default_timeout 30_000

  @impl true
  @spec embed(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.result()} | {:error, term()}
  def embed(text, opts \\ []) do
    case do_embed([text], opts) do
      {:ok, %{embeddings: [embedding | _]} = result} ->
        {:ok,
         %{
           embedding: embedding,
           model: result.model,
           provider: result.provider,
           usage: result.usage,
           dimensions: length(embedding)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.batch_result()} | {:error, term()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    do_embed(texts, opts)
  end

  # ── Private ──

  defp do_embed(texts, opts) do
    provider = Keyword.get(opts, :provider, :openai)
    {base_url, default_model, auth_header} = provider_config(provider)

    model = Keyword.get(opts, :model, default_model)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    url = "#{base_url}/v1/embeddings"

    body =
      %{model: model, input: texts}
      |> maybe_add_dimensions(opts)
      |> Jason.encode!()

    headers =
      [{"content-type", "application/json"}]
      |> maybe_add_auth(auth_header)

    Logger.debug(
      "OpenAI embed request: provider=#{provider}, model=#{model}, texts=#{length(texts)}"
    )

    case Req.post(url,
           body: body,
           headers: headers,
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_openai_response(body, model, provider)

      {:ok, %{status: status, body: body}} ->
        error_msg = extract_error(body)

        Logger.warning(
          "OpenAI embed failed: provider=#{provider}, status=#{status}, error=#{error_msg}"
        )

        {:error, {:openai_error, status, error_msg}}

      {:error, reason} ->
        Logger.warning(
          "OpenAI embed request failed: provider=#{provider}, error=#{inspect(reason)}"
        )

        {:error, {:connection_error, reason}}
    end
  end

  defp provider_config(:openai) do
    base_url = get_provider_url(:openai, @default_openai_url)
    api_key_env = get_api_key_env(:openai, "OPENAI_API_KEY")
    api_key = System.get_env(api_key_env)
    auth = if api_key, do: "Bearer #{api_key}", else: nil
    {base_url, @default_openai_model, auth}
  end

  defp provider_config(:lmstudio) do
    base_url = get_provider_url(:lmstudio, @default_lmstudio_url)
    {base_url, @default_lmstudio_model, nil}
  end

  defp provider_config(other) do
    # Treat unknown providers as OpenAI-compatible
    provider_config(:openai)
    |> then(fn {_url, model, auth} ->
      base_url = get_provider_url(other, @default_openai_url)
      {base_url, model, auth}
    end)
  end

  defp get_provider_url(provider, default) do
    case Application.get_env(:arbor_ai, provider) do
      nil -> default
      config -> Keyword.get(config, :base_url, default)
    end
  end

  defp get_api_key_env(provider, default) do
    case Application.get_env(:arbor_ai, provider) do
      nil -> default
      config -> Keyword.get(config, :api_key_env, default)
    end
  end

  defp maybe_add_dimensions(body, opts) do
    case Keyword.get(opts, :dimensions) do
      nil -> body
      dim -> Map.put(body, :dimensions, dim)
    end
  end

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, auth), do: [{"authorization", auth} | headers]

  defp parse_openai_response(
         %{"data" => data, "usage" => usage, "model" => model_name},
         _model,
         provider
       )
       when is_list(data) do
    # Sort by index to maintain order
    sorted = Enum.sort_by(data, & &1["index"])
    embeddings = Enum.map(sorted, & &1["embedding"])

    dimensions =
      case embeddings do
        [first | _] when is_list(first) -> length(first)
        _ -> 0
      end

    {:ok,
     %{
       embeddings: embeddings,
       model: model_name,
       provider: provider,
       usage: %{
         prompt_tokens: Map.get(usage, "prompt_tokens", 0),
         total_tokens: Map.get(usage, "total_tokens", 0)
       },
       dimensions: dimensions
     }}
  end

  # Some providers omit usage
  defp parse_openai_response(%{"data" => data, "model" => model_name}, _model, provider)
       when is_list(data) do
    sorted = Enum.sort_by(data, & &1["index"])
    embeddings = Enum.map(sorted, & &1["embedding"])

    dimensions =
      case embeddings do
        [first | _] when is_list(first) -> length(first)
        _ -> 0
      end

    {:ok,
     %{
       embeddings: embeddings,
       model: model_name,
       provider: provider,
       usage: %{prompt_tokens: 0, total_tokens: 0},
       dimensions: dimensions
     }}
  end

  defp parse_openai_response(body, _model, _provider) do
    {:error, {:unexpected_response, body}}
  end

  defp extract_error(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body) when is_binary(body), do: body
  defp extract_error(body), do: inspect(body)
end
