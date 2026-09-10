defmodule Arbor.Memory.HybridSearch do
  @moduledoc false

  alias Arbor.{AI, LLM, Trust}
  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.{Config, HybridSearchCore, KnowledgeGraphStore}
  alias Arbor.Memory.KnowledgeGraph.Codec

  @route_keys [
    :enabled,
    :provider,
    :model,
    :base_url,
    :timeout_ms,
    :min_cosine,
    :min_score,
    :semantic_weight
  ]

  def search(caller, agent, query, opts, reauthorize) do
    started = System.monotonic_time(:millisecond)

    with {:ok, route} <- route(),
         :ok <- LLM.validate_live_embedding_pipeline(),
         {:ok, snapshot} <- KnowledgeGraphStore.get_snapshot(agent),
         {:ok, digest} <- snapshot_digest(snapshot),
         {:ok, nodes, bytes} <- HybridSearchCore.candidates(snapshot, query, opts) do
      route = %{
        route
        | min_cosine: max(route.min_cosine, Keyword.get(opts, :min_cosine, route.min_cosine)),
          min_score: max(route.min_score, Keyword.get(opts, :min_score, route.min_score))
      }

      search_snapshot(%{
        caller: caller,
        agent: agent,
        query: query,
        opts: opts,
        reauthorize: reauthorize,
        route: route,
        snapshot: snapshot,
        digest: digest,
        nodes: nodes,
        bytes: bytes,
        started: started
      })
    end
  rescue
    _ -> {:error, :hybrid_search_unavailable}
  catch
    _, _ -> {:error, :hybrid_search_unavailable}
  end

  defp search_snapshot(%{nodes: []} = ctx) do
    with :ok <- recheck(ctx),
         {:ok, _remaining} <- remaining(ctx) do
      result(ctx, [], %{})
    end
  end

  defp search_snapshot(ctx) do
    with {:ok, taint} <- HybridSearchCore.egress_taint(ctx.snapshot, ctx.nodes),
         :ok <- authorize_egress(ctx.caller, ctx.route, taint),
         :ok <- ctx.reauthorize.(),
         {:ok, remaining} <- remaining(ctx),
         {:ok, batch} <-
           LLM.embed_batch(
             ctx.route.provider,
             ctx.route.model,
             [ctx.query | Enum.map(ctx.nodes, & &1.content)],
             base_url: ctx.route.base_url,
             timeout_ms: remaining,
             max_response_bytes: HybridSearchCore.limits().response_bytes,
             req_http_options: [retry: false, redirect: false],
             require_live_pipeline: true
           ),
         {:ok, vectors} <- HybridSearchCore.embeddings(batch, ctx.route, length(ctx.nodes) + 1),
         :ok <- recheck(ctx),
         {:ok, _remaining} <- remaining(ctx) do
      ranked =
        HybridSearchCore.rank(ctx.snapshot, ctx.nodes, ctx.query, vectors, ctx.route, ctx.opts)

      result(ctx, ranked, Map.get(batch, :usage, %{}))
    end
  end

  defp authorize_egress(caller, route, taint) do
    case Trust.authorize_egress(caller, :on_host,
           egress_taint: taint,
           egress_destination: route.base_url,
           egress_provider: route.provider,
           egress_model: route.model,
           egress_runtime: "arbor"
         ) do
      :allow -> :ok
      _ -> {:error, :hybrid_search_egress_refused}
    end
  end

  defp recheck(ctx) do
    with :ok <- ctx.reauthorize.(),
         {:ok, current} <- KnowledgeGraphStore.get_snapshot(ctx.agent),
         {:ok, current_digest} <- snapshot_digest(current) do
      if ctx.digest == current_digest,
        do: :ok,
        else: {:error, :hybrid_search_snapshot_changed}
    end
  end

  defp snapshot_digest(snapshot) do
    with {:ok, wrapper} <- Codec.encode(snapshot),
         {:ok, bytes} <- TaintEnvelope.canonical_json(wrapper) do
      {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    end
  end

  defp result(ctx, results, usage) do
    route = ctx.route

    value = %{
      results: results,
      strategy: :experimental_hybrid,
      measurement: %{
        provider: route.provider,
        model: route.model,
        dimensions: VectorRecord.dimensions(),
        semantic_weight: route.semantic_weight,
        keyword_weight: 1.0 - route.semantic_weight,
        min_cosine: route.min_cosine,
        min_score: route.min_score,
        corpus_digest: ctx.digest,
        candidate_count: length(ctx.nodes),
        input_bytes: ctx.bytes,
        elapsed_ms: System.monotonic_time(:millisecond) - ctx.started,
        usage: usage
      }
    }

    maximum = HybridSearchCore.limits().result_bytes

    with :ok <-
           LLM.validate_decoded_term(value,
             max_bytes: maximum,
             max_nodes: 10_000,
             max_depth: 24,
             max_map_keys: 5000,
             max_list_items: 10_000
           ),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= maximum do
      with {:ok, _remaining} <- remaining(ctx), do: {:ok, value}
    else
      _ -> {:error, {:hybrid_search_limit_exceeded, :result_bytes, maximum}}
    end
  end

  defp remaining(ctx) do
    left = ctx.route.timeout_ms - (System.monotonic_time(:millisecond) - ctx.started)
    if left > 0, do: {:ok, left}, else: {:error, :hybrid_search_deadline_exceeded}
  end

  defp route do
    case Config.hybrid_knowledge_search() do
      disabled when disabled in [false, nil] -> {:error, :hybrid_search_disabled}
      opts -> resolve_route(opts)
    end
  end

  defp resolve_route(opts) do
    with true <- HybridSearchCore.options?(opts, @route_keys),
         true <- Keyword.get(opts, :enabled) === true,
         provider <- Keyword.get(opts, :provider),
         true <- provider in ["ollama", "lm_studio"],
         model <- Keyword.get(opts, :model),
         true <- HybridSearchCore.label?(model, 256) and String.trim(model) == model,
         {:ok, base} <-
           LLM.validate_endpoint(Keyword.get(opts, :base_url), {:req_llm_base, provider}),
         true <- loopback?(base),
         :on_host <- AI.egress_tier_for(provider, base),
         timeout <- Keyword.get(opts, :timeout_ms, 10_000),
         true <- is_integer(timeout) and timeout in 1..30_000,
         cosine <- Keyword.get(opts, :min_cosine),
         score <- Keyword.get(opts, :min_score),
         weight <- Keyword.get(opts, :semantic_weight, 0.7),
         true <- Enum.all?([cosine, score, weight], &HybridSearchCore.unit?/1) do
      {:ok,
       %{
         provider: provider,
         model: model,
         base_url: base,
         timeout_ms: timeout,
         min_cosine: cosine,
         min_score: score,
         semantic_weight: weight
       }}
    else
      _ -> {:error, :invalid_hybrid_search_configuration}
    end
  end

  defp loopback?(base) do
    case URI.parse(base).host do
      "::1" ->
        true

      host when is_binary(host) ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, {127, _, _, _}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end
end
