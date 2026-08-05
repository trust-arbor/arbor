defmodule Arbor.Memory.KnowledgeGraphCodecTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraph.Codec

  @moduletag :fast

  test "strict wrapper round-trips exact graph state and provenance without embeddings" do
    agent_id = "agent_graph_codec_roundtrip"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false, max_tokens: {:fixed, 2_000})

    {:ok, graph, first_id} =
      KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "A durable fact",
        metadata: %{"string-key" => :preserved, source: "test"},
        skip_dedup: true
      })

    {:ok, graph, second_id} =
      KnowledgeGraph.add_node(graph, %{
        type: :insight,
        content: "A durable insight",
        referenced_date: ~U[2026-08-05 12:00:00Z],
        skip_dedup: true
      })

    {:ok, graph} =
      KnowledgeGraph.add_edge(graph, first_id, second_id, :supports,
        metadata: %{created_by: :reflection}
      )

    {:ok, graph, pending_id} =
      KnowledgeGraph.add_pending_fact(graph, %{
        content: "A pending fact",
        source: "reflection",
        metadata: %{review: :required}
      })

    assert {:ok, snapshot} = Codec.reconcile(agent_id, graph, nil, trusted_taint())
    assert {:ok, wrapper} = Codec.encode(snapshot)

    assert Map.keys(wrapper) |> Enum.sort() ==
             ~w(agent_id kind payload provenance version)

    refute Map.has_key?(wrapper["payload"]["nodes"][first_id], "embedding")

    assert %{
             "nodes" => %{^first_id => %{"envelope" => _}},
             "pending_facts" => %{^pending_id => %{"envelope" => _}}
           } = wrapper["provenance"]

    assert {:ok, decoded, :current} =
             Codec.decode(agent_id, wrapper, snapshot.aggregate.taint, :verified)

    assert decoded.payload == snapshot.payload
    assert decoded.graph.max_tokens == {:fixed, 2_000}

    assert decoded.graph.nodes[first_id].metadata == %{
             "string-key" => :preserved,
             source: "test"
           }

    assert hd(decoded.graph.edges[first_id]).metadata == %{created_by: :reflection}
    assert hd(decoded.graph.pending_facts).metadata == %{review: :required}
  end

  test "wrapper-shaped corruption, unknown versions, and agent mismatch fail closed" do
    agent_id = "agent_graph_codec_strict"
    {wrapper, aggregate} = encoded_graph(agent_id)

    malformed = update_in(wrapper, ["provenance"], &Map.delete(&1, "aggregate"))
    assert {:error, :invalid_wrapper} = Codec.decode(agent_id, malformed, aggregate, :verified)

    assert {:error, :invalid_wrapper} =
             Codec.decode(agent_id, %{wrapper | "version" => 999}, aggregate, :verified)

    assert {:error, :invalid_wrapper} =
             Codec.decode("agent_graph_codec_other", wrapper, aggregate, :verified)

    legacy_looking = Map.put(KnowledgeGraph.to_map(KnowledgeGraph.new(agent_id)), "version", 1)

    assert {:error, :invalid_wrapper} =
             Codec.decode(
               agent_id,
               legacy_looking,
               TaintEnvelope.missing_fallback(),
               :legacy_unlabeled
             )
  end

  test "unwrapped legacy graphs receive conservative labels" do
    agent_id = "agent_graph_codec_legacy"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Legacy"})

    assert {:ok, snapshot, :migration} =
             Codec.decode(
               agent_id,
               KnowledgeGraph.to_map(graph),
               TaintEnvelope.missing_fallback(),
               :legacy_unlabeled
             )

    assert snapshot.aggregate.status == :legacy_unlabeled
    assert snapshot.base.status == :legacy_unlabeled
    assert snapshot.nodes[node_id].label.status == :legacy_unlabeled
  end

  test "aggregate provenance cannot weaken when hostile content is removed" do
    agent_id = "agent_graph_codec_monotonic"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    assert {:ok, initial} = Codec.reconcile(agent_id, graph, nil, trusted_taint())

    {:ok, graph, node_id} =
      KnowledgeGraph.add_node(initial.graph, %{type: :fact, content: "Hostile input"})

    assert {:ok, hostile} = Codec.reconcile(agent_id, graph, initial, hostile_taint())
    assert hostile.aggregate.taint.level == :hostile

    {:ok, graph} = KnowledgeGraph.remove_node(hostile.graph, node_id)
    assert {:ok, after_delete} = Codec.reconcile(agent_id, graph, hostile, trusted_taint())

    assert after_delete.aggregate.taint.level == :hostile
    assert after_delete.aggregate.taint.sensitivity == :restricted
  end

  test "content inventory is rejected before traversing more than 256 items" do
    agent_id = "agent_graph_codec_inventory_bound"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    now = ~U[2026-08-05 12:00:00Z]

    nodes =
      Map.new(1..257, fn index ->
        id = "node_fact_#{index}"

        {id,
         %{
           id: id,
           type: :fact,
           content: "bounded",
           relevance: 1.0,
           confidence: 0.5,
           access_count: 0,
           created_at: now,
           last_accessed: now,
           metadata: %{},
           pinned: false,
           embedding: nil,
           cached_tokens: 1,
           referenced_date: nil
         }}
      end)

    assert {:error, :graph_limit_exceeded} = Codec.prepare(agent_id, %{graph | nodes: nodes})
  end

  test "encoded graph authority is capped below one MiB" do
    agent_id = "agent_graph_codec_byte_bound"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    now = ~U[2026-08-05 12:00:00Z]
    content = String.duplicate("x", 65_536)

    nodes =
      Map.new(1..17, fn index ->
        id = "node_fact_large_#{index}"

        {id,
         %{
           id: id,
           type: :fact,
           content: content,
           relevance: 1.0,
           confidence: 0.5,
           access_count: 0,
           created_at: now,
           last_accessed: now,
           metadata: %{},
           pinned: false,
           embedding: nil,
           cached_tokens: 16_384,
           referenced_date: nil
         }}
      end)

    assert {:error, :graph_limit_exceeded} = Codec.prepare(agent_id, %{graph | nodes: nodes})
  end

  defp encoded_graph(agent_id) do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    {:ok, graph, _node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Strict"})
    {:ok, snapshot} = Codec.reconcile(agent_id, graph, nil, trusted_taint())
    {:ok, wrapper} = Codec.encode(snapshot)
    {wrapper, snapshot.aggregate.taint}
  end

  defp trusted_taint do
    %Taint{
      level: :trusted,
      sensitivity: :internal,
      sanitizations: 255,
      confidence: :verified,
      source: "codec_test",
      chain: []
    }
  end

  defp hostile_taint do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: "hostile_codec_test",
      chain: []
    }
  end
end
