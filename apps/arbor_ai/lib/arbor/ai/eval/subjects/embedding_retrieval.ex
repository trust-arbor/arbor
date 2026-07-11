defmodule Arbor.AI.Eval.Subjects.EmbeddingRetrieval do
  @moduledoc """
  Evaluation subject that ranks an explicit action index by embedding similarity.

  The caller must provide `:index_path`; the owning AI library deliberately has
  no knowledge of an Orchestrator dataset location.

  ## Options

    * `:index_path` - required path to an action-index JSON file
    * `:model` - required embedding model name
    * `:top_k` - number of ranked actions to return (default: 5, maximum: 100)
    * `:base_url` - Ollama base URL (default: `http://localhost:11434`)
    * `:timeout` - request timeout in milliseconds (default: 30 seconds, maximum: 5 minutes)
    * `:embed_fn` - injectable `(base_url, model, prompt, timeout -> result)` callback
  """

  @behaviour Arbor.Eval.Subject

  alias Arbor.AI.Eval.RetrievalSupport

  @default_base_url "http://localhost:11434"
  @default_timeout 30_000
  @default_top_k 5

  @impl true
  def run(input, opts \\ []) do
    with :ok <- RetrievalSupport.validate_opts(opts),
         {:ok, index_path} <- RetrievalSupport.required_string(opts, :index_path),
         {:ok, prompt} <- RetrievalSupport.extract_prompt(input),
         {:ok, model} <- RetrievalSupport.required_string(opts, :model),
         {:ok, top_k} <-
           RetrievalSupport.positive_integer_option(opts, :top_k, @default_top_k),
         {:ok, base_url} <-
           RetrievalSupport.string_option(opts, :base_url, @default_base_url),
         {:ok, timeout} <-
           RetrievalSupport.positive_integer_option(opts, :timeout, @default_timeout),
         {:ok, embed_fn} <-
           RetrievalSupport.callback_option(opts, :embed_fn, 4, &default_embed/4),
         {:ok, actions} <- RetrievalSupport.load_index(index_path),
         {:ok, indexed_actions} <-
           RetrievalSupport.embeddings_for_model(actions, model, index_path) do
      retrieve(indexed_actions, prompt, model, top_k, base_url, timeout, embed_fn)
    end
  end

  defp retrieve(indexed_actions, prompt, model, top_k, base_url, timeout, embed_fn) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, query_vector} <- embed(embed_fn, base_url, model, prompt, timeout),
         :ok <- RetrievalSupport.validate_query_dimensions(indexed_actions, query_vector) do
      ranked = RetrievalSupport.rank(indexed_actions, query_vector, top_k)

      {:ok,
       %{
         text: Jason.encode!(Enum.map(ranked, & &1.module)),
         retrieved: ranked,
         duration_ms: System.monotonic_time(:millisecond) - started_at,
         model: model,
         provider: "ollama"
       }}
    end
  end

  defp embed(embed_fn, base_url, model, prompt, timeout) do
    case RetrievalSupport.invoke(
           embed_fn,
           [base_url, model, prompt, timeout],
           :embedding_callback_failed
         ) do
      {:ok, vector} -> RetrievalSupport.validate_vector(vector)
      {:error, _reason} = error -> error
      _response -> {:error, {:invalid_embedding_response, :ok_tuple_required}}
    end
  end

  defp default_embed(base_url, model, prompt, timeout) do
    case Req.post(base_url <> "/api/embeddings",
           json: %{model: model, prompt: prompt},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"embedding" => vector}}} when is_list(vector) ->
        {:ok, vector}

      {:ok, %{status: status, body: body}} ->
        RetrievalSupport.http_error(:embedding_http_error, status, body)

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end
end
