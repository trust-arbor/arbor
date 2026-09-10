defmodule Arbor.Memory.HybridSearchCore do
  @moduledoc false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.KnowledgeGraph.GraphSearch

  @option_keys [:types, :min_relevance, :limit, :min_cosine, :min_score]
  @types [
    :fact,
    :experience,
    :skill,
    :insight,
    :relationship,
    :goal,
    :observation,
    :trait,
    :intention
  ]
  @max_candidates 64
  @max_query_bytes 4096
  @max_text_bytes 8192
  @max_batch_bytes 262_144

  def limits,
    do: %{
      candidates: @max_candidates,
      query_bytes: @max_query_bytes,
      text_bytes: @max_text_bytes,
      batch_bytes: @max_batch_bytes,
      result_count: 10,
      result_bytes: 65_536,
      response_bytes: 2_097_152
    }

  def validate_request(caller, agent, query, opts) do
    if label?(caller, 256) and label?(agent, 256) and label?(query, @max_query_bytes) and
         options?(opts, @option_keys) and valid_options?(opts),
       do: :ok,
       else: {:error, :invalid_hybrid_search_request}
  end

  def options?([], _allowed), do: true

  def options?([{key, _} | rest], allowed) when is_atom(key) do
    key in allowed and options?(rest, List.delete(allowed, key))
  end

  def options?(_, _), do: false

  def label?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
        String.trim(value) != ""

  def unit?(value), do: is_number(value) and value >= 0 and value <= 1

  defp valid_options?(opts) do
    Enum.all?(opts, fn
      {:limit, n} -> is_integer(n) and n in 1..10
      {:types, types} -> valid_types?(types, @types)
      {_key, n} -> unit?(n)
    end)
  end

  defp valid_types?([], _remaining), do: true

  defp valid_types?([type | rest], remaining),
    do: type in remaining and valid_types?(rest, List.delete(remaining, type))

  defp valid_types?(_malformed, _remaining), do: false

  def candidates(snapshot, query, opts) do
    if map_size(snapshot.graph.nodes) <= @max_candidates do
      types = Keyword.get(opts, :types, @types)
      relevance = Keyword.get(opts, :min_relevance, 0.0)

      nodes =
        snapshot.graph.nodes
        |> Map.values()
        |> Enum.filter(&(&1.type in types and &1.relevance >= relevance))
        |> Enum.sort_by(& &1.id)

      with {:ok, bytes} <- input_bytes(nodes, byte_size(query)) do
        {:ok, nodes, bytes}
      end
    else
      {:error, {:hybrid_search_limit_exceeded, :candidates, @max_candidates}}
    end
  end

  defp input_bytes([], bytes), do: {:ok, bytes}

  defp input_bytes([node | rest], bytes) do
    text = node.content

    cond do
      not label?(text, @max_text_bytes) ->
        {:error, {:hybrid_search_limit_exceeded, :text_bytes, @max_text_bytes}}

      bytes + byte_size(text) > @max_batch_bytes ->
        {:error, {:hybrid_search_limit_exceeded, :batch_bytes, @max_batch_bytes}}

      true ->
        input_bytes(rest, bytes + byte_size(text))
    end
  end

  def egress_taint(snapshot, nodes) do
    labels = Enum.map(nodes, &snapshot.nodes[&1.id].label.taint)
    Taint.join_many([TaintEnvelope.missing_fallback() | labels])
  end

  def embeddings(result, route, count) do
    with %{
           association_version: 1,
           indexed_embeddings: indexed,
           embeddings: vectors,
           provider: provider,
           model: model,
           dimensions: dimensions
         } <- result,
         true <- provider == route.provider and model == route.model,
         true <- dimensions == VectorRecord.dimensions(),
         true <- is_list(indexed) and length(indexed) == count,
         true <- Enum.map(indexed, &Map.get(&1, :index)) == Enum.to_list(0..(count - 1)),
         true <- Enum.map(indexed, &Map.get(&1, :embedding)) == vectors do
      Enum.reduce_while(vectors, {:ok, []}, fn vector, {:ok, acc} ->
        case VectorRecord.normalize_vector(vector) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          _ -> {:halt, {:error, :invalid_hybrid_search_embeddings}}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    else
      _ -> {:error, :invalid_hybrid_search_embeddings}
    end
  end

  def rank(snapshot, nodes, query, [query_vector | vectors], route, opts) do
    cosine_floor = max(route.min_cosine, Keyword.get(opts, :min_cosine, route.min_cosine))
    score_floor = max(route.min_score, Keyword.get(opts, :min_score, route.min_score))

    Enum.zip(nodes, vectors)
    |> Enum.map(fn {node, vector} ->
      %{
        id: node.id,
        payload: snapshot.nodes[node.id].payload,
        provenance: snapshot.nodes[node.id].label,
        scores:
          GraphSearch.hybrid_scores(query, query_vector, node, vector, route.semantic_weight)
      }
    end)
    |> Enum.filter(&(&1.scores.semantic >= cosine_floor and &1.scores.combined >= score_floor))
    |> Enum.sort_by(&{-&1.scores.combined, &1.id})
    |> Enum.take(Keyword.get(opts, :limit, 10))
  end
end
