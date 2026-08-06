defmodule Arbor.Memory.KnowledgeGraph.Codec do
  @moduledoc false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.KnowledgeGraph

  @kind "arbor_knowledge_graph"
  @version 1
  # The durable wrapper carries one payload plus one provenance envelope per
  # content item. Sixty-four remains encodable under TaintEnvelope's 4,096-node
  # ceiling even when every label has a maximum-length provenance chain.
  @max_content_items 64
  @max_edges 256
  @max_operation_receipts 256
  @max_identifier_bytes 256
  @max_generic_nodes 512
  @max_generic_depth 16
  @max_generic_entries 256

  @wrapper_keys ~w(agent_id kind payload provenance version)
  @provenance_keys ~w(
    aggregate base maintenance_effects nodes pending_facts pending_learnings
  )
  @entry_keys ~w(envelope status)
  @payload_keys ~w(
    active_set agent_id config dedup_threshold edges last_decay_at max_active
    max_tokens nodes operation_receipt_order operation_receipts pending_facts
    pending_learnings pending_maintenance_effect type_quotas
  )
  @node_keys ~w(
    access_count cached_tokens confidence content created_at id last_accessed metadata
    pinned referenced_date relevance type
  )
  @edge_keys ~w(created_at id metadata relationship source_id strength target_id)
  @pending_keys ~w(confidence content extracted_at id metadata source type)
  @operation_receipt_keys ~w(fingerprint kind result)
  @maintenance_receipt_keys ~w(metrics status)
  @maintenance_effect_keys ~w(archive_entries metrics mode occurred_at operation_id)
  @maintenance_archive_entry_keys ~w(node reason)
  @maintenance_metric_keys ~w(
    archived_count average_relevance decayed_count evicted_count pruned_count
    reinforced_count total_nodes
  )
  @maintenance_modes ~w(basic enhanced)
  @maintenance_reasons ~w(low_relevance quota_exceeded)
  @operation_kinds ~w(
    add_edge add_node add_pending_fact add_pending_learning add_pending_learning_batch
    approve_pending cascade_recall consolidate merge_node_metadata merge_node_metadata_batch
    reinforce reject_pending
  )
  @config_keys ~w(auto_embed decay_rate max_nodes_per_type prune_threshold)
  @legacy_node_keys @node_keys ++ ["embedding"]
  @accepted_proposal_key "$arbor_accepted_proposal_id"
  @legacy_edge_keys @edge_keys ++ ["weight"]

  @allowed_node_types [
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

  @allowed_relationships [
    :associated_with,
    :causes,
    :contradicts,
    :depends_on,
    :derived_from,
    :enables,
    :example_of,
    :follows,
    :part_of,
    :precedes,
    :related_to,
    :relates_to,
    :supports,
    :uses
  ]

  # Extensible metadata should use string keys/values. Atom preservation is
  # deliberately limited to this load-order-independent semantic registry.
  @semantic_atoms Enum.uniq(
                    @allowed_node_types ++
                      @allowed_relationships ++
                      [
                        :accepted,
                        :action,
                        # Written by Arbor.Actions.Memory.Remember on EVERY agent
                        # remember call (metadata: %{source: :agent_tool}). Missing
                        # from this list until 2026-08-06, which made every such
                        # call fail with :invalid_graph. Guarded by
                        # test/arbor/memory/knowledge_graph/metadata_atom_encoding_test.exs
                        :agent_tool,
                        :archived_count,
                        :auto_embed,
                        :average_relevance,
                        :basic,
                        :blocked_at,
                        :blocked_reason,
                        :capability,
                        :category,
                        :confidence,
                        :context,
                        :conversation_id,
                        :count,
                        :created_by,
                        :decay_rate,
                        :description,
                        :decayed_count,
                        :detection_source,
                        :evidence,
                        :enhanced,
                        :evicted_count,
                        :failure,
                        :failure_then_success,
                        :feedback,
                        :fixed,
                        :goal_id,
                        :long_sequence,
                        :low_relevance,
                        :memory_id,
                        :max_nodes_per_type,
                        :min_max,
                        :name,
                        :occurrences,
                        :original_confidence,
                        :outcome,
                        :pattern_analysis,
                        :pattern_type,
                        :percentage,
                        :personality,
                        :preference,
                        :preserved,
                        :promotion_blocked,
                        :promoted_at,
                        :pruned_count,
                        :prune_threshold,
                        :quota_exceeded,
                        :query_used,
                        :reason,
                        :reflection,
                        :reflection_learning,
                        :rejected,
                        :reinforced_count,
                        :repeated_sequence,
                        :required,
                        :review,
                        :self,
                        :skill,
                        :source,
                        :success,
                        :tags,
                        :task_id,
                        :technical,
                        :total_nodes,
                        :tool,
                        :tool_name,
                        :tools,
                        :trait,
                        :unlimited,
                        :updated_at,
                        :value,
                        :working_memory
                      ]
                  )
  @semantic_atoms_by_name Map.new(@semantic_atoms, &{Atom.to_string(&1), &1})

  @capacity_probe_taint %Taint{
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

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance
  @type label :: %{taint: Taint.t(), status: provenance_status()}
  @type labelled_item :: %{payload: map(), label: label()}
  @type snapshot :: %{
          graph: KnowledgeGraph.t(),
          payload: map(),
          base_payload: map(),
          base: label(),
          aggregate: label(),
          nodes: %{String.t() => labelled_item()},
          pending_facts: %{String.t() => labelled_item()},
          pending_learnings: %{String.t() => labelled_item()},
          maintenance_effects: %{String.t() => labelled_item()}
        }

  @spec kind() :: String.t()
  def kind, do: @kind

  @spec version() :: pos_integer()
  def version, do: @version

  @spec max_content_items() :: pos_integer()
  def max_content_items, do: @max_content_items

  @spec missing_taint() :: Taint.t()
  def missing_taint, do: TaintEnvelope.missing_fallback()

  @spec wrapper_shaped?(term()) :: boolean()
  def wrapper_shaped?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(
      ["kind", "version", "payload", "provenance", :kind, :version, :payload, :provenance],
      &Map.has_key?(value, &1)
    )
  end

  def wrapper_shaped?(_value), do: false

  @spec prepare(String.t(), KnowledgeGraph.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(agent_id, %KnowledgeGraph{} = graph) do
    with :ok <- validate_identifier(agent_id),
         true <- exact_graph_struct?(graph),
         true <- graph.agent_id == agent_id,
         :ok <-
           validate_content_inventory(
             graph.nodes,
             graph.pending_facts,
             graph.pending_learnings,
             graph.pending_maintenance_effect
           ),
         {:ok, nodes} <- encode_nodes(graph.nodes),
         {:ok, edges} <- encode_edges(graph.edges, Map.keys(nodes)),
         {:ok, pending_facts} <- encode_pending(graph.pending_facts, :fact),
         {:ok, pending_learnings} <- encode_pending(graph.pending_learnings, :learning),
         {:ok, pending_maintenance_effect} <-
           encode_maintenance_effect(graph.pending_maintenance_effect),
         {:ok, operation_receipts} <- encode_operation_receipts(graph.operation_receipts),
         {:ok, operation_receipt_order} <-
           encode_operation_receipt_order(
             graph.operation_receipt_order,
             operation_receipts
           ),
         {:ok, active_set} <- encode_active_set(graph.active_set, Map.keys(nodes)),
         {:ok, config} <- encode_config(graph.config),
         {:ok, max_tokens} <- encode_max_tokens(graph.max_tokens),
         {:ok, type_quotas} <- encode_type_quotas(graph.type_quotas),
         {:ok, last_decay_at} <- encode_optional_datetime(graph.last_decay_at),
         :ok <- validate_graph_scalars(graph) do
      payload = %{
        "agent_id" => agent_id,
        "nodes" => nodes,
        "edges" => edges,
        "pending_facts" => pending_facts,
        "pending_learnings" => pending_learnings,
        "pending_maintenance_effect" => pending_maintenance_effect,
        "operation_receipts" => operation_receipts,
        "operation_receipt_order" => operation_receipt_order,
        "config" => config,
        "active_set" => active_set,
        "max_active" => graph.max_active,
        "dedup_threshold" => graph.dedup_threshold,
        "max_tokens" => max_tokens,
        "type_quotas" => type_quotas,
        "last_decay_at" => last_decay_at
      }

      with :ok <- ensure_pending_ids_disjoint(pending_facts, pending_learnings),
           {:ok, _bytes} <- TaintEnvelope.canonical_json(payload),
           {:ok, normalized_graph} <- decode_graph_payload(agent_id, payload) do
        prepared = %{
          graph: normalized_graph,
          payload: payload,
          base_payload: base_payload(payload),
          nodes: nodes,
          pending_facts: index_pending(pending_facts),
          pending_learnings: index_pending(pending_learnings),
          maintenance_effects: index_maintenance_effect(pending_maintenance_effect)
        }

        with :ok <- validate_prepared_capacity(prepared) do
          {:ok, prepared}
        end
      else
        _ -> {:error, :graph_limit_exceeded}
      end
    else
      false -> {:error, :invalid_graph}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  rescue
    _ -> {:error, :invalid_graph}
  catch
    _, _ -> {:error, :invalid_graph}
  end

  def prepare(_agent_id, _graph), do: {:error, :invalid_graph}

  @spec reconcile(String.t(), KnowledgeGraph.t(), snapshot() | nil, term()) ::
          {:ok, snapshot()} | {:error, atom()}
  def reconcile(agent_id, graph, previous, supplied_taint) do
    reconcile(agent_id, graph, previous, supplied_taint, %{})
  end

  @spec reconcile(String.t(), KnowledgeGraph.t(), snapshot() | nil, term(), map()) ::
          {:ok, snapshot()} | {:error, atom()}
  def reconcile(agent_id, graph, previous, supplied_taint, context) do
    with {:ok, prepared} <- prepare(agent_id, graph),
         {:ok, supplied_taint} <- Taint.canonicalize(supplied_taint),
         {:ok, context} <- normalize_reconciliation_context(context) do
      supplied = label_record(supplied_taint, status_for_taint(supplied_taint))

      base =
        if context.provenance_neutral and previous_label(previous, :base) do
          previous_label(previous, :base)
        else
          reconcile_label(
            prepared.base_payload,
            previous_value(previous, :base_payload),
            previous_label(previous, :base),
            supplied
          )
        end

      nodes = reconcile_nodes(prepared.nodes, previous, supplied, context.accepted_pending)

      pending_facts =
        reconcile_items(
          prepared.pending_facts,
          previous_items(previous, :pending_facts),
          supplied
        )

      pending_learnings =
        reconcile_items(
          prepared.pending_learnings,
          previous_items(previous, :pending_learnings),
          supplied
        )

      maintenance_effects =
        reconcile_maintenance_effects(
          prepared.maintenance_effects,
          previous,
          supplied,
          context.archived_node_ids
        )

      components =
        [base] ++
          item_labels(nodes) ++
          item_labels(pending_facts) ++
          item_labels(pending_learnings) ++ item_labels(maintenance_effects)

      aggregate =
        case previous_label(previous, :aggregate) do
          nil -> join_labels(components)
          prior -> join_labels([prior | components])
        end

      snapshot =
        Map.merge(prepared, %{
          base: base,
          aggregate: aggregate,
          nodes: nodes,
          pending_facts: pending_facts,
          pending_learnings: pending_learnings,
          maintenance_effects: maintenance_effects
        })

      with {:ok, _wrapper} <- encode(snapshot) do
        {:ok, snapshot}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  rescue
    _ -> {:error, :invalid_graph}
  catch
    _, _ -> {:error, :invalid_graph}
  end

  @spec encode(snapshot()) :: {:ok, map()} | {:error, atom()}
  def encode(snapshot) when is_map(snapshot) do
    with {:ok, base} <- encode_label_entry(snapshot.base_payload, snapshot.base),
         {:ok, aggregate} <- encode_label_entry(snapshot.payload, snapshot.aggregate),
         {:ok, nodes} <- encode_labelled_inventory(snapshot.nodes),
         {:ok, pending_facts} <- encode_labelled_inventory(snapshot.pending_facts),
         {:ok, pending_learnings} <- encode_labelled_inventory(snapshot.pending_learnings),
         {:ok, maintenance_effects} <-
           encode_labelled_inventory(snapshot.maintenance_effects) do
      wrapper = %{
        "kind" => @kind,
        "version" => @version,
        "agent_id" => snapshot.graph.agent_id,
        "payload" => snapshot.payload,
        "provenance" => %{
          "base" => base,
          "aggregate" => aggregate,
          "nodes" => nodes,
          "pending_facts" => pending_facts,
          "pending_learnings" => pending_learnings,
          "maintenance_effects" => maintenance_effects
        }
      }

      case TaintEnvelope.canonical_json(wrapper) do
        {:ok, _bytes} -> {:ok, wrapper}
        {:error, _reason} -> {:error, :graph_limit_exceeded}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_wrapper}
    end
  rescue
    _ -> {:error, :invalid_wrapper}
  catch
    _, _ -> {:error, :invalid_wrapper}
  end

  def encode(_snapshot), do: {:error, :invalid_wrapper}

  @spec decode(String.t(), term(), term(), provenance_status()) ::
          {:ok, snapshot(), :current | :migration} | {:error, atom()}
  def decode(agent_id, data, outer_taint, outer_status) do
    if wrapper_shaped?(data) do
      decode_wrapper(agent_id, data, outer_taint, outer_status)
    else
      decode_legacy(agent_id, data, outer_taint, outer_status)
    end
  rescue
    _ -> {:error, :invalid_wrapper}
  catch
    _, _ -> {:error, :invalid_wrapper}
  end

  @spec decode_legacy_graph(String.t(), term()) :: {:ok, KnowledgeGraph.t()} | {:error, atom()}
  def decode_legacy_graph(agent_id, data) do
    with {:ok, snapshot, :migration} <-
           decode_legacy(
             agent_id,
             data,
             TaintEnvelope.missing_fallback(),
             :legacy_unlabeled
           ) do
      {:ok, snapshot.graph}
    end
  end

  defp decode_wrapper(agent_id, data, outer_taint, outer_status) do
    with {:ok, _bytes} <- TaintEnvelope.canonical_json(data),
         true <- exact_string_keys?(data, @wrapper_keys),
         true <- data["kind"] == @kind,
         true <- data["version"] == @version,
         true <- data["agent_id"] == agent_id,
         {:ok, graph} <- decode_graph_payload(agent_id, data["payload"]),
         provenance when is_map(provenance) and not is_struct(provenance) <- data["provenance"],
         true <- exact_string_keys?(provenance, @provenance_keys),
         {:ok, base} <- decode_label_entry(provenance["base"], base_payload(data["payload"])),
         {:ok, nodes} <- decode_labelled_inventory(provenance["nodes"], data["payload"]["nodes"]),
         {:ok, pending_facts} <-
           decode_labelled_inventory(
             provenance["pending_facts"],
             index_pending(data["payload"]["pending_facts"])
           ),
         {:ok, pending_learnings} <-
           decode_labelled_inventory(
             provenance["pending_learnings"],
             index_pending(data["payload"]["pending_learnings"])
           ),
         {:ok, maintenance_effects} <-
           decode_labelled_inventory(
             provenance["maintenance_effects"],
             index_maintenance_effect(data["payload"]["pending_maintenance_effect"])
           ),
         {:ok, aggregate} <- decode_label_entry(provenance["aggregate"], data["payload"]),
         minimum <-
           join_labels(
             [base] ++
               item_labels(nodes) ++
               item_labels(pending_facts) ++
               item_labels(pending_learnings) ++ item_labels(maintenance_effects)
           ),
         true <- label_dominates?(aggregate, minimum) do
      snapshot = %{
        graph: graph,
        payload: data["payload"],
        base_payload: base_payload(data["payload"]),
        base: base,
        aggregate: aggregate,
        nodes: nodes,
        pending_facts: pending_facts,
        pending_learnings: pending_learnings,
        maintenance_effects: maintenance_effects
      }

      normalize_outer_provenance(snapshot, outer_taint, outer_status)
    else
      _ -> {:error, :invalid_wrapper}
    end
  end

  defp decode_legacy(agent_id, data, outer_taint, outer_status) do
    with :ok <- legacy_preflight(agent_id, data),
         %KnowledgeGraph{} = graph <- KnowledgeGraph.from_map(data),
         {:ok, graph} <- normalize_legacy_graph(graph),
         {:ok, prepared} <- prepare(agent_id, graph),
         {:ok, outer_taint} <- Taint.canonicalize(outer_taint) do
      floor =
        join_labels([
          label_record(TaintEnvelope.missing_fallback(), :legacy_unlabeled),
          label_record(outer_taint, normalize_status(outer_status))
        ])

      nodes = label_inventory(prepared.nodes, floor)
      pending_facts = label_inventory(prepared.pending_facts, floor)
      pending_learnings = label_inventory(prepared.pending_learnings, floor)
      maintenance_effects = label_inventory(prepared.maintenance_effects, floor)

      {:ok,
       Map.merge(prepared, %{
         base: floor,
         aggregate: floor,
         nodes: nodes,
         pending_facts: pending_facts,
         pending_learnings: pending_learnings,
         maintenance_effects: maintenance_effects
       }), :migration}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  end

  defp normalize_outer_provenance(snapshot, outer_taint, :verified) do
    with {:ok, outer_taint} <- Taint.canonicalize(outer_taint),
         true <- outer_taint == snapshot.aggregate.taint do
      {:ok, snapshot, :current}
    else
      _ -> {:error, :invalid_wrapper}
    end
  end

  defp normalize_outer_provenance(snapshot, outer_taint, status)
       when status in [:legacy_unlabeled, :invalid_durable_provenance] do
    with {:ok, outer_taint} <- Taint.canonicalize(outer_taint) do
      floor =
        join_labels([
          label_record(TaintEnvelope.missing_fallback(), :legacy_unlabeled),
          label_record(outer_taint, normalize_status(status))
        ])

      base = join_labels([snapshot.base, floor])
      nodes = join_inventory_floor(snapshot.nodes, floor)
      pending_facts = join_inventory_floor(snapshot.pending_facts, floor)
      pending_learnings = join_inventory_floor(snapshot.pending_learnings, floor)
      maintenance_effects = join_inventory_floor(snapshot.maintenance_effects, floor)

      aggregate =
        join_labels(
          [snapshot.aggregate, base, floor] ++
            item_labels(nodes) ++
            item_labels(pending_facts) ++
            item_labels(pending_learnings) ++ item_labels(maintenance_effects)
        )

      {:ok,
       %{
         snapshot
         | base: base,
           aggregate: aggregate,
           nodes: nodes,
           pending_facts: pending_facts,
           pending_learnings: pending_learnings,
           maintenance_effects: maintenance_effects
       }, :migration}
    else
      _ -> {:error, :invalid_wrapper}
    end
  end

  defp normalize_outer_provenance(_snapshot, _outer_taint, _status),
    do: {:error, :invalid_wrapper}

  defp decode_graph_payload(agent_id, payload) do
    with true <- exact_string_keys?(payload, @payload_keys),
         true <- payload["agent_id"] == agent_id,
         :ok <- validate_identifier(agent_id),
         :ok <-
           validate_encoded_content_inventory(
             payload["nodes"],
             payload["pending_facts"],
             payload["pending_learnings"],
             payload["pending_maintenance_effect"]
           ),
         {:ok, nodes} <- decode_nodes(payload["nodes"]),
         {:ok, edges} <- decode_edges(payload["edges"], nodes),
         {:ok, pending_facts} <- decode_pending(payload["pending_facts"], :fact),
         {:ok, pending_learnings} <- decode_pending(payload["pending_learnings"], :learning),
         {:ok, pending_maintenance_effect} <-
           decode_maintenance_effect(payload["pending_maintenance_effect"]),
         :ok <- ensure_decoded_pending_ids_disjoint(pending_facts, pending_learnings),
         {:ok, operation_receipts} <-
           decode_operation_receipts(payload["operation_receipts"]),
         {:ok, operation_receipt_order} <-
           decode_operation_receipt_order(
             payload["operation_receipt_order"],
             operation_receipts
           ),
         :ok <-
           validate_maintenance_receipt_link(
             pending_maintenance_effect,
             operation_receipts
           ),
         {:ok, config} <- decode_config(payload["config"]),
         true <- valid_max_active?(payload["max_active"]),
         {:ok, active_set} <- decode_active_set(payload["active_set"], nodes),
         true <- length(active_set) <= payload["max_active"],
         true <- valid_ratio?(payload["dedup_threshold"]),
         {:ok, max_tokens} <- decode_max_tokens(payload["max_tokens"]),
         {:ok, type_quotas} <- decode_type_quotas(payload["type_quotas"]),
         {:ok, last_decay_at} <- decode_optional_datetime(payload["last_decay_at"]) do
      {:ok,
       %KnowledgeGraph{
         agent_id: agent_id,
         nodes: nodes,
         edges: edges,
         pending_facts: pending_facts,
         pending_learnings: pending_learnings,
         pending_maintenance_effect: pending_maintenance_effect,
         operation_receipts: operation_receipts,
         operation_receipt_order: operation_receipt_order,
         config: config,
         active_set: active_set,
         max_active: payload["max_active"],
         dedup_threshold: payload["dedup_threshold"],
         max_tokens: max_tokens,
         type_quotas: type_quotas,
         last_decay_at: last_decay_at
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_nodes(nodes) when is_map(nodes) and not is_struct(nodes) do
    if map_size(nodes) <= @max_content_items do
      Enum.reduce_while(nodes, {:ok, %{}}, fn {id, node}, {:ok, acc} ->
        with :ok <- validate_identifier(id),
             false <- Map.has_key?(acc, id),
             {:ok, encoded} <- encode_node(id, node) do
          {:cont, {:ok, Map.put(acc, id, encoded)}}
        else
          _ -> {:halt, {:error, :invalid_graph}}
        end
      end)
    else
      {:error, :graph_limit_exceeded}
    end
  end

  defp encode_nodes(_nodes), do: {:error, :invalid_graph}

  defp encode_node(id, node) when is_map(node) and not is_struct(node) do
    with {:ok, type} <- normalize_node_type(field(node, :type)),
         content when is_binary(content) <- field(node, :content),
         true <- valid_string?(content),
         true <- valid_ratio?(field(node, :relevance)),
         true <- valid_ratio?(field(node, :confidence, 0.5)),
         true <- valid_non_negative_integer?(field(node, :access_count, 0)),
         {:ok, created_at} <- encode_datetime(field(node, :created_at)),
         {:ok, last_accessed} <- encode_datetime(field(node, :last_accessed)),
         {:ok, metadata} <- encode_generic(field(node, :metadata, %{})),
         true <- is_boolean(field(node, :pinned, false)),
         true <- valid_non_negative_integer?(field(node, :cached_tokens, 0)),
         {:ok, referenced_date} <- encode_optional_datetime(field(node, :referenced_date)),
         true <- field(node, :id) == id do
      {:ok,
       %{
         "id" => id,
         "type" => Atom.to_string(type),
         "content" => content,
         "relevance" => field(node, :relevance),
         "confidence" => field(node, :confidence, 0.5),
         "access_count" => field(node, :access_count, 0),
         "created_at" => created_at,
         "last_accessed" => last_accessed,
         "metadata" => metadata,
         "pinned" => field(node, :pinned, false),
         "cached_tokens" => field(node, :cached_tokens, 0),
         "referenced_date" => referenced_date
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_node(_id, _node), do: {:error, :invalid_graph}

  defp decode_nodes(nodes) when is_map(nodes) and not is_struct(nodes) do
    if map_size(nodes) <= @max_content_items do
      Enum.reduce_while(nodes, {:ok, %{}}, fn {id, node}, {:ok, acc} ->
        case decode_node(id, node) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(acc, id, decoded)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :graph_limit_exceeded}
    end
  end

  defp decode_nodes(_nodes), do: {:error, :invalid_graph}

  defp decode_node(id, node) do
    with :ok <- validate_identifier(id),
         true <- exact_string_keys?(node, @node_keys),
         true <- node["id"] == id,
         {:ok, type} <- normalize_node_type(node["type"]),
         true <- valid_string?(node["content"]),
         true <- valid_ratio?(node["relevance"]),
         true <- valid_ratio?(node["confidence"]),
         true <- valid_non_negative_integer?(node["access_count"]),
         {:ok, created_at} <- decode_datetime(node["created_at"]),
         {:ok, last_accessed} <- decode_datetime(node["last_accessed"]),
         {:ok, metadata} <- decode_generic(node["metadata"]),
         true <- is_map(metadata) and not is_struct(metadata),
         true <- is_boolean(node["pinned"]),
         true <- valid_non_negative_integer?(node["cached_tokens"]),
         {:ok, referenced_date} <- decode_optional_datetime(node["referenced_date"]) do
      {:ok,
       %{
         id: id,
         type: type,
         content: node["content"],
         relevance: node["relevance"],
         confidence: node["confidence"],
         access_count: node["access_count"],
         created_at: created_at,
         last_accessed: last_accessed,
         metadata: metadata,
         pinned: node["pinned"],
         embedding: nil,
         cached_tokens: node["cached_tokens"],
         referenced_date: referenced_date
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_edges(edges, node_ids) when is_map(edges) and not is_struct(edges) do
    node_ids = MapSet.new(node_ids)

    with true <- map_size(edges) <= MapSet.size(node_ids),
         {:ok, encoded, _count, _ids, _logical_edges} <-
           Enum.reduce_while(
             edges,
             {:ok, %{}, 0, MapSet.new(), MapSet.new()},
             fn {source_id, source_edges}, {:ok, acc, count, ids, logical_edges} ->
               with true <- MapSet.member?(node_ids, source_id),
                    {:ok, values, count, ids, logical_edges} <-
                      encode_edge_list(
                        source_edges,
                        source_id,
                        node_ids,
                        count,
                        ids,
                        logical_edges
                      ) do
                 {:cont, {:ok, Map.put(acc, source_id, values), count, ids, logical_edges}}
               else
                 _ -> {:halt, {:error, :invalid_graph}}
               end
             end
           ) do
      {:ok, encoded}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_edges(_edges, _node_ids), do: {:error, :invalid_graph}

  defp encode_edge_list(edges, source_id, node_ids, count, ids, logical_edges) do
    reduce_bounded_list(
      edges,
      @max_edges - count,
      {:ok, [], count, ids, logical_edges},
      fn edge, {:ok, acc, n, seen_ids, seen_logical} ->
        with {:ok, encoded} <- encode_edge(edge, source_id, node_ids),
             logical <- {source_id, encoded["target_id"], encoded["relationship"]},
             false <- MapSet.member?(seen_ids, encoded["id"]),
             false <- MapSet.member?(seen_logical, logical) do
          {:ok, [encoded | acc], n + 1, MapSet.put(seen_ids, encoded["id"]),
           MapSet.put(seen_logical, logical)}
        else
          _ -> {:error, :invalid_graph}
        end
      end
    )
    |> case do
      {:ok, values, total, seen_ids, seen_logical} ->
        {:ok, Enum.reverse(values), total, seen_ids, seen_logical}

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_edge(edge, source_id, node_ids) when is_map(edge) and not is_struct(edge) do
    with id when is_binary(id) <- field(edge, :id),
         :ok <- validate_identifier(id),
         true <- field(edge, :source_id) == source_id,
         target_id when is_binary(target_id) <- field(edge, :target_id),
         true <- MapSet.member?(node_ids, target_id),
         {:ok, relationship} <- normalize_relationship(field(edge, :relationship)),
         true <- valid_edge_strength?(field(edge, :strength, field(edge, :weight, 1.0))),
         {:ok, created_at} <- encode_datetime(field(edge, :created_at)),
         {:ok, metadata} <- encode_generic(field(edge, :metadata, %{})) do
      {:ok,
       %{
         "id" => id,
         "source_id" => source_id,
         "target_id" => target_id,
         "relationship" => Atom.to_string(relationship),
         "strength" => field(edge, :strength, field(edge, :weight, 1.0)),
         "created_at" => created_at,
         "metadata" => metadata
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_edge(_edge, _source_id, _node_ids), do: {:error, :invalid_graph}

  defp decode_edges(edges, nodes) when is_map(edges) and not is_struct(edges) do
    node_ids = Map.keys(nodes) |> MapSet.new()

    with true <- map_size(edges) <= MapSet.size(node_ids),
         {:ok, decoded, _count, _ids, _logical_edges} <-
           Enum.reduce_while(
             edges,
             {:ok, %{}, 0, MapSet.new(), MapSet.new()},
             fn {source_id, source_edges}, {:ok, acc, count, ids, logical_edges} ->
               with true <- MapSet.member?(node_ids, source_id),
                    {:ok, values, count, ids, logical_edges} <-
                      decode_edge_list(
                        source_edges,
                        source_id,
                        node_ids,
                        count,
                        ids,
                        logical_edges
                      ) do
                 {:cont, {:ok, Map.put(acc, source_id, values), count, ids, logical_edges}}
               else
                 _ -> {:halt, {:error, :invalid_graph}}
               end
             end
           ) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_edges(_edges, _nodes), do: {:error, :invalid_graph}

  defp decode_edge_list(edges, source_id, node_ids, count, ids, logical_edges) do
    reduce_bounded_list(
      edges,
      @max_edges - count,
      {:ok, [], count, ids, logical_edges},
      fn edge, {:ok, acc, n, seen_ids, seen_logical} ->
        with {:ok, decoded} <- decode_edge(edge, source_id, node_ids),
             logical <- {source_id, decoded.target_id, decoded.relationship},
             false <- MapSet.member?(seen_ids, decoded.id),
             false <- MapSet.member?(seen_logical, logical) do
          {:ok, [decoded | acc], n + 1, MapSet.put(seen_ids, decoded.id),
           MapSet.put(seen_logical, logical)}
        else
          _ -> {:error, :invalid_graph}
        end
      end
    )
    |> case do
      {:ok, values, total, seen_ids, seen_logical} ->
        {:ok, Enum.reverse(values), total, seen_ids, seen_logical}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_edge(edge, source_id, node_ids) do
    with true <- exact_string_keys?(edge, @edge_keys),
         :ok <- validate_identifier(edge["id"]),
         true <- edge["source_id"] == source_id,
         true <- MapSet.member?(node_ids, edge["target_id"]),
         {:ok, relationship} <- normalize_relationship(edge["relationship"]),
         true <- valid_edge_strength?(edge["strength"]),
         {:ok, created_at} <- decode_datetime(edge["created_at"]),
         {:ok, metadata} <- decode_generic(edge["metadata"]),
         true <- is_map(metadata) and not is_struct(metadata) do
      {:ok,
       %{
         id: edge["id"],
         source_id: source_id,
         target_id: edge["target_id"],
         relationship: relationship,
         strength: edge["strength"],
         created_at: created_at,
         metadata: metadata
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_pending(items, expected_type) do
    reduce_bounded_list(items, @max_content_items, {:ok, [], MapSet.new()}, fn item,
                                                                               {:ok, acc, ids} ->
      with {:ok, encoded} <- encode_pending_item(item, expected_type),
           false <- MapSet.member?(ids, encoded["id"]) do
        {:ok, [encoded | acc], MapSet.put(ids, encoded["id"])}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
    |> case do
      {:ok, values, _ids} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp encode_pending_item(item, expected_type) when is_map(item) and not is_struct(item) do
    with id when is_binary(id) <- field(item, :id),
         :ok <- validate_identifier(id),
         type <- field(item, :type),
         true <- type in [expected_type, Atom.to_string(expected_type)],
         true <- valid_string?(field(item, :content)),
         true <- valid_ratio?(field(item, :confidence, 0.5)),
         source <- field(item, :source),
         true <- is_nil(source) or valid_string?(source),
         {:ok, extracted_at} <- encode_datetime(field(item, :extracted_at)),
         {:ok, metadata} <- encode_generic(field(item, :metadata, %{})) do
      {:ok,
       %{
         "id" => id,
         "type" => Atom.to_string(expected_type),
         "content" => field(item, :content),
         "confidence" => field(item, :confidence, 0.5),
         "source" => source,
         "extracted_at" => extracted_at,
         "metadata" => metadata
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_pending_item(_item, _expected_type), do: {:error, :invalid_graph}

  defp decode_pending(items, expected_type) do
    reduce_bounded_list(items, @max_content_items, {:ok, [], MapSet.new()}, fn item,
                                                                               {:ok, acc, ids} ->
      with {:ok, decoded} <- decode_pending_item(item, expected_type),
           false <- MapSet.member?(ids, decoded.id) do
        {:ok, [decoded | acc], MapSet.put(ids, decoded.id)}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
    |> case do
      {:ok, values, _ids} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_pending_item(item, expected_type) do
    with true <- exact_string_keys?(item, @pending_keys),
         :ok <- validate_identifier(item["id"]),
         true <- item["type"] == Atom.to_string(expected_type),
         true <- valid_string?(item["content"]),
         true <- valid_ratio?(item["confidence"]),
         true <- is_nil(item["source"]) or valid_string?(item["source"]),
         {:ok, extracted_at} <- decode_datetime(item["extracted_at"]),
         {:ok, metadata} <- decode_generic(item["metadata"]),
         true <- is_map(metadata) and not is_struct(metadata) do
      {:ok,
       %{
         id: item["id"],
         type: expected_type,
         content: item["content"],
         confidence: item["confidence"],
         source: item["source"],
         extracted_at: extracted_at,
         metadata: metadata
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_maintenance_effect(nil), do: {:ok, nil}

  defp encode_maintenance_effect(effect) when is_map(effect) and not is_struct(effect) do
    with :ok <- validate_legacy_map_shape(effect, @maintenance_effect_keys),
         :ok <- validate_identifier(field(effect, :operation_id)),
         {:ok, mode} <- normalize_maintenance_mode(field(effect, :mode)),
         {:ok, occurred_at} <- encode_datetime(field(effect, :occurred_at)),
         {:ok, archive_entries} <-
           encode_maintenance_archive_entries(field(effect, :archive_entries)),
         {:ok, metrics} <- encode_maintenance_metrics(field(effect, :metrics)) do
      {:ok,
       %{
         "operation_id" => field(effect, :operation_id),
         "mode" => Atom.to_string(mode),
         "occurred_at" => occurred_at,
         "archive_entries" => archive_entries,
         "metrics" => metrics
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_maintenance_effect(_effect), do: {:error, :invalid_graph}

  defp decode_maintenance_effect(nil), do: {:ok, nil}

  defp decode_maintenance_effect(effect) when is_map(effect) and not is_struct(effect) do
    with true <- exact_string_keys?(effect, @maintenance_effect_keys),
         :ok <- validate_identifier(effect["operation_id"]),
         {:ok, mode} <- normalize_maintenance_mode(effect["mode"]),
         {:ok, occurred_at} <- decode_datetime(effect["occurred_at"]),
         {:ok, archive_entries} <-
           decode_maintenance_archive_entries(effect["archive_entries"]),
         {:ok, metrics} <- decode_maintenance_metrics(effect["metrics"]) do
      {:ok,
       %{
         operation_id: effect["operation_id"],
         mode: mode,
         occurred_at: occurred_at,
         archive_entries: archive_entries,
         metrics: metrics
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_maintenance_effect(_effect), do: {:error, :invalid_graph}

  defp encode_maintenance_archive_entries(entries) do
    reduce_bounded_list(entries, @max_content_items, {:ok, [], MapSet.new()}, fn entry,
                                                                                 {:ok, acc, seen} ->
      with true <- is_map(entry) and not is_struct(entry),
           :ok <- validate_legacy_map_shape(entry, @maintenance_archive_entry_keys),
           node when is_map(node) and not is_struct(node) <- field(entry, :node),
           id when is_binary(id) <- field(node, :id),
           false <- MapSet.member?(seen, id),
           {:ok, encoded_node} <- encode_node(id, node),
           {:ok, reason} <- normalize_maintenance_reason(field(entry, :reason)) do
        encoded = %{"node" => encoded_node, "reason" => Atom.to_string(reason)}
        {:ok, [encoded | acc], MapSet.put(seen, id)}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
    |> case do
      {:ok, reversed, _seen} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_maintenance_archive_entries(entries) do
    reduce_bounded_list(entries, @max_content_items, {:ok, [], MapSet.new()}, fn entry,
                                                                                 {:ok, acc, seen} ->
      with true <- exact_string_keys?(entry, @maintenance_archive_entry_keys),
           node when is_map(node) and not is_struct(node) <- entry["node"],
           id when is_binary(id) <- node["id"],
           false <- MapSet.member?(seen, id),
           {:ok, decoded_node} <- decode_node(id, node),
           {:ok, reason} <- normalize_maintenance_reason(entry["reason"]) do
        {:ok, [%{node: decoded_node, reason: reason} | acc], MapSet.put(seen, id)}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
    |> case do
      {:ok, reversed, _seen} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp encode_maintenance_metrics(metrics)
       when is_map(metrics) and not is_struct(metrics) do
    with :ok <- validate_legacy_map_shape(metrics, @maintenance_metric_keys),
         normalized <-
           Map.new(@maintenance_metric_keys, fn key ->
             {key, field(metrics, Map.fetch!(@semantic_atoms_by_name, key))}
           end),
         true <- exact_string_keys?(normalized, @maintenance_metric_keys),
         true <- valid_maintenance_metrics?(normalized) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_maintenance_metrics(_metrics), do: {:error, :invalid_graph}

  defp decode_maintenance_metrics(metrics)
       when is_map(metrics) and not is_struct(metrics) do
    with true <- exact_string_keys?(metrics, @maintenance_metric_keys),
         true <- valid_maintenance_metrics?(metrics) do
      {:ok,
       Map.new(metrics, fn {key, value} ->
         {Map.fetch!(@semantic_atoms_by_name, key), value}
       end)}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_maintenance_metrics(_metrics), do: {:error, :invalid_graph}

  defp valid_maintenance_metrics?(metrics) do
    Enum.all?(
      @maintenance_metric_keys -- ["average_relevance"],
      &valid_non_negative_integer?(metrics[&1])
    ) and valid_ratio?(metrics["average_relevance"])
  end

  defp normalize_maintenance_mode(value) when is_atom(value),
    do: normalize_maintenance_mode(Atom.to_string(value))

  defp normalize_maintenance_mode(value) when value in @maintenance_modes,
    do: {:ok, Map.fetch!(@semantic_atoms_by_name, value)}

  defp normalize_maintenance_mode(_value), do: {:error, :invalid_graph}

  defp normalize_maintenance_reason(value) when is_atom(value),
    do: normalize_maintenance_reason(Atom.to_string(value))

  defp normalize_maintenance_reason(value) when value in @maintenance_reasons,
    do: {:ok, Map.fetch!(@semantic_atoms_by_name, value)}

  defp normalize_maintenance_reason(_value), do: {:error, :invalid_graph}

  defp encode_operation_receipts(receipts)
       when is_map(receipts) and not is_struct(receipts) and
              map_size(receipts) <= @max_operation_receipts do
    Enum.reduce_while(receipts, {:ok, %{}}, fn {operation_id, receipt}, {:ok, acc} ->
      with :ok <- validate_identifier(operation_id),
           {:ok, normalized} <- normalize_operation_receipt(receipt),
           {:ok, result} <-
             encode_operation_receipt_result(normalized.kind, normalized.result) do
        encoded = %{
          "kind" => normalized.kind,
          "fingerprint" => normalized.fingerprint,
          "result" => result
        }

        {:cont, {:ok, Map.put(acc, operation_id, encoded)}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp encode_operation_receipts(_receipts), do: {:error, :graph_limit_exceeded}

  defp decode_operation_receipts(receipts)
       when is_map(receipts) and not is_struct(receipts) and
              map_size(receipts) <= @max_operation_receipts do
    Enum.reduce_while(receipts, {:ok, %{}}, fn {operation_id, receipt}, {:ok, acc} ->
      with :ok <- validate_identifier(operation_id),
           true <- exact_string_keys?(receipt, @operation_receipt_keys),
           {:ok, normalized} <- normalize_operation_receipt(receipt) do
        {:cont, {:ok, Map.put(acc, operation_id, normalized)}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp decode_operation_receipts(_receipts), do: {:error, :graph_limit_exceeded}

  defp normalize_operation_receipts(receipts)
       when is_map(receipts) and not is_struct(receipts) and
              map_size(receipts) <= @max_operation_receipts do
    Enum.reduce_while(receipts, {:ok, %{}}, fn {operation_id, receipt}, {:ok, acc} ->
      with :ok <- validate_identifier(operation_id),
           true <- is_map(receipt) and not is_struct(receipt),
           :ok <- validate_legacy_map_shape(receipt, @operation_receipt_keys),
           {:ok, normalized} <- normalize_operation_receipt(receipt) do
        {:cont, {:ok, Map.put(acc, operation_id, normalized)}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp normalize_operation_receipts(_receipts), do: {:error, :graph_limit_exceeded}

  defp normalize_operation_receipt(receipt) when is_map(receipt) and not is_struct(receipt) do
    kind = field(receipt, :kind)
    fingerprint = field(receipt, :fingerprint)
    result = field(receipt, :result)

    kind = if is_atom(kind), do: Atom.to_string(kind), else: kind

    with true <- kind in @operation_kinds,
         true <- valid_fingerprint?(fingerprint),
         {:ok, result} <- normalize_operation_receipt_result(kind, result) do
      {:ok, %{kind: kind, fingerprint: fingerprint, result: result}}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp normalize_operation_receipt(_receipt), do: {:error, :invalid_graph}

  defp normalize_operation_receipt_result("consolidate", result)
       when is_map(result) and not is_struct(result) do
    with :ok <- validate_legacy_map_shape(result, @maintenance_receipt_keys),
         status when status in ["pending", "drained"] <- field(result, :status),
         {:ok, metrics} <- encode_maintenance_metrics(field(result, :metrics)),
         {:ok, metrics} <- decode_maintenance_metrics(metrics) do
      {:ok, %{status: status, metrics: metrics}}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp normalize_operation_receipt_result("consolidate", _result),
    do: {:error, :invalid_graph}

  defp normalize_operation_receipt_result(_kind, result) do
    with :ok <- validate_identifier(result), do: {:ok, result}
  end

  defp encode_operation_receipt_result("consolidate", %{status: status, metrics: metrics}) do
    with true <- status in ["pending", "drained"],
         {:ok, metrics} <- encode_maintenance_metrics(metrics) do
      {:ok, %{"status" => status, "metrics" => metrics}}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_operation_receipt_result(_kind, result) when is_binary(result),
    do: {:ok, result}

  defp encode_operation_receipt_result(_kind, _result), do: {:error, :invalid_graph}

  defp encode_operation_receipt_order(order, receipts) do
    reduce_bounded_list(order, @max_operation_receipts, {:ok, [], MapSet.new()}, fn operation_id,
                                                                                    {:ok, acc,
                                                                                     seen} ->
      with :ok <- validate_identifier(operation_id),
           true <- Map.has_key?(receipts, operation_id),
           false <- MapSet.member?(seen, operation_id) do
        {:ok, [operation_id | acc], MapSet.put(seen, operation_id)}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
    |> case do
      {:ok, reversed, seen} ->
        if map_size(receipts) == MapSet.size(seen),
          do: {:ok, Enum.reverse(reversed)},
          else: {:error, :invalid_graph}

      _ ->
        {:error, :invalid_graph}
    end
  end

  defp decode_operation_receipt_order(order, receipts),
    do: encode_operation_receipt_order(order, receipts)

  defp validate_maintenance_receipt_link(nil, receipts) do
    if Enum.any?(receipts, fn {_id, receipt} -> pending_maintenance_receipt?(receipt) end),
      do: {:error, :invalid_graph},
      else: :ok
  end

  defp validate_maintenance_receipt_link(
         %{operation_id: operation_id, metrics: metrics},
         receipts
       ) do
    case Map.fetch(receipts, operation_id) do
      {:ok, %{kind: "consolidate", result: %{status: "pending", metrics: ^metrics}}} -> :ok
      _ -> {:error, :invalid_graph}
    end
  end

  defp pending_maintenance_receipt?(%{
         kind: "consolidate",
         result: %{status: "pending"}
       }),
       do: true

  defp pending_maintenance_receipt?(_receipt), do: false

  defp encode_active_set(active_set, node_ids) do
    node_ids = MapSet.new(node_ids)

    reduce_bounded_list(active_set, @max_content_items, {:ok, [], MapSet.new()}, fn id,
                                                                                    {:ok, acc,
                                                                                     seen} ->
      with :ok <- validate_identifier(id),
           true <- MapSet.member?(node_ids, id),
           false <- MapSet.member?(seen, id) do
        {:ok, [id | acc], MapSet.put(seen, id)}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
    |> case do
      {:ok, values, _seen} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_active_set(active_set, nodes), do: encode_active_set(active_set, Map.keys(nodes))

  defp validate_content_inventory(
         nodes,
         pending_facts,
         pending_learnings,
         pending_maintenance_effect
       )
       when is_map(nodes) and not is_struct(nodes) do
    with {:ok, facts_count} <- bounded_list_count(pending_facts, @max_content_items),
         {:ok, learning_count} <-
           bounded_list_count(pending_learnings, @max_content_items - facts_count),
         {:ok, maintenance_count} <-
           bounded_maintenance_entry_count(
             pending_maintenance_effect,
             @max_content_items - facts_count - learning_count
           ),
         true <-
           map_size(nodes) + facts_count + learning_count + maintenance_count <=
             @max_content_items do
      :ok
    else
      _ -> {:error, :graph_limit_exceeded}
    end
  end

  defp validate_content_inventory(
         _nodes,
         _pending_facts,
         _pending_learnings,
         _pending_maintenance_effect
       ),
       do: {:error, :invalid_graph}

  defp validate_encoded_content_inventory(
         nodes,
         pending_facts,
         pending_learnings,
         pending_maintenance_effect
       ),
       do:
         validate_content_inventory(
           nodes,
           pending_facts,
           pending_learnings,
           pending_maintenance_effect
         )

  defp bounded_maintenance_entry_count(nil, _limit), do: {:ok, 0}

  defp bounded_maintenance_entry_count(effect, limit)
       when is_map(effect) and not is_struct(effect) and limit >= 0 do
    case field(effect, :archive_entries) do
      entries when is_list(entries) -> bounded_list_count(entries, limit)
      _ -> {:error, :graph_limit_exceeded}
    end
  end

  defp bounded_maintenance_entry_count(_effect, _limit),
    do: {:error, :graph_limit_exceeded}

  defp legacy_preflight(agent_id, data) when is_map(data) and not is_struct(data) do
    with :ok <- validate_legacy_map_shape(data, @payload_keys),
         true <- field(data, :agent_id) == agent_id,
         nodes when is_map(nodes) and not is_struct(nodes) <- field(data, :nodes),
         edges when is_map(edges) and not is_struct(edges) <- field(data, :edges),
         pending_facts when is_list(pending_facts) <- field(data, :pending_facts, []),
         pending_learnings when is_list(pending_learnings) <- field(data, :pending_learnings, []),
         :ok <-
           validate_content_inventory(
             nodes,
             pending_facts,
             pending_learnings,
             field(data, :pending_maintenance_effect)
           ),
         :ok <- legacy_node_preflight(nodes),
         :ok <- legacy_edge_preflight(edges),
         {:ok, fact_ids} <- legacy_pending_preflight(pending_facts, :fact),
         {:ok, learning_ids} <- legacy_pending_preflight(pending_learnings, :learning),
         true <- MapSet.disjoint?(fact_ids, learning_ids),
         :ok <-
           legacy_operation_receipts_preflight(field(data, :operation_receipts, %{})),
         :ok <-
           legacy_operation_receipt_order_preflight(
             field(data, :operation_receipt_order, []),
             field(data, :operation_receipts, %{})
           ),
         {:ok, _maintenance_effect} <-
           encode_maintenance_effect(field(data, :pending_maintenance_effect)),
         :ok <- legacy_config_preflight(field(data, :config, %{})),
         :ok <- legacy_type_quotas_preflight(field(data, :type_quotas, %{})) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp legacy_preflight(_agent_id, _data), do: {:error, :invalid_graph}

  defp legacy_node_preflight(nodes) do
    Enum.reduce_while(nodes, :ok, fn {id, node}, :ok ->
      with :ok <- validate_identifier(id),
           true <- is_map(node) and not is_struct(node),
           :ok <- validate_legacy_map_shape(node, @legacy_node_keys),
           true <- field(node, :id) == id,
           metadata when is_map(metadata) and not is_struct(metadata) <-
             field(node, :metadata, %{}),
           false <- Map.has_key?(metadata, @accepted_proposal_key),
           {:ok, _encoded} <- encode_generic(metadata) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp legacy_edge_preflight(edges) when map_size(edges) <= @max_content_items do
    Enum.reduce_while(edges, {:ok, 0}, fn {source_id, values}, {:ok, count} ->
      with :ok <- validate_identifier(source_id),
           {:ok, value_count} <- bounded_list_count(values, @max_edges - count),
           :ok <- legacy_edge_list_preflight(values) do
        {:cont, {:ok, count + value_count}}
      else
        {:error, _reason} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
    |> case do
      {:ok, _count} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp legacy_edge_preflight(_edges), do: {:error, :graph_limit_exceeded}

  defp legacy_edge_list_preflight(edges) do
    Enum.reduce_while(edges, :ok, fn edge, :ok ->
      with true <- is_map(edge) and not is_struct(edge),
           :ok <- validate_legacy_map_shape(edge, @legacy_edge_keys),
           metadata when is_map(metadata) and not is_struct(metadata) <-
             field(edge, :metadata, %{}),
           {:ok, _encoded} <- encode_generic(metadata) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp legacy_pending_preflight(items, expected_type) do
    Enum.reduce_while(items, {:ok, MapSet.new()}, fn item, {:ok, ids} ->
      with true <- is_map(item) and not is_struct(item),
           :ok <- validate_legacy_map_shape(item, @pending_keys),
           id when is_binary(id) <- field(item, :id),
           :ok <- validate_identifier(id),
           false <- MapSet.member?(ids, id),
           type <- field(item, :type),
           true <- type in [expected_type, Atom.to_string(expected_type)],
           metadata when is_map(metadata) and not is_struct(metadata) <-
             field(item, :metadata, %{}),
           {:ok, _encoded} <- encode_generic(metadata) do
        {:cont, {:ok, MapSet.put(ids, id)}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp legacy_operation_receipts_preflight(receipts) do
    with {:ok, _normalized} <- normalize_operation_receipts(receipts) do
      :ok
    end
  end

  defp legacy_operation_receipt_order_preflight(order, receipts) do
    with {:ok, receipts} <- normalize_operation_receipts(receipts),
         {:ok, _order} <- encode_operation_receipt_order(order, receipts) do
      :ok
    end
  end

  defp legacy_config_preflight(config) when is_map(config) and not is_struct(config) do
    with :ok <- validate_legacy_map_shape(config, @config_keys),
         {:ok, normalized} <- normalize_legacy_config(config),
         :ok <- validate_config(normalized) do
      :ok
    end
  end

  defp legacy_config_preflight(_config), do: {:error, :invalid_graph}

  defp legacy_type_quotas_preflight(quotas) when is_map(quotas) and not is_struct(quotas) do
    with {:ok, normalized} <- normalize_type_quotas(quotas),
         :ok <- validate_type_quotas(normalized) do
      :ok
    end
  end

  defp legacy_type_quotas_preflight(_quotas), do: {:error, :invalid_graph}

  defp validate_legacy_map_shape(map, allowed_keys) do
    names =
      Enum.map(Map.keys(map), fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _key -> :invalid
      end)

    cond do
      map_size(map) > length(allowed_keys) -> {:error, :invalid_graph}
      :invalid in names -> {:error, :invalid_graph}
      Enum.any?(names, &(&1 not in allowed_keys)) -> {:error, :invalid_graph}
      not no_alias_keys?(map, allowed_keys) -> {:error, :invalid_graph}
      true -> :ok
    end
  end

  defp encode_labelled_inventory(inventory) when is_map(inventory) and not is_struct(inventory) do
    if map_size(inventory) <= @max_content_items do
      Enum.reduce_while(inventory, {:ok, %{}}, fn {id, item}, {:ok, acc} ->
        case encode_label_entry(item.payload, item.label) do
          {:ok, entry} -> {:cont, {:ok, Map.put(acc, id, entry)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :graph_limit_exceeded}
    end
  end

  defp encode_labelled_inventory(_inventory), do: {:error, :invalid_wrapper}

  defp decode_labelled_inventory(persisted, payloads)
       when is_map(persisted) and not is_struct(persisted) and is_map(payloads) and
              not is_struct(payloads) do
    if map_size(persisted) == map_size(payloads) and
         MapSet.new(Map.keys(persisted)) == MapSet.new(Map.keys(payloads)) do
      Enum.reduce_while(payloads, {:ok, %{}}, fn {id, payload}, {:ok, acc} ->
        case decode_label_entry(persisted[id], payload) do
          {:ok, label} -> {:cont, {:ok, Map.put(acc, id, %{payload: payload, label: label})}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_wrapper}
    end
  end

  defp decode_labelled_inventory(_persisted, _payloads), do: {:error, :invalid_wrapper}

  defp encode_label_entry(payload, label) do
    with {:ok, envelope} <- TaintEnvelope.new(payload, label.taint),
         {:ok, envelope} <- TaintEnvelope.to_map(envelope),
         true <- label.status == status_for_taint(label.taint) do
      {:ok, %{"envelope" => envelope, "status" => Atom.to_string(label.status)}}
    else
      _ -> {:error, :invalid_wrapper}
    end
  end

  defp decode_label_entry(entry, payload) do
    with true <- exact_string_keys?(entry, @entry_keys),
         {:ok, envelope} <- TaintEnvelope.verify(entry["envelope"], payload),
         {:ok, status} <- decode_status(entry["status"]),
         true <- status == status_for_taint(envelope.taint) do
      {:ok, label_record(envelope.taint, status)}
    else
      _ -> {:error, :invalid_wrapper}
    end
  end

  defp normalize_reconciliation_context(context)
       when is_map(context) and not is_struct(context) and map_size(context) <= 3 do
    allowed = [:accepted_pending, :archived_node_ids, :provenance_neutral]

    with true <- Enum.all?(Map.keys(context), &(&1 in allowed)),
         {:ok, accepted_pending} <-
           normalize_accepted_pending(Map.get(context, :accepted_pending, %{})),
         {:ok, archived_node_ids} <-
           normalize_archived_node_ids(Map.get(context, :archived_node_ids, [])),
         provenance_neutral when is_boolean(provenance_neutral) <-
           Map.get(context, :provenance_neutral, false) do
      {:ok,
       %{
         accepted_pending: accepted_pending,
         archived_node_ids: archived_node_ids,
         provenance_neutral: provenance_neutral
       }}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp normalize_reconciliation_context(_context), do: {:error, :invalid_graph}

  defp normalize_accepted_pending(transfers)
       when is_map(transfers) and not is_struct(transfers) and map_size(transfers) <= 1 do
    Enum.reduce_while(transfers, {:ok, %{}}, fn {node_id, pending_id}, {:ok, acc} ->
      with :ok <- validate_identifier(node_id),
           :ok <- validate_identifier(pending_id) do
        {:cont, {:ok, Map.put(acc, node_id, pending_id)}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp normalize_accepted_pending(_transfers), do: {:error, :invalid_graph}

  defp normalize_archived_node_ids(node_ids) do
    reduce_bounded_list(node_ids, @max_content_items, {:ok, MapSet.new()}, fn node_id,
                                                                              {:ok, seen} ->
      with :ok <- validate_identifier(node_id),
           false <- MapSet.member?(seen, node_id) do
        {:ok, MapSet.put(seen, node_id)}
      else
        _ -> {:error, :invalid_graph}
      end
    end)
  end

  defp reconcile_items(current, previous, supplied) do
    Map.new(current, fn {id, payload} ->
      prior = Map.get(previous, id)
      label = reconcile_label(payload, item_payload(prior), item_label(prior), supplied)
      {id, %{payload: payload, label: label}}
    end)
  end

  defp reconcile_nodes(current, previous, supplied, accepted_pending) do
    previous_nodes = previous_items(previous, :nodes)

    Map.new(current, fn {id, payload} ->
      prior = Map.get(previous_nodes, id)

      label =
        case prior do
          nil ->
            transferred_pending_label(id, payload, previous, accepted_pending) || supplied

          prior ->
            reconcile_label(payload, item_payload(prior), item_label(prior), supplied)
        end

      {id, %{payload: payload, label: label}}
    end)
  end

  defp transferred_pending_label(node_id, payload, previous, accepted_pending)
       when is_map(previous) do
    with pending_id when is_binary(pending_id) <- Map.get(accepted_pending, node_id),
         %{payload: pending_payload, label: label} <- previous_pending_item(previous, pending_id),
         true <- accepted_node_matches_pending?(payload, pending_payload) do
      label
    else
      _ -> nil
    end
  end

  defp transferred_pending_label(_node_id, _payload, _previous, _accepted_pending), do: nil

  defp previous_pending_item(previous, pending_id) do
    Map.get(previous_items(previous, :pending_facts), pending_id) ||
      Map.get(previous_items(previous, :pending_learnings), pending_id)
  end

  defp accepted_node_matches_pending?(node_payload, pending_payload) do
    expected_type = if pending_payload["type"] == "fact", do: "fact", else: "skill"

    pending_payload["type"] in ["fact", "learning"] and
      node_payload["type"] == expected_type and
      node_payload["content"] == pending_payload["content"]
  end

  defp reconcile_maintenance_effects(current, previous, supplied, archived_node_ids) do
    previous_effects = previous_items(previous, :maintenance_effects)
    previous_nodes = previous_items(previous, :nodes)

    Map.new(current, fn {id, payload} ->
      prior = Map.get(previous_effects, id)

      label =
        cond do
          prior != nil ->
            reconcile_label(payload, item_payload(prior), item_label(prior), supplied)

          MapSet.member?(archived_node_ids, id) and Map.has_key?(previous_nodes, id) ->
            previous_nodes |> Map.fetch!(id) |> item_label()

          true ->
            supplied
        end

      {id, %{payload: payload, label: label}}
    end)
  end

  defp reconcile_label(payload, payload, %{} = previous, _supplied), do: previous
  defp reconcile_label(_payload, _previous_payload, nil, supplied), do: supplied

  defp reconcile_label(_payload, _previous_payload, previous, supplied),
    do: join_labels([previous, supplied])

  defp label_inventory(inventory, label) do
    Map.new(inventory, fn {id, payload} -> {id, %{payload: payload, label: label}} end)
  end

  defp join_inventory_floor(inventory, floor) do
    Map.new(inventory, fn {id, item} ->
      {id, %{item | label: join_labels([item.label, floor])}}
    end)
  end

  defp previous_value(nil, _key), do: nil
  defp previous_value(previous, key), do: Map.get(previous, key)
  defp previous_label(nil, _key), do: nil
  defp previous_label(previous, key), do: Map.get(previous, key)
  defp previous_items(nil, _key), do: %{}
  defp previous_items(previous, key), do: Map.get(previous, key, %{})
  defp item_payload(nil), do: nil
  defp item_payload(item), do: Map.get(item, :payload)
  defp item_label(nil), do: nil
  defp item_label(item), do: Map.get(item, :label)
  defp item_labels(inventory), do: Enum.map(inventory, fn {_id, item} -> item.label end)

  defp join_labels([first | rest]) do
    Enum.reduce(rest, first, fn right, left ->
      taint =
        case Taint.join(left.taint, right.taint) do
          {:ok, joined} -> joined
          {:error, _reason} -> TaintEnvelope.invalid_fallback()
        end

      label_record(taint, worst_status([left.status, right.status, status_for_taint(taint)]))
    end)
  end

  defp label_dominates?(candidate, minimum) do
    case Taint.join(candidate.taint, minimum.taint) do
      {:ok, joined} ->
        joined == candidate.taint and
          worst_status([candidate.status, minimum.status]) == candidate.status

      {:error, _reason} ->
        false
    end
  end

  defp label_record(taint, status), do: %{taint: taint, status: status}

  defp status_for_taint(taint) do
    labels = [taint.source | taint.chain]

    cond do
      taint == TaintEnvelope.invalid_fallback() -> :invalid_durable_provenance
      "legacy_unlabeled" in labels -> :legacy_unlabeled
      true -> :verified
    end
  end

  defp normalize_status(status)
       when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance],
       do: status

  defp normalize_status(_status), do: :invalid_durable_provenance

  defp worst_status(statuses) do
    cond do
      :invalid_durable_provenance in statuses -> :invalid_durable_provenance
      :legacy_unlabeled in statuses -> :legacy_unlabeled
      true -> :verified
    end
  end

  defp decode_status("verified"), do: {:ok, :verified}
  defp decode_status("legacy_unlabeled"), do: {:ok, :legacy_unlabeled}

  defp decode_status("invalid_durable_provenance"),
    do: {:ok, :invalid_durable_provenance}

  defp decode_status(_status), do: {:error, :invalid_wrapper}

  defp base_payload(payload),
    do:
      Map.drop(payload, [
        "nodes",
        "pending_facts",
        "pending_learnings",
        "pending_maintenance_effect"
      ])

  defp index_pending(items), do: Map.new(items, &{&1["id"], &1})

  defp index_maintenance_effect(nil), do: %{}

  defp index_maintenance_effect(%{"archive_entries" => entries}) do
    Map.new(entries, fn entry -> {entry["node"]["id"], entry} end)
  end

  defp ensure_pending_ids_disjoint(facts, learnings) do
    fact_ids = MapSet.new(facts, & &1["id"])
    learning_ids = MapSet.new(learnings, & &1["id"])

    if MapSet.disjoint?(fact_ids, learning_ids),
      do: :ok,
      else: {:error, :invalid_graph}
  end

  defp ensure_decoded_pending_ids_disjoint(facts, learnings) do
    fact_ids = MapSet.new(facts, & &1.id)
    learning_ids = MapSet.new(learnings, & &1.id)

    if MapSet.disjoint?(fact_ids, learning_ids),
      do: :ok,
      else: {:error, :invalid_graph}
  end

  defp normalize_legacy_graph(%KnowledgeGraph{} = graph) do
    with {:ok, config} <- normalize_legacy_config(graph.config),
         {:ok, type_quotas} <- normalize_type_quotas(graph.type_quotas),
         {:ok, operation_receipts} <-
           normalize_operation_receipts(graph.operation_receipts),
         {:ok, operation_receipt_order} <-
           encode_operation_receipt_order(
             graph.operation_receipt_order,
             operation_receipts
           ),
         {:ok, encoded_maintenance_effect} <-
           encode_maintenance_effect(graph.pending_maintenance_effect),
         {:ok, pending_maintenance_effect} <-
           decode_maintenance_effect(encoded_maintenance_effect),
         :ok <-
           validate_maintenance_receipt_link(
             pending_maintenance_effect,
             operation_receipts
           ) do
      {:ok,
       %{
         graph
         | config: config,
           type_quotas: type_quotas,
           pending_maintenance_effect: pending_maintenance_effect,
           operation_receipts: operation_receipts,
           operation_receipt_order: operation_receipt_order
       }}
    end
  end

  defp normalize_legacy_config(config) when is_map(config) and not is_struct(config) do
    normalized = %{
      auto_embed: field(config, :auto_embed, true),
      decay_rate: field(config, :decay_rate, 0.10),
      max_nodes_per_type: field(config, :max_nodes_per_type, 500),
      prune_threshold: field(config, :prune_threshold, 0.10)
    }

    case validate_config(normalized) do
      :ok -> {:ok, normalized}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_legacy_config(_config), do: {:error, :invalid_graph}

  defp encode_config(config) do
    with :ok <- validate_config(config) do
      encode_generic(config)
    end
  end

  defp decode_config(encoded) do
    with {:ok, config} <- decode_generic(encoded),
         :ok <- validate_config(config) do
      {:ok, config}
    end
  end

  defp validate_config(config) when is_map(config) and not is_struct(config) do
    if Map.keys(config) |> Enum.sort() ==
         [:auto_embed, :decay_rate, :max_nodes_per_type, :prune_threshold] do
      cond do
        not is_boolean(config.auto_embed) -> {:error, :invalid_graph}
        not valid_ratio?(config.decay_rate) -> {:error, :invalid_graph}
        not valid_positive_integer?(config.max_nodes_per_type) -> {:error, :invalid_graph}
        config.max_nodes_per_type > 1_000_000 -> {:error, :invalid_graph}
        not valid_ratio?(config.prune_threshold) -> {:error, :invalid_graph}
        true -> :ok
      end
    else
      {:error, :invalid_graph}
    end
  end

  defp validate_config(_config), do: {:error, :invalid_graph}

  defp encode_type_quotas(quotas) do
    with :ok <- validate_type_quotas(quotas) do
      encode_generic(quotas)
    end
  end

  defp decode_type_quotas(encoded) do
    with {:ok, quotas} <- decode_generic(encoded),
         :ok <- validate_type_quotas(quotas) do
      {:ok, quotas}
    end
  end

  defp normalize_type_quotas(quotas) when is_map(quotas) and not is_struct(quotas) do
    Enum.reduce_while(quotas, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, type} <- normalize_node_type(key),
           false <- Map.has_key?(acc, type) do
        {:cont, {:ok, Map.put(acc, type, value)}}
      else
        _ -> {:halt, {:error, :invalid_graph}}
      end
    end)
  end

  defp normalize_type_quotas(_quotas), do: {:error, :invalid_graph}

  defp validate_type_quotas(quotas) when is_map(quotas) and not is_struct(quotas) do
    valid_entries? =
      map_size(quotas) <= length(@allowed_node_types) and
        Enum.all?(quotas, fn {type, fraction} ->
          type in @allowed_node_types and valid_ratio?(fraction)
        end)

    total = Enum.reduce(quotas, 0.0, fn {_type, fraction}, acc -> acc + fraction end)

    if valid_entries? and total <= 1.000_000_1,
      do: :ok,
      else: {:error, :invalid_graph}
  rescue
    _ -> {:error, :invalid_graph}
  end

  defp validate_type_quotas(_quotas), do: {:error, :invalid_graph}

  defp validate_prepared_capacity(prepared) do
    label = label_record(@capacity_probe_taint, status_for_taint(@capacity_probe_taint))

    snapshot =
      Map.merge(prepared, %{
        base: label,
        aggregate: label,
        nodes: label_inventory(prepared.nodes, label),
        pending_facts: label_inventory(prepared.pending_facts, label),
        pending_learnings: label_inventory(prepared.pending_learnings, label),
        maintenance_effects: label_inventory(prepared.maintenance_effects, label)
      })

    case encode(snapshot) do
      {:ok, _wrapper} -> :ok
      {:error, _reason} -> {:error, :graph_limit_exceeded}
    end
  end

  defp encode_generic(value) do
    case encode_generic(value, %{nodes: 0}, 0) do
      {:ok, encoded, _state} -> {:ok, encoded}
      {:error, _reason} = error -> error
    end
  end

  defp encode_generic(_value, _state, depth) when depth > @max_generic_depth,
    do: {:error, :graph_limit_exceeded}

  defp encode_generic(%DateTime{} = value, state, _depth) do
    with {:ok, state} <- enter_generic_node(state) do
      {:ok, %{"$datetime" => DateTime.to_iso8601(value)}, state}
    end
  end

  defp encode_generic(value, state, depth) when is_map(value) and not is_struct(value) do
    if map_size(value) <= @max_generic_entries do
      with {:ok, state} <- enter_generic_node(state),
           {:ok, entries, state} <- encode_generic_map(Map.to_list(value), state, depth, []) do
        {:ok, %{"$map" => Enum.sort_by(entries, &hd/1)}, state}
      end
    else
      {:error, :graph_limit_exceeded}
    end
  end

  defp encode_generic(value, state, depth) when is_list(value) do
    with {:ok, state} <- enter_generic_node(state),
         {:ok, values, state} <-
           encode_generic_list(value, state, depth, 0, @max_generic_entries, []) do
      {:ok, Enum.reverse(values), state}
    end
  end

  defp encode_generic(value, state, depth) when is_tuple(value) do
    if tuple_size(value) <= @max_generic_entries do
      with {:ok, state} <- enter_generic_node(state),
           {:ok, values, state} <-
             encode_generic_list(
               Tuple.to_list(value),
               state,
               depth,
               0,
               @max_generic_entries,
               []
             ) do
        {:ok, %{"$tuple" => Enum.reverse(values)}, state}
      end
    else
      {:error, :graph_limit_exceeded}
    end
  end

  defp encode_generic(value, state, _depth) when value in @semantic_atoms do
    with {:ok, state} <- enter_generic_node(state) do
      {:ok, %{"$atom" => Atom.to_string(value)}, state}
    end
  end

  defp encode_generic(value, state, _depth)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value) do
    with true <- valid_scalar?(value),
         {:ok, state} <- enter_generic_node(state) do
      {:ok, value, state}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_generic(_value, _state, _depth), do: {:error, :invalid_graph}

  defp encode_generic_map([], state, _depth, acc), do: {:ok, acc, state}

  defp encode_generic_map([{key, value} | rest], state, depth, acc) do
    with {:ok, key} <- encode_generic_key(key),
         logical_key <- generic_encoded_key_name(key),
         false <-
           Enum.any?(acc, &(generic_encoded_key_name(hd(&1)) == logical_key)),
         {:ok, value, state} <- encode_generic(value, state, depth + 1) do
      encode_generic_map(rest, state, depth, [[key, value] | acc])
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_generic_key(key) when key in @semantic_atoms,
    do: {:ok, "a:" <> Atom.to_string(key)}

  defp encode_generic_key(key) when is_binary(key) do
    if valid_string?(key), do: {:ok, "s:" <> key}, else: {:error, :invalid_graph}
  end

  defp encode_generic_key(_key), do: {:error, :invalid_graph}

  defp generic_encoded_key_name("a:" <> value), do: value
  defp generic_encoded_key_name("s:" <> value), do: value

  defp encode_generic_list([], state, _depth, _count, _limit, acc), do: {:ok, acc, state}

  defp encode_generic_list([value | rest], state, depth, count, limit, acc)
       when count < limit do
    with {:ok, value, state} <- encode_generic(value, state, depth + 1) do
      encode_generic_list(rest, state, depth, count + 1, limit, [value | acc])
    end
  end

  defp encode_generic_list(_value, _state, _depth, _count, _limit, _acc),
    do: {:error, :graph_limit_exceeded}

  defp decode_generic(value) do
    case decode_generic(value, %{nodes: 0}, 0) do
      {:ok, decoded, _state} -> {:ok, decoded}
      {:error, _reason} = error -> error
    end
  end

  defp decode_generic(_value, _state, depth) when depth > @max_generic_depth,
    do: {:error, :graph_limit_exceeded}

  defp decode_generic(%{"$datetime" => value} = tagged, state, _depth)
       when map_size(tagged) == 1 do
    with {:ok, datetime} <- decode_datetime(value),
         {:ok, state} <- enter_generic_node(state) do
      {:ok, datetime, state}
    end
  end

  defp decode_generic(%{"$atom" => value} = tagged, state, _depth)
       when map_size(tagged) == 1 do
    with {:ok, atom} <- semantic_atom(value),
         {:ok, state} <- enter_generic_node(state) do
      {:ok, atom, state}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_generic(%{"$tuple" => values} = tagged, state, depth)
       when map_size(tagged) == 1 do
    with {:ok, state} <- enter_generic_node(state),
         {:ok, values, state} <-
           decode_generic_list(values, state, depth, 0, @max_generic_entries, []) do
      {:ok, values |> Enum.reverse() |> List.to_tuple(), state}
    end
  end

  defp decode_generic(%{"$map" => entries} = tagged, state, depth)
       when map_size(tagged) == 1 do
    with {:ok, state} <- enter_generic_node(state),
         {:ok, decoded, state} <-
           decode_generic_map(entries, state, depth, 0, @max_generic_entries, %{}) do
      {:ok, decoded, state}
    end
  end

  defp decode_generic(value, state, depth) when is_list(value) do
    with {:ok, state} <- enter_generic_node(state),
         {:ok, values, state} <-
           decode_generic_list(value, state, depth, 0, @max_generic_entries, []) do
      {:ok, Enum.reverse(values), state}
    end
  end

  defp decode_generic(value, state, _depth)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value) do
    with true <- valid_scalar?(value),
         {:ok, state} <- enter_generic_node(state) do
      {:ok, value, state}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_generic(_value, _state, _depth), do: {:error, :invalid_graph}

  defp decode_generic_map([], state, _depth, _count, _limit, acc), do: {:ok, acc, state}

  defp decode_generic_map([[key, value] | rest], state, depth, count, limit, acc)
       when count < limit do
    with {:ok, key} <- decode_generic_key(key),
         logical_key <- generic_decoded_key_name(key),
         false <-
           Enum.any?(Map.keys(acc), &(generic_decoded_key_name(&1) == logical_key)),
         {:ok, value, state} <- decode_generic(value, state, depth + 1) do
      decode_generic_map(rest, state, depth, count + 1, limit, Map.put(acc, key, value))
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_generic_map(_entries, _state, _depth, _count, _limit, _acc),
    do: {:error, :graph_limit_exceeded}

  defp decode_generic_key("a:" <> value) do
    case semantic_atom(value) do
      {:ok, atom} -> {:ok, atom}
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_generic_key("s:" <> value) do
    if valid_string?(value), do: {:ok, value}, else: {:error, :invalid_graph}
  end

  defp decode_generic_key(_key), do: {:error, :invalid_graph}

  defp generic_decoded_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp generic_decoded_key_name(key) when is_binary(key), do: key

  defp decode_generic_list([], state, _depth, _count, _limit, acc), do: {:ok, acc, state}

  defp decode_generic_list([value | rest], state, depth, count, limit, acc)
       when count < limit do
    with {:ok, value, state} <- decode_generic(value, state, depth + 1) do
      decode_generic_list(rest, state, depth, count + 1, limit, [value | acc])
    end
  end

  defp decode_generic_list(_value, _state, _depth, _count, _limit, _acc),
    do: {:error, :graph_limit_exceeded}

  defp enter_generic_node(%{nodes: nodes} = state) when nodes < @max_generic_nodes,
    do: {:ok, %{state | nodes: nodes + 1}}

  defp enter_generic_node(_state), do: {:error, :graph_limit_exceeded}

  defp encode_max_tokens(nil), do: {:ok, nil}
  defp encode_max_tokens(value), do: encode_generic(value)

  defp decode_max_tokens(nil), do: {:ok, nil}

  defp decode_max_tokens(value) do
    with {:ok, decoded} <- decode_generic(value),
         true <- valid_token_budget?(decoded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp valid_token_budget?({:fixed, count}), do: valid_non_negative_integer?(count)

  defp valid_token_budget?({:percentage, percentage}),
    do: finite_number?(percentage) and percentage >= 0 and percentage <= 1

  defp valid_token_budget?({:min_max, minimum, maximum, percentage}),
    do:
      valid_non_negative_integer?(minimum) and valid_non_negative_integer?(maximum) and
        minimum <= maximum and finite_number?(percentage) and percentage >= 0 and percentage <= 1

  defp valid_token_budget?(_value), do: false

  defp validate_graph_scalars(graph) do
    with true <- valid_max_active?(graph.max_active),
         {:ok, active_count} <- bounded_list_count(graph.active_set, @max_content_items),
         true <- active_count <= graph.max_active,
         true <- valid_ratio?(graph.dedup_threshold),
         true <- is_nil(graph.max_tokens) or valid_token_budget?(graph.max_tokens),
         :ok <- validate_config(graph.config),
         :ok <- validate_type_quotas(graph.type_quotas) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp encode_datetime(%DateTime{} = datetime), do: {:ok, DateTime.to_iso8601(datetime)}

  defp encode_datetime(value) when is_binary(value) do
    with {:ok, datetime} <- decode_datetime(value) do
      {:ok, DateTime.to_iso8601(datetime)}
    end
  end

  defp encode_datetime(_value), do: {:error, :invalid_graph}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_graph}
    end
  end

  defp decode_datetime(_value), do: {:error, :invalid_graph}

  defp encode_optional_datetime(nil), do: {:ok, nil}
  defp encode_optional_datetime(value), do: encode_datetime(value)
  defp decode_optional_datetime(nil), do: {:ok, nil}
  defp decode_optional_datetime(value), do: decode_datetime(value)

  defp normalize_node_type(value) when value in @allowed_node_types, do: {:ok, value}

  defp normalize_node_type(value) when is_binary(value) do
    case Map.fetch(@semantic_atoms_by_name, value) do
      {:ok, type} when type in @allowed_node_types -> {:ok, type}
      _ -> {:error, :invalid_graph}
    end
  end

  defp normalize_node_type(_value), do: {:error, :invalid_graph}

  defp normalize_relationship(value) when value in @allowed_relationships, do: {:ok, value}

  defp normalize_relationship(value) when is_binary(value) do
    case Map.fetch(@semantic_atoms_by_name, value) do
      {:ok, relationship} when relationship in @allowed_relationships -> {:ok, relationship}
      _ -> {:error, :invalid_graph}
    end
  end

  defp normalize_relationship(_value), do: {:error, :invalid_graph}

  defp semantic_atom(value) when is_binary(value) do
    case Map.fetch(@semantic_atoms_by_name, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_graph}
    end
  end

  defp semantic_atom(_value), do: {:error, :invalid_graph}

  defp field(map, key, default \\ nil) do
    atom? = Map.has_key?(map, key)
    string_key = Atom.to_string(key)
    string? = Map.has_key?(map, string_key)

    case {atom?, string?} do
      {true, false} -> Map.get(map, key)
      {false, true} -> Map.get(map, string_key)
      {false, false} -> default
      {true, true} -> :alias_collision
    end
  end

  defp exact_string_keys?(value, keys) when is_map(value) and not is_struct(value) do
    map_size(value) == length(keys) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  end

  defp exact_string_keys?(_value, _keys), do: false

  defp no_alias_keys?(map, keys) do
    Enum.all?(keys, fn key ->
      not (Map.has_key?(map, key) and Map.has_key?(map, String.to_atom(key)))
    end)
  end

  defp exact_graph_struct?(%KnowledgeGraph{} = graph) do
    Map.keys(graph) |> Enum.sort() ==
      [
        :__struct__,
        :active_set,
        :agent_id,
        :config,
        :dedup_threshold,
        :edges,
        :last_decay_at,
        :max_active,
        :max_tokens,
        :nodes,
        :operation_receipts,
        :operation_receipt_order,
        :pending_facts,
        :pending_learnings,
        :pending_maintenance_effect,
        :type_quotas
      ]
      |> Enum.sort()
  end

  defp validate_identifier(value) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes and String.valid?(value),
      do: :ok,
      else: {:error, :invalid_graph}
  end

  defp validate_identifier(_value), do: {:error, :invalid_graph}

  defp valid_fingerprint?(value) when is_binary(value),
    do: byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]+\z/

  defp valid_fingerprint?(_value), do: false

  defp valid_string?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 65_536

  defp finite_number?(value) when is_integer(value), do: abs(value) <= 9_007_199_254_740_991

  defp finite_number?(value) when is_float(value) do
    value == value and abs(value) <= 9_007_199_254_740_991
  rescue
    _ -> false
  end

  defp finite_number?(_value), do: false

  defp valid_non_negative_integer?(value),
    do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991

  defp valid_positive_integer?(value), do: valid_non_negative_integer?(value) and value > 0

  defp valid_max_active?(value),
    do: valid_non_negative_integer?(value) and value <= @max_content_items

  defp valid_ratio?(value), do: finite_number?(value) and value >= 0 and value <= 1

  defp valid_edge_strength?(value),
    do: finite_number?(value) and value >= 0 and value <= 10

  defp valid_scalar?(value) when is_binary(value), do: valid_string?(value)
  defp valid_scalar?(value) when is_integer(value) or is_float(value), do: finite_number?(value)
  defp valid_scalar?(value) when is_boolean(value) or is_nil(value), do: true
  defp valid_scalar?(_value), do: false

  defp bounded_list_count(value, limit), do: bounded_list_count(value, limit, 0)
  defp bounded_list_count([], _limit, count), do: {:ok, count}

  defp bounded_list_count([_item | rest], limit, count) when count < limit,
    do: bounded_list_count(rest, limit, count + 1)

  defp bounded_list_count(_value, _limit, _count), do: {:error, :graph_limit_exceeded}

  defp reduce_bounded_list(value, limit, acc, reducer),
    do: reduce_bounded_list(value, limit, 0, acc, reducer)

  defp reduce_bounded_list([], _limit, _count, acc, _reducer), do: acc

  defp reduce_bounded_list([item | rest], limit, count, acc, reducer) when count < limit do
    case reducer.(item, acc) do
      {:error, _reason} = error -> error
      next -> reduce_bounded_list(rest, limit, count + 1, next, reducer)
    end
  end

  defp reduce_bounded_list(_value, _limit, _count, _acc, _reducer),
    do: {:error, :graph_limit_exceeded}
end
