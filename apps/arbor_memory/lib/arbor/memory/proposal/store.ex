defmodule Arbor.Memory.Proposal.Store do
  @moduledoc false

  use GenServer

  alias Arbor.Contracts.Memory.{Goal, Intent}
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.{Events, GoalStore, GraphOps, IntentStore, Signals}
  alias Arbor.Memory.Proposal.Core

  @call_timeout 30_000
  @deadline_margin 1_000

  @type provenance_status :: Core.provenance_status()
  @type reason ::
          :invalid_request
          | :invalid_type
          | :missing_content
          | :invalid_provenance
          | :invalid_status
          | :not_found
          | :store_unavailable
          | :transfer_outcome_unknown
          | :limit_exceeded
          | :request_expired
          | :empty_description
          | :transfer_in_flight
          | {:invalid_type, atom(), [atom()]}
          | {:invalid_status, atom(), atom()}
          | {:batch_incomplete, list()}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec create(String.t(), atom(), map(), Taint.t(), provenance_status()) ::
          {:ok, map()} | {:ok, :reinforced} | {:error, reason()}
  def create(agent_id, type, data, taint, provenance_status) do
    with :ok <- ensure_status(provenance_status),
         {:ok, taint} <- canonicalize_taint(taint),
         {:ok, fields} <- Core.validate_create(agent_id, type, data) do
      case safe_call({:create, agent_id, type, fields, taint, provenance_status}) do
        {:ok, :check_graph, content, create_taint} ->
          maybe_reinforce_or_insert(
            agent_id,
            type,
            fields,
            content,
            create_taint,
            provenance_status
          )

        other ->
          other
      end
    end
  end

  @spec get_tainted(String.t(), String.t()) ::
          {:ok, TaintedValue.t(), provenance_status()} | {:error, reason()}
  def get_tainted(agent_id, proposal_id) do
    if Core.valid_identifier?(agent_id) and Core.valid_identifier?(proposal_id) do
      safe_call({:get_tainted, agent_id, proposal_id})
    else
      {:error, :invalid_request}
    end
  end

  @spec list_pending_tainted(String.t(), keyword()) ::
          {:ok, [{TaintedValue.t(), provenance_status()}]} | {:error, reason()}
  def list_pending_tainted(agent_id, opts \\ []) do
    with true <- Core.valid_identifier?(agent_id),
         {:ok, clean_opts} <- Core.validate_list_opts(opts) do
      safe_call({:list_pending_tainted, agent_id, clean_opts})
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  @spec reject(String.t(), String.t(), keyword(), Taint.t(), provenance_status()) ::
          :ok | {:error, reason()}
  def reject(agent_id, proposal_id, opts, decision_taint, decision_status) do
    with {:ok, reason} <- Core.validate_reject_opts(opts) do
      review_transition(
        agent_id,
        proposal_id,
        :pending,
        decision_taint,
        decision_status,
        {:reject, reason}
      )
      |> case do
        {:ok, proposal, _taint} ->
          safe_emit(fn ->
            Events.record_pending_rejected(agent_id, proposal_id, proposal.type, reason)
            Signals.emit_proposal_rejected(agent_id, proposal_id, proposal.type, nil)
          end)

          :ok

        error ->
          error
      end
    end
  end

  @spec defer(String.t(), String.t(), Taint.t(), provenance_status()) :: :ok | {:error, reason()}
  def defer(agent_id, proposal_id, decision_taint, decision_status) do
    review_transition(agent_id, proposal_id, :pending, decision_taint, decision_status, :defer)
    |> case do
      {:ok, _proposal, _taint} ->
        safe_emit(fn -> Signals.emit_proposal_deferred(agent_id, proposal_id) end)
        :ok

      error ->
        error
    end
  end

  @spec undefer(String.t(), String.t(), Taint.t(), provenance_status()) ::
          :ok | {:error, reason()}
  def undefer(agent_id, proposal_id, decision_taint, decision_status) do
    review_transition(agent_id, proposal_id, :deferred, decision_taint, decision_status, :undefer)
    |> case do
      {:ok, _proposal, _taint} -> :ok
      error -> error
    end
  end

  @spec accept(String.t(), String.t(), Taint.t(), provenance_status()) ::
          {:ok, String.t()} | {:error, reason()}
  def accept(agent_id, proposal_id, decision_taint, decision_status) do
    with :ok <- ensure_status(decision_status),
         {:ok, decision_taint} <- canonicalize_taint(decision_taint),
         {:ok, prep} <-
           safe_call({:prepare_accept, agent_id, proposal_id, decision_taint, decision_status}) do
      case prep do
        {:already_done, target_id} ->
          {:ok, target_id}

        {:ready, proposal, joined_taint, joined_status, fence} ->
          execute_and_complete_accept(
            agent_id,
            proposal_id,
            proposal,
            joined_taint,
            joined_status,
            fence
          )
      end
    end
  end

  @spec accept_all(String.t(), atom() | nil, Taint.t(), provenance_status()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, {:batch_incomplete, list()} | reason()}
  def accept_all(agent_id, type, decision_taint, decision_status) do
    opts = if type, do: [type: type], else: []

    with {:ok, items} <- list_pending_tainted(agent_id, opts) do
      ordered =
        Enum.map(items, fn {%TaintedValue{value: proposal}, _status} ->
          case accept(agent_id, proposal.id, decision_taint, decision_status) do
            {:ok, target_id} -> {proposal.id, {:ok, target_id}}
            {:error, reason} -> {proposal.id, {:error, reason}}
          end
        end)

      if Enum.all?(ordered, &match?({_, {:ok, _}}, &1)) do
        {:ok, Enum.map(ordered, fn {id, {:ok, target}} -> {id, target} end)}
      else
        {:error, {:batch_incomplete, ordered}}
      end
    end
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, reason()}
  def delete(agent_id, proposal_id) do
    if Core.valid_identifier?(agent_id) and Core.valid_identifier?(proposal_id) do
      safe_call({:delete, agent_id, proposal_id})
    else
      {:error, :invalid_request}
    end
  end

  @spec delete_agent_content(String.t()) :: :ok | {:error, reason()}
  def delete_agent_content(agent_id) do
    if Core.valid_identifier?(agent_id) do
      safe_call({:delete_agent_content, agent_id})
    else
      {:error, :invalid_request}
    end
  end

  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, :store_unavailable | :absence_uncertain | :invalid_request}
  def agent_content_absent?(agent_id) do
    if Core.valid_identifier?(agent_id) do
      safe_call({:agent_content_absent?, agent_id})
    else
      {:error, :invalid_request}
    end
  end

  @spec count_pending(String.t(), keyword()) :: non_neg_integer() | {:error, reason()}
  def count_pending(agent_id, opts \\ []) do
    case list_pending_tainted(agent_id, opts) do
      {:ok, items} -> length(items)
      {:error, _} = error -> error
    end
  end

  @spec stats(String.t()) :: {:ok, map()} | {:error, reason()}
  def stats(agent_id) do
    if Core.valid_identifier?(agent_id) do
      safe_call({:stats, agent_id})
    else
      {:error, :invalid_request}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{by_agent: %{}, totals: %{entries: 0, bytes: 0}}}
  end

  # Owner-checked deadline: a timed-out client must not mutate after the call expires.
  @impl true
  def handle_call({:timed, deadline_ms, message}, from, state)
      when is_integer(deadline_ms) do
    if System.monotonic_time(:millisecond) > deadline_ms do
      {:reply, {:error, :request_expired}, state}
    else
      handle_call(message, from, state)
    end
  end

  def handle_call(
        {:create, agent_id, type, fields, taint, provenance_status},
        _from,
        state
      ) do
    agent_map = Map.get(state.by_agent, agent_id, %{})
    candidates = Enum.map(Map.values(agent_map), & &1.proposal)

    case Core.find_duplicate(candidates, type, fields.content) do
      {:duplicate, existing} ->
        reply = boost_existing(state, agent_id, existing.id, taint, provenance_status)
        {:reply, elem(reply, 0), elem(reply, 1)}

      :no_duplicate ->
        {:reply, {:ok, :check_graph, fields.content, taint}, state}
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call(
        {:insert_new, agent_id, type, fields, taint, provenance_status},
        _from,
        state
      ) do
    reply = do_insert_new(state, agent_id, type, fields, taint, provenance_status)
    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:get_tainted, agent_id, proposal_id}, _from, state) do
    reply = do_get_tainted(state, agent_id, proposal_id)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:list_pending_tainted, agent_id, opts}, _from, state) do
    reply = do_list_pending_tainted(state, agent_id, opts)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call(
        {:review_transition, agent_id, proposal_id, expected, decision_taint, decision_status,
         review_op},
        _from,
        state
      ) do
    reply =
      do_review_transition(
        state,
        agent_id,
        proposal_id,
        expected,
        decision_taint,
        decision_status,
        review_op
      )

    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call(
        {:prepare_accept, agent_id, proposal_id, decision_taint, decision_status},
        _from,
        state
      ) do
    reply = do_prepare_accept(state, agent_id, proposal_id, decision_taint, decision_status)
    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call(
        {:complete_accept, agent_id, proposal_id, target_id, expected_operation_id},
        _from,
        state
      ) do
    reply =
      do_complete_accept(state, agent_id, proposal_id, target_id, expected_operation_id)

    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:abort_accept, agent_id, proposal_id, keep_in_flight?}, _from, state) do
    reply = do_abort_accept(state, agent_id, proposal_id, keep_in_flight?)
    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:delete, agent_id, proposal_id}, _from, state) do
    reply = do_delete(state, agent_id, proposal_id)
    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:delete_agent_content, agent_id}, _from, state) do
    reply = do_delete_agent_content(state, agent_id)
    {:reply, elem(reply, 0), elem(reply, 1)}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call({:agent_content_absent?, agent_id}, _from, state) do
    agent_map = Map.get(state.by_agent, agent_id, %{})
    {:reply, {:ok, map_size(agent_map) == 0}, state}
  rescue
    _ -> {:reply, {:error, :absence_uncertain}, state}
  catch
    _, _ -> {:reply, {:error, :absence_uncertain}, state}
  end

  def handle_call({:stats, agent_id}, _from, state) do
    proposals =
      state.by_agent
      |> Map.get(agent_id, %{})
      |> Map.values()
      |> Enum.map(& &1.proposal)

    {:reply, {:ok, Core.stats(proposals)}, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, state}
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :invalid_request}, state}

  # ---------------------------------------------------------------------------
  # Private client helpers
  # ---------------------------------------------------------------------------

  defp maybe_reinforce_or_insert(
         agent_id,
         type,
         fields,
         content,
         create_taint,
         provenance_status
       ) do
    with {:ok, graph} <- safe_get_graph(agent_id) do
      case Core.find_similar_node(graph, type, content) do
        {:duplicate, node_id} ->
          op_id = Core.reinforce_op_id(agent_id, type, content)

          case GraphOps.reinforce_knowledge_tainted(agent_id, node_id, create_taint,
                 operation_id: op_id
               ) do
            {:ok, _} ->
              {:ok, :reinforced}

            {:error, :outcome_unknown} ->
              {:error, :transfer_outcome_unknown}

            {:error, reason} ->
              {:error, map_transfer_error(reason)}
          end

        :new ->
          safe_call({:insert_new, agent_id, type, fields, create_taint, provenance_status})
      end
    end
  end

  defp safe_get_graph(agent_id) do
    case GraphOps.get_graph(agent_id) do
      {:ok, graph} -> {:ok, graph}
      {:error, :graph_not_initialized} -> {:ok, nil}
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      {:error, :outcome_unknown} -> {:error, :transfer_outcome_unknown}
      {:error, _} -> {:ok, nil}
    end
  rescue
    _ -> {:ok, nil}
  catch
    _, _ -> {:ok, nil}
  end

  # Review ops are applied to the current owner record (not a stale client snapshot)
  # so concurrent boosts cannot be clobbered by reject/defer/undefer.
  defp review_transition(
         agent_id,
         proposal_id,
         expected,
         decision_taint,
         decision_status,
         review_op
       ) do
    with :ok <- ensure_status(decision_status),
         {:ok, decision_taint} <- canonicalize_taint(decision_taint),
         true <- Core.valid_identifier?(agent_id) and Core.valid_identifier?(proposal_id) do
      safe_call(
        {:review_transition, agent_id, proposal_id, expected, decision_taint, decision_status,
         review_op}
      )
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp execute_and_complete_accept(
         agent_id,
         proposal_id,
         proposal,
         joined_taint,
         _joined_status,
         fence
       ) do
    case execute_transfer(proposal, joined_taint, fence) do
      {:ok, target_id} ->
        case safe_call({:complete_accept, agent_id, proposal_id, target_id, fence.operation_id}) do
          :ok ->
            safe_emit(fn ->
              Events.record_proposal_accepted(agent_id, proposal_id, target_id, proposal.type)
              Signals.emit_proposal_accepted(agent_id, proposal_id, target_id)
            end)

            {:ok, target_id}

          {:error, _} = error ->
            error
        end

      {:error, :transfer_outcome_unknown} = error ->
        _ = safe_call({:abort_accept, agent_id, proposal_id, true})
        error

      {:error, _reason} = error ->
        _ = safe_call({:abort_accept, agent_id, proposal_id, false})
        error
    end
  rescue
    _ ->
      _ = safe_call({:abort_accept, agent_id, proposal_id, true})
      {:error, :transfer_outcome_unknown}
  catch
    _, _ ->
      _ = safe_call({:abort_accept, agent_id, proposal_id, true})
      {:error, :transfer_outcome_unknown}
  end

  defp execute_transfer(proposal, taint, fence) do
    case Core.transfer_plan(proposal) do
      {:goal, plan} ->
        transfer_goal(proposal.agent_id, plan, fence.domain_id, taint)

      {:goal_update, plan} ->
        transfer_goal_update(proposal.agent_id, plan, taint)

      {:intent, plan} ->
        transfer_intent(proposal.agent_id, plan, fence.domain_id, taint)

      {:knowledge, node_data} ->
        case GraphOps.add_knowledge_tainted(proposal.agent_id, node_data, taint,
               operation_id: fence.operation_id
             ) do
          {:ok, node_id} -> {:ok, node_id}
          {:error, :outcome_unknown} -> {:error, :transfer_outcome_unknown}
          {:error, reason} -> {:error, map_transfer_error(reason)}
        end
    end
  end

  defp transfer_goal(agent_id, plan, goal_id, taint) do
    description = String.trim(plan.description || "")

    if description == "" do
      {:error, :empty_description}
    else
      goal =
        Goal.new(description,
          id: goal_id,
          priority: normalize_priority(plan.priority)
        )

      case GoalStore.add_goal_tainted(agent_id, goal, taint) do
        {:ok, committed} -> {:ok, committed.id}
        {:error, :outcome_unknown} -> {:error, :transfer_outcome_unknown}
        {:error, reason} -> {:error, map_transfer_error(reason)}
      end
    end
  end

  defp normalize_priority(p) when p in [:low, :medium, :high, :critical], do: p
  defp normalize_priority(p) when is_integer(p), do: p
  defp normalize_priority(p) when is_float(p), do: p
  defp normalize_priority("low"), do: :low
  defp normalize_priority("medium"), do: :medium
  defp normalize_priority("high"), do: :high
  defp normalize_priority("critical"), do: :critical
  defp normalize_priority(_), do: :medium

  defp transfer_goal_update(agent_id, plan, taint) do
    goal_id = plan.goal_id
    progress = plan.progress

    cond do
      not is_binary(goal_id) or goal_id == "" ->
        {:error, :invalid_request}

      not is_number(progress) ->
        {:error, :invalid_request}

      true ->
        case GoalStore.update_goal_progress_tainted(agent_id, goal_id, progress * 1.0, taint) do
          {:ok, _} -> {:ok, goal_id}
          {:error, :outcome_unknown} -> {:error, :transfer_outcome_unknown}
          {:error, reason} -> {:error, map_transfer_error(reason)}
        end
    end
  end

  defp transfer_intent(agent_id, plan, intent_id, taint) do
    intent =
      Intent.capability_intent(plan.capability, coerce_op(plan.op), plan.target,
        id: intent_id,
        reasoning: plan.description
      )

    case IntentStore.record_intent_tainted(agent_id, intent, taint) do
      {:ok, recorded} -> {:ok, recorded.id}
      {:error, :commit_outcome_unknown} -> {:error, :transfer_outcome_unknown}
      {:error, reason} -> {:error, map_transfer_error(reason)}
    end
  end

  defp coerce_op(op) when is_atom(op), do: op

  defp coerce_op(op) when is_binary(op) do
    case op do
      "read" ->
        :read

      "write" ->
        :write

      "exec" ->
        :exec

      "search" ->
        :search

      "file" ->
        :file

      "unknown" ->
        :unknown

      other ->
        try do
          String.to_existing_atom(other)
        rescue
          ArgumentError -> :unknown
        end
    end
  end

  defp coerce_op(_), do: :unknown

  defp map_transfer_error(:invalid_provenance), do: :invalid_provenance
  defp map_transfer_error(:invalid_request), do: :invalid_request
  defp map_transfer_error(:empty_description), do: :empty_description
  defp map_transfer_error(:store_unavailable), do: :store_unavailable
  defp map_transfer_error(:not_found), do: :not_found
  defp map_transfer_error(:graph_not_initialized), do: :store_unavailable
  defp map_transfer_error(_), do: :invalid_request

  # ---------------------------------------------------------------------------
  # State mutations
  # ---------------------------------------------------------------------------

  defp boost_existing(state, agent_id, proposal_id, incoming_taint, incoming_status) do
    with {:ok, record} <- fetch_record(state, agent_id, proposal_id),
         :ok <- ensure_not_in_flight(record),
         payload <- Core.canonicalize_payload(record.proposal),
         {:ok, envelope} <- TaintEnvelope.verify(record.envelope, payload),
         {:ok, joined} <- Core.join_taint(envelope.taint, incoming_taint) do
      boosted = Core.boost_confidence(record.proposal)

      if admit_replacement_bytes?(state, record.proposal, boosted) do
        new_payload = Core.canonicalize_payload(boosted)

        case build_envelope(new_payload, joined) do
          {:ok, env_map} ->
            new_status = Core.worst_status(record.status, incoming_status)
            new_record = %{record | proposal: boosted, envelope: env_map, status: new_status}
            new_state = put_record(state, agent_id, proposal_id, new_record, record)
            {{:ok, struct_proposal(boosted)}, new_state}

          {:error, _} ->
            {{:error, :invalid_provenance}, state}
        end
      else
        {{:error, :limit_exceeded}, state}
      end
    else
      {:error, :not_found} -> {{:error, :not_found}, state}
      {:error, :transfer_in_flight} -> {{:error, :transfer_in_flight}, state}
      {:error, _} -> {{:error, :invalid_provenance}, state}
      _ -> {{:error, :invalid_provenance}, state}
    end
  end

  # Final owner-side linearization: recheck exact/fuzzy dedup after external graph lookup.
  defp do_insert_new(state, agent_id, type, fields, taint, provenance_status) do
    agent_map = Map.get(state.by_agent, agent_id, %{})
    candidates = Enum.map(Map.values(agent_map), & &1.proposal)

    case Core.find_duplicate(candidates, type, fields.content) do
      {:duplicate, existing} ->
        boost_existing(state, agent_id, existing.id, taint, provenance_status)

      :no_duplicate ->
        insert_fresh(state, agent_id, type, fields, taint, provenance_status)
    end
  end

  defp insert_fresh(state, agent_id, type, fields, taint, provenance_status) do
    agent_map = Map.get(state.by_agent, agent_id, %{})

    case select_prunable_ids(agent_map) do
      {:error, :limit_exceeded} ->
        {{:error, :limit_exceeded}, state}

      {:ok, prune_ids} ->
        pruned_bytes =
          Enum.reduce(prune_ids, 0, fn id, acc ->
            case Map.fetch(agent_map, id) do
              {:ok, record} -> acc + Core.estimate_bytes(record.proposal)
              :error -> acc
            end
          end)

        id = generate_proposal_id()
        created_at = DateTime.utc_now()
        proposal_map = Core.build_proposal(agent_id, type, fields, id, created_at)
        bytes = Core.estimate_bytes(proposal_map)
        payload = Core.canonicalize_payload(proposal_map)

        projected_agent_count = map_size(agent_map) - length(prune_ids)
        projected_entries = state.totals.entries - length(prune_ids)
        projected_bytes = state.totals.bytes - pruned_bytes

        # Mutate only after envelope + projected admission succeed (atomic admit).
        case build_envelope(payload, taint) do
          {:ok, env_map} ->
            cond do
              not Core.within_agent_bounds?(projected_agent_count) ->
                {{:error, :limit_exceeded}, state}

              not Core.within_total_bounds?(projected_entries, projected_bytes, bytes) ->
                {{:error, :limit_exceeded}, state}

              true ->
                state_after_prune =
                  Enum.reduce(prune_ids, state, fn prune_id, acc ->
                    delete_record(acc, agent_id, prune_id)
                  end)

                record = %{
                  proposal: proposal_map,
                  envelope: env_map,
                  status: provenance_status,
                  fence: nil
                }

                new_state = put_record(state_after_prune, agent_id, id, record, nil)
                proposal = struct_proposal(proposal_map)

                safe_emit(fn -> Signals.emit_proposal_created(agent_id, proposal) end)
                {{:ok, proposal}, new_state}
            end

          {:error, _} ->
            {{:error, :invalid_provenance}, state}
        end
    end
  end

  # Never prune in-flight proposals. If the pending cap cannot be met from
  # eligible (non-in-flight) records, fail closed without mutating state.
  defp select_prunable_ids(agent_map) do
    pending_records =
      agent_map
      |> Map.values()
      |> Enum.filter(fn record -> record.proposal.status == :pending end)

    overflow = length(pending_records) - Core.max_pending() + 1

    if overflow <= 0 do
      {:ok, []}
    else
      prunable =
        pending_records
        |> Enum.reject(&in_flight?/1)
        |> Enum.map(& &1.proposal)

      if length(prunable) < overflow do
        {:error, :limit_exceeded}
      else
        prune_ids =
          prunable
          |> Enum.sort_by(fn p -> {p.confidence, p.created_at} end, :asc)
          |> Enum.take(overflow)
          |> Enum.map(& &1.id)

        {:ok, prune_ids}
      end
    end
  end

  defp do_get_tainted(state, agent_id, proposal_id) do
    with {:ok, record} <- fetch_record(state, agent_id, proposal_id),
         payload <- Core.canonicalize_payload(record.proposal),
         {:ok, envelope} <- TaintEnvelope.verify(record.envelope, payload) do
      proposal = struct_proposal(record.proposal)
      {:ok, TaintedValue.wrap(proposal, envelope.taint), record.status}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :invalid_provenance}
      _ -> {:error, :invalid_provenance}
    end
  end

  defp do_list_pending_tainted(state, agent_id, opts) do
    records = Map.get(state.by_agent, agent_id, %{}) |> Map.values()
    proposals = Enum.map(records, & &1.proposal)
    pending = Core.sort_and_filter(proposals, opts)

    Enum.reduce_while(pending, {:ok, []}, fn proposal, {:ok, acc} ->
      case do_get_tainted(state, agent_id, proposal.id) do
        {:ok, tv, status} ->
          {:cont, {:ok, acc ++ [{tv, status}]}}

        {:error, :invalid_provenance} ->
          {:halt, {:error, :invalid_provenance}}

        {:error, :not_found} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp do_review_transition(
         state,
         agent_id,
         proposal_id,
         expected,
         decision_taint,
         decision_status,
         review_op
       ) do
    with {:ok, record} <- fetch_record(state, agent_id, proposal_id),
         :ok <- ensure_not_in_flight(record),
         :ok <- Core.validate_transition(record.proposal, expected),
         payload <- Core.canonicalize_payload(record.proposal),
         {:ok, envelope} <- TaintEnvelope.verify(record.envelope, payload),
         {:ok, joined} <- Core.join_taint(envelope.taint, decision_taint),
         {:ok, updated_map} <- apply_review_op(record.proposal, review_op) do
      if admit_replacement_bytes?(state, record.proposal, updated_map) do
        new_payload = Core.canonicalize_payload(updated_map)

        case build_envelope(new_payload, joined) do
          {:ok, env_map} ->
            new_status = Core.worst_status(record.status, decision_status)

            new_record = %{
              record
              | proposal: updated_map,
                envelope: env_map,
                status: new_status
            }

            new_state = put_record(state, agent_id, proposal_id, new_record, record)
            {{:ok, struct_proposal(new_record.proposal), joined}, new_state}

          {:error, _} ->
            {{:error, :invalid_provenance}, state}
        end
      else
        {{:error, :limit_exceeded}, state}
      end
    else
      {:error, :not_found} -> {{:error, :not_found}, state}
      {:error, :transfer_in_flight} -> {{:error, :transfer_in_flight}, state}
      {:error, {:invalid_status, _, _} = reason} -> {{:error, reason}, state}
      {:error, :invalid_request} -> {{:error, :invalid_request}, state}
      {:error, _} -> {{:error, :invalid_provenance}, state}
      _ -> {{:error, :invalid_provenance}, state}
    end
  end

  defp apply_review_op(proposal, {:reject, reason}),
    do: {:ok, Core.apply_reject(proposal, reason)}

  defp apply_review_op(proposal, :defer),
    do: {:ok, Core.apply_defer(proposal, DateTime.utc_now())}

  defp apply_review_op(proposal, :undefer), do: {:ok, Core.apply_undefer(proposal)}
  defp apply_review_op(_proposal, _op), do: {:error, :invalid_request}

  defp do_prepare_accept(state, agent_id, proposal_id, decision_taint, decision_status) do
    with {:ok, record} <- fetch_record(state, agent_id, proposal_id),
         payload <- Core.canonicalize_payload(record.proposal),
         {:ok, envelope} <- TaintEnvelope.verify(record.envelope, payload),
         {:ok, payload_sha256} <- TaintEnvelope.payload_sha256(payload),
         {:ok, envelope_fingerprint} <- envelope_fingerprint(record.envelope),
         {:ok, joined} <- Core.join_taint(envelope.taint, decision_taint) do
      joined_status = Core.worst_status(record.status, decision_status)
      fence_ids = Core.fence_ids(record.proposal)

      cond do
        record.proposal.status == :accepted and
            match?(%{phase: :done, target_id: t} when is_binary(t), record.fence) ->
          {{:ok, {:already_done, record.fence.target_id}}, state}

        match?(%{phase: :in_flight, operation_id: op} when is_binary(op), record.fence) ->
          fence = record.fence

          case verify_fence_snapshot(fence, payload_sha256, envelope_fingerprint) do
            :ok ->
              proposal = struct_proposal(record.proposal)
              reserved_joined = Map.fetch!(fence, :joined_taint)
              reserved_status = Map.fetch!(fence, :joined_status)
              {{:ok, {:ready, proposal, reserved_joined, reserved_status, fence}}, state}

            {:error, reason} ->
              {{:error, reason}, state}
          end

        record.proposal.status != :pending ->
          {{:error, {:invalid_status, record.proposal.status, :pending}}, state}

        true ->
          fence = %{
            operation_id: fence_ids.operation_id,
            domain_id: fence_ids.domain_id,
            phase: :in_flight,
            target_id: nil,
            decision_taint: decision_taint,
            decision_status: decision_status,
            joined_taint: joined,
            joined_status: joined_status,
            payload_sha256: payload_sha256,
            envelope_fingerprint: envelope_fingerprint
          }

          new_record = %{record | fence: fence}
          new_state = put_record(state, agent_id, proposal_id, new_record, record)
          proposal = struct_proposal(record.proposal)

          {{:ok, {:ready, proposal, joined, joined_status, fence}}, new_state}
      end
    else
      {:error, :not_found} -> {{:error, :not_found}, state}
      {:error, _} -> {{:error, :invalid_provenance}, state}
      _ -> {{:error, :invalid_provenance}, state}
    end
  end

  defp do_complete_accept(state, agent_id, proposal_id, target_id, expected_operation_id) do
    with {:ok, record} <- fetch_record(state, agent_id, proposal_id),
         :ok <- match_in_flight_fence(record.fence, expected_operation_id),
         payload <- Core.canonicalize_payload(record.proposal),
         {:ok, _envelope} <- TaintEnvelope.verify(record.envelope, payload),
         {:ok, payload_sha256} <- TaintEnvelope.payload_sha256(payload),
         {:ok, envelope_fingerprint} <- envelope_fingerprint(record.envelope),
         :ok <-
           verify_fence_snapshot(record.fence, payload_sha256, envelope_fingerprint),
         joined_taint when not is_nil(joined_taint) <- Map.get(record.fence, :joined_taint),
         joined_status when not is_nil(joined_status) <- Map.get(record.fence, :joined_status) do
      accepted = Core.apply_accept(record.proposal)

      if admit_replacement_bytes?(state, record.proposal, accepted) do
        accepted_payload = Core.canonicalize_payload(accepted)

        case build_envelope(accepted_payload, joined_taint) do
          {:ok, env_map} ->
            fence = %{
              operation_id: expected_operation_id,
              domain_id: Map.get(record.fence, :domain_id),
              phase: :done,
              target_id: target_id,
              decision_taint: Map.get(record.fence, :decision_taint),
              decision_status: Map.get(record.fence, :decision_status),
              joined_taint: joined_taint,
              joined_status: joined_status,
              payload_sha256: Map.get(record.fence, :payload_sha256),
              envelope_fingerprint: Map.get(record.fence, :envelope_fingerprint)
            }

            new_record = %{
              record
              | proposal: accepted,
                envelope: env_map,
                status: joined_status,
                fence: fence
            }

            new_state = put_record(state, agent_id, proposal_id, new_record, record)
            {:ok, new_state}

          {:error, _} ->
            {{:error, :invalid_provenance}, state}
        end
      else
        {{:error, :limit_exceeded}, state}
      end
    else
      {:error, :not_found} -> {{:error, :not_found}, state}
      {:error, :transfer_in_flight} -> {{:error, :transfer_in_flight}, state}
      {:error, :invalid_fence} -> {{:error, :invalid_request}, state}
      {:error, :invalid_provenance} -> {{:error, :invalid_provenance}, state}
      {:error, _} -> {{:error, :invalid_provenance}, state}
      nil -> {{:error, :invalid_request}, state}
      _ -> {{:error, :invalid_provenance}, state}
    end
  end

  defp verify_fence_snapshot(fence, payload_sha256, envelope_fingerprint) do
    reserved_payload = Map.get(fence, :payload_sha256)
    reserved_envelope = Map.get(fence, :envelope_fingerprint)

    cond do
      not is_binary(reserved_payload) or not is_binary(reserved_envelope) ->
        {:error, :invalid_provenance}

      reserved_payload != payload_sha256 ->
        {:error, :invalid_provenance}

      reserved_envelope != envelope_fingerprint ->
        {:error, :invalid_provenance}

      true ->
        :ok
    end
  end

  defp envelope_fingerprint(envelope_map) when is_map(envelope_map) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(envelope_map))
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    _ -> {:error, :invalid_provenance}
  end

  defp envelope_fingerprint(_), do: {:error, :invalid_provenance}

  defp ensure_not_in_flight(record) do
    if in_flight?(record), do: {:error, :transfer_in_flight}, else: :ok
  end

  defp in_flight?(record) do
    match?(%{phase: :in_flight}, record.fence)
  end

  defp match_in_flight_fence(%{phase: :in_flight, operation_id: op} = _fence, expected)
       when is_binary(op) and op == expected,
       do: :ok

  defp match_in_flight_fence(%{phase: :in_flight}, _expected), do: {:error, :invalid_fence}
  defp match_in_flight_fence(_fence, _expected), do: {:error, :invalid_fence}

  defp do_abort_accept(state, agent_id, proposal_id, keep_in_flight?) do
    case fetch_record(state, agent_id, proposal_id) do
      {:ok, record} ->
        fence =
          if keep_in_flight? do
            record.fence
          else
            nil
          end

        new_record = %{record | fence: fence}
        new_state = put_record(state, agent_id, proposal_id, new_record, record)
        {:ok, new_state}

      {:error, :not_found} ->
        {:ok, state}
    end
  end

  defp do_delete(state, agent_id, proposal_id) do
    case fetch_record(state, agent_id, proposal_id) do
      {:ok, _} ->
        {:ok, delete_record(state, agent_id, proposal_id)}

      {:error, :not_found} ->
        {{:error, :not_found}, state}
    end
  end

  defp do_delete_agent_content(state, agent_id) do
    agent_map = Map.get(state.by_agent, agent_id, %{})

    new_state =
      Enum.reduce(Map.keys(agent_map), state, fn id, acc ->
        delete_record(acc, agent_id, id)
      end)

    {:ok, new_state}
  end

  defp fetch_record(state, agent_id, proposal_id) do
    case get_in(state.by_agent, [agent_id, proposal_id]) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp put_record(state, agent_id, proposal_id, record, previous) do
    old_bytes = if previous, do: Core.estimate_bytes(previous.proposal), else: 0
    new_bytes = Core.estimate_bytes(record.proposal)
    entry_delta = if previous, do: 0, else: 1

    agent_map =
      state.by_agent
      |> Map.get(agent_id, %{})
      |> Map.put(proposal_id, record)

    %{
      state
      | by_agent: Map.put(state.by_agent, agent_id, agent_map),
        totals: %{
          entries: state.totals.entries + entry_delta,
          bytes: state.totals.bytes - old_bytes + new_bytes
        }
    }
  end

  defp delete_record(state, agent_id, proposal_id) do
    case fetch_record(state, agent_id, proposal_id) do
      {:ok, record} ->
        bytes = Core.estimate_bytes(record.proposal)
        agent_map = Map.get(state.by_agent, agent_id, %{}) |> Map.delete(proposal_id)

        by_agent =
          if map_size(agent_map) == 0 do
            Map.delete(state.by_agent, agent_id)
          else
            Map.put(state.by_agent, agent_id, agent_map)
          end

        %{
          state
          | by_agent: by_agent,
            totals: %{
              entries: max(0, state.totals.entries - 1),
              bytes: max(0, state.totals.bytes - bytes)
            }
        }

      {:error, :not_found} ->
        state
    end
  end

  defp admit_replacement_bytes?(state, old_proposal, new_proposal) do
    projected =
      state.totals.bytes - Core.estimate_bytes(old_proposal) + Core.estimate_bytes(new_proposal)

    projected <= Core.limits().max_total_bytes
  end

  defp generate_proposal_id do
    "prop_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp build_envelope(payload, taint) do
    with {:ok, envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, map} <- TaintEnvelope.to_map(envelope) do
      {:ok, map}
    end
  end

  defp struct_proposal(map) when is_map(map) do
    %{
      id: Map.fetch!(map, :id),
      agent_id: Map.fetch!(map, :agent_id),
      type: Map.fetch!(map, :type),
      content: Map.fetch!(map, :content),
      confidence: Map.get(map, :confidence, 0.5),
      source: Map.get(map, :source),
      evidence: Map.get(map, :evidence, []),
      metadata: Map.get(map, :metadata, %{}),
      created_at: Map.get(map, :created_at),
      status: Map.get(map, :status, :pending)
    }
  end

  defp canonicalize_taint(taint) do
    case Taint.canonicalize(taint) do
      {:ok, %Taint{} = t} -> {:ok, t}
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  defp ensure_status(status)
       when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance],
       do: :ok

  defp ensure_status(_), do: {:error, :invalid_request}

  defp safe_call(message) do
    # Deadline checked by owner before mutation so a timed-out queued call cannot
    # apply after the client already observed :request_expired.
    deadline_ms =
      System.monotonic_time(:millisecond) + @call_timeout - @deadline_margin

    GenServer.call(__MODULE__, {:timed, deadline_ms, message}, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :store_unavailable}
    :exit, {:timeout, _} -> {:error, :request_expired}
    :exit, _ -> {:error, :store_unavailable}
  end

  defp safe_emit(fun) do
    _ = fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
