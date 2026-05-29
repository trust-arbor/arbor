defmodule Arbor.Orchestrator.Eval.Subjects.HybridRetrieval do
  @moduledoc """
  Eval subject for tool/capability retrieval via hybrid embedding + LLM rerank.

  Two-stage pipeline:

    1. **Recall stage** — embedding model picks top-K candidates from the 69-action
       index by cosine similarity. Cheap (~24ms with mxbai-embed-large at K=10).
    2. **Precision stage** — small LLM reranks just those K candidates by reading
       their full descriptions. Smaller prompt than `LLMRouter` (K actions vs 69),
       so faster.

  The final top-5 is built as:

    - LLM's chosen modules in order, in whatever count it returned (typically 1-3),
      then
    - Remaining candidates from the embedder's ranking that the LLM didn't pick,
      filling out to top-5.

  This combines Path 2's top-1 strength with Path 1's recall — the LLM gets to
  override the embedder on the first slot, but the embedder backfills slots 2-5
  so p@5 / r@5 don't suffer from the LLM's tendency to return only 1-2 items.

  ## Options

    * `:model` — the **rerank** LLM model (e.g. "granite4:1b"). This is the model
      passed via `--model` in the mix task — for consistency with the eval CLI.
    * `:embed_model` — the **recall** embedding model (default: "mxbai-embed-large").
    * `:candidate_k` — number of candidates the embedder produces for the LLM to
      rerank (default: 10).
    * `:top_k` — final number of results returned (default: 5).
    * `:max_desc_chars` — truncate each action description in the rerank prompt
      (default: 400 — generous, since the prompt only has K actions, not 69).
    * `:base_url` — Ollama base URL (default: http://localhost:11434).
    * `:timeout` — request timeout in ms (default: 60_000).

  ## Output

  Same shape as `EmbeddingRetrieval` and `LLMRouter`:

      {:ok, %{
        text: "[\\"Arbor.Actions.File\\", ...]",
        retrieved: [%{module: "Arbor.Actions.File", score: nil, source: :llm}, ...],
        duration_ms: 320,
        model: "granite4:1b",
        provider: "ollama"
      }}

  Each `retrieved` entry has a `:source` indicating whether it came from the LLM's
  pick (`:llm`) or the embedder's backfill (`:embed`). Useful for diagnosing which
  stage drove a given result.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  alias Arbor.Orchestrator.Eval.Subjects.EmbeddingRetrieval

  @default_index_path "apps/arbor_orchestrator/priv/eval_datasets/preprocessor_tool_retrieval/action_index.json"
  @default_base_url "http://localhost:11434"
  @default_timeout 60_000
  @default_top_k 5
  @default_candidate_k 10
  @default_embed_model "mxbai-embed-large"
  @default_max_desc_chars 400

  @impl true
  def run(input, opts \\ []) do
    prompt = extract_prompt(input)
    rerank_model = Keyword.fetch!(opts, :model)
    embed_model = Keyword.get(opts, :embed_model, @default_embed_model)
    candidate_k = Keyword.get(opts, :candidate_k, @default_candidate_k)
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    max_desc_chars = Keyword.get(opts, :max_desc_chars, @default_max_desc_chars)
    index_path = Keyword.get(opts, :index_path, @default_index_path)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    start = System.monotonic_time(:millisecond)

    with {:ok, candidates} <-
           recall_stage(input, embed_model, candidate_k, index_path, base_url, timeout),
         {:ok, descriptions} <- load_descriptions(index_path, candidates),
         {:ok, llm_picks} <-
           rerank_stage(
             prompt,
             candidates,
             descriptions,
             rerank_model,
             base_url,
             timeout,
             max_desc_chars,
             top_k
           ) do
      duration_ms = System.monotonic_time(:millisecond) - start
      final = fuse(llm_picks, candidates, top_k)

      {:ok,
       %{
         text: Jason.encode!(Enum.map(final, & &1.module)),
         retrieved: final,
         duration_ms: duration_ms,
         model: rerank_model,
         provider: "ollama"
       }}
    end
  end

  defp extract_prompt(%{"prompt" => prompt}) when is_binary(prompt), do: prompt
  defp extract_prompt(prompt) when is_binary(prompt), do: prompt

  defp extract_prompt(input),
    do:
      raise("HybridRetrieval expects %{\"prompt\" => binary} or a binary; got: #{inspect(input)}")

  defp recall_stage(input, embed_model, candidate_k, index_path, base_url, timeout) do
    embed_opts = [
      model: embed_model,
      top_k: candidate_k,
      index_path: index_path,
      base_url: base_url,
      timeout: timeout
    ]

    case EmbeddingRetrieval.run(input, embed_opts) do
      {:ok, %{retrieved: ranked}} -> {:ok, ranked}
      {:error, reason} -> {:error, {:recall_failed, reason}}
    end
  end

  # Look up descriptions for the candidate modules from the index.
  # We re-read from :persistent_term (the index was cached during recall_stage).
  defp load_descriptions(index_path, candidates) do
    key = {EmbeddingRetrieval, :index, Path.expand(index_path)}

    case :persistent_term.get(key, :miss) do
      :miss ->
        {:error, "index not cached in :persistent_term — recall_stage should have loaded it"}

      index ->
        modules_wanted = MapSet.new(candidates, & &1.module)

        descriptions =
          index["actions"]
          |> Enum.filter(&MapSet.member?(modules_wanted, &1["module"]))
          |> Enum.into(%{}, fn a -> {a["module"], a["description"] || ""} end)

        {:ok, descriptions}
    end
  end

  defp rerank_stage(
         prompt,
         candidates,
         descriptions,
         model,
         base_url,
         timeout,
         max_desc_chars,
         top_k
       ) do
    system_prompt = build_rerank_prompt(candidates, descriptions, max_desc_chars, top_k)
    known = MapSet.new(candidates, & &1.module)

    case call_llm(base_url, model, system_prompt, prompt, timeout) do
      {:ok, content} -> {:ok, parse_response(content, known, top_k)}
      {:error, reason} -> {:error, {:rerank_failed, reason}}
    end
  end

  defp build_rerank_prompt(candidates, descriptions, max_desc_chars, top_k) do
    action_list =
      candidates
      |> Enum.map(fn %{module: m} ->
        desc = truncate(Map.get(descriptions, m, ""), max_desc_chars)
        "- #{m}: #{desc}"
      end)
      |> Enum.join("\n")

    """
    You are an action selector for the Arbor agent framework. A retrieval system has pre-filtered #{length(candidates)} candidate actions for the user's request. Pick the #{top_k} most relevant from this shortlist, ordered most-relevant first.

    Candidate actions:

    #{action_list}

    Respond with ONLY a JSON object in this exact shape:

    {"selected": ["Arbor.Actions.X", "Arbor.Actions.Y", ...]}

    The "selected" array MUST contain only module names from the shortlist above, ordered by relevance to the user's request. Do not invent module names. Do not include any prose.
    """
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max) <> "..."

  defp call_llm(base_url, model, system, user, timeout) do
    url = base_url <> "/api/chat"

    body = %{
      model: model,
      messages: [
        %{role: "system", content: system},
        %{role: "user", content: user}
      ],
      stream: false,
      format: "json",
      options: %{temperature: 0.0}
    }

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error, "ollama chat returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp parse_response(content, known, top_k) do
    case Jason.decode(content) do
      {:ok, %{"selected" => list}} when is_list(list) -> normalize(list, known, top_k)
      {:ok, %{"actions" => list}} when is_list(list) -> normalize(list, known, top_k)
      {:ok, list} when is_list(list) -> normalize(list, known, top_k)
      _ -> []
    end
  end

  defp normalize(list, known, top_k) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.filter(&MapSet.member?(known, &1))
    |> Enum.uniq()
    |> Enum.take(top_k)
  end

  # Fuse LLM picks with embedder backfill. LLM picks go first (preserving their
  # order), then any embedder candidate the LLM didn't pick fills out to top_k.
  defp fuse(llm_picks, candidates, top_k) do
    llm_set = MapSet.new(llm_picks)

    llm_entries =
      Enum.map(llm_picks, fn module ->
        %{module: module, score: nil, source: :llm}
      end)

    backfill =
      candidates
      |> Enum.reject(fn %{module: m} -> MapSet.member?(llm_set, m) end)
      |> Enum.map(fn %{module: m, score: s} ->
        %{module: m, score: s, source: :embed}
      end)

    (llm_entries ++ backfill) |> Enum.take(top_k)
  end
end
