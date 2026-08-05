defmodule Arbor.Memory.KnowledgeGraphCodecTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraph.{Codec, Operation}

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
    assert decoded.graph == graph
    assert decoded.graph.max_tokens == {:fixed, 2_000}

    assert decoded.graph.nodes[first_id].metadata == %{
             "string-key" => :preserved,
             source: "test"
           }

    assert hd(decoded.graph.edges[first_id]).metadata == %{created_by: :reflection}
    assert hd(decoded.graph.pending_facts).metadata == %{review: :required}

    assert {:ok, ^wrapper} = Codec.encode(snapshot)
    assert {:ok, first_bytes} = TaintEnvelope.canonical_json(wrapper)
    assert {:ok, ^first_bytes} = TaintEnvelope.canonical_json(wrapper)
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

    assert {:error, :invalid_wrapper} =
             Codec.decode(
               agent_id,
               put_in(wrapper, ["payload", "agent_id"], "agent_payload_mismatch"),
               aggregate,
               :verified
             )

    assert {:error, :invalid_wrapper} =
             Codec.decode(agent_id, Map.put(wrapper, :version, 1), aggregate, :verified)

    legacy_looking = Map.put(KnowledgeGraph.to_map(KnowledgeGraph.new(agent_id)), "version", 1)

    assert {:error, :invalid_wrapper} =
             Codec.decode(
               agent_id,
               legacy_looking,
               TaintEnvelope.missing_fallback(),
               :legacy_unlabeled
             )
  end

  test "digest, aggregate dominance, and verified outer taint fail closed" do
    agent_id = "agent_graph_codec_integrity"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Bound"})
    assert {:ok, snapshot} = Codec.reconcile(agent_id, graph, nil, trusted_taint())
    assert {:ok, wrapper} = Codec.encode(snapshot)

    digest_mismatch = put_in(wrapper, ["payload", "nodes", node_id, "content"], "Tampered")

    assert {:error, :invalid_wrapper} =
             Codec.decode(agent_id, digest_mismatch, snapshot.aggregate.taint, :verified)

    node_payload = wrapper["payload"]["nodes"][node_id]
    assert {:ok, hostile_envelope} = TaintEnvelope.new(node_payload, hostile_taint())
    assert {:ok, hostile_envelope} = TaintEnvelope.to_map(hostile_envelope)

    weakened =
      put_in(
        wrapper,
        ["provenance", "nodes", node_id],
        %{"envelope" => hostile_envelope, "status" => "verified"}
      )

    assert {:error, :invalid_wrapper} =
             Codec.decode(agent_id, weakened, snapshot.aggregate.taint, :verified)

    assert {:error, :invalid_wrapper} =
             Codec.decode(agent_id, wrapper, hostile_taint(), :verified)
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

  test "legacy nested aliases, unknown fields, and cross-queue IDs are rejected" do
    agent_id = "agent_graph_codec_legacy_nested"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "Legacy"})
    legacy = KnowledgeGraph.to_map(graph)

    aliased_node = update_in(legacy, [:nodes, node_id], &Map.put(&1, "content", "alias"))
    assert_legacy_rejected(agent_id, aliased_node)

    unknown_node = update_in(legacy, [:nodes, node_id], &Map.put(&1, :unknown_field, true))
    assert_legacy_rejected(agent_id, unknown_node)

    aliased_metadata =
      update_in(legacy, [:nodes, node_id, :metadata], fn _ ->
        %{"source" => "two", source: "one"}
      end)

    assert_legacy_rejected(agent_id, aliased_metadata)

    pending = pending_item("shared_pending", :fact)

    duplicate_pending = %{
      legacy
      | pending_facts: [pending],
        pending_learnings: [%{pending | type: :learning}]
    }

    assert_legacy_rejected(agent_id, duplicate_pending)
  end

  test "semantic config, quotas, active-set capacity, and metadata depth are validated" do
    agent_id = "agent_graph_codec_semantics"
    base = KnowledgeGraph.new(agent_id, auto_embed: false)
    {:ok, graph, node_id} = KnowledgeGraph.add_node(base, %{type: :fact, content: "Active"})

    invalid_graphs = [
      %{graph | config: Map.put(graph.config, :unknown, true)},
      %{graph | config: %{graph.config | decay_rate: -0.1}},
      %{graph | config: %{graph.config | prune_threshold: 1.1}},
      %{graph | config: %{graph.config | max_nodes_per_type: 0}},
      %{graph | dedup_threshold: 1.1},
      %{graph | max_active: 0, active_set: [node_id]},
      %{graph | type_quotas: %{fact: 0.8, skill: 0.8}},
      %{graph | type_quotas: %{unknown: 0.5}}
    ]

    Enum.each(invalid_graphs, fn invalid ->
      assert {:error, _reason} = Codec.prepare(agent_id, invalid)
    end)

    deep_metadata = Enum.reduce(1..18, "leaf", fn index, acc -> %{"d#{index}" => acc} end)
    deep_graph = put_in(graph.nodes[node_id].metadata, deep_metadata)
    assert {:error, _reason} = Codec.prepare(agent_id, deep_graph)
  end

  test "duplicate logical edges are rejected even when edge IDs differ" do
    agent_id = "agent_graph_codec_duplicate_edge"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    {:ok, graph, source_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "A"})
    {:ok, graph, target_id} = KnowledgeGraph.add_node(graph, %{type: :fact, content: "B"})
    {:ok, graph} = KnowledgeGraph.add_edge(graph, source_id, target_id, :supports)

    [edge] = graph.edges[source_id]
    duplicate = %{edge | id: "edge_duplicate_logical"}
    graph = put_in(graph.edges[source_id], [edge, duplicate])

    assert {:error, :invalid_graph} = Codec.prepare(agent_id, graph)
  end

  test "atom persistence uses a closed cold-start registry" do
    agent_id = "agent_graph_codec_atoms"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    {:ok, known, _node_id} =
      KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "Known atoms",
        metadata: %{source: :reflection}
      })

    assert {:ok, snapshot} = Codec.reconcile(agent_id, known, nil, trusted_taint())
    assert {:ok, wrapper} = Codec.encode(snapshot)

    assert {:ok, decoded, :current} =
             Codec.decode(agent_id, wrapper, snapshot.aggregate.taint, :verified)

    assert decoded.graph == known

    {:ok, unknown, unknown_id} =
      KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "Warm VM atom",
        metadata: %{source: :codec_unregistered_existing_atom}
      })

    assert is_atom(unknown.nodes[unknown_id].metadata.source)
    assert {:error, :invalid_graph} = Codec.prepare(agent_id, unknown)
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

    assert {:ok, wrapper} = Codec.encode(after_delete)

    assert {:ok, restored, :current} =
             Codec.decode(agent_id, wrapper, after_delete.aggregate.taint, :verified)

    assert restored.graph == after_delete.graph
    assert restored.aggregate == after_delete.aggregate
  end

  test "maintenance outbox independently binds each removed node label" do
    agent_id = "agent_graph_codec_maintenance_provenance"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    {:ok, graph, node_id} =
      KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "label survives maintenance",
        relevance: 0.05,
        skip_dedup: true
      })

    source = trusted_taint()
    assert {:ok, initial} = Codec.reconcile(agent_id, graph, nil, source)
    assert {:ok, operation} = Operation.consolidate("codec_maintenance", :basic, [])

    assert {:ok, maintained, effect, :changed} =
             Operation.apply(operation, initial.graph, Codec.missing_taint())

    assert {:ok, snapshot} =
             Codec.reconcile(
               agent_id,
               maintained,
               initial,
               Codec.missing_taint(),
               %{archived_node_ids: [node_id]}
             )

    assert snapshot.maintenance_effects[node_id].label == initial.nodes[node_id].label
    refute Map.has_key?(snapshot.base_payload, "pending_maintenance_effect")
    assert effect.operation_id == "codec_maintenance"

    assert {:ok, wrapper} = Codec.encode(snapshot)

    assert {:ok, restored, :current} =
             Codec.decode(agent_id, wrapper, snapshot.aggregate.taint, :verified)

    assert restored.maintenance_effects[node_id].label == initial.nodes[node_id].label

    tampered =
      put_in(
        wrapper,
        ["provenance", "maintenance_effects", node_id],
        wrapper["provenance"]["base"]
      )

    assert {:error, :invalid_wrapper} =
             Codec.decode(agent_id, tampered, snapshot.aggregate.taint, :verified)
  end

  test "declared capacity encodes at the envelope boundary and rejects the next item" do
    agent_id = "agent_graph_codec_inventory_bound"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    boundary = Codec.max_content_items()
    graph = %{graph | nodes: nodes(boundary)}

    assert {:ok, _prepared} = Codec.prepare(agent_id, graph)
    assert {:ok, snapshot} = Codec.reconcile(agent_id, graph, nil, maximum_taint())
    assert {:ok, wrapper} = Codec.encode(snapshot)
    assert {:ok, bytes} = TaintEnvelope.canonical_json(wrapper)
    assert byte_size(bytes) <= TaintEnvelope.limits().max_payload_bytes

    too_many = %{graph | nodes: nodes(boundary + 1)}
    assert {:error, :graph_limit_exceeded} = Codec.prepare(agent_id, too_many)
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

  defp assert_legacy_rejected(agent_id, legacy) do
    assert {:error, :invalid_graph} =
             Codec.decode(
               agent_id,
               legacy,
               TaintEnvelope.missing_fallback(),
               :legacy_unlabeled
             )
  end

  defp pending_item(id, type) do
    %{
      id: id,
      type: type,
      content: "pending",
      confidence: 0.5,
      source: "test",
      extracted_at: ~U[2026-08-05 12:00:00Z],
      metadata: %{}
    }
  end

  defp nodes(count) do
    now = ~U[2026-08-05 12:00:00Z]

    Map.new(1..count, fn index ->
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

  defp maximum_taint do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: String.duplicate("s", Taint.max_source_bytes()),
      chain:
        List.duplicate(
          String.duplicate("c", Taint.max_chain_entry_bytes()),
          Taint.max_chain_entries()
        )
    }
  end
end
