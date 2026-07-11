defmodule Arbor.AI.Eval.Subjects.HybridRetrieval do
  @moduledoc """
  Evaluation subject combining embedding recall with LLM reranking.

  The action index is loaded from the required `:index_path` option and passed
  directly through both stages. `:embed_fn` and `:router_fn` provide injectable
  boundaries for deterministic evaluation and testing.

  `:top_k` is capped at 100, `:candidate_k` at 500, the legacy
  `:max_desc_chars` option is enforced as a UTF-8 byte ceiling capped at 4,096,
  and `:timeout` at five minutes.
  """

  @behaviour Arbor.Eval.Subject

  alias Arbor.AI.Eval.RetrievalSupport

  @default_base_url "http://localhost:11434"
  @default_timeout 60_000
  @default_top_k 5
  @default_candidate_k 10
  @default_embed_model "mxbai-embed-large"
  @default_max_desc_chars 400
  @max_embedding_response_bytes 262_144
  @max_chat_response_bytes 262_144

  @impl true
  def run(input, opts \\ []) do
    with :ok <- RetrievalSupport.validate_opts(opts),
         {:ok, index_path} <- RetrievalSupport.required_string(opts, :index_path),
         {:ok, prompt} <- RetrievalSupport.extract_prompt(input),
         {:ok, rerank_model} <- RetrievalSupport.required_string(opts, :model),
         {:ok, embed_model} <-
           RetrievalSupport.string_option(opts, :embed_model, @default_embed_model),
         {:ok, candidate_k} <-
           RetrievalSupport.positive_integer_option(opts, :candidate_k, @default_candidate_k),
         {:ok, top_k} <-
           RetrievalSupport.positive_integer_option(opts, :top_k, @default_top_k),
         {:ok, max_desc_chars} <-
           RetrievalSupport.positive_integer_option(
             opts,
             :max_desc_chars,
             @default_max_desc_chars
           ),
         {:ok, base_url} <-
           RetrievalSupport.string_option(opts, :base_url, @default_base_url),
         {:ok, timeout} <-
           RetrievalSupport.positive_integer_option(opts, :timeout, @default_timeout),
         {:ok, embed_fn} <-
           RetrievalSupport.callback_option(opts, :embed_fn, 4, &default_embed/4),
         {:ok, router_fn} <-
           RetrievalSupport.callback_option(opts, :router_fn, 5, &default_router/5),
         {:ok, actions} <- RetrievalSupport.load_index(index_path) do
      run_stages(
        actions,
        prompt,
        index_path,
        rerank_model,
        embed_model,
        candidate_k,
        top_k,
        max_desc_chars,
        base_url,
        timeout,
        embed_fn,
        router_fn
      )
    end
  end

  defp run_stages(
         actions,
         prompt,
         index_path,
         rerank_model,
         embed_model,
         candidate_k,
         top_k,
         max_desc_chars,
         base_url,
         timeout,
         embed_fn,
         router_fn
       ) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, candidates} <-
           recall_stage(
             actions,
             prompt,
             index_path,
             embed_model,
             candidate_k,
             base_url,
             timeout,
             embed_fn
           ),
         {:ok, llm_picks} <-
           rerank_stage(
             actions,
             prompt,
             candidates,
             rerank_model,
             top_k,
             max_desc_chars,
             base_url,
             timeout,
             router_fn
           ) do
      final = fuse(llm_picks, candidates, top_k)
      duration_ms = System.monotonic_time(:millisecond) - started_at

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

  defp recall_stage(
         actions,
         prompt,
         index_path,
         embed_model,
         candidate_k,
         base_url,
         timeout,
         embed_fn
       ) do
    with {:ok, indexed_actions} <-
           RetrievalSupport.embeddings_for_model(actions, embed_model, index_path),
         {:ok, query_vector} <- embed(embed_fn, base_url, embed_model, prompt, timeout),
         :ok <- RetrievalSupport.validate_query_dimensions(indexed_actions, query_vector) do
      {:ok, RetrievalSupport.rank(indexed_actions, query_vector, candidate_k)}
    else
      {:error, reason} -> {:error, {:recall_failed, reason}}
    end
  end

  defp rerank_stage(
         actions,
         prompt,
         candidates,
         model,
         top_k,
         max_desc_chars,
         base_url,
         timeout,
         router_fn
       ) do
    descriptions = Map.new(actions, &{&1.module, &1.description})
    known_modules = MapSet.new(candidates, & &1.module)

    with {:ok, system_prompt} <-
           candidates
           |> build_rerank_prompt(descriptions, max_desc_chars, top_k)
           |> RetrievalSupport.validate_router_prompt() do
      case RetrievalSupport.invoke(
             router_fn,
             [base_url, model, system_prompt, prompt, timeout],
             :router_callback_failed
           ) do
        {:ok, content} when is_binary(content) ->
          case RetrievalSupport.parse_router_response(content, known_modules, top_k) do
            {:ok, modules} -> {:ok, modules}
            {:error, reason} -> {:error, {:rerank_failed, reason}}
          end

        {:ok, _content} ->
          {:error, {:rerank_failed, {:invalid_router_response, :binary_content_required}}}

        {:error, reason} ->
          {:error, {:rerank_failed, reason}}

        _response ->
          {:error, {:rerank_failed, {:invalid_router_response, :ok_tuple_required}}}
      end
    else
      {:error, reason} -> {:error, {:rerank_failed, reason}}
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

  defp build_rerank_prompt(candidates, descriptions, max_desc_chars, top_k) do
    action_list =
      candidates
      |> Enum.map(fn candidate ->
        description =
          descriptions
          |> Map.get(candidate.module, "")
          |> RetrievalSupport.truncate_utf8(max_desc_chars)

        "- #{candidate.module}: #{description}"
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

  defp default_embed(base_url, model, prompt, timeout) do
    case RetrievalSupport.post_json(
           base_url <> "/api/embeddings",
           %{model: model, prompt: prompt},
           timeout,
           @max_embedding_response_bytes
         ) do
      {:ok, 200, %{"embedding" => vector}} when is_list(vector) ->
        {:ok, vector}

      {:ok, status, body} ->
        RetrievalSupport.http_error(:embedding_http_error, status, body)

      {:error, _reason} = error ->
        error
    end
  end

  defp default_router(base_url, model, system_prompt, user_prompt, timeout) do
    body = %{
      model: model,
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      stream: false,
      format: "json",
      options: %{temperature: 0.0}
    }

    case RetrievalSupport.post_json(
           base_url <> "/api/chat",
           body,
           timeout,
           @max_chat_response_bytes
         ) do
      {:ok, 200, %{"message" => %{"content" => content}}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, status, response_body} ->
        RetrievalSupport.http_error(:router_http_error, status, response_body)

      {:error, _reason} = error ->
        error
    end
  end

  defp fuse(llm_picks, candidates, top_k) do
    llm_modules = MapSet.new(llm_picks)

    llm_entries =
      Enum.map(llm_picks, fn module ->
        %{module: module, score: nil, source: :llm}
      end)

    backfill =
      candidates
      |> Enum.reject(&MapSet.member?(llm_modules, &1.module))
      |> Enum.map(fn candidate ->
        %{module: candidate.module, score: candidate.score, source: :embed}
      end)

    Enum.take(llm_entries ++ backfill, top_k)
  end
end
