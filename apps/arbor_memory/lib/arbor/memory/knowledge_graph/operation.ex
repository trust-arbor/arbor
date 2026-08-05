defmodule Arbor.Memory.KnowledgeGraph.Operation do
  @moduledoc false

  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraph.{Codec, GraphSearch}

  @max_operation_bytes 1_048_576
  @max_identifier_bytes 256
  @max_metadata_entries 256
  @max_receipts 256
  @node_data_keys [
    :confidence,
    :content,
    :metadata,
    :pinned,
    :referenced_date,
    :relevance,
    :skip_dedup,
    :type
  ]
  @edge_option_keys [:metadata, :strength]
  @cascade_option_keys [:decay_factor, :max_depth, :min_boost]
  @accepted_proposal_key "$arbor_accepted_proposal_id"

  # Generic receipts guarantee exactly-once effects within this FIFO horizon.
  # Replayed state-returning operations reconstruct their response from the
  # current graph; they do not preserve an immutable historical response.
  @doc false
  def receipt_horizon, do: @max_receipts

  @type t ::
          {:initialize, KnowledgeGraph.t()}
          | {:add_node, String.t(), map(), String.t(), DateTime.t()}
          | {:add_edge, String.t(), String.t(), String.t(), atom() | String.t(), keyword(),
             String.t(), DateTime.t()}
          | {:reinforce, String.t(), String.t(), DateTime.t()}
          | {:approve_pending, String.t(), String.t(), String.t(), DateTime.t()}
          | {:reject_pending, String.t(), String.t()}
          | {:cascade_recall, String.t(), String.t(), number(), keyword(), DateTime.t()}

  @spec initialize(KnowledgeGraph.t()) :: {:ok, t()} | {:error, atom()}
  def initialize(%KnowledgeGraph{} = graph), do: validate_new({:initialize, graph})
  def initialize(_graph), do: {:error, :invalid_graph}

  @spec add_node(String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def add_node(operation_id, node_data) do
    with :ok <- validate_node_data_shape(node_data),
         {:ok, prefix} <- node_id_prefix(Map.get(node_data, :type)) do
      operation =
        {:add_node, operation_id, node_data, generated_id(prefix), DateTime.utc_now()}

      validate_new(operation)
    end
  end

  @spec add_edge(String.t(), String.t(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def add_edge(operation_id, source_id, target_id, relationship, opts) do
    with {:ok, opts} <- normalize_keyword(opts, @edge_option_keys) do
      operation =
        {:add_edge, operation_id, source_id, target_id, relationship, opts, generated_id("edge_"),
         DateTime.utc_now()}

      validate_new(operation)
    end
  end

  @spec reinforce(String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def reinforce(operation_id, node_id) do
    validate_new({:reinforce, operation_id, node_id, DateTime.utc_now()})
  end

  @spec approve_pending(String.t()) :: {:ok, t()} | {:error, atom()}
  def approve_pending(pending_id) do
    operation_id = stable_operation_id("approve_pending", pending_id)

    validate_new(
      {:approve_pending, operation_id, pending_id, generated_nonce(), DateTime.utc_now()}
    )
  end

  @spec reject_pending(String.t()) :: {:ok, t()} | {:error, atom()}
  def reject_pending(pending_id) do
    validate_new({:reject_pending, stable_operation_id("reject_pending", pending_id), pending_id})
  end

  @spec cascade_recall(String.t(), String.t(), number(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def cascade_recall(operation_id, node_id, boost_amount, opts) do
    with {:ok, opts} <- normalize_keyword(opts, @cascade_option_keys) do
      validate_new(
        {:cascade_recall, operation_id, node_id, boost_amount, opts, DateTime.utc_now()}
      )
    end
  end

  @spec validate(t()) :: :ok | {:error, atom()}
  def validate({:initialize, %KnowledgeGraph{agent_id: agent_id} = graph}) do
    with :ok <- validate_identifier(agent_id),
         true <- bounded_term?(graph),
         {:ok, _snapshot} <- Codec.prepare(agent_id, graph) do
      :ok
    else
      {:error, :graph_limit_exceeded} = error -> error
      _ -> {:error, :invalid_graph}
    end
  end

  def validate({:add_node, operation_id, node_data, node_id, %DateTime{} = occurred_at}) do
    validation_agent = "agent_operation_validation"
    graph = KnowledgeGraph.new(validation_agent, auto_embed: false)

    with :ok <- validate_identifier(operation_id),
         :ok <- validate_node_data_shape(node_data),
         :ok <- validate_identifier(node_id),
         {:ok, graph, _node_id} <-
           KnowledgeGraph.add_node_transition(graph, node_data, node_id, occurred_at),
         {:ok, _prepared} <- Codec.prepare(validation_agent, graph) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  def validate(
        {:add_edge, operation_id, source_id, target_id, relationship, opts, edge_id,
         %DateTime{} = occurred_at}
      ) do
    validation_agent = "agent_operation_validation"
    graph = validation_graph(validation_agent, occurred_at)

    with :ok <- validate_identifier(operation_id),
         :ok <- validate_identifier(source_id),
         :ok <- validate_identifier(target_id),
         :ok <- validate_identifier(edge_id),
         :ok <- validate_keyword(opts, @edge_option_keys),
         true <- valid_metadata?(Keyword.get(opts, :metadata, %{})),
         {:ok, graph} <-
           KnowledgeGraph.add_edge_transition(
             graph,
             "a",
             "b",
             relationship,
             opts,
             edge_id,
             occurred_at
           ),
         {:ok, _prepared} <- Codec.prepare(validation_agent, graph) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  def validate({:reinforce, operation_id, node_id, %DateTime{}}) do
    with :ok <- validate_identifier(operation_id), do: validate_identifier(node_id)
  end

  def validate({:approve_pending, operation_id, pending_id, nonce, %DateTime{}}) do
    with :ok <- validate_identifier(operation_id),
         :ok <- validate_identifier(pending_id),
         true <- valid_nonce?(nonce) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  def validate({:reject_pending, operation_id, pending_id}) do
    with :ok <- validate_identifier(operation_id), do: validate_identifier(pending_id)
  end

  def validate({:cascade_recall, operation_id, node_id, boost_amount, opts, %DateTime{}}) do
    with :ok <- validate_identifier(operation_id),
         :ok <- validate_identifier(node_id),
         true <- valid_ratio?(boost_amount),
         :ok <- validate_keyword(opts, @cascade_option_keys),
         true <- valid_depth?(Keyword.get(opts, :max_depth, 3)),
         true <- valid_ratio?(Keyword.get(opts, :min_boost, 0.05)),
         true <- valid_ratio?(Keyword.get(opts, :decay_factor, 0.5)) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  def validate(_operation), do: {:error, :invalid_graph}

  @spec apply(t(), KnowledgeGraph.t() | nil) ::
          {:ok, KnowledgeGraph.t(), term(), :changed | :replayed} | {:error, term()}
  def apply({:initialize, %KnowledgeGraph{} = graph}, _current),
    do: {:ok, graph, :ok, :changed}

  def apply(_operation, nil), do: {:error, :graph_not_initialized}

  def apply(
        {:approve_pending, _operation_id, pending_id, _nonce, _occurred_at} = operation,
        %KnowledgeGraph{} = graph
      ) do
    case accepted_proposal_node(graph, pending_id) do
      {:ok, node_id} -> {:ok, graph, node_id, :replayed}
      :not_found -> apply_with_receipt(operation, graph)
    end
  end

  def apply(operation, %KnowledgeGraph{} = graph) do
    apply_with_receipt(operation, graph)
  end

  def apply(_operation, _graph), do: {:error, :invalid_graph}

  defp apply_with_receipt(operation, graph) do
    with {:ok, operation_id, kind, fingerprint} <- receipt_identity(operation) do
      case Map.fetch(graph.operation_receipts, operation_id) do
        {:ok, %{kind: ^kind, fingerprint: ^fingerprint, result: result}} ->
          replay_result(kind, result, graph)

        {:ok, _different_receipt} ->
          {:error, :operation_id_conflict}

        :error ->
          apply_and_record(operation, operation_id, kind, fingerprint, graph)
      end
    end
  end

  defp apply_and_record(operation, operation_id, kind, fingerprint, graph) do
    with {:ok, graph, result} <- apply_once(operation, graph),
         {:ok, receipt_result} <- receipt_result(kind, result),
         {:ok, graph} <-
           put_receipt(graph, operation_id, %{
             kind: kind,
             fingerprint: fingerprint,
             result: receipt_result
           }) do
      {:ok, graph, result, :changed}
    end
  end

  defp apply_once({:add_node, _operation_id, node_data, node_id, occurred_at}, graph) do
    KnowledgeGraph.add_node_transition(graph, node_data, node_id, occurred_at)
  end

  defp apply_once(
         {:add_edge, _operation_id, source_id, target_id, relationship, opts, edge_id,
          occurred_at},
         graph
       ) do
    case KnowledgeGraph.add_edge_transition(
           graph,
           source_id,
           target_id,
           relationship,
           opts,
           edge_id,
           occurred_at
         ) do
      {:ok, graph} -> {:ok, graph, :ok}
      {:error, _reason} = error -> error
    end
  end

  defp apply_once({:reinforce, _operation_id, node_id, occurred_at}, graph) do
    KnowledgeGraph.reinforce_at(graph, node_id, occurred_at)
  end

  defp apply_once(
         {:approve_pending, _operation_id, pending_id, nonce, occurred_at},
         graph
       ) do
    KnowledgeGraph.approve_pending_transition(graph, pending_id, nonce, occurred_at)
  end

  defp apply_once({:reject_pending, _operation_id, pending_id}, graph) do
    case KnowledgeGraph.reject_pending(graph, pending_id) do
      {:ok, graph} -> {:ok, graph, :ok}
      {:error, _reason} = error -> error
    end
  end

  defp apply_once(
         {:cascade_recall, _operation_id, node_id, boost_amount, opts, occurred_at},
         graph
       ) do
    graph = GraphSearch.cascade_recall_at(graph, node_id, boost_amount, occurred_at, opts)
    {:ok, graph, KnowledgeGraph.stats(graph)}
  end

  defp receipt_identity(operation) do
    with {:ok, operation_id, kind, logical_input} <- logical_operation(operation),
         {:ok, fingerprint} <- fingerprint(logical_input) do
      {:ok, operation_id, kind, fingerprint}
    end
  end

  defp logical_operation({:add_node, operation_id, node_data, _node_id, _occurred_at}),
    do: {:ok, operation_id, "add_node", {:add_node, node_data}}

  defp logical_operation(
         {:add_edge, operation_id, source_id, target_id, relationship, opts, _edge_id,
          _occurred_at}
       ),
       do: {:ok, operation_id, "add_edge", {:add_edge, source_id, target_id, relationship, opts}}

  defp logical_operation({:reinforce, operation_id, node_id, _occurred_at}),
    do: {:ok, operation_id, "reinforce", {:reinforce, node_id}}

  defp logical_operation({:approve_pending, operation_id, pending_id, _nonce, _occurred_at}),
    do: {:ok, operation_id, "approve_pending", {:approve_pending, pending_id}}

  defp logical_operation({:reject_pending, operation_id, pending_id}),
    do: {:ok, operation_id, "reject_pending", {:reject_pending, pending_id}}

  defp logical_operation(
         {:cascade_recall, operation_id, node_id, boost_amount, opts, _occurred_at}
       ),
       do: {:ok, operation_id, "cascade_recall", {:cascade_recall, node_id, boost_amount, opts}}

  defp logical_operation(_operation), do: {:error, :invalid_graph}

  defp fingerprint(logical_input) do
    encoded = :erlang.term_to_binary(logical_input, [:deterministic])
    {:ok, :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)}
  rescue
    _ -> {:error, :invalid_graph}
  catch
    _, _ -> {:error, :invalid_graph}
  end

  defp receipt_result("add_node", node_id) when is_binary(node_id), do: {:ok, node_id}
  defp receipt_result("approve_pending", node_id) when is_binary(node_id), do: {:ok, node_id}
  defp receipt_result("reinforce", %{id: node_id}) when is_binary(node_id), do: {:ok, node_id}
  defp receipt_result(kind, :ok) when kind in ["add_edge", "reject_pending"], do: {:ok, "ok"}
  defp receipt_result("cascade_recall", result) when is_map(result), do: {:ok, "ok"}
  defp receipt_result(_kind, _result), do: {:error, :invalid_graph}

  defp replay_result(kind, node_id, graph) when kind in ["add_node", "approve_pending"],
    do: {:ok, graph, node_id, :replayed}

  defp replay_result(kind, "ok", graph) when kind in ["add_edge", "reject_pending"],
    do: {:ok, graph, :ok, :replayed}

  defp replay_result("reinforce", node_id, graph) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, node} -> {:ok, graph, node, :replayed}
      :error -> {:error, :operation_result_unavailable}
    end
  end

  defp replay_result("cascade_recall", "ok", graph),
    do: {:ok, graph, KnowledgeGraph.stats(graph), :replayed}

  defp replay_result(_kind, _result, _graph), do: {:error, :invalid_graph}

  defp put_receipt(
         %KnowledgeGraph{operation_receipts: receipts, operation_receipt_order: order} = graph,
         operation_id,
         receipt
       ) do
    if Map.has_key?(receipts, operation_id) do
      {:error, :operation_id_conflict}
    else
      {receipts, order} = evict_oldest_receipt(receipts, order)

      {:ok,
       %{
         graph
         | operation_receipts: Map.put(receipts, operation_id, receipt),
           operation_receipt_order: order ++ [operation_id]
       }}
    end
  end

  defp evict_oldest_receipt(receipts, [oldest | remaining])
       when map_size(receipts) >= @max_receipts,
       do: {Map.delete(receipts, oldest), remaining}

  defp evict_oldest_receipt(receipts, order), do: {receipts, order}

  defp accepted_proposal_node(graph, pending_id) do
    Enum.find_value(graph.nodes, :not_found, fn {node_id, node} ->
      if Map.get(node.metadata, @accepted_proposal_key) == pending_id,
        do: {:ok, node_id},
        else: false
    end)
  end

  defp validate_new(operation) do
    with :ok <- validate(operation),
         true <- bounded_term?(operation) do
      {:ok, operation}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :graph_limit_exceeded}
    end
  end

  defp validate_node_data_shape(node_data)
       when is_map(node_data) and not is_struct(node_data) and
              map_size(node_data) <= length(@node_data_keys) do
    with true <- Enum.all?(Map.keys(node_data), &(&1 in @node_data_keys)),
         true <- valid_node_metadata?(Map.get(node_data, :metadata, %{})),
         true <- is_boolean(Map.get(node_data, :skip_dedup, false)) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp validate_node_data_shape(_node_data), do: {:error, :invalid_graph}

  defp normalize_keyword(value, allowed_keys) do
    with :ok <- validate_keyword(value, allowed_keys) do
      {:ok, Enum.sort_by(value, fn {key, _value} -> key end)}
    end
  end

  defp validate_keyword(value, allowed_keys) do
    with {:ok, count} <- bounded_list_count(value, length(allowed_keys)),
         true <- Keyword.keyword?(value),
         keys <- Keyword.keys(value),
         true <- count == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in allowed_keys)) do
      :ok
    else
      _ -> {:error, :invalid_graph}
    end
  end

  defp valid_metadata?(metadata) when is_map(metadata) and not is_struct(metadata),
    do: map_size(metadata) <= @max_metadata_entries and bounded_term?(metadata)

  defp valid_metadata?(_metadata), do: false

  defp valid_node_metadata?(metadata),
    do: valid_metadata?(metadata) and not Map.has_key?(metadata, @accepted_proposal_key)

  defp validation_graph(agent_id, occurred_at) do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    {:ok, graph, _} =
      KnowledgeGraph.add_node_transition(graph, validation_node(), "a", occurred_at)

    {:ok, graph, _} =
      KnowledgeGraph.add_node_transition(graph, validation_node(), "b", occurred_at)

    graph
  end

  defp validation_node, do: %{type: :fact, content: "operation", skip_dedup: true}

  defp node_id_prefix(type) when is_atom(type), do: node_id_prefix(Atom.to_string(type))

  defp node_id_prefix(type)
       when is_binary(type) and byte_size(type) > 0 and byte_size(type) <= 32,
       do: {:ok, "node_#{type}_"}

  defp node_id_prefix(_type), do: {:error, :invalid_graph}

  defp stable_operation_id(kind, external_id) when is_binary(external_id) do
    digest = :crypto.hash(:sha256, external_id) |> Base.encode16(case: :lower)
    "kg_#{kind}_#{digest}"
  end

  defp stable_operation_id(kind, external_id), do: stable_operation_id(kind, inspect(external_id))

  defp generated_id(prefix), do: prefix <> generated_nonce()
  defp generated_nonce, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp valid_nonce?(value) when is_binary(value),
    do: byte_size(value) == 16 and value =~ ~r/\A[0-9a-f]+\z/

  defp valid_nonce?(_value), do: false

  defp validate_identifier(value) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes and String.valid?(value),
      do: :ok,
      else: {:error, :invalid_graph}
  end

  defp validate_identifier(_value), do: {:error, :invalid_graph}

  defp valid_depth?(value), do: is_integer(value) and value >= 0 and value <= 64

  defp valid_ratio?(value) when is_integer(value), do: value >= 0 and value <= 1

  defp valid_ratio?(value) when is_float(value) do
    value == value and value >= 0.0 and value <= 1.0
  rescue
    _ -> false
  end

  defp valid_ratio?(_value), do: false

  defp bounded_term?(term) do
    :erlang.external_size(term) <= @max_operation_bytes
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp bounded_list_count(value, limit), do: bounded_list_count(value, limit, 0)
  defp bounded_list_count([], _limit, count), do: {:ok, count}

  defp bounded_list_count([_item | rest], limit, count) when count < limit,
    do: bounded_list_count(rest, limit, count + 1)

  defp bounded_list_count(_value, _limit, _count), do: {:error, :invalid_graph}
end
