defmodule Arbor.Orchestrator.Eval.Subjects.EmbeddingRetrieval do
  @moduledoc """
  Eval subject for tool/capability retrieval via embedding similarity.

  Takes a user prompt, embeds it via an Ollama embedding model, and returns
  the top-K most similar actions from a pre-computed action index.

  ## Input

  A map with a `"prompt"` key:

      %{"prompt" => "Read the contents of config.yaml"}

  ## Options

    * `:provider` — must be "ollama" (only supported provider here)
    * `:model` — embedding model name (e.g. "embeddinggemma", "mxbai-embed-large", "nomic-embed-text")
    * `:index_path` — path to the action_index.json (default: apps/arbor_orchestrator/priv/eval_datasets/preprocessor_tool_retrieval/action_index.json)
    * `:top_k` — number of results to return (default: 5)
    * `:base_url` — Ollama base URL (default: http://localhost:11434)
    * `:timeout` — request timeout in ms (default: 30_000)

  ## Output

      {:ok, %{
        text: "[\"Arbor.Actions.File\", ...]",  # JSON-encoded ranked URI list, for storage
        retrieved: [%{module: "Arbor.Actions.File", score: 0.78}, ...],  # structured
        duration_ms: 42,
        model: "embeddinggemma",
        provider: "ollama"
      }}

  ## Index format

  The action_index.json is built by `scripts/build_action_index.exs`. Shape:

      %{
        "models" => ["embeddinggemma", ...],
        "actions" => [
          %{"module" => "Arbor.Actions.File", "description" => "...", "embeddings" => %{...}},
          ...
        ]
      }
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @default_index_path "apps/arbor_orchestrator/priv/eval_datasets/preprocessor_tool_retrieval/action_index.json"
  @default_base_url "http://localhost:11434"
  @default_timeout 30_000
  @default_top_k 5

  @impl true
  def run(input, opts \\ []) do
    prompt = extract_prompt(input)
    model = Keyword.fetch!(opts, :model)
    index_path = Keyword.get(opts, :index_path, @default_index_path)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case load_index(index_path) do
      {:ok, index} ->
        actions_for_model = filter_by_model(index, model)

        if actions_for_model == [] do
          {:error, "no embeddings for model '#{model}' in index #{index_path}"}
        else
          start = System.monotonic_time(:millisecond)

          with {:ok, query_vec} <- embed_query(base_url, model, prompt, timeout) do
            ranked = rank_actions(actions_for_model, query_vec, top_k)
            duration_ms = System.monotonic_time(:millisecond) - start

            {:ok,
             %{
               text: Jason.encode!(Enum.map(ranked, & &1.module)),
               retrieved: ranked,
               duration_ms: duration_ms,
               model: model,
               provider: "ollama"
             }}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_prompt(%{"prompt" => prompt}) when is_binary(prompt), do: prompt
  defp extract_prompt(prompt) when is_binary(prompt), do: prompt
  defp extract_prompt(input), do: raise("EmbeddingRetrieval expects %{\"prompt\" => binary} or a binary; got: #{inspect(input)}")

  # Load the index once into :persistent_term keyed by absolute path.
  # Subsequent calls are O(1).
  defp load_index(path) do
    key = {__MODULE__, :index, Path.expand(path)}

    case :persistent_term.get(key, :miss) do
      :miss ->
        case File.read(path) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, index} ->
                :persistent_term.put(key, index)
                {:ok, index}

              {:error, err} ->
                {:error, "failed to parse index json: #{inspect(err)}"}
            end

          {:error, err} ->
            {:error, "failed to read index at #{path}: #{inspect(err)}"}
        end

      index ->
        {:ok, index}
    end
  end

  defp filter_by_model(index, model) do
    index["actions"]
    |> Enum.flat_map(fn action ->
      case action["embeddings"][model] do
        nil -> []
        vec when is_list(vec) -> [{action["module"], vec}]
      end
    end)
  end

  defp embed_query(base_url, model, prompt, timeout) do
    url = base_url <> "/api/embeddings"

    case Req.post(url, json: %{model: model, prompt: prompt}, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"embedding" => vec}}} when is_list(vec) ->
        {:ok, vec}

      {:ok, %{status: status, body: body}} ->
        {:error, "ollama embeddings returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp rank_actions(actions, query_vec, top_k) do
    actions
    |> Enum.map(fn {module, action_vec} ->
      %{module: module, score: cosine_similarity(query_vec, action_vec)}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  # Cosine similarity = dot(a, b) / (norm(a) * norm(b))
  defp cosine_similarity(a, b) when length(a) == length(b) do
    {dot, na_sq, nb_sq} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, ax, bx} ->
        {d + x * y, ax + x * x, bx + y * y}
      end)

    denom = :math.sqrt(na_sq) * :math.sqrt(nb_sq)

    if denom == 0.0 do
      0.0
    else
      dot / denom
    end
  end

  defp cosine_similarity(_, _), do: 0.0
end
