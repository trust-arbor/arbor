defmodule Arbor.Memory.KnowledgeGraphStore do
  @moduledoc false

  use GenServer

  alias Arbor.Contracts.Security.{Taint, TaintedValue}

  alias Arbor.Memory.{KnowledgeGraph, MemoryStore, Provenance}
  alias Arbor.Memory.KnowledgeGraph.Codec

  @namespace "knowledge_graph"
  @graph_ets :arbor_memory_graphs
  @call_timeout 60_000
  @cas_attempts 8
  @projection_attempts 8
  @projection_domains [
    :knowledge_graph_base,
    :knowledge_graph_aggregate,
    :knowledge_node,
    :knowledge_pending_fact,
    :knowledge_pending_learning
  ]

  @type store_error ::
          :graph_not_initialized
          | :store_unavailable
          | :outcome_unknown
          | :conflict
          | :invalid_graph
          | :invalid_provenance
          | :graph_limit_exceeded

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec get_graph(String.t()) :: {:ok, KnowledgeGraph.t()} | {:error, store_error()}
  def get_graph(agent_id), do: safe_call({:read, agent_id}, :read)

  @spec get_snapshot(String.t()) :: {:ok, Codec.snapshot()} | {:error, store_error()}
  def get_snapshot(agent_id), do: safe_call({:read_snapshot, agent_id}, :read)

  @spec save_graph(String.t(), KnowledgeGraph.t()) :: :ok | {:error, store_error()}
  def save_graph(agent_id, %KnowledgeGraph{} = graph) do
    case safe_call({:save, agent_id, graph, Codec.missing_taint()}, :mutation) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :outcome_unknown}
    end
  end

  def save_graph(_agent_id, _graph), do: {:error, :invalid_graph}

  @spec save_graph_tainted(String.t(), KnowledgeGraph.t(), Taint.t()) ::
          :ok | {:error, store_error()}
  def save_graph_tainted(agent_id, %KnowledgeGraph{} = graph, %Taint{} = taint) do
    case safe_call({:save, agent_id, graph, taint}, :mutation) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :outcome_unknown}
    end
  end

  def save_graph_tainted(_agent_id, _graph, _taint), do: {:error, :invalid_graph}

  @spec mutate(String.t(), (KnowledgeGraph.t() -> term())) ::
          {:ok, term()} | {:error, term()}
  def mutate(agent_id, operation) when is_function(operation, 1) do
    safe_call({:mutate, agent_id, operation, Codec.missing_taint()}, :mutation)
  end

  def mutate(_agent_id, _operation), do: {:error, :invalid_graph}

  @spec mutate_tainted(String.t(), Taint.t(), (KnowledgeGraph.t() -> term())) ::
          {:ok, term()} | {:error, term()}
  def mutate_tainted(agent_id, %Taint{} = taint, operation) when is_function(operation, 1) do
    safe_call({:mutate, agent_id, operation, taint}, :mutation)
  end

  def mutate_tainted(_agent_id, _taint, _operation), do: {:error, :invalid_graph}

  @spec import_legacy_graph(String.t(), map()) :: :ok | {:error, store_error()}
  def import_legacy_graph(agent_id, graph_map) when is_map(graph_map) do
    case safe_call({:import_legacy, agent_id, graph_map}, :mutation) do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :outcome_unknown}
    end
  end

  def import_legacy_graph(_agent_id, _graph_map), do: {:error, :invalid_graph}

  @spec delete_graph(String.t()) :: :ok | {:error, store_error()}
  def delete_graph(agent_id), do: safe_call({:delete, agent_id}, :mutation)

  @spec converge_projection(String.t()) :: :ok | {:error, store_error()}
  def converge_projection(agent_id) do
    case safe_call({:converge, agent_id}, :read) do
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

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:read_snapshot, agent_id}, _from, state) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, snapshot, _record} ->
        {:reply, {:ok, snapshot}, project_or_schedule(state, agent_id, snapshot)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:save, agent_id, graph, taint}, _from, state) do
    operation = fn _current -> {:ok, graph, :ok} end

    case mutate_authority(agent_id, operation, taint, :create, @cas_attempts) do
      {:ok, snapshot, result} ->
        {:reply, {:ok, result}, project_or_schedule(state, agent_id, snapshot)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mutate, agent_id, operation, taint}, _from, state) do
    case mutate_authority(agent_id, operation, taint, :existing, @cas_attempts) do
      {:ok, snapshot, result} ->
        {:reply, {:ok, result}, project_or_schedule(state, agent_id, snapshot)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:import_legacy, agent_id, graph_map}, _from, state) do
    with {:ok, graph} <- Codec.decode_legacy_graph(agent_id, graph_map),
         {:ok, snapshot, result} <-
           mutate_authority(
             agent_id,
             fn _current -> {:ok, graph, :ok} end,
             Codec.missing_taint(),
             :create,
             @cas_attempts
           ) do
      {:reply, {:ok, result}, project_or_schedule(state, agent_id, snapshot)}
    else
      {:error, _reason} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_graph}, state}
    end
  end

  def handle_call({:delete, agent_id}, _from, state) do
    case MemoryStore.delete_tainted_authoritative(@namespace, agent_id) do
      :ok ->
        evict_projection(agent_id)

        state = clear_pending_projection(state, agent_id)

        state =
          case clear_projection_provenance(agent_id) do
            :ok -> state
            {:error, _reason} -> schedule_projection(state, agent_id)
          end

        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, map_store_error(error), state}

      _ ->
        {:reply, {:error, :outcome_unknown}, state}
    end
  end

  def handle_call({:converge, agent_id}, _from, state) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, snapshot, _record} ->
        {:reply, {:ok, snapshot.graph}, project_or_schedule(state, agent_id, snapshot)}

      {:error, :graph_not_initialized} = error ->
        evict_projection(agent_id)

        state =
          case clear_projection_provenance(agent_id) do
            :ok -> clear_pending_projection(state, agent_id)
            {:error, _reason} -> schedule_projection(state, agent_id)
          end

        {:reply, error, state}

      {:error, _reason} = error ->
        evict_projection(agent_id)
        {:reply, error, clear_pending_projection(state, agent_id)}
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
          evict_projection(agent_id)

          case clear_projection_provenance(agent_id) do
            :ok -> {:noreply, state}
            {:error, _reason} -> {:noreply, retry_projection(state, agent_id, attempt)}
          end

        {:error, reason} when reason in [:store_unavailable, :conflict] ->
          evict_projection(agent_id)
          {:noreply, retry_projection(state, agent_id, attempt)}

        {:error, _reason} ->
          evict_projection(agent_id)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp mutate_authority(_agent_id, _operation, _taint, _mode, 0),
    do: {:error, :conflict}

  defp mutate_authority(agent_id, operation, taint, mode, attempts) do
    with {:ok, taint} <- Taint.canonicalize(taint),
         {:ok, previous, expected} <- mutation_baseline(agent_id, mode),
         {:ok, graph, result} <- apply_operation(operation, previous),
         {:ok, candidate} <- Codec.reconcile(agent_id, graph, previous, taint),
         {:ok, wrapper} <- Codec.encode(candidate) do
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
          mutate_authority(agent_id, operation, taint, mode, attempts - 1)

        {:error, _reason} = error ->
          map_store_error(error)

        _ ->
          {:error, :outcome_unknown}
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

  defp mutation_baseline(agent_id, mode) do
    case read_authority(agent_id, @cas_attempts) do
      {:ok, snapshot, record} ->
        {:ok, snapshot, record}

      {:error, :graph_not_initialized} when mode == :create ->
        {:ok, nil, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_operation(operation, nil) do
    case operation.(nil) do
      {:ok, %KnowledgeGraph{} = graph, result} -> {:ok, graph, result}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  end

  defp apply_operation(operation, snapshot) do
    case operation.(snapshot.graph) do
      {:ok, %KnowledgeGraph{} = graph, result} -> {:ok, graph, result}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_graph}
    end
  end

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
    Enum.reduce_while(@projection_domains, :ok, fn domain, :ok ->
      case Provenance.delete_domain_agent(domain, agent_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :projection_unavailable}}
        _ -> {:halt, {:error, :projection_unavailable}}
      end
    end)
  rescue
    _ -> {:error, :projection_unavailable}
  catch
    _, _ -> {:error, :projection_unavailable}
  end

  defp evict_projection(agent_id) do
    if :ets.whereis(@graph_ets) != :undefined, do: :ets.delete(@graph_ets, agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

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

  defp safe_call(message, mode) when mode in [:read, :mutation] do
    case Process.whereis(__MODULE__) do
      nil ->
        unavailable_for(mode)

      pid ->
        monitor = Process.monitor(pid)

        try do
          GenServer.call(pid, message, @call_timeout)
        catch
          :exit, _reason -> unavailable_for(mode)
        after
          Process.demonitor(monitor, [:flush])
        end
    end
  rescue
    _ -> unavailable_for(mode)
  catch
    _, _ -> unavailable_for(mode)
  end

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
