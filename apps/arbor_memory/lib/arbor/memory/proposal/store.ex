defmodule Arbor.Memory.Proposal.Store do
  @moduledoc false

  use GenServer

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.{Events, GoalStore, GraphOps, IntentStore, KnowledgeGraphStore, Signals}
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.{Lease, OwnerRoots}
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
    end
  end

  @spec defer(String.t(), String.t(), Taint.t(), provenance_status()) :: :ok | {:error, reason()}
  def defer(agent_id, proposal_id, decision_taint, decision_status) do
    review_transition(agent_id, proposal_id, :pending, decision_taint, decision_status, :defer)
  end

  @spec undefer(String.t(), String.t(), Taint.t(), provenance_status()) ::
          :ok | {:error, reason()}
  def undefer(agent_id, proposal_id, decision_taint, decision_status) do
    review_transition(agent_id, proposal_id, :deferred, decision_taint, decision_status, :undefer)
  end

  @spec accept(String.t(), String.t(), Taint.t(), provenance_status()) ::
          {:ok, String.t()} | {:error, reason()}
  def accept(agent_id, proposal_id, decision_taint, decision_status) do
    with :ok <- ensure_status(decision_status),
         {:ok, decision_taint} <- canonicalize_taint(decision_taint),
         true <- Core.valid_identifier?(agent_id) and Core.valid_identifier?(proposal_id) do
      safe_call({:accept, agent_id, proposal_id, decision_taint, decision_status})
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec acknowledge_transfer(map()) :: :ok | {:error, atom()}
  def acknowledge_transfer(report) when is_map(report) do
    GenServer.call(__MODULE__, {:proposal_transfer_result, report}, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :store_unavailable}
    :exit, {:timeout, _} -> {:error, :store_unavailable}
    :exit, _ -> {:error, :store_unavailable}
  end

  def acknowledge_transfer(_report), do: {:error, :invalid_request}

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
    {:ok, empty_state()}
  end

  # Owner-checked deadline: a timed-out client must not mutate after the call expires.
  @impl true
  def handle_call({:timed, deadline_ms, message}, from, state)
      when is_integer(deadline_ms) do
    if System.monotonic_time(:millisecond) > deadline_ms do
      {:reply, {:error, :request_expired}, state}
    else
      handle_call(attach_owner_deadline(message, deadline_ms), from, state)
    end
  end

  def handle_call(
        {:create, agent_id, type, fields, taint, provenance_status},
        _from,
        state
      ) do
    state = normalize_state(state)

    case Core.validate_create_mailbox(agent_id, type, fields, taint, provenance_status) do
      {:ok, fields} ->
        agent_map = Map.get(state.by_agent, agent_id, %{})
        candidates = Enum.map(Map.values(agent_map), & &1.proposal)

        case Core.find_duplicate(candidates, type, fields.content) do
          {:duplicate, existing} ->
            with_simple_root(state, agent_id, fn state ->
              boost_existing(state, agent_id, existing.id, taint, provenance_status)
            end)

          :no_duplicate ->
            {:reply, {:ok, :check_graph, fields.content, taint}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call(
        {:insert_new, agent_id, type, fields, taint, provenance_status},
        _from,
        state
      ) do
    state = normalize_state(state)

    case Core.validate_create_mailbox(agent_id, type, fields, taint, provenance_status) do
      {:ok, fields} ->
        with_simple_root(state, agent_id, fn state ->
          do_insert_new(state, agent_id, type, fields, taint, provenance_status)
        end)

      {:error, _} = error ->
        {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:get_tainted, agent_id, proposal_id}, _from, state) do
    state = normalize_state(state)
    reply = do_get_tainted(state, agent_id, proposal_id)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:list_pending_tainted, agent_id, opts}, _from, state) do
    state = normalize_state(state)
    reply = do_list_pending_tainted(state, agent_id, opts)
    {:reply, reply, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call(
        {:review_transition, agent_id, proposal_id, expected, decision_taint, decision_status,
         review_op},
        _from,
        state
      ) do
    state = normalize_state(state)

    case Core.validate_review_mailbox(
           agent_id,
           proposal_id,
           expected,
           decision_taint,
           decision_status,
           review_op
         ) do
      {:ok, review_op} ->
        with_simple_root(state, agent_id, fn state ->
          {reply, new_state} =
            do_review_transition(
              state,
              agent_id,
              proposal_id,
              expected,
              decision_taint,
              decision_status,
              review_op
            )

          case reply do
            {:ok, proposal, _joined} ->
              emit_review_effects(agent_id, proposal_id, proposal, review_op)
              {:ok, new_state}

            _ ->
              {reply, new_state}
          end
        end)

      {:error, _} = error ->
        {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call(
        {:accept, agent_id, proposal_id, decision_taint, decision_status, deadline_ms},
        from,
        state
      )
      when is_integer(deadline_ms) do
    state = normalize_state(state)

    case validate_accept_request(state, agent_id, proposal_id, decision_taint, decision_status) do
      {:already_done, target_id} ->
        with_simple_root(state, agent_id, fn state -> {{:ok, target_id}, state} end)

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, request} ->
        begin_accept(state, from, agent_id, proposal_id, request, deadline_ms)
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:proposal_transfer_result, report}, from, state) do
    state = normalize_state(state)
    {reply, new_state} = handle_transfer_result(state, from, report)
    {:reply, reply, new_state}
  rescue
    _ -> {:reply, {:error, :invalid_request}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :invalid_request}, normalize_state(state)}
  end

  def handle_call(
        {:prepare_accept, agent_id, proposal_id, decision_taint, decision_status},
        _from,
        state
      ) do
    state = normalize_state(state)

    if pending_for_proposal?(state, agent_id, proposal_id) do
      {:reply, {:error, :invalid_request}, state}
    else
      with_simple_root(state, agent_id, fn state ->
        do_prepare_accept(state, agent_id, proposal_id, decision_taint, decision_status)
      end)
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call(
        {:complete_accept, agent_id, proposal_id, target_id, expected_operation_id},
        _from,
        state
      ) do
    state = normalize_state(state)

    if pending_for_proposal?(state, agent_id, proposal_id) do
      {:reply, {:error, :invalid_request}, state}
    else
      with_simple_root(state, agent_id, fn state ->
        do_complete_accept(state, agent_id, proposal_id, target_id, expected_operation_id)
      end)
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:abort_accept, agent_id, proposal_id, keep_in_flight?}, _from, state) do
    state = normalize_state(state)

    if pending_for_proposal?(state, agent_id, proposal_id) do
      {:reply, {:error, :invalid_request}, state}
    else
      with_simple_root(state, agent_id, fn state ->
        do_abort_accept(state, agent_id, proposal_id, keep_in_flight?)
      end)
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:delete, agent_id, proposal_id}, _from, state) do
    state = normalize_state(state)

    case Core.validate_delete_mailbox(agent_id, proposal_id) do
      :ok ->
        with_simple_root(state, agent_id, fn state ->
          do_delete(state, agent_id, proposal_id)
        end)

      {:error, _} = error ->
        {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:delete_agent_content, agent_id}, _from, state) do
    state = normalize_state(state)
    {reply, new_state} = cleanup_agent_content(state, agent_id)
    {:reply, reply, new_state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call({:agent_content_absent?, agent_id}, _from, state) do
    state = normalize_state(state)
    agent_map = Map.get(state.by_agent, agent_id, %{})
    absent? = map_size(agent_map) == 0 and not agent_has_owned_work?(state, agent_id)
    {:reply, {:ok, absent?}, state}
  rescue
    _ -> {:reply, {:error, :absence_uncertain}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :absence_uncertain}, normalize_state(state)}
  end

  def handle_call({:stats, agent_id}, _from, state) do
    state = normalize_state(state)

    proposals =
      state.by_agent
      |> Map.get(agent_id, %{})
      |> Map.values()
      |> Enum.map(& &1.proposal)

    {:reply, {:ok, Core.stats(proposals)}, state}
  rescue
    _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  catch
    _, _ -> {:reply, {:error, :store_unavailable}, normalize_state(state)}
  end

  def handle_call(_msg, _from, state) do
    {:reply, {:error, :invalid_request}, normalize_state(state)}
  end

  @impl true
  def handle_continue({:reserve, ref}, state) do
    state = normalize_state(state)
    continue_reserve(state, ref)
  rescue
    _ -> {:noreply, normalize_state(state)}
  catch
    _, _ -> {:noreply, normalize_state(state)}
  end

  def handle_continue(_other, state), do: {:noreply, normalize_state(state)}

  @impl true
  def handle_info({:proposal_handoff, ref}, state) do
    state = normalize_state(state)
    continue_handoff(state, ref)
  rescue
    _ -> {:noreply, normalize_state(state)}
  catch
    _, _ -> {:noreply, normalize_state(state)}
  end

  def handle_info({:accept_timeout, ref}, state) do
    state = normalize_state(state)
    interrupt_pending(state, ref, :timeout)
  rescue
    _ -> {:noreply, normalize_state(state)}
  catch
    _, _ -> {:noreply, normalize_state(state)}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    state = normalize_state(state)

    case pending_by_monitor(state, mon) do
      {:ok, pending} -> interrupt_pending(state, pending.operation_ref, :down)
      :error -> {:noreply, state}
    end
  rescue
    _ -> {:noreply, normalize_state(state)}
  catch
    _, _ -> {:noreply, normalize_state(state)}
  end

  def handle_info({:unresolved_retry, gen}, state) do
    state = normalize_state(state)

    case state[:unresolved_retry] do
      %{gen: ^gen} ->
        {state, progressed?} = retry_unresolved_batch(state)

        state =
          if map_size(unresolved_map(state)) == 0 do
            state
            |> cancel_unresolved_retry()
            |> Map.put(:unresolved_cursor, nil)
          else
            attempts = unresolved_retry_attempts(state)
            next_attempts = if progressed?, do: 0, else: attempts + 1
            schedule_unresolved_retry(state, next_attempts)
          end

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  rescue
    _ -> {:noreply, normalize_state(state)}
  catch
    _, _ -> {:noreply, normalize_state(state)}
  end

  def handle_info(_msg, state), do: {:noreply, normalize_state(state)}

  @impl true
  def format_status(status) when is_map(status) do
    case status do
      %{state: state} when is_map(state) ->
        %{status | state: redact_status_state(state)}

      _ ->
        status
    end
  end

  def format_status(status), do: status

  @impl true
  def code_change(_old_vsn, state, _extra),
    do: {:ok, state |> normalize_state() |> rearm_stale_unresolved_retry()}

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

  defp emit_review_effects(agent_id, proposal_id, proposal, {:reject, reason}) do
    safe_emit(fn ->
      Events.record_pending_rejected(agent_id, proposal_id, proposal.type, reason)
      Signals.emit_proposal_rejected(agent_id, proposal_id, proposal.type, nil)
    end)
  end

  defp emit_review_effects(agent_id, proposal_id, _proposal, :defer) do
    safe_emit(fn -> Signals.emit_proposal_deferred(agent_id, proposal_id) end)
  end

  defp emit_review_effects(_agent_id, _proposal_id, _proposal, _op), do: :ok

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

  defp attach_owner_deadline(
         {:accept, agent_id, proposal_id, decision_taint, decision_status},
         deadline_ms
       ) do
    {:accept, agent_id, proposal_id, decision_taint, decision_status, deadline_ms}
  end

  defp attach_owner_deadline(message, _deadline_ms), do: message

  defp safe_emit(fun) do
    _ = fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Owner roots and acceptance machine
  # ---------------------------------------------------------------------------

  @unresolved_settle_batch 8

  defp empty_state do
    %{
      by_agent: %{},
      totals: %{entries: 0, bytes: 0},
      owner_roots: OwnerRoots.new(),
      pending_acceptances: %{},
      unresolved_roots: %{},
      unresolved_cursor: nil,
      unresolved_retry: nil
    }
  end

  defp normalize_state(state) when is_map(state) do
    state =
      state
      |> Map.put_new(:by_agent, %{})
      |> Map.put_new(:totals, %{entries: 0, bytes: 0})
      |> Map.put_new(:owner_roots, OwnerRoots.new())
      |> Map.put_new(:pending_acceptances, %{})
      |> Map.put_new(:unresolved_roots, %{})
      |> Map.put_new(:unresolved_cursor, nil)
      |> Map.put_new(:unresolved_retry, nil)

    state = reject_malformed_lease_evidence!(state)

    {kept, state} =
      Enum.reduce(pending_map(state), {%{}, state}, fn {ref, pending}, {acc, acc_state} ->
        case canonicalize_pending(pending) do
          {:ok, pending} when pending.operation_ref == ref ->
            pending = maybe_rearm_timer(pending)
            {Map.put(acc, ref, pending), acc_state}

          _error ->
            {acc, quarantine_malformed_pending(acc_state, pending)}
        end
      end)

    state
    |> Map.put(:pending_acceptances, kept)
    |> queue_orphan_owner_roots()
  end

  defp normalize_state(_state), do: empty_state()

  defp canonicalize_pending(pending) when is_map(pending) do
    agent_id = pending[:agent_id]
    target_pid = pending[:target_pid]
    target_module = pending[:target_module]

    with true <- well_formed_from?(pending[:from]),
         true <- Core.valid_identifier?(agent_id),
         true <- Core.valid_identifier?(pending[:proposal_id]),
         true <- is_reference(pending[:operation_ref]),
         true <- Core.valid_identifier?(pending[:operation_id]),
         true <- matching_module_kind?(target_module, pending[:kind]),
         true <- is_pid(target_pid),
         true <- is_reference(pending[:target_monitor]),
         true <- is_integer(pending[:deadline_ms]),
         true <- match?(%Taint{}, pending[:joined_taint]),
         true <- Core.valid_owner_lease?(pending[:proposal_lease], agent_id),
         true <- pending[:fence_origin] in [:new, :preexisting],
         true <- pending[:phase] in [:reserving, :handing_off, :awaiting_result],
         true <- valid_phase_lease?(pending[:phase], pending[:target_lease], agent_id),
         {:ok, plan} <- Core.canonicalize_owner_plan(pending[:kind], pending[:plan]) do
      {:ok, Map.put(pending, :plan, plan)}
    else
      _ -> :error
    end
  end

  defp canonicalize_pending(_), do: :error

  defp valid_phase_lease?(phase, lease, agent_id) when phase in [:reserving, :handing_off],
    do: Core.valid_owner_lease?(lease, agent_id)

  defp valid_phase_lease?(:awaiting_result, :handed, _agent_id), do: true
  defp valid_phase_lease?(_phase, _lease, _agent_id), do: false

  defp reject_malformed_lease_evidence!(state) do
    pending_leases =
      state
      |> pending_map()
      |> Map.values()
      |> Enum.flat_map(fn
        pending when is_map(pending) -> [pending[:proposal_lease], pending[:target_lease]]
        _ -> []
      end)

    owner_leases =
      case owner_roots(state) do
        %OwnerRoots{by_agent: by_agent} ->
          Enum.flat_map(by_agent, fn {_id, leases} -> List.wrap(leases) end)

        _ ->
          []
      end

    unresolved_leases =
      state
      |> unresolved_map()
      |> Enum.flat_map(fn {_id, leases} -> List.wrap(leases) end)

    if Enum.any?(
         pending_leases ++ owner_leases ++ unresolved_leases,
         &malformed_lease_evidence?/1
       ) do
      exit(:malformed_proposal_acceptance_lease)
    else
      state
    end
  end

  defp malformed_lease_evidence?(%{__struct__: Lease} = lease) do
    agent_id = Map.get(lease, :agent_id)
    not Core.valid_owner_lease?(lease, agent_id)
  end

  defp malformed_lease_evidence?(_), do: false

  defp well_formed_pending?(pending), do: match?({:ok, _}, canonicalize_pending(pending))

  defp well_formed_from?({pid, tag}) when is_pid(pid) and is_reference(tag), do: true

  defp well_formed_from?({pid, [:alias | tag]}) when is_pid(pid) and is_reference(tag),
    do: true

  defp well_formed_from?(_), do: false

  defp maybe_rearm_timer(pending) do
    timer_ref = pending[:timer_ref]

    cond do
      is_reference(timer_ref) and is_integer(Process.read_timer(timer_ref)) ->
        pending

      is_integer(pending.deadline_ms) ->
        remaining = max(pending.deadline_ms - System.monotonic_time(:millisecond), 0)

        %{
          pending
          | timer_ref:
              Process.send_after(self(), {:accept_timeout, pending.operation_ref}, remaining)
        }

      true ->
        remaining = 0

        %{
          pending
          | timer_ref:
              Process.send_after(self(), {:accept_timeout, pending.operation_ref}, remaining)
        }
    end
  end

  defp quarantine_malformed_pending(state, pending) when is_map(pending) do
    agent_id = pending_agent_id(pending)

    cancel_pending_watches(pending)

    if well_formed_from?(pending[:from]) do
      GenServer.reply(pending.from, {:error, :transfer_outcome_unknown})
    end

    state
    |> settle_owned(agent_id, pending[:proposal_lease])
    |> settle_unhanded(agent_id, pending[:target_lease])
  end

  defp quarantine_malformed_pending(state, _pending), do: state

  defp queue_orphan_owner_roots(state) do
    referenced =
      state
      |> pending_map()
      |> Map.values()
      |> Enum.map(& &1.proposal_lease)
      |> MapSet.new()

    case owner_roots(state) do
      %OwnerRoots{by_agent: by_agent} ->
        Enum.reduce(by_agent, state, fn {agent_id, leases}, acc ->
          queue_orphan_leases(acc, agent_id, leases, referenced)
        end)

      _ ->
        state
    end
  end

  defp queue_orphan_leases(state, agent_id, leases, referenced) do
    leases
    |> Enum.reject(&MapSet.member?(referenced, &1))
    |> Enum.reduce(state, fn lease, acc -> remember_unresolved(acc, agent_id, lease) end)
  end

  defp owner_roots(%{owner_roots: %OwnerRoots{} = roots}), do: roots
  defp owner_roots(_), do: OwnerRoots.new()

  defp put_owner_roots(state, roots), do: Map.put(state, :owner_roots, roots)

  defp forget_owner_root(state, %Lease{} = lease),
    do: put_owner_roots(state, OwnerRoots.forget(owner_roots(state), lease))

  defp forget_owner_root(state, _lease), do: state

  defp pending_map(%{pending_acceptances: pending}) when is_map(pending), do: pending
  defp pending_map(_), do: %{}

  defp put_pending(state, pending) do
    pending_map = Map.put(pending_map(state), pending.operation_ref, pending)
    %{state | pending_acceptances: pending_map}
  end

  defp drop_pending(state, ref) do
    %{state | pending_acceptances: Map.delete(pending_map(state), ref)}
  end

  defp fetch_pending(state, ref) do
    case Map.fetch(pending_map(state), ref) do
      {:ok, pending} -> {:ok, pending}
      :error -> :error
    end
  end

  defp pending_for_proposal?(state, agent_id, proposal_id) do
    Enum.any?(pending_map(state), fn {_ref, pending} ->
      well_formed_pending?(pending) and pending.agent_id == agent_id and
        pending.proposal_id == proposal_id
    end)
  end

  defp agent_pending_count(state, agent_id) do
    Enum.count(pending_map(state), fn {_ref, pending} ->
      well_formed_pending?(pending) and pending.agent_id == agent_id
    end)
  end

  defp pending_by_monitor(state, mon) do
    Enum.find_value(pending_map(state), :error, fn {_ref, pending} ->
      if well_formed_pending?(pending) and pending.target_monitor == mon,
        do: {:ok, pending},
        else: nil
    end)
  end

  defp admit_fresh(agent_id) do
    case OwnerRoots.admit_new(OwnerRoots.new(), agent_id) do
      {:ok, lease} -> {:ok, lease}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  defp with_simple_root(state, agent_id, fun) do
    case admit_fresh(agent_id) do
      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, state}

      {:ok, lease} ->
        try do
          {reply, new_state} = unwrap_mutation(fun.(state))
          {:reply, reply, finish_simple(new_state, lease)}
        rescue
          _ ->
            {:reply, {:error, :store_unavailable}, finish_simple(normalize_state(state), lease)}
        catch
          _, _ ->
            {:reply, {:error, :store_unavailable}, finish_simple(normalize_state(state), lease)}
        end
    end
  end

  defp unwrap_mutation({:ok, state}) when is_map(state), do: {:ok, state}
  defp unwrap_mutation({reply, state}) when is_map(state), do: {reply, state}

  defp finish_simple(state, %Lease{} = lease) do
    settle_owned(state, lease.agent_id, lease)
  end

  defp finish_simple(state, _lease), do: state

  defp matching_module_kind?(GoalStore, kind) when kind in [:create_goal, :update_goal], do: true
  defp matching_module_kind?(IntentStore, :record_intent), do: true
  defp matching_module_kind?(KnowledgeGraphStore, :create_knowledge), do: true
  defp matching_module_kind?(_module, _kind), do: false

  defp defer_proposal_lease(state, agent_id, lease) do
    case OwnerRoots.defer(owner_roots(state), agent_id, lease) do
      {:ok, roots} -> put_owner_roots(state, roots)
      {:error, _} -> finish_simple(state, lease)
    end
  end

  defp settle_owned(state, agent_id, %Lease{} = lease) do
    {state, _classification} = settle_owned_result(state, agent_id, lease)
    state
  end

  defp settle_owned(state, _agent_id, _), do: state

  defp settle_owned_result(state, agent_id, %Lease{} = lease) do
    agent_id = pending_agent_id(%{agent_id: agent_id, proposal_lease: lease})

    {state, result} =
      try do
        case MutationAdmission.assert_owner(lease) do
          :ok ->
            {roots, result} = OwnerRoots.ack(owner_roots(state), lease)
            {put_owner_roots(state, roots), result}

          other ->
            {state, other}
        end
      catch
        :exit, _reason -> {state, {:error, :unavailable}}
      end

    classification = Core.classify_root_settle(result)

    state =
      case classification do
        :transient ->
          remember_unresolved(state, agent_id, lease)

        :released ->
          forget_unresolved(state, agent_id, lease)

        :absent ->
          state
          |> forget_owner_root(lease)
          |> forget_unresolved(agent_id, lease)
      end

    {state, classification}
  rescue
    _ -> {remember_unresolved(state, agent_id, lease), :transient}
  catch
    _, _ -> {remember_unresolved(state, agent_id, lease), :transient}
  end

  defp settle_owned_result(state, _agent_id, _lease), do: {state, :absent}

  defp settle_unhanded(state, agent_id, %Lease{} = lease),
    do: settle_owned(state, agent_id, lease)

  defp settle_unhanded(state, _agent_id, _), do: state

  defp prove_release(state, agent_id, lease), do: settle_owned(state, agent_id, lease)

  defp remember_unresolved(state, agent_id, %Lease{} = lease) do
    agent_id = pending_agent_id(%{agent_id: agent_id, proposal_lease: lease})

    if is_binary(agent_id) do
      next = Core.remember_unresolved_leases(unresolved_for(state, agent_id), lease)
      unresolved = Map.put(unresolved_map(state), agent_id, next)

      %{state | unresolved_roots: unresolved}
      |> arm_unresolved_retry()
    else
      state
    end
  end

  defp remember_unresolved(state, _agent_id, _), do: state

  defp forget_unresolved(state, agent_id, %Lease{} = lease) when is_binary(agent_id) do
    remaining = Enum.reject(unresolved_for(state, agent_id), &(&1 == lease))
    unresolved = put_unresolved_list(unresolved_map(state), agent_id, remaining)
    state = %{state | unresolved_roots: unresolved}

    if map_size(unresolved_map(state)) == 0 do
      state
      |> cancel_unresolved_retry()
      |> Map.put(:unresolved_cursor, nil)
    else
      state
    end
  end

  defp forget_unresolved(state, _agent_id, _), do: state

  defp unresolved_map(%{unresolved_roots: unresolved}) when is_map(unresolved), do: unresolved
  defp unresolved_map(_), do: %{}

  defp unresolved_for(state, agent_id), do: Map.get(unresolved_map(state), agent_id, [])

  defp put_unresolved_list(unresolved, agent_id, []), do: Map.delete(unresolved, agent_id)

  defp put_unresolved_list(unresolved, agent_id, leases),
    do: Map.put(unresolved, agent_id, leases)

  defp pending_agent_id(pending) when is_map(pending) do
    cond do
      is_binary(pending[:agent_id]) and pending[:agent_id] != "" ->
        pending[:agent_id]

      match?(%Lease{agent_id: id} when is_binary(id) and id != "", pending[:proposal_lease]) ->
        pending[:proposal_lease].agent_id

      match?(%Lease{agent_id: id} when is_binary(id) and id != "", pending[:target_lease]) ->
        pending[:target_lease].agent_id

      true ->
        pending[:agent_id]
    end
  end

  defp pending_agent_id(_pending), do: nil

  defp retry_unresolved_for(state, agent_id, leases \\ nil) do
    leases = leases || unresolved_for(state, agent_id)

    Enum.reduce(List.wrap(leases), state, fn
      %Lease{} = lease, acc -> settle_owned(acc, agent_id, lease)
      _other, acc -> acc
    end)
  end

  defp retry_unresolved_batch(state) do
    settle_unresolved_batch(state)
  end

  defp settle_unresolved_batch(state) do
    cursor = unresolved_cursor(state)

    {state, cursor, _remaining, progressed?} =
      settle_unresolved_cursor(state, cursor, @unresolved_settle_batch, false)

    {%{state | unresolved_cursor: cursor}, progressed?}
  end

  defp settle_unresolved_cursor(state, cursor, 0, progressed?),
    do: {state, cursor, 0, progressed?}

  defp settle_unresolved_cursor(
         state,
         {:map_iterator, iterator, agent_id, [%Lease{} = lease | rest]},
         remaining,
         progressed?
       ) do
    {state, classification} = settle_owned_result(state, agent_id, lease)

    settle_unresolved_cursor(
      state,
      {:map_iterator, iterator, agent_id, rest},
      remaining - 1,
      progressed? or classification != :transient
    )
  end

  defp settle_unresolved_cursor(
         state,
         {:map_iterator, iterator, agent_id, [_invalid | rest]},
         remaining,
         progressed?
       ) do
    settle_unresolved_cursor(
      state,
      {:map_iterator, iterator, agent_id, rest},
      remaining - 1,
      progressed?
    )
  end

  defp settle_unresolved_cursor(
         state,
         {:map_iterator, iterator, _agent_id, []},
         remaining,
         progressed?
       ) do
    case :maps.next(iterator) do
      {agent_id, leases, next_iterator} ->
        settle_unresolved_cursor(
          state,
          {:map_iterator, next_iterator, agent_id, List.wrap(leases)},
          remaining - 1,
          progressed?
        )

      :none ->
        {state, nil, remaining, progressed?}
    end
  end

  defp unresolved_cursor(%{unresolved_cursor: {:map_iterator, _, _, _} = cursor}), do: cursor

  defp unresolved_cursor(state),
    do: {:map_iterator, :maps.iterator(unresolved_map(state)), nil, []}

  defp arm_unresolved_retry(state) do
    ensure_unresolved_retry(state)
  end

  defp ensure_unresolved_retry(state) do
    if map_size(unresolved_map(state)) == 0 do
      state
      |> cancel_unresolved_retry()
      |> Map.put(:unresolved_cursor, nil)
    else
      case state[:unresolved_retry] do
        %{status: :manual_cleanup} ->
          state

        %{status: :armed, timer_ref: ref} when is_reference(ref) ->
          state

        _ ->
          schedule_unresolved_retry(state, unresolved_retry_attempts(state))
      end
    end
  end

  defp rearm_stale_unresolved_retry(state) do
    case state[:unresolved_retry] do
      %{status: :armed, timer_ref: ref} when is_reference(ref) ->
        if is_integer(Process.read_timer(ref)) do
          state
        else
          schedule_unresolved_retry(state, unresolved_retry_attempts(state))
        end

      _ ->
        ensure_unresolved_retry(state)
    end
  end

  defp schedule_unresolved_retry(state, attempts) do
    state = cancel_unresolved_retry(state)

    case Core.unresolved_backoff(attempts) do
      {:retry, delay} when is_integer(delay) and delay > 0 ->
        gen = System.unique_integer([:positive])
        ref = Process.send_after(self(), {:unresolved_retry, gen}, delay)

        Map.put(state, :unresolved_retry, %{
          timer_ref: ref,
          gen: gen,
          attempts: attempts,
          status: :armed
        })

      _ ->
        Map.put(state, :unresolved_retry, %{
          timer_ref: nil,
          gen: nil,
          attempts: attempts,
          status: :manual_cleanup
        })
    end
  end

  defp cancel_unresolved_retry(state) do
    case state[:unresolved_retry] do
      %{timer_ref: ref} when is_reference(ref) ->
        _ = Process.cancel_timer(ref)
        Map.put(state, :unresolved_retry, nil)

      _ ->
        Map.put(state, :unresolved_retry, nil)
    end
  end

  defp unresolved_retry_attempts(state) do
    case state[:unresolved_retry] do
      %{attempts: attempts} when is_integer(attempts) -> attempts
      _ -> 0
    end
  end

  defp agent_has_owned_work?(state, agent_id) do
    agent_pending_count(state, agent_id) > 0 or
      unresolved_for(state, agent_id) != [] or
      OwnerRoots.held?(owner_roots(state), agent_id) or
      Enum.any?(pending_map(state), fn {_ref, pending} ->
        is_map(pending) and pending[:agent_id] == agent_id
      end)
  end

  defp remaining_ms(pending) do
    remaining = pending.deadline_ms - System.monotonic_time(:millisecond)
    if remaining > 0, do: remaining, else: 1
  end

  defp validate_accept_request(state, agent_id, proposal_id, decision_taint, decision_status) do
    with :ok <- ensure_status(decision_status),
         {:ok, decision_taint} <- canonicalize_taint(decision_taint),
         true <- Core.valid_identifier?(agent_id) and Core.valid_identifier?(proposal_id),
         {:ok, record} <- fetch_record(state, agent_id, proposal_id),
         {:ok, provenance} <- verify_accept_provenance(record, decision_taint) do
      cond do
        already_done?(record) ->
          {:already_done, record.fence.target_id}

        pending_for_proposal?(state, agent_id, proposal_id) ->
          {:error, :transfer_in_flight}

        agent_pending_count(state, agent_id) >= Core.max_pending() ->
          {:error, :limit_exceeded}

        true ->
          with {:ok, {kind_tag, plan}} <- Core.validate_transfer_plan(record.proposal),
               {:ok, module, kind} <- resolve_target(kind_tag),
               {:ok, target_pid} <- live_owner(module) do
            {:ok,
             %{
               record: record,
               proposal: struct_proposal(record.proposal),
               plan: decorate_plan(plan, kind, record.proposal),
               kind: kind,
               module: module,
               target_pid: target_pid,
               joined: provenance.joined,
               joined_status: Core.worst_status(record.status, decision_status),
               decision_taint: decision_taint,
               decision_status: decision_status,
               payload_sha256: provenance.payload_sha256,
               envelope_fingerprint: provenance.envelope_fingerprint
             }}
          end
      end
    else
      false -> {:error, :invalid_request}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp verify_accept_provenance(record, decision_taint) do
    payload = Core.canonicalize_payload(record.proposal)

    with {:ok, envelope} <- TaintEnvelope.verify(record.envelope, payload),
         {:ok, payload_sha256} <- TaintEnvelope.payload_sha256(payload),
         {:ok, envelope_fingerprint} <- envelope_fingerprint(record.envelope),
         {:ok, joined} <- Core.join_taint(envelope.taint, decision_taint) do
      {:ok,
       %{
         joined: joined,
         payload_sha256: payload_sha256,
         envelope_fingerprint: envelope_fingerprint
       }}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp already_done?(record) do
    record.proposal.status == :accepted and
      match?(%{phase: :done, target_id: t} when is_binary(t), record.fence)
  end

  defp resolve_target(:goal), do: {:ok, GoalStore, :create_goal}
  defp resolve_target(:goal_update), do: {:ok, GoalStore, :update_goal}
  defp resolve_target(:intent), do: {:ok, IntentStore, :record_intent}
  defp resolve_target(:knowledge), do: {:ok, KnowledgeGraphStore, :create_knowledge}
  defp resolve_target(_), do: {:error, :invalid_request}

  defp live_owner(module) do
    case Process.whereis(module) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :store_unavailable}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp decorate_plan(plan, :create_goal, _proposal) do
    Map.put(plan, :priority, normalize_priority(Map.get(plan, :priority)))
  end

  defp decorate_plan(plan, _kind, _proposal), do: plan

  defp normalize_priority(p) when p in [:low, :medium, :high, :critical], do: p
  defp normalize_priority("low"), do: :low
  defp normalize_priority("medium"), do: :medium
  defp normalize_priority("high"), do: :high
  defp normalize_priority("critical"), do: :critical
  defp normalize_priority(_), do: :medium

  defp begin_accept(state, from, agent_id, proposal_id, request, deadline_ms) do
    with {:ok, proposal_lease} <- admit_fresh(agent_id),
         {:ok, target_lease} <- admit_second(agent_id, proposal_lease) do
      case recheck_accept_gate(state, request, agent_id, proposal_id, deadline_ms) do
        {:error, reason} ->
          state = prove_release(state, agent_id, target_lease)
          {:reply, {:error, reason}, finish_simple(state, proposal_lease)}

        :ok ->
          origin = fence_origin(request.record)

          case do_prepare_accept(
                 state,
                 agent_id,
                 proposal_id,
                 request.decision_taint,
                 request.decision_status
               ) do
            {{:ok, {:already_done, target_id}}, new_state} ->
              new_state = prove_release(new_state, agent_id, target_lease)
              {:reply, {:ok, target_id}, finish_simple(new_state, proposal_lease)}

            {{:ok, {:ready, proposal, joined, _status, fence}}, new_state} ->
              park_accept(
                new_state,
                from,
                agent_id,
                proposal_id,
                request,
                {proposal, joined, fence, origin},
                {proposal_lease, target_lease},
                deadline_ms
              )

            {{:error, reason}, new_state} ->
              new_state = prove_release(new_state, agent_id, target_lease)
              {:reply, {:error, reason}, finish_simple(new_state, proposal_lease)}
          end
      end
    else
      {:error, :store_unavailable, proposal_lease} ->
        {:reply, {:error, :store_unavailable}, finish_simple(state, proposal_lease)}

      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  defp admit_second(agent_id, proposal_lease) do
    case admit_fresh(agent_id) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, reason, proposal_lease}
    end
  end

  defp recheck_accept_gate(state, request, agent_id, proposal_id, deadline_ms) do
    if deadline_expired?(deadline_ms) do
      {:error, :request_expired}
    else
      case live_owner(request.module) do
        {:ok, pid} when pid == request.target_pid ->
          if pending_for_proposal?(state, agent_id, proposal_id) or
               agent_pending_count(state, agent_id) >= Core.max_pending() do
            {:error, :limit_exceeded}
          else
            :ok
          end

        _ ->
          {:error, :store_unavailable}
      end
    end
  end

  defp fence_origin(record) do
    if match?(%{phase: :in_flight, operation_id: op} when is_binary(op), record.fence),
      do: :preexisting,
      else: :new
  end

  defp park_accept(
         state,
         from,
         agent_id,
         proposal_id,
         request,
         {proposal, joined, fence, origin},
         {proposal_lease, target_lease},
         deadline_ms
       ) do
    if deadline_expired?(deadline_ms) do
      {_, state} =
        if origin == :new,
          do: do_abort_accept(state, agent_id, proposal_id, false),
          else: {{:error, :request_expired}, state}

      state = prove_release(state, agent_id, target_lease)
      {:reply, {:error, :request_expired}, finish_simple(state, proposal_lease)}
    else
      ref = make_ref()
      mon = Process.monitor(request.target_pid)
      remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)
      timer_ref = Process.send_after(self(), {:accept_timeout, ref}, remaining)

      plan =
        request.plan
        |> Map.put(:domain_id, fence.domain_id)
        |> Map.put(:proposal_type, proposal.type)

      pending = %{
        from: from,
        agent_id: agent_id,
        proposal_id: proposal_id,
        operation_ref: ref,
        operation_id: fence.operation_id,
        target_pid: request.target_pid,
        target_module: request.module,
        target_monitor: mon,
        deadline_ms: deadline_ms,
        timer_ref: timer_ref,
        proposal_lease: proposal_lease,
        target_lease: target_lease,
        kind: request.kind,
        plan: plan,
        joined_taint: joined,
        fence_origin: origin,
        phase: :reserving
      }

      state =
        state
        |> defer_proposal_lease(agent_id, proposal_lease)
        |> put_pending(pending)

      {:noreply, state, {:continue, {:reserve, ref}}}
    end
  end

  defp deadline_expired?(deadline_ms),
    do: System.monotonic_time(:millisecond) > deadline_ms

  defp continue_reserve(state, ref) do
    case fetch_pending(state, ref) do
      :error ->
        {:noreply, state}

      {:ok, pending} ->
        if deadline_expired?(pending.deadline_ms) do
          apply_interrupt(state, pending, :reserving, :request_expired)
        else
          req = reserve_request(pending)

          result =
            try do
              GenServer.call(
                pending.target_pid,
                {:proposal_transfer_reserve, req},
                remaining_ms(pending)
              )
            catch
              :exit, _ -> {:error, :transfer_outcome_unknown}
            end

          case result do
            :reserved ->
              send(self(), {:proposal_handoff, ref})
              {:noreply, state}

            {:error, reason} ->
              apply_interrupt(state, pending, :reserving, reason)

            _ ->
              apply_interrupt(state, pending, :reserving, :transfer_outcome_unknown)
          end
        end
    end
  end

  defp reserve_request(pending) do
    %{
      agent_id: pending.agent_id,
      proposal_id: pending.proposal_id,
      operation_ref: pending.operation_ref,
      operation_id: pending.operation_id,
      domain_id: Map.get(pending.plan, :domain_id),
      kind: pending.kind,
      plan: pending.plan,
      joined_taint: pending.joined_taint,
      deadline_ms: pending.deadline_ms,
      lease: pending.target_lease
    }
  end

  defp continue_handoff(state, ref) do
    case fetch_pending(state, ref) do
      {:ok, %{phase: :reserving} = pending} ->
        if deadline_expired?(pending.deadline_ms) do
          apply_interrupt(state, pending, :reserving, :request_expired)
        else
          case live_owner(pending.target_module) do
            {:ok, pid} when pid == pending.target_pid ->
              pending = %{pending | phase: :handing_off}
              state = put_pending(state, pending)
              do_handoff_and_activate(state, pending)

            _ ->
              apply_interrupt(state, pending, :reserving, :store_unavailable)
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  defp do_handoff_and_activate(state, pending) do
    lease = pending.target_lease

    handoff_result =
      try do
        MutationAdmission.handoff(lease, pending.target_pid)
      catch
        :exit, _ -> {:error, :indeterminate}
      end

    store_assert =
      try do
        MutationAdmission.assert_owner(lease)
      catch
        :exit, _ -> {:error, :unavailable}
      end

    case Core.classify_handoff_ownership(handoff_result, store_assert) do
      :release_store_owned_unknown ->
        state = prove_release(state, pending.agent_id, lease)
        close_unknown(state, pending, :keep)

      :handed_activate ->
        pending = %{pending | target_lease: :handed}
        state = put_pending(state, pending)

        if deadline_expired?(pending.deadline_ms) do
          state = finish_pending(state, pending, {:error, :request_expired})
          _ = cancel_target_reservation(pending)
          {:noreply, state}
        else
          activate_target(state, pending, lease)
        end

      :release_store_owned_pre_handoff ->
        state = prove_release(state, pending.agent_id, lease)
        apply_interrupt(state, pending, :reserving, map_handoff_error(handoff_result))

      :uncertain_unknown ->
        close_unknown(state, pending, :keep_no_target_release)
    end
  end

  defp map_handoff_error({:error, :invalid_target}), do: :store_unavailable
  defp map_handoff_error({:error, :store_unavailable}), do: :store_unavailable
  defp map_handoff_error(_), do: :transfer_outcome_unknown

  defp activate_target(state, pending, lease) do
    result =
      try do
        GenServer.call(
          pending.target_pid,
          {:proposal_transfer_activate, %{operation_ref: pending.operation_ref, lease: lease}},
          remaining_ms(pending)
        )
      catch
        :exit, _ -> {:error, :transfer_outcome_unknown}
      end

    case result do
      :scheduled ->
        {:noreply, put_pending(state, %{pending | phase: :awaiting_result})}

      _ ->
        close_unknown(state, %{pending | target_lease: :handed}, :keep_no_target_release)
    end
  end

  defp interrupt_pending(state, ref, _kind) do
    case fetch_pending(state, ref) do
      :error ->
        {:noreply, state}

      {:ok, pending} ->
        apply_interrupt(state, pending, pending.phase, :transfer_outcome_unknown)
    end
  end

  defp apply_interrupt(state, pending, phase, reason) do
    action = Core.classify_store_interrupt(phase, pending.fence_origin)
    apply_interrupt_action(state, pending, action, reason)
  end

  defp apply_interrupt_action(state, pending, :pre_handoff_rollback, reason) do
    {_, state} = do_abort_accept(state, pending.agent_id, pending.proposal_id, false)
    state = settle_unhanded(state, pending.agent_id, pending.target_lease)
    state = finish_pending(state, pending, {:error, reason})
    _ = cancel_target_reservation(pending)
    {:noreply, state}
  end

  defp apply_interrupt_action(state, pending, :pre_handoff_keep_unknown, _reason) do
    state = settle_unhanded(state, pending.agent_id, pending.target_lease)
    state = finish_pending(state, pending, {:error, :transfer_outcome_unknown})
    _ = cancel_target_reservation(pending)
    {:noreply, state}
  end

  defp apply_interrupt_action(state, pending, :uncertain_keep_unknown, _reason) do
    state = settle_unhanded(state, pending.agent_id, pending.target_lease)
    state = finish_pending(state, pending, {:error, :transfer_outcome_unknown})
    _ = cancel_target_reservation(pending)
    {:noreply, state}
  end

  defp apply_interrupt_action(state, pending, :post_handoff_unknown, _reason) do
    state = finish_pending(state, pending, {:error, :transfer_outcome_unknown})
    {:noreply, state}
  end

  defp close_unknown(state, pending, :keep) do
    state = finish_pending(state, pending, {:error, :transfer_outcome_unknown})
    _ = cancel_target_reservation(pending)
    {:noreply, state}
  end

  defp close_unknown(state, pending, :keep_no_target_release) do
    state = finish_pending(state, pending, {:error, :transfer_outcome_unknown})
    {:noreply, state}
  end

  defp finish_pending(state, pending, reply) do
    cancel_pending_watches(pending)
    GenServer.reply(pending.from, reply)
    state = drop_pending(state, pending.operation_ref)
    settle_owned(state, pending.agent_id, pending.proposal_lease)
  end

  defp cancel_pending_watches(pending) do
    if is_reference(pending[:timer_ref]), do: Process.cancel_timer(pending.timer_ref)

    if is_reference(pending[:target_monitor]) do
      Process.demonitor(pending.target_monitor, [:flush])
    end

    :ok
  end

  defp cancel_target_reservation(pending) do
    pid = pending.target_pid

    if is_pid(pid) and Process.alive?(pid) do
      try do
        GenServer.call(
          pid,
          {:proposal_transfer_cancel, %{operation_ref: pending.operation_ref}},
          1_000
        )
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp handle_transfer_result(state, {caller, _}, report) when is_map(report) do
    ref = Map.get(report, :operation_ref)

    with {:ok, pending} <- fetch_pending(state, ref),
         true <- pending.phase == :awaiting_result,
         true <- caller == pending.target_pid,
         true <- Process.whereis(pending.target_module) == pending.target_pid,
         true <- Map.get(report, :operation_id) == pending.operation_id,
         true <- Map.get(report, :agent_id) == pending.agent_id,
         true <- Map.get(report, :proposal_id) == pending.proposal_id do
      settle_authenticated_result(state, pending, Map.get(report, :outcome))
    else
      _ -> {{:error, :invalid_request}, state}
    end
  end

  defp handle_transfer_result(state, _from, _report), do: {{:error, :invalid_request}, state}

  defp settle_authenticated_result(state, pending, {:ok, target_id}) when is_binary(target_id) do
    case do_complete_accept(
           state,
           pending.agent_id,
           pending.proposal_id,
           target_id,
           pending.operation_id
         ) do
      {:ok, new_state} ->
        emit_accepted(pending, target_id)
        {:ok, finish_pending(new_state, pending, {:ok, target_id})}

      {{:error, _reason}, new_state} ->
        {:ok, finish_pending(new_state, pending, {:error, :transfer_outcome_unknown})}
    end
  end

  defp settle_authenticated_result(state, pending, {:error, reason}) do
    kind = Core.failure_kind(reason)

    case Core.classify_attempt_failure(pending.fence_origin, kind) do
      :abort ->
        {_, new_state} = do_abort_accept(state, pending.agent_id, pending.proposal_id, false)
        {:ok, finish_pending(new_state, pending, {:error, map_transfer_error(reason)})}

      _ ->
        {:ok, finish_pending(state, pending, {:error, :transfer_outcome_unknown})}
    end
  end

  defp settle_authenticated_result(state, pending, {:unknown, _reason}) do
    {:ok, finish_pending(state, pending, {:error, :transfer_outcome_unknown})}
  end

  defp settle_authenticated_result(state, pending, _outcome) do
    {:ok, finish_pending(state, pending, {:error, :transfer_outcome_unknown})}
  end

  defp emit_accepted(pending, target_id) do
    type = Map.get(pending.plan, :proposal_type)

    safe_emit(fn ->
      Events.record_proposal_accepted(pending.agent_id, pending.proposal_id, target_id, type)
      Signals.emit_proposal_accepted(pending.agent_id, pending.proposal_id, target_id)
    end)
  end

  defp map_transfer_error(reason)
       when reason in [
              :invalid_provenance,
              :invalid_request,
              :empty_description,
              :store_unavailable,
              :not_found,
              :transfer_outcome_unknown,
              :limit_exceeded,
              :request_expired
            ],
       do: reason

  defp map_transfer_error(:graph_not_initialized), do: :store_unavailable
  defp map_transfer_error(:goal_limit_reached), do: :limit_exceeded
  defp map_transfer_error(_), do: :invalid_request

  defp cleanup_agent_content(state, agent_id) do
    pendings =
      state
      |> pending_map()
      |> Enum.filter(fn {_ref, pending} ->
        is_map(pending) and pending[:agent_id] == agent_id
      end)

    state =
      Enum.reduce(pendings, state, fn {ref, pending}, acc ->
        cancel_pending_watches(pending)

        if well_formed_pending?(pending) do
          GenServer.reply(pending.from, {:error, :transfer_outcome_unknown})
        end

        acc =
          acc
          |> settle_unhanded(agent_id, pending[:target_lease])
          |> settle_owned(agent_id, pending[:proposal_lease])

        _ = cancel_target_reservation(pending)
        drop_pending(acc, ref)
      end)

    state =
      state
      |> settle_tracked_agent_roots(agent_id)
      |> retry_unresolved_for(agent_id)

    {reply, state} = do_delete_agent_content(state, agent_id)
    {reply, maybe_clear_unresolved_cursor(state)}
  end

  defp maybe_clear_unresolved_cursor(state) do
    if map_size(unresolved_map(state)) == 0 do
      state
      |> cancel_unresolved_retry()
      |> Map.put(:unresolved_cursor, nil)
    else
      state
    end
  end

  defp settle_tracked_agent_roots(state, agent_id) do
    leases =
      case owner_roots(state) do
        %OwnerRoots{by_agent: by_agent} -> Map.get(by_agent, agent_id, [])
        _ -> []
      end

    Enum.reduce(leases, state, fn lease, acc -> settle_owned(acc, agent_id, lease) end)
  end

  defp redact_status_state(state) when is_map(state) do
    counts =
      case owner_roots(state) do
        %OwnerRoots{by_agent: by_agent} ->
          Map.new(by_agent, fn {agent_id, leases} -> {agent_id, length(leases)} end)

        _ ->
          %{}
      end

    agents =
      state
      |> pending_map()
      |> Map.values()
      |> Enum.flat_map(fn pending ->
        case pending do
          %{agent_id: agent_id} when is_binary(agent_id) -> [agent_id]
          _ -> []
        end
      end)
      |> Enum.uniq()

    unresolved_counts =
      Map.new(unresolved_map(state), fn {agent_id, leases} -> {agent_id, length(leases)} end)

    retry =
      case state[:unresolved_retry] do
        %{status: :manual_cleanup, attempts: attempts} ->
          %{attempts: attempts, armed: false, status: :manual_cleanup}

        %{status: :armed, attempts: attempts} ->
          %{attempts: attempts, armed: true, status: :armed}

        %{attempts: attempts} ->
          %{attempts: attempts, armed: false, status: :idle}

        _ ->
          %{attempts: 0, armed: false, status: :idle}
      end

    state
    |> Map.put(:owner_roots, counts)
    |> Map.put(:pending_acceptances, %{count: map_size(pending_map(state)), agents: agents})
    |> Map.put(:unresolved_roots, unresolved_counts)
    |> Map.put(:unresolved_cursor, if(state[:unresolved_cursor], do: :active, else: :idle))
    |> Map.put(:unresolved_retry, retry)
  end

  defp redact_status_state(state), do: state
end
