defmodule Arbor.Memory.KnowledgeGraphStore do
  @moduledoc false

  use GenServer

  alias Arbor.Contracts.Security.{Taint, TaintedValue}

  alias Arbor.Memory.{KnowledgeGraph, MemoryStore, Provenance}
  alias Arbor.Memory.KnowledgeGraph.{Codec, Operation}

  @namespace "knowledge_graph"
  @graph_ets :arbor_memory_graphs
  @call_timeout 60_000
  @deadline_margin 1_000
  @cas_attempts 8
  @projection_attempts 8
  @projection_domains [
    :knowledge_graph_base,
    :knowledge_graph_aggregate,
    :knowledge_node,
    :knowledge_pending_fact,
    :knowledge_pending_learning,
    :knowledge_maintenance_effect
  ]

  @type store_error ::
          :graph_not_initialized
          | :store_unavailable
          | :outcome_unknown
          | :conflict
          | :invalid_graph
          | :invalid_provenance
          | :graph_limit_exceeded
          | :request_expired

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec get_graph(String.t()) :: {:ok, KnowledgeGraph.t()} | {:error, store_error()}
  def get_graph(agent_id), do: safe_call({:read, agent_id}, :read, agent_id)

  @spec get_snapshot(String.t()) :: {:ok, Codec.snapshot()} | {:error, store_error()}
  def get_snapshot(agent_id), do: safe_call({:read_snapshot, agent_id}, :read, agent_id)

  @spec save_graph(String.t(), KnowledgeGraph.t()) :: :ok | {:error, store_error()}
  def save_graph(agent_id, %KnowledgeGraph{} = graph) do
    with {:ok, operation} <- Operation.initialize(graph) do
      call_save(agent_id, operation, Codec.missing_taint())
    end
  end

  def save_graph(_agent_id, _graph), do: {:error, :invalid_graph}

  @spec save_graph_tainted(String.t(), KnowledgeGraph.t(), Taint.t()) ::
          :ok | {:error, store_error()}
  def save_graph_tainted(agent_id, %KnowledgeGraph{} = graph, %Taint{} = taint) do
    with {:ok, operation} <- Operation.initialize(graph) do
      call_save(agent_id, operation, taint)
    end
  end

  def save_graph_tainted(_agent_id, _graph, _taint), do: {:error, :invalid_graph}

  @spec add_node(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def add_node(agent_id, operation_id, node_data) do
    with {:ok, operation} <- Operation.add_node(operation_id, node_data) do
      call_operation(agent_id, operation)
    end
  end

  @spec add_node_tainted(String.t(), String.t(), map(), Taint.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_node_tainted(agent_id, operation_id, node_data, %Taint{} = taint) do
    with {:ok, operation} <- Operation.add_node(operation_id, node_data) do
      call_operation(agent_id, operation, taint)
    end
  end

  def add_node_tainted(_agent_id, _operation_id, _node_data, _taint),
    do: {:error, :invalid_graph}

  @spec add_pending_learning(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def add_pending_learning(agent_id, operation_id, learning_data) do
    with {:ok, operation} <- Operation.add_pending_learning(operation_id, learning_data) do
      call_operation(agent_id, operation)
    end
  end

  @spec add_pending_learning_batch(String.t(), String.t(), [map()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def add_pending_learning_batch(agent_id, operation_id, learning_data) do
    with {:ok, operation} <-
           Operation.add_pending_learning_batch(operation_id, learning_data) do
      call_operation(agent_id, operation)
    end
  end

  @spec add_pending_fact(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def add_pending_fact(agent_id, operation_id, fact_data) do
    with {:ok, operation} <- Operation.add_pending_fact(operation_id, fact_data) do
      call_operation(agent_id, operation)
    end
  end

  @spec add_pending_fact_tainted(String.t(), String.t(), map(), Taint.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_pending_fact_tainted(agent_id, operation_id, fact_data, %Taint{} = taint) do
    with {:ok, operation} <- Operation.add_pending_fact(operation_id, fact_data) do
      call_operation(agent_id, operation, taint)
    end
  end

  def add_pending_fact_tainted(_agent_id, _operation_id, _fact_data, _taint),
    do: {:error, :invalid_graph}

  @spec add_pending_learning_tainted(String.t(), String.t(), map(), Taint.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_pending_learning_tainted(
        agent_id,
        operation_id,
        learning_data,
        %Taint{} = taint
      ) do
    with {:ok, operation} <- Operation.add_pending_learning(operation_id, learning_data) do
      call_operation(agent_id, operation, taint)
    end
  end

  def add_pending_learning_tainted(_agent_id, _operation_id, _learning_data, _taint),
    do: {:error, :invalid_graph}

  @spec add_edge(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          atom() | String.t(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def add_edge(agent_id, operation_id, source_id, target_id, relationship, opts \\ []) do
    with {:ok, operation} <-
           Operation.add_edge(operation_id, source_id, target_id, relationship, opts),
         {:ok, :ok} <- call_operation(agent_id, operation) do
      :ok
    end
  end

  @spec reinforce(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reinforce(agent_id, operation_id, node_id) do
    with {:ok, operation} <- Operation.reinforce(operation_id, node_id) do
      call_operation(agent_id, operation)
    end
  end

  @spec reinforce_tainted(String.t(), String.t(), String.t(), Taint.t()) ::
          {:ok, map()} | {:error, term()}
  def reinforce_tainted(agent_id, operation_id, node_id, %Taint{} = taint) do
    with {:ok, operation} <- Operation.reinforce(operation_id, node_id) do
      call_operation(agent_id, operation, taint)
    end
  end

  def reinforce_tainted(_agent_id, _operation_id, _node_id, _taint),
    do: {:error, :invalid_graph}

  @spec merge_node_metadata(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def merge_node_metadata(agent_id, operation_id, node_id, fields) do
    with {:ok, operation} <- Operation.merge_node_metadata(operation_id, node_id, fields) do
      call_operation(agent_id, operation)
    end
  end

  @spec merge_node_metadata_batch(String.t(), String.t(), [{String.t(), map()}]) ::
          :ok | {:error, term()}
  def merge_node_metadata_batch(agent_id, operation_id, updates) do
    with {:ok, operation} <- Operation.merge_node_metadata_batch(operation_id, updates),
         {:ok, :ok} <- call_operation(agent_id, operation) do
      :ok
    end
  end

  @spec approve_pending(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def approve_pending(agent_id, pending_id) do
    with {:ok, operation} <- Operation.approve_pending(pending_id) do
      call_operation(agent_id, operation)
    end
  end

  @spec approve_pending(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def approve_pending(agent_id, operation_id, pending_id) do
    with {:ok, operation} <- Operation.approve_pending(operation_id, pending_id) do
      call_operation(agent_id, operation)
    end
  end

  @spec reject_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def reject_pending(agent_id, pending_id) do
    with {:ok, operation} <- Operation.reject_pending(pending_id),
         {:ok, :ok} <- call_operation(agent_id, operation) do
      :ok
    end
  end

  @spec cascade_recall(String.t(), String.t(), String.t(), number(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cascade_recall(agent_id, operation_id, node_id, boost_amount, opts \\ []) do
    with {:ok, operation} <-
           Operation.cascade_recall(operation_id, node_id, boost_amount, opts) do
      call_operation(agent_id, operation)
    end
  end

  @spec consolidate(String.t(), String.t(), :basic | :enhanced, keyword()) ::
          {:ok, KnowledgeGraph.t(), map()} | {:error, term()}
  def consolidate(agent_id, operation_id, mode, opts \\ []) do
    with {:ok, operation} <- Operation.consolidate(operation_id, mode, opts),
         {:ok, %{graph: %KnowledgeGraph{} = graph} = result} <-
           call_operation(agent_id, operation) do
      {:ok, graph, Map.delete(result, :graph)}
    end
  end

  @spec pending_maintenance_effect(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def pending_maintenance_effect(agent_id) do
    with {:ok, snapshot} <- get_snapshot(agent_id) do
      {:ok, labelled_maintenance_effect(snapshot)}
    end
  end

  @spec acknowledge_maintenance_effect(String.t(), String.t()) :: :ok | {:error, term()}
  def acknowledge_maintenance_effect(agent_id, operation_id) do
    with {:ok, operation} <- Operation.acknowledge_maintenance_effect(operation_id),
         {:ok, :ok} <- call_operation(agent_id, operation) do
      :ok
    end
  end

  @spec import_legacy_graph(String.t(), map()) :: :ok | {:error, store_error()}
  def import_legacy_graph(agent_id, graph_map) when is_map(graph_map) do
    case safe_call(
           {:import_legacy, agent_id, graph_map, request_deadline()},
           :mutation,
           agent_id
         ) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :outcome_unknown}
    end
  end

  def import_legacy_graph(_agent_id, _graph_map), do: {:error, :invalid_graph}

  @spec delete_graph(String.t()) :: :ok | {:error, store_error()}
  def delete_graph(agent_id) do
    safe_call({:delete, agent_id, request_deadline()}, :mutation, agent_id)
  end

  @doc """
  Idempotent content-only deletion for exactly one agent.

  Removes durable knowledge-graph aggregate content (nodes, pending facts/
  learnings, maintenance effects, graph state), ETS projection, and owner-local
  projection-retry state. Retains every Provenance sidecar byte-for-byte.

  C3I2A precondition (caller-owned, not enforced here): C3I1 mutation gate
  must be closed and drained before invoke. This API is not race-free agent
  destruction.
  """
  @spec delete_agent_content(String.t()) :: :ok | {:error, store_error()}
  def delete_agent_content(agent_id) do
    if valid_agent_id?(agent_id) do
      content_safe_call(
        {:delete_agent_content, agent_id, request_deadline()},
        :mutation,
        agent_id
      )
    else
      {:error, :invalid_graph}
    end
  end

  @doc """
  Authoritative absence across durable graph, ETS projection, and owner
  deferred projection-retry state. Returns `{:ok, true}` only when no
  exact-agent content remains.
  """
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, store_error()}
  def agent_content_absent?(agent_id) do
    if valid_agent_id?(agent_id) do
      content_safe_call({:agent_content_absent?, agent_id}, :read, agent_id)
    else
      {:error, :invalid_graph}
    end
  end

  @spec converge_projection(String.t()) :: :ok | {:error, store_error()}
  def converge_projection(agent_id) do
    case safe_call({:converge, agent_id}, :read, agent_id) do
      {:ok, _graph} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :store_unavailable}
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{pending_projection: %{}}}

  @impl true
  def handle_call({:read, agent_id}, _from, state) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, snapshot, _record} ->
        {:reply, {:ok, snapshot.graph}, project_or_schedule(state, agent_id, snapshot)}

      {:error, reason} = error ->
        {:reply, error, invalidate_after_read(state, agent_id, reason)}
    end
  end

  def handle_call({:read_snapshot, agent_id}, _from, state) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, snapshot, _record} ->
        {:reply, {:ok, snapshot}, project_or_schedule(state, agent_id, snapshot)}

      {:error, reason} = error ->
        {:reply, error, invalidate_after_read(state, agent_id, reason)}
    end
  end

  def handle_call({:save, agent_id, operation, taint, deadline}, _from, state) do
    with :ok <- ensure_deadline(deadline),
         :ok <- Operation.validate(operation),
         {:ok, snapshot, result} <-
           mutate_authority(
             agent_id,
             operation,
             taint,
             :create_if_absent,
             @cas_attempts,
             deadline
           ) do
      {:reply, {:ok, result}, project_or_schedule(state, agent_id, snapshot)}
    else
      {:error, reason} = error ->
        {:reply, error, invalidate_after_mutation(state, agent_id, reason)}

      _ ->
        {:reply, {:error, :invalid_graph}, state}
    end
  end

  def handle_call({:operate, agent_id, operation, taint, deadline}, _from, state) do
    with :ok <- ensure_deadline(deadline),
         :ok <- validate_existing_operation(operation),
         {:ok, snapshot, result} <-
           mutate_authority(
             agent_id,
             operation,
             taint,
             :existing,
             @cas_attempts,
             deadline
           ) do
      result = attach_operation_provenance(operation, snapshot, result)
      {:reply, {:ok, result}, project_or_schedule(state, agent_id, snapshot)}
    else
      {:error, reason} = error ->
        {:reply, error, invalidate_after_mutation(state, agent_id, reason)}

      _ ->
        {:reply, {:error, :invalid_graph}, state}
    end
  end

  def handle_call({:import_legacy, agent_id, graph_map, deadline}, _from, state) do
    with :ok <- ensure_deadline(deadline),
         {:ok, graph} <- Codec.decode_legacy_graph(agent_id, graph_map),
         {:ok, operation} <- Operation.initialize(graph),
         {:ok, snapshot, result} <-
           mutate_authority(
             agent_id,
             operation,
             Codec.missing_taint(),
             :create_if_absent,
             @cas_attempts,
             deadline
           ) do
      {:reply, {:ok, result}, project_or_schedule(state, agent_id, snapshot)}
    else
      {:error, reason} = error ->
        {:reply, error, invalidate_after_mutation(state, agent_id, reason)}

      _ ->
        {:reply, {:error, :invalid_graph}, state}
    end
  end

  def handle_call({:delete, agent_id, deadline}, _from, state) do
    with :ok <- ensure_deadline(deadline) do
      case MemoryStore.delete_tainted_authoritative(@namespace, agent_id) do
        :ok ->
          state = invalidate_projection(state, agent_id)
          {:reply, :ok, state}

        {:error, _reason} = error ->
          state = invalidate_projection(state, agent_id) |> schedule_projection(agent_id)
          {:reply, map_store_error(error), state}

        _ ->
          state = invalidate_projection(state, agent_id) |> schedule_projection(agent_id)
          {:reply, {:error, :outcome_unknown}, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:delete_agent_content, agent_id, deadline}, _from, state) do
    with :ok <- ensure_deadline(deadline) do
      case MemoryStore.delete_tainted_authoritative(@namespace, agent_id) do
        :ok ->
          # Content-only: ETS + deferred only; provenance sidecars retained.
          evict_projection(agent_id)
          state = clear_pending_projection(state, agent_id)
          {:reply, :ok, state}

        {:error, _reason} = error ->
          # Conservative projection eviction; provenance intact.
          evict_projection(agent_id)
          {:reply, map_store_error(error), state}

        _ ->
          evict_projection(agent_id)
          {:reply, {:error, :outcome_unknown}, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :outcome_unknown}, state}
  catch
    _, _ -> {:reply, {:error, :outcome_unknown}, state}
  end

  def handle_call({:agent_content_absent?, agent_id}, _from, state) do
    reply = do_agent_content_absent?(agent_id, state)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:converge, agent_id}, _from, state) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, snapshot, _record} ->
        {:reply, {:ok, snapshot.graph}, project_or_schedule(state, agent_id, snapshot)}

      {:error, reason} = error ->
        {:reply, error, invalidate_after_read(state, agent_id, reason)}
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :invalid_graph}, state}

  @impl true
  def handle_info({:converge_projection, agent_id, attempt}, state) do
    if state.pending_projection[agent_id] == attempt do
      state = clear_pending_projection(state, agent_id)

      case read_authority(agent_id, @cas_attempts) do
        {:ok, snapshot, _record} ->
          case install_projection(agent_id, snapshot) do
            :ok -> {:noreply, state}
            {:error, _reason} -> {:noreply, retry_projection(state, agent_id, attempt)}
          end

        {:error, :graph_not_initialized} ->
          state = invalidate_projection(state, agent_id)
          {:noreply, retry_projection(state, agent_id, attempt)}

        {:error, reason}
        when reason in [:store_unavailable, :conflict, :outcome_unknown] ->
          state = invalidate_projection(state, agent_id)
          {:noreply, retry_projection(state, agent_id, attempt)}

        {:error, _reason} ->
          {:noreply, invalidate_projection(state, agent_id)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp mutate_authority(_agent_id, _operation, _taint, _mode, 0, _deadline),
    do: {:error, :conflict}

  defp mutate_authority(agent_id, operation, taint, mode, attempts, deadline) do
    with :ok <- ensure_deadline(deadline),
         {:ok, taint} <- Taint.canonicalize(taint),
         {:ok, previous, expected} <- mutation_baseline(agent_id, mode),
         {:ok, graph, result, effect} <-
           Operation.apply(operation, previous_graph(previous), taint) do
      case effect do
        :replayed ->
          {:ok, previous, result}

        :changed ->
          commit_mutation(
            agent_id,
            operation,
            graph,
            result,
            previous,
            expected,
            taint,
            mode,
            attempts,
            deadline
          )
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp commit_mutation(
         agent_id,
         operation,
         graph,
         result,
         previous,
         expected,
         taint,
         mode,
         attempts,
         deadline
       ) do
    reconciliation_context = reconciliation_context(operation, result)

    with {:ok, candidate} <-
           Codec.reconcile(agent_id, graph, previous, taint, reconciliation_context),
         {:ok, wrapper} <- Codec.encode(candidate),
         :ok <- ensure_deadline(deadline) do
      case MemoryStore.compare_and_swap_tainted(
             @namespace,
             agent_id,
             expected,
             wrapper,
             taint: candidate.aggregate.taint
           ) do
        {:ok, _stored} ->
          {:ok, candidate, result}

        {:error, {:memory_store, :critical, :conflict}} ->
          mutate_authority(agent_id, operation, taint, mode, attempts - 1, deadline)

        {:error, _reason} = error ->
          map_store_error(error)

        _ ->
          {:error, :outcome_unknown}
      end
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp mutation_baseline(agent_id, mode) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, _snapshot, _record} when mode == :create_if_absent ->
        {:error, :conflict}

      {:ok, snapshot, record} when mode == :existing ->
        {:ok, snapshot, record}

      {:error, :graph_not_initialized} when mode == :create_if_absent ->
        {:ok, nil, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp previous_graph(nil), do: nil
  defp previous_graph(snapshot), do: snapshot.graph

  defp reconciliation_context(
         {:approve_pending, _operation_id, pending_id, _nonce, _occurred_at},
         node_id
       )
       when is_binary(node_id) do
    %{accepted_pending: %{node_id => pending_id}}
  end

  defp reconciliation_context(
         {:consolidate, _operation_id, _mode, _opts, _occurred_at},
         %{archive_entries: entries}
       ) do
    %{archived_node_ids: Enum.map(entries, & &1.node.id)}
  end

  defp reconciliation_context({:ack_maintenance_effect, _operation_id}, :ok),
    do: %{provenance_neutral: true}

  defp reconciliation_context(_operation, _result), do: %{}

  defp validate_existing_operation({:initialize, _graph}), do: {:error, :invalid_graph}
  defp validate_existing_operation(operation), do: Operation.validate(operation)

  defp read_authority(_agent_id, 0), do: {:error, :conflict}

  defp read_authority(agent_id, attempts) do
    case MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id) do
      {:ok, %TaintedValue{value: data, taint: outer_taint}, status, record, _location} ->
        case Codec.decode(agent_id, data, outer_taint, status) do
          {:ok, snapshot, :current} ->
            {:ok, snapshot, record}

          {:ok, snapshot, :migration} ->
            migrate_snapshot(agent_id, snapshot, record, attempts)

          {:error, :graph_limit_exceeded} ->
            {:error, :graph_limit_exceeded}

          {:error, _reason} ->
            {:error, :invalid_provenance}
        end

      {:error, :not_found} ->
        {:error, :graph_not_initialized}

      {:error, _reason} = error ->
        map_store_error(error)

      _ ->
        {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp migrate_snapshot(agent_id, snapshot, expected, attempts) do
    with {:ok, wrapper} <- Codec.encode(snapshot) do
      case MemoryStore.compare_and_swap_tainted(
             @namespace,
             agent_id,
             expected,
             wrapper,
             taint: snapshot.aggregate.taint
           ) do
        {:ok, stored} ->
          {:ok, snapshot, stored}

        {:error, {:memory_store, :critical, :conflict}} ->
          read_authority(agent_id, attempts - 1)

        {:error, _reason} = error ->
          map_store_error(error)

        _ ->
          {:error, :outcome_unknown}
      end
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp project_or_schedule(state, agent_id, snapshot) do
    case install_projection(agent_id, snapshot) do
      :ok -> clear_pending_projection(state, agent_id)
      {:error, _reason} -> schedule_projection(state, agent_id)
    end
  end

  defp install_projection(agent_id, snapshot) do
    evict_projection(agent_id)

    with :ok <- clear_projection_provenance(agent_id),
         :ok <-
           put_label(
             :knowledge_graph_base,
             agent_id,
             "base",
             snapshot.base_payload,
             snapshot.base
           ),
         :ok <-
           put_label(
             :knowledge_graph_aggregate,
             agent_id,
             "aggregate",
             snapshot.payload,
             snapshot.aggregate
           ),
         :ok <- put_inventory(:knowledge_node, agent_id, snapshot.nodes),
         :ok <- put_inventory(:knowledge_pending_fact, agent_id, snapshot.pending_facts),
         :ok <-
           put_inventory(:knowledge_pending_learning, agent_id, snapshot.pending_learnings),
         :ok <-
           put_inventory(
             :knowledge_maintenance_effect,
             agent_id,
             snapshot.maintenance_effects
           ),
         true <- :ets.insert(@graph_ets, {agent_id, snapshot.graph}) do
      :ok
    else
      _ ->
        evict_projection(agent_id)
        _ = clear_projection_provenance(agent_id)
        {:error, :projection_unavailable}
    end
  rescue
    _ ->
      evict_projection(agent_id)
      _ = clear_projection_provenance(agent_id)
      {:error, :projection_unavailable}
  catch
    _, _ ->
      evict_projection(agent_id)
      _ = clear_projection_provenance(agent_id)
      {:error, :projection_unavailable}
  end

  defp put_inventory(domain, agent_id, inventory) do
    Enum.reduce_while(inventory, :ok, fn {item_id, item}, :ok ->
      case put_label(domain, agent_id, item_id, item.payload, item.label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_label(domain, agent_id, item_id, payload, label) do
    case Provenance.put(domain, agent_id, item_id, payload, label.taint) do
      :ok -> :ok
      {:error, _reason} -> {:error, :projection_unavailable}
      _ -> {:error, :projection_unavailable}
    end
  end

  defp clear_projection_provenance(agent_id) do
    Enum.reduce(@projection_domains, :ok, fn domain, result ->
      case Provenance.delete_domain_agent(domain, agent_id) do
        :ok -> result
        {:error, _reason} -> {:error, :projection_unavailable}
        _ -> {:error, :projection_unavailable}
      end
    end)
  rescue
    _ -> {:error, :projection_unavailable}
  catch
    _, _ -> {:error, :projection_unavailable}
  end

  defp invalidate_projection(state, agent_id) do
    evict_projection(agent_id)
    _ = clear_projection_provenance(agent_id)
    clear_pending_projection(state, agent_id)
  end

  defp invalidate_after_read(state, agent_id, reason) do
    state = invalidate_projection(state, agent_id)

    if transient_authority_failure?(reason),
      do: schedule_projection(state, agent_id),
      else: state
  end

  defp invalidate_after_mutation(state, agent_id, reason) do
    invalidate? =
      reason in [
        :conflict,
        :graph_limit_exceeded,
        :graph_not_initialized,
        :invalid_provenance,
        :outcome_unknown,
        :store_unavailable
      ]

    if invalidate? do
      state = invalidate_projection(state, agent_id)

      if transient_authority_failure?(reason),
        do: schedule_projection(state, agent_id),
        else: state
    else
      state
    end
  end

  defp transient_authority_failure?(reason),
    do: reason in [:conflict, :outcome_unknown, :store_unavailable]

  defp evict_projection(agent_id) do
    if :ets.whereis(@graph_ets) != :undefined, do: :ets.delete(@graph_ets, agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_agent_content_absent?(agent_id, state) do
    case durable_graph_presence(agent_id) do
      :present ->
        {:ok, false}

      :absent ->
        ets_absent? = graph_ets_absent?(agent_id)
        deferred_absent? = not Map.has_key?(state.pending_projection, agent_id)

        if ets_absent? and deferred_absent? do
          {:ok, true}
        else
          {:ok, false}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp durable_graph_presence(agent_id) do
    case MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id) do
      {:ok, _value, _status, _record, _location} ->
        :present

      {:error, :not_found} ->
        :absent

      {:error, _reason} = error ->
        case map_store_error(error) do
          {:error, :graph_not_initialized} -> :absent
          other -> other
        end

      _ ->
        {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp graph_ets_absent?(agent_id) do
    case :ets.whereis(@graph_ets) do
      :undefined -> true
      _ -> :ets.lookup(@graph_ets, agent_id) == []
    end
  rescue
    _ -> true
  catch
    _, _ -> false
  end

  defp valid_agent_id?(agent_id) when is_binary(agent_id) do
    byte_size(agent_id) in 1..256 and String.valid?(agent_id) and String.trim(agent_id) != ""
  end

  defp valid_agent_id?(_agent_id), do: false

  defp schedule_projection(%{pending_projection: pending} = state, agent_id) do
    if Map.has_key?(pending, agent_id) do
      state
    else
      Process.send_after(self(), {:converge_projection, agent_id, 1}, 10)
      %{state | pending_projection: Map.put(pending, agent_id, 1)}
    end
  end

  defp retry_projection(state, _agent_id, attempt) when attempt >= @projection_attempts,
    do: state

  defp retry_projection(%{pending_projection: pending} = state, agent_id, attempt) do
    next_attempt = attempt + 1
    delay = min(10 * next_attempt * next_attempt, 1_000)
    Process.send_after(self(), {:converge_projection, agent_id, next_attempt}, delay)
    %{state | pending_projection: Map.put(pending, agent_id, next_attempt)}
  end

  defp clear_pending_projection(%{pending_projection: pending} = state, agent_id),
    do: %{state | pending_projection: Map.delete(pending, agent_id)}

  defp call_save(agent_id, operation, taint) do
    case safe_call(
           {:save, agent_id, operation, taint, request_deadline()},
           :mutation,
           agent_id
         ) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :outcome_unknown}
    end
  end

  defp call_operation(agent_id, operation),
    do: call_operation(agent_id, operation, Codec.missing_taint())

  defp call_operation(agent_id, operation, taint) do
    safe_call(
      {:operate, agent_id, operation, taint, request_deadline()},
      :mutation,
      agent_id
    )
  end

  defp attach_operation_provenance(
         {:consolidate, _operation_id, _mode, _opts, _occurred_at},
         snapshot,
         result
       ) do
    labelled_maintenance_result(snapshot, result)
  end

  defp attach_operation_provenance(_operation, _snapshot, result), do: result

  defp labelled_maintenance_effect(%{
         graph: %KnowledgeGraph{pending_maintenance_effect: nil}
       }),
       do: nil

  defp labelled_maintenance_effect(
         %{
           graph: %KnowledgeGraph{pending_maintenance_effect: effect}
         } = snapshot
       ) do
    labelled_maintenance_result(snapshot, effect)
  end

  defp labelled_maintenance_result(snapshot, result) do
    entries =
      Enum.map(result.archive_entries, fn %{node: %{id: node_id}, reason: reason} = entry ->
        %{label: label, payload: archive_payload} =
          Map.fetch!(snapshot.maintenance_effects, node_id)

        entry
        |> Map.put(:archive_payload, archive_payload)
        |> Map.put(:taint, label.taint)
        |> Map.put(:provenance_status, label.status)
        |> Map.put(:idempotency_key, {result.operation_id, node_id, reason})
      end)

    %{result | archive_entries: entries}
  end

  defp request_deadline do
    System.monotonic_time(:millisecond) + @call_timeout - @deadline_margin
  end

  defp ensure_deadline(deadline) when is_integer(deadline) do
    if System.monotonic_time(:millisecond) <= deadline,
      do: :ok,
      else: {:error, :request_expired}
  end

  defp ensure_deadline(_deadline), do: {:error, :request_expired}

  defp safe_call(message, mode, agent_id) when mode in [:read, :mutation] do
    case Process.whereis(__MODULE__) do
      nil ->
        fail_closed_unavailable(agent_id, mode)

      pid ->
        monitor = Process.monitor(pid)

        try do
          GenServer.call(pid, message, call_timeout(mode))
        catch
          :exit, _reason -> fail_closed_unavailable(agent_id, mode)
        after
          Process.demonitor(monitor, [:flush])
        end
    end
  rescue
    _ -> fail_closed_unavailable(agent_id, mode)
  catch
    _, _ -> fail_closed_unavailable(agent_id, mode)
  end

  # Content-only paths must never clear Provenance on owner loss.
  defp content_safe_call(message, mode, agent_id) when mode in [:read, :mutation] do
    case Process.whereis(__MODULE__) do
      nil ->
        content_fail_closed_unavailable(agent_id, mode)

      pid ->
        monitor = Process.monitor(pid)

        try do
          GenServer.call(pid, message, call_timeout(mode))
        catch
          :exit, _reason -> content_fail_closed_unavailable(agent_id, mode)
        after
          Process.demonitor(monitor, [:flush])
        end
    end
  rescue
    _ -> content_fail_closed_unavailable(agent_id, mode)
  catch
    _, _ -> content_fail_closed_unavailable(agent_id, mode)
  end

  defp fail_closed_unavailable(agent_id, mode) do
    evict_projection(agent_id)
    _ = clear_projection_provenance(agent_id)
    unavailable_for(mode)
  end

  defp content_fail_closed_unavailable(agent_id, mode) do
    # Conservative ETS eviction only; provenance sidecars retained.
    evict_projection(agent_id)
    unavailable_for(mode)
  end

  # Authoritative backends own their finite operation timeout. Reads can also
  # perform a version-migration CAS, so every authority call must wait for that
  # bounded outcome rather than return while an effect can still commit.
  defp call_timeout(mode) when mode in [:read, :mutation], do: :infinity

  defp unavailable_for(:read), do: {:error, :store_unavailable}
  defp unavailable_for(:mutation), do: {:error, :outcome_unknown}

  defp map_store_error({:error, {:memory_store, :critical, :conflict}}),
    do: {:error, :conflict}

  defp map_store_error({:error, {:memory_store, :critical, :outcome_unknown}}),
    do: {:error, :outcome_unknown}

  defp map_store_error({:error, {:memory_store, :critical, :inventory_limit_exceeded}}),
    do: {:error, :graph_limit_exceeded}

  defp map_store_error({:error, {:memory_store, :critical, reason}})
       when reason in [:durable_unavailable, :insufficient_durability],
       do: {:error, :store_unavailable}

  defp map_store_error({:error, {:memory_store, :critical, _reason}}),
    do: {:error, :invalid_provenance}

  defp map_store_error({:error, {:memory_store, :invalid_durable_provenance, _reason}}),
    do: {:error, :invalid_provenance}

  defp map_store_error({:error, :not_found}), do: {:error, :graph_not_initialized}
  defp map_store_error({:error, _reason}), do: {:error, :store_unavailable}
  defp map_store_error(_other), do: {:error, :store_unavailable}
end
