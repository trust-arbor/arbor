defmodule Arbor.Comms.InteractionRegistry.Authority do
  @moduledoc false

  use GenServer

  require Logger

  alias Arbor.Comms.Config
  alias Arbor.Comms.InteractionRegistry.DurableLifecycleCore
  alias Arbor.Comms.InteractionRegistry.DurableStore
  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Comms.Interaction
  alias Arbor.Contracts.Persistence.Record

  @pending_topic "interactions"
  @terminal_topic "interactions:resolved"
  @terminal_ttl_ms 120_000
  @terminal_max_entries 512
  @max_timer_delay_ms 60_000
  @deadline_retry_ms 100

  @type terminal_status :: :responded | :abandoned | :expired
  @type admission_disposition :: :inserted | :existing
  @type dispatch_claim :: %{
          request_id: String.t(),
          operation_id: String.t(),
          authority_epoch: String.t(),
          claim_id: reference()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec admit(Interaction.t(), keyword()) ::
          {:ok, admission_disposition(), Interaction.t()} | {:error, term()}
  def admit(interaction, opts \\ [])

  def admit(%Interaction{} = interaction, opts) when is_list(opts) do
    call({:admit, interaction, opts})
  end

  def admit(_interaction, _opts), do: {:error, :invalid_options}

  @spec admit_durable(Interaction.t(), non_neg_integer()) ::
          {:ok, admission_disposition(), Interaction.t(), map()} | {:error, term()}
  def admit_durable(%Interaction{} = interaction, owner_deadline_unix_ms)
      when is_integer(owner_deadline_unix_ms) and owner_deadline_unix_ms >= 0 do
    call({:admit_durable, interaction, owner_deadline_unix_ms})
  end

  def admit_durable(_interaction, _owner_deadline_unix_ms), do: {:error, :invalid_options}

  @spec put(Interaction.t(), keyword()) :: {:ok, Interaction.t()} | {:error, term()}
  def put(interaction, opts \\ [])

  def put(%Interaction{} = interaction, opts) when is_list(opts) do
    case admit(interaction, opts) do
      {:ok, _disposition, stored_interaction} -> {:ok, stored_interaction}
      {:error, _reason} = error -> error
    end
  end

  def put(_interaction, _opts), do: {:error, :invalid_options}

  @spec durable_readiness() :: :ready | {:error, atom()}
  def durable_readiness, do: call(:durable_readiness)

  @doc false
  @spec claim_dispatch(String.t()) ::
          {:ok, dispatch_claim(), Interaction.t()}
          | :already_claimed
          | :not_dispatchable
          | :not_found
          | {:error, term()}
  def claim_dispatch(request_id) when is_binary(request_id),
    do: call({:claim_dispatch, request_id})

  @doc false
  @spec claim_next_dispatch() ::
          {:ok, dispatch_claim(), Interaction.t()} | :empty | {:error, term()}
  def claim_next_dispatch, do: call(:claim_next_dispatch)

  @doc false
  @spec accept_dispatch(dispatch_claim()) :: :ok | {:error, term()}
  def accept_dispatch(claim) when is_map(claim), do: call({:accept_dispatch, claim})
  def accept_dispatch(_claim), do: {:error, :invalid_dispatch_claim}

  @doc false
  @spec release_dispatch(dispatch_claim()) :: :ok | {:error, term()}
  def release_dispatch(claim) when is_map(claim), do: call({:release_dispatch, claim})
  def release_dispatch(_claim), do: {:error, :invalid_dispatch_claim}

  @spec pending(String.t()) :: {:ok, Interaction.t()} | :not_found
  def pending(request_id) when is_binary(request_id), do: call({:pending, request_id})

  @spec terminal(String.t()) :: {:ok, map()} | :not_found
  def terminal(request_id) when is_binary(request_id), do: call({:terminal, request_id})

  @spec status(String.t()) :: {:ok, :pending | terminal_status()} | :not_found
  def status(request_id) when is_binary(request_id), do: call({:status, request_id})

  @spec reconcile_operation(String.t(), String.t()) ::
          {:ok, :pending | {:terminal, map()}} | {:error, :stale_operation} | :not_found
  def reconcile_operation(request_id, operation_id)
      when is_binary(request_id) and is_binary(operation_id),
      do: call({:reconcile_operation, request_id, operation_id})

  @spec observe_durable(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, :pending | {:terminal, map()}}
          | {:error, :interaction_identity_mismatch}
          | :not_found
  def observe_durable(request_id, agent_id, operation_id, owner_deadline_unix_ms)
      when is_binary(request_id) and is_binary(agent_id) and is_binary(operation_id) and
             is_integer(owner_deadline_unix_ms) and owner_deadline_unix_ms >= 0 do
    call({:observe_durable, request_id, agent_id, operation_id, owner_deadline_unix_ms})
  end

  @spec respond(String.t(), term(), map()) ::
          {:ok, Interaction.t()}
          | {:error, {:already_terminal, terminal_status()} | term()}
          | :not_found
  def respond(request_id, response, metadata)
      when is_binary(request_id) and is_map(metadata),
      do: call({:respond, request_id, response, metadata})

  @spec abandon(String.t(), atom() | String.t()) ::
          {:ok, Interaction.t() | :already_abandoned}
          | {:error, {:already_terminal, terminal_status()} | term()}
          | :not_found
  def abandon(request_id, reason)
      when is_binary(request_id) and (is_atom(reason) or is_binary(reason)),
      do: call({:abandon, request_id, reason})

  @spec arm_timeout(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()} | :not_found
  def arm_timeout(request_id, timeout_ms)
      when is_binary(request_id) and is_integer(timeout_ms) and timeout_ms >= 0,
      do: call({:arm_timeout, request_id, timeout_ms})

  @spec finalize_timeout(pid(), String.t()) :: {:ok, map()} | {:error, term()} | :not_found
  def finalize_timeout(authority_pid, request_id)
      when is_pid(authority_pid) and is_binary(request_id),
      do: call(authority_pid, {:finalize_timeout, request_id})

  @spec finalize_timeout(pid(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()} | :not_found
  def finalize_timeout(authority_pid, request_id, operation_id, authority_epoch)
      when is_pid(authority_pid) and is_binary(request_id) and is_binary(operation_id) and
             is_binary(authority_epoch),
      do: call(authority_pid, {:finalize_timeout, request_id, operation_id, authority_epoch})

  @spec reset() :: :ok
  def reset, do: call(:reset)

  @impl true
  def init(opts) do
    base = %{
      entries: %{},
      tracker: Keyword.get(opts, :tracker, Arbor.Comms.InteractionRegistry),
      pubsub: Keyword.get(opts, :pubsub_server, Arbor.Comms.PubSub),
      authority_node: node(),
      authority_epoch: fresh_id("epoch"),
      durable_status: :unknown,
      dispatch_claims: %{}
    }

    case hydrate(base) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:ok, %{base | durable_status: {:error, reason}}}
    end
  end

  @impl true
  def handle_call({:admit, %Interaction{} = interaction, opts}, _from, state) do
    admit_call(state, interaction, opts)
  end

  def handle_call(
        {:admit_durable, %Interaction{} = interaction, owner_deadline_unix_ms},
        _from,
        state
      ) do
    durable_admit_call(state, interaction, owner_deadline_unix_ms)
  end

  def handle_call({:put, %Interaction{} = interaction, opts}, _from, state) do
    case admit_call(state, interaction, opts) do
      {:reply, {:ok, _disposition, stored_interaction}, next_state} ->
        {:reply, {:ok, stored_interaction}, next_state}

      other ->
        other
    end
  end

  def handle_call(:durable_readiness, _from, state) do
    reply =
      case state.durable_status do
        :ready -> :ready
        {:error, reason} -> {:error, reason}
        _ -> {:error, :unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_dispatch, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case claim_dispatch_entry(state, request_id, now_ms()) do
      {:ok, claim, interaction, next_state} ->
        {:reply, {:ok, claim, interaction}, next_state}

      {:reply, reply} ->
        {:reply, reply, state}
    end
  end

  def handle_call(:claim_next_dispatch, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case next_dispatch_request_id(state, now_ms()) do
      nil ->
        {:reply, :empty, state}

      request_id ->
        case claim_dispatch_entry(state, request_id, now_ms()) do
          {:ok, claim, interaction, next_state} ->
            {:reply, {:ok, claim, interaction}, next_state}

          {:reply, _unexpected_race} ->
            {:reply, :empty, state}
        end
    end
  end

  def handle_call({:accept_dispatch, claim}, _from, state) do
    settle_dispatch_claim(state, claim, :accept)
  end

  def handle_call({:release_dispatch, claim}, _from, state) do
    settle_dispatch_claim(state, claim, :release)
  end

  def handle_call({:pending, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{status: :pending, interaction: interaction} -> {:ok, interaction}
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:terminal, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{status: status, terminal: terminal} when status != :pending -> {:ok, terminal}
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:status, request_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{status: status} -> {:ok, status}
        nil -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:reconcile_operation, request_id, operation_id}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    reply =
      case Map.get(state.entries, request_id) do
        %{durability: :node_restart, operation_id: ^operation_id, status: :pending} ->
          {:ok, :pending}

        %{
          durability: :node_restart,
          operation_id: ^operation_id,
          status: status,
          terminal: terminal
        }
        when status != :pending ->
          {:ok, {:terminal, terminal}}

        nil ->
          :not_found

        _other ->
          {:error, :stale_operation}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:observe_durable, request_id, agent_id, operation_id, owner_deadline_unix_ms},
        _from,
        state
      ) do
    reply =
      case Map.get(state.entries, request_id) do
        %{
          durability: :node_restart,
          interaction: %Interaction{request_id: ^request_id, agent_id: ^agent_id},
          operation_id: ^operation_id,
          owner_deadline: ^owner_deadline_unix_ms,
          status: :pending
        } ->
          {:ok, :pending}

        %{
          durability: :node_restart,
          interaction: %Interaction{request_id: ^request_id, agent_id: ^agent_id},
          operation_id: ^operation_id,
          owner_deadline: ^owner_deadline_unix_ms,
          status: status,
          terminal: terminal
        }
        when status != :pending ->
          {:ok, {:terminal, terminal}}

        nil ->
          :not_found

        _other ->
          {:error, :interaction_identity_mismatch}
      end

    {:reply, reply, state}
  end

  def handle_call({:respond, request_id, response, metadata}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{durability: :node_restart} = entry ->
        durable_respond(state, request_id, entry, response, metadata)

      %{durability: :volatile} ->
        transition_volatile(
          state,
          request_id,
          fn interaction, now ->
            %{
              status: :responded,
              decision: approval_decision(interaction, response, metadata),
              response: response,
              metadata: bound_metadata(metadata),
              reason: nil,
              resolved_at: now,
              authority_node: node()
            }
          end,
          nil
        )

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:abandon, request_id, reason}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{durability: :node_restart} = entry ->
        durable_abandon(state, request_id, entry, reason)

      %{durability: :volatile} ->
        transition_volatile(
          state,
          request_id,
          fn _interaction, now ->
            %{
              status: :abandoned,
              decision: nil,
              response: nil,
              metadata: %{},
              reason: bound_reason(reason),
              resolved_at: now,
              authority_node: node()
            }
          end,
          :abandoned
        )

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:arm_timeout, request_id, timeout_ms}, _from, state) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{durability: :node_restart} = entry ->
        durable_arm_timeout(state, request_id, entry, timeout_ms)

      %{durability: :volatile} = entry ->
        volatile_arm_timeout(state, request_id, entry, timeout_ms)

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:finalize_timeout, request_id}, _from, state) do
    finalize_timeout_call(state, request_id, nil, nil)
  end

  def handle_call({:finalize_timeout, request_id, operation_id, authority_epoch}, _from, state) do
    finalize_timeout_call(state, request_id, operation_id, authority_epoch)
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.entries, fn {_request_id, entry} -> cancel_entry_timer(entry) end)
    _ = safe_untrack_all(state.tracker)
    {:reply, :ok, %{state | entries: %{}, dispatch_claims: %{}}}
  end

  @impl true
  def handle_info(
        {:durable_owner_deadline, request_id, operation_id, authority_epoch,
         scheduled_deadline_unix_ms},
        state
      ) do
    case Map.get(state.entries, request_id) do
      %{
        durability: :node_restart,
        status: :pending,
        operation_id: ^operation_id,
        authority_epoch: ^authority_epoch,
        timer_deadline: ^scheduled_deadline_unix_ms
      } = entry ->
        {:noreply,
         settle_or_rearm_durable_deadline(
           state,
           request_id,
           entry,
           scheduled_deadline_unix_ms
         )}

      _stale_or_terminal ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit_call(state, interaction, opts) do
    state = state |> expire_due_pending() |> prune_terminals()

    case requested_durability(opts) do
      {:ok, durability} -> admit_with_durability(state, interaction, durability, nil)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp durable_admit_call(state, interaction, owner_deadline_unix_ms) do
    state = state |> expire_due_pending() |> prune_terminals()

    case admit_with_durability(
           state,
           interaction,
           :node_restart,
           owner_deadline_unix_ms
         ) do
      {:reply, {:ok, disposition, stored_interaction}, next_state} ->
        case durable_receipt(next_state, stored_interaction.request_id) do
          {:ok, receipt} ->
            {:reply, {:ok, disposition, stored_interaction, receipt}, next_state}

          {:error, _reason} = error ->
            {:reply, error, next_state}
        end

      other ->
        other
    end
  end

  defp finalize_timeout_call(state, request_id, operation_id, authority_epoch) do
    state = state |> expire_due_pending() |> prune_terminals()

    case Map.get(state.entries, request_id) do
      %{durability: :node_restart} = entry ->
        durable_finalize_timeout(state, request_id, entry, operation_id, authority_epoch)

      %{durability: :volatile, interaction: interaction} ->
        if is_nil(operation_id) and is_nil(authority_epoch) do
          {terminal, next_state} =
            terminalize_volatile(state, request_id, interaction, :abandoned, :await_timeout)

          {:reply, {:ok, terminal}, next_state}
        else
          {:reply, {:error, :invalid_timeout_capture}, state}
        end

      %{terminal: terminal} ->
        {:reply, {:ok, terminal}, state}

      nil ->
        {:reply, :not_found, state}
    end
  end

  defp admit_with_durability(
         state,
         %Interaction{request_id: request_id} = interaction,
         durability,
         owner_deadline_unix_ms
       ) do
    case Map.get(state.entries, request_id) do
      nil ->
        put_new(state, interaction, durability, owner_deadline_unix_ms)

      entry ->
        classify_existing_admission(
          state,
          interaction,
          durability,
          entry,
          owner_deadline_unix_ms
        )
    end
  end

  defp classify_existing_admission(
         state,
         interaction,
         durability,
         entry,
         owner_deadline_unix_ms
       ) do
    cond do
      entry.status != :pending ->
        {:reply, {:error, {:already_terminal, entry.status}}, state}

      entry.durability != durability ->
        {:reply, {:error, :already_tracked}, state}

      same_admission_identity?(entry.interaction, interaction) ->
        admit_existing(state, entry, owner_deadline_unix_ms)

      true ->
        {:reply, {:error, :already_tracked}, state}
    end
  end

  defp admit_existing(state, %{durability: :volatile, interaction: interaction}, _deadline),
    do: {:reply, {:ok, :existing, interaction}, state}

  defp admit_existing(
         state,
         %{durability: :node_restart} = entry,
         owner_deadline_unix_ms
       ) do
    with {:ok, next_state} <-
           maybe_shorten_durable_deadline(state, entry, owner_deadline_unix_ms) do
      current_entry = next_state.entries[entry.interaction.request_id]
      reply_existing_durable_admission(next_state, current_entry)
    else
      {:error, {:already_terminal, status}, next_state} ->
        {:reply, {:error, {:already_terminal, status}}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  defp reply_existing_durable_admission(state, %{interaction: interaction} = entry) do
    case mirror_durable_entry(state.tracker, entry) do
      :ok ->
        if Map.get(entry, :admission_state, :admitted) == :persisted_unmirrored do
          next_entry = Map.put(entry, :admission_state, :admitted)
          next_state = put_in(state.entries[interaction.request_id], next_entry)
          {:reply, {:ok, :inserted, interaction}, next_state}
        else
          {:reply, {:ok, :existing, interaction}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :tracker_unavailable}, state}
    end
  end

  defp put_new(state, interaction, :volatile, _owner_deadline_unix_ms),
    do: put_new_volatile(state, interaction)

  defp put_new(state, interaction, :node_restart, owner_deadline_unix_ms),
    do: put_new_durable(state, interaction, owner_deadline_unix_ms)

  defp put_new_volatile(state, %Interaction{request_id: request_id} = interaction) do
    case durable_truth_status(request_id) do
      :clear ->
        case mirror_pending(state.tracker, interaction) do
          :ok ->
            entry = volatile_entry(interaction)
            next_state = put_in(state.entries[request_id], entry) |> expire_due_pending()
            {:reply, {:ok, :inserted, interaction}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :pending ->
        {:reply, {:error, :already_tracked}, state}

      {:terminal, status} ->
        {:reply, {:error, {:already_terminal, status}}, state}

      :unavailable ->
        {:reply, {:error, :durable_unavailable}, state}
    end
  end

  defp durable_truth_status(request_id) do
    case DurableStore.readiness() do
      {:error, :disabled} ->
        :clear

      {:ok, _details} ->
        case DurableStore.get(request_id) do
          {:ok, %Record{data: data}} ->
            case DurableLifecycleCore.decode(data) do
              {:ok, %{"status" => "pending"}} -> :pending
              {:ok, %{"status" => status}} -> {:terminal, status_atom(status)}
              {:error, _reason} -> :unavailable
            end

          {:error, :not_found} ->
            :clear

          {:error, _reason} ->
            :unavailable
        end

      {:error, _reason} ->
        :unavailable
    end
  end

  defp put_new_durable(
         %{durable_status: {:error, _reason}} = state,
         _interaction,
         _owner_deadline_unix_ms
       ),
       do: {:reply, {:error, :durable_unavailable}, state}

  defp put_new_durable(
         state,
         %Interaction{request_id: request_id} = interaction,
         owner_deadline_unix_ms
       ) do
    now_ms = now_ms()
    operation_id = fresh_id("op")
    authority_node = Atom.to_string(state.authority_node)

    with {:ok, data} <-
           DurableLifecycleCore.new(
             interaction,
             operation_id,
             authority_node,
             state.authority_epoch,
             now_ms
           ),
         {:ok, data} <- arm_initial_deadline(data, owner_deadline_unix_ms, now_ms),
         {:ok, data} <-
           DurableLifecycleCore.settle_due(
             data,
             authority_node,
             state.authority_epoch,
             now_ms
           ),
         {:ok, record} <- durable_insert(request_id, data) do
      adopt_durable_record(state, record, :inserted)
    else
      {:error, :conflict} ->
        durable_duplicate(state, interaction, owner_deadline_unix_ms)

      {:error, _reason} ->
        {:reply, {:error, :durable_unavailable}, state}
    end
  end

  defp durable_insert(request_id, data) do
    case DurableStore.insert_once(request_id, data) do
      {:ok, %Record{data: stored_data} = record} ->
        case DurableLifecycleCore.decode(stored_data) do
          {:ok, _decoded} -> {:ok, record}
          {:error, _reason} -> {:error, :malformed_record}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_normalized_record(request_id) do
    with {:ok, %Record{} = record} <- DurableStore.get(request_id),
         {:ok, %Record{} = record, data} <- normalize_record_schema(record) do
      {:ok, record, data}
    end
  end

  defp normalize_record_schema(%Record{data: raw_data} = record) do
    case DurableLifecycleCore.decode(raw_data) do
      {:ok, decoded} when decoded == raw_data ->
        {:ok, record, decoded}

      {:ok, decoded} ->
        replacement = Record.update(record, decoded)

        case DurableStore.compare_and_swap(record.key, record, replacement) do
          {:ok, %Record{} = stored} ->
            case DurableLifecycleCore.decode(stored.data) do
              {:ok, stored_data} -> {:ok, stored, stored_data}
              {:error, _reason} -> {:error, :malformed_record}
            end

          {:error, :conflict} ->
            {:error, :stale_authority}

          {:error, _reason} ->
            {:error, :unavailable}
        end

      {:error, _reason} ->
        {:error, :malformed_record}
    end
  end

  defp durable_duplicate(
         state,
         %Interaction{request_id: request_id} = interaction,
         owner_deadline_unix_ms
       ) do
    case load_normalized_record(request_id) do
      {:ok, %Record{} = record, data} ->
        with true <- data["authority_node"] == Atom.to_string(state.authority_node) do
          cond do
            data["status"] != "pending" ->
              {:reply, {:error, {:already_terminal, status_atom(data["status"])}}, state}

            not same_admission_identity?(data["interaction"], interaction) ->
              {:reply, {:error, :already_tracked}, state}

            true ->
              case ensure_current_epoch(state, record, data) do
                {:ok, current_record} ->
                  adopt_durable_duplicate(
                    state,
                    current_record,
                    owner_deadline_unix_ms
                  )

                {:error, _reason} ->
                  {:reply, {:error, :durable_unavailable}, state}
              end
          end
        else
          false -> {:reply, {:error, :already_tracked}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :durable_unavailable}, state}
    end
  end

  defp adopt_durable_duplicate(state, record, owner_deadline_unix_ms) do
    case adopt_durable_record(state, record, :existing) do
      {:reply, {:ok, :existing, _interaction}, next_state} ->
        entry = next_state.entries[record.key]
        admit_existing(next_state, entry, owner_deadline_unix_ms)

      other ->
        other
    end
  end

  defp ensure_current_epoch(state, %Record{} = record, data) do
    if data["status"] == "pending" and data["authority_epoch"] != state.authority_epoch do
      now = now_ms()

      with {:ok, claimed} <-
             DurableLifecycleCore.claim_epoch(
               data,
               Atom.to_string(state.authority_node),
               data["authority_epoch"],
               state.authority_epoch,
               now
             ),
           replacement = Record.update(record, claimed),
           {:ok, stored} <- DurableStore.compare_and_swap(record.key, record, replacement) do
        DurableLifecycleCore.decode(stored.data) |> map_record(stored)
      else
        {:error, :conflict} -> {:error, :conflict}
        {:error, _reason} -> {:error, :durable_unavailable}
      end
    else
      {:ok, record}
    end
  end

  defp map_record({:ok, _data}, %Record{} = record), do: {:ok, record}
  defp map_record({:error, reason}, _record), do: {:error, reason}

  defp arm_initial_deadline(data, nil, _now_ms), do: {:ok, data}

  defp arm_initial_deadline(data, owner_deadline_unix_ms, now_ms),
    do: DurableLifecycleCore.arm_deadline(data, owner_deadline_unix_ms, now_ms)

  defp maybe_shorten_durable_deadline(state, _entry, nil), do: {:ok, state}

  defp maybe_shorten_durable_deadline(
         state,
         %{owner_deadline: current_deadline},
         requested_deadline
       )
       when is_integer(current_deadline) and requested_deadline >= current_deadline,
       do: {:ok, state}

  defp maybe_shorten_durable_deadline(state, entry, requested_deadline)
       when is_integer(requested_deadline) do
    now = now_ms()
    authority_node = Atom.to_string(state.authority_node)

    with {:ok, armed} <-
           DurableLifecycleCore.arm_deadline(entry.record.data, requested_deadline, now),
         {:ok, data} <-
           DurableLifecycleCore.settle_due(
             armed,
             authority_node,
             state.authority_epoch,
             now
           ) do
      replacement = Record.update(record_from_entry(entry), data)

      case DurableStore.compare_and_swap(
             entry.interaction.request_id,
             record_from_entry(entry),
             replacement
           ) do
        {:ok, %Record{} = stored} ->
          adopt_shortened_deadline(state, stored)

        {:error, :conflict} ->
          case adopt_conflicting_terminal(state, entry.interaction.request_id) do
            {:ok, next_state, terminal} ->
              {:error, {:already_terminal, terminal.status}, next_state}

            {:error, next_state} ->
              {:error, :stale_authority, next_state}
          end

        {:error, _reason} ->
          {:error, :authority_unavailable, state}
      end
    else
      {:error, _reason} -> {:error, :durable_unavailable, state}
    end
  end

  defp adopt_shortened_deadline(state, %Record{} = stored) do
    case state_after_durable_record(state, stored) do
      {:ok, next_state} ->
        case next_state.entries[stored.key] do
          %{status: :pending} ->
            {:ok, next_state}

          %{status: status} ->
            publish_durable_terminal(next_state, stored.key)
            {:error, {:already_terminal, status}, next_state}
        end

      {:error, _reason} ->
        {:error, :durable_unavailable, state}
    end
  end

  defp adopt_durable_record(state, %Record{data: data} = record, disposition) do
    case DurableLifecycleCore.decode(data) do
      {:ok, decoded} ->
        with {:ok, projected_interaction} <- DurableLifecycleCore.project_interaction(decoded),
             {:ok, entry} <- durable_entry(decoded, projected_interaction) do
          next_state = install_durable_entry(state, record, entry)

          case mirror_durable_entry(next_state.tracker, next_state.entries[record.key]) do
            :ok ->
              durable_admission_reply(
                next_state,
                disposition,
                projected_interaction,
                next_state.entries[record.key]
              )

            {:error, _reason} ->
              # Keep the initial dispatch disposition retryable until Tracker
              # makes the durable record observable. External dispatch itself
              # is not an outbox and remains outside this Authority transaction.
              failed_entry =
                if disposition == :inserted do
                  Map.put(
                    next_state.entries[projected_interaction.request_id],
                    :admission_state,
                    :persisted_unmirrored
                  )
                else
                  next_state.entries[projected_interaction.request_id]
                end

              next_state =
                put_in(state.entries[projected_interaction.request_id], failed_entry)

              {:reply, {:error, :tracker_unavailable}, next_state}
          end
        else
          _ -> {:reply, {:error, :durable_unavailable}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :durable_unavailable}, state}
    end
  end

  defp durable_admission_reply(
         state,
         disposition,
         interaction,
         %{status: :pending}
       ),
       do: {:reply, {:ok, disposition, interaction}, state}

  defp durable_admission_reply(state, _disposition, _interaction, %{status: status}),
    do: {:reply, {:error, {:already_terminal, status}}, state}

  defp durable_entry(data, %Interaction{} = interaction) do
    terminal =
      case DurableLifecycleCore.project_terminal(data) do
        {:ok, terminal} -> public_terminal(terminal)
        {:error, :no_terminal} -> nil
        {:error, _reason} -> :invalid
      end

    status = status_atom(data["status"])

    if terminal == :invalid or (status == :pending and not is_nil(terminal)) or
         (status != :pending and is_nil(terminal)) do
      {:error, :malformed_record}
    else
      {:ok,
       %{
         durability: :node_restart,
         record: nil,
         operation_id: data["operation_id"],
         authority_epoch: data["authority_epoch"],
         interaction: interaction,
         status: status,
         dispatch_status: dispatch_status_atom(data["dispatch"]["status"]),
         dispatch_attempts: data["dispatch"]["attempts"],
         dispatch_not_before: data["dispatch"]["next_attempt_at_unix_ms"],
         terminal: terminal,
         owner_deadline: data["owner_deadline_unix_ms"],
         timer_ref: nil,
         timer_deadline: nil,
         admission_state: :admitted
       }}
    end
  end

  defp volatile_entry(interaction),
    do: %{
      durability: :volatile,
      interaction: interaction,
      status: :pending,
      terminal: nil,
      owner_deadline: nil
    }

  defp durable_respond(state, request_id, entry, response, metadata) do
    case durable_apply_transition(state, request_id, entry, {:respond, response, metadata}) do
      {:ok, next_state, %{status: :responded}} ->
        {:reply, {:ok, entry.interaction}, next_state}

      {:ok, next_state, %{status: status}} ->
        {:reply, {:error, {:already_terminal, status}}, next_state}

      {:already, next_state, status} ->
        {:reply, {:error, {:already_terminal, status}}, next_state}

      {:conflict, next_state, status} ->
        {:reply, {:error, {:already_terminal, status}}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  defp durable_abandon(state, request_id, entry, reason) do
    case durable_apply_transition(state, request_id, entry, {:abandon, reason}) do
      {:ok, next_state, _terminal} ->
        {:reply, {:ok, entry.interaction}, next_state}

      {:already, next_state, :abandoned} ->
        {:reply, {:ok, :already_abandoned}, next_state}

      {:already, next_state, status} ->
        {:reply, {:error, {:already_terminal, status}}, next_state}

      {:conflict, next_state, status} ->
        {:reply, {:error, {:already_terminal, status}}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  defp durable_finalize_timeout(state, request_id, entry, operation_id, authority_epoch) do
    if operation_id == entry.operation_id and authority_epoch == entry.authority_epoch do
      case durable_apply_transition(state, request_id, entry, {:abandon, :await_timeout}) do
        {:ok, next_state, terminal} ->
          {:reply, {:ok, terminal}, next_state}

        {:already, next_state, _status} ->
          {:reply, {:ok, entry.terminal}, next_state}

        {:conflict, next_state, _status} ->
          {:reply, {:ok, terminal_for(next_state, request_id)}, next_state}

        {:error, reason, next_state} ->
          {:reply, {:error, reason}, next_state}
      end
    else
      {:reply, {:error, :stale_timeout_capture}, state}
    end
  end

  defp durable_arm_timeout(state, request_id, entry, timeout_ms) do
    now = now_ms()
    deadline = now + timeout_ms

    case DurableLifecycleCore.arm_deadline(entry.record.data, deadline, now) do
      {:ok, data} ->
        cas_result =
          DurableStore.compare_and_swap(
            request_id,
            record_from_entry(entry),
            Record.update(record_from_entry(entry), data)
          )

        case cas_result do
          {:ok, %Record{} = stored} ->
            {:ok, next_state} = state_after_durable_record(state, stored)
            next_state = expire_due_pending(next_state)

            case Map.get(next_state.entries, request_id) do
              %{status: :pending} = current ->
                {:reply, {:ok, durable_capture(self(), request_id, current, :armed)}, next_state}

              %{terminal: terminal} ->
                {:reply, {:ok, durable_capture(self(), request_id, entry, {:terminal, terminal})},
                 next_state}

              _ ->
                {:reply, :not_found, next_state}
            end

          {:error, :conflict} ->
            case adopt_conflicting_terminal(state, request_id) do
              {:ok, next_state, _terminal} ->
                {:reply,
                 {:ok,
                  durable_capture(
                    self(),
                    request_id,
                    entry,
                    {:terminal, terminal_for(next_state, request_id)}
                  )}, next_state}

              {:error, next_state} ->
                {:reply, {:error, :stale_authority}, next_state}
            end

          {:error, _reason} ->
            {:reply, {:error, :authority_unavailable}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :durable_unavailable}, state}
    end
  end

  defp durable_apply_transition(state, request_id, entry, transition) do
    cond do
      entry.status != :pending ->
        {:already, state, entry.status}

      entry.authority_epoch != state.authority_epoch ->
        {:error, :stale_authority, state}

      true ->
        now = now_ms()
        authority_node = Atom.to_string(state.authority_node)

        result =
          case transition do
            {:respond, response, metadata} ->
              DurableLifecycleCore.respond(
                entry.record.data,
                response,
                metadata,
                authority_node,
                state.authority_epoch,
                now
              )

            {:abandon, reason} ->
              DurableLifecycleCore.abandon(
                entry.record.data,
                reason,
                authority_node,
                state.authority_epoch,
                now
              )

            {:expire, reason} ->
              DurableLifecycleCore.transition(
                entry.record.data,
                %{
                  status: :expired,
                  decision: nil,
                  response: nil,
                  metadata: %{},
                  reason: reason
                },
                authority_node,
                state.authority_epoch,
                now
              )
          end

        case result do
          {:ok, data} -> durable_cas_transition(state, request_id, entry, data)
          {:error, _reason} -> {:error, :durable_unavailable, state}
        end
    end
  end

  defp durable_cas_transition(state, request_id, entry, data) do
    current_record = record_from_entry(entry)
    replacement = Record.update(current_record, data)

    case DurableStore.compare_and_swap(request_id, current_record, replacement) do
      {:ok, %Record{} = stored} ->
        case state_after_durable_record(state, stored) do
          {:ok, next_state} ->
            terminal = terminal_for(next_state, request_id)
            publish_durable_terminal(next_state, request_id)
            {:ok, next_state, terminal}

          {:error, _reason} ->
            {:error, :durable_unavailable, state}
        end

      {:error, :conflict} ->
        case adopt_conflicting_terminal(state, request_id) do
          {:ok, next_state, terminal} -> {:conflict, next_state, terminal.status}
          {:error, next_state} -> {:error, :stale_authority, next_state}
        end

      {:error, _reason} ->
        {:error, :authority_unavailable, state}
    end
  end

  defp adopt_conflicting_terminal(state, request_id) do
    case DurableStore.get(request_id) do
      {:ok, %Record{data: data} = record} ->
        with {:ok, decoded} <- DurableLifecycleCore.decode(data),
             true <- decoded["authority_node"] == Atom.to_string(state.authority_node),
             false <- decoded["status"] == "pending",
             {:ok, interaction} <- DurableLifecycleCore.project_interaction(decoded),
             {:ok, entry} <- durable_entry(decoded, interaction),
             {:ok, next_state} <- state_after_durable_entry(state, record, entry) do
          {:ok, next_state, entry.terminal}
        else
          _ -> {:error, state}
        end

      _ ->
        {:error, state}
    end
  end

  defp state_after_durable_record(state, %Record{data: data} = record) do
    with {:ok, decoded} <- DurableLifecycleCore.decode(data),
         {:ok, interaction} <- DurableLifecycleCore.project_interaction(decoded),
         {:ok, entry} <- durable_entry(decoded, interaction),
         {:ok, next_state} <- state_after_durable_entry(state, record, entry) do
      {:ok, next_state}
    else
      _ -> {:error, :malformed_record}
    end
  end

  defp state_after_durable_entry(state, %Record{} = record, entry) do
    next_state = install_durable_entry(state, record, entry)

    case mirror_durable_entry(next_state.tracker, next_state.entries[record.key]) do
      :ok ->
        {:ok, next_state}

      {:error, _reason} ->
        {:ok, next_state}
    end
  end

  defp install_durable_entry(state, %Record{} = record, entry) do
    request_id = entry.interaction.request_id
    previous_entry = Map.get(state.entries, request_id)
    cancel_entry_timer(previous_entry)

    next_entry = %{
      entry
      | record: record,
        timer_ref: nil,
        timer_deadline: nil,
        admission_state: preserved_admission_state(previous_entry, entry)
    }

    next_state =
      state
      |> put_in([:entries, request_id], next_entry)
      |> retain_valid_dispatch_claim(request_id, next_entry)

    schedule_durable_deadline(next_state, request_id)
  end

  defp preserved_admission_state(
         %{operation_id: operation_id, admission_state: admission_state},
         %{operation_id: operation_id}
       ),
       do: admission_state

  defp preserved_admission_state(_previous_entry, entry), do: entry.admission_state

  defp record_from_entry(%{record: %Record{} = record}), do: record

  defp next_dispatch_request_id(state, now) do
    state.entries
    |> Enum.filter(fn {request_id, entry} ->
      dispatch_entry_due?(state, request_id, entry, now)
    end)
    |> Enum.min_by(
      fn {request_id, entry} -> {entry.dispatch_not_before, request_id} end,
      fn -> nil end
    )
    |> case do
      {request_id, _entry} -> request_id
      nil -> nil
    end
  end

  defp claim_dispatch_entry(state, request_id, now) do
    case Map.get(state.entries, request_id) do
      nil ->
        {:reply, :not_found}

      entry ->
        cond do
          Map.has_key?(state.dispatch_claims, request_id) ->
            {:reply, :already_claimed}

          not dispatch_entry_due?(state, request_id, entry, now) ->
            {:reply, :not_dispatchable}

          true ->
            claim = %{
              request_id: request_id,
              operation_id: entry.operation_id,
              authority_epoch: entry.authority_epoch,
              claim_id: make_ref()
            }

            next_state = put_in(state.dispatch_claims[request_id], claim)
            {:ok, claim, entry.interaction, next_state}
        end
    end
  end

  defp dispatch_entry_due?(
         state,
         request_id,
         %{
           durability: :node_restart,
           status: :pending,
           dispatch_status: :pending,
           admission_state: :admitted,
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           record: %Record{} = record
         },
         now
       ) do
    is_binary(operation_id) and
      authority_epoch == state.authority_epoch and
      not Map.has_key?(state.dispatch_claims, request_id) and
      DurableLifecycleCore.dispatch_due?(record.data, now)
  end

  defp dispatch_entry_due?(_state, _request_id, _entry, _now), do: false

  defp settle_dispatch_claim(state, claim, action) do
    with {:ok, request_id, entry} <- validate_dispatch_claim(state, claim),
         {:ok, data} <-
           dispatch_claim_transition(entry, state, action)
           |> tag_dispatch_transition(request_id),
         replacement = Record.update(record_from_entry(entry), data) do
      case DurableStore.compare_and_swap(
             request_id,
             record_from_entry(entry),
             replacement
           ) do
        {:ok, %Record{} = stored} ->
          case state_after_durable_record(state, stored) do
            {:ok, next_state} ->
              {:reply, :ok, drop_dispatch_claim(next_state, request_id)}

            {:error, _reason} ->
              {:reply, {:error, :durable_unavailable}, drop_dispatch_claim(state, request_id)}
          end

        {:error, :conflict} ->
          next_state = refresh_after_dispatch_conflict(state, request_id)
          {:reply, {:error, :stale_dispatch_claim}, drop_dispatch_claim(next_state, request_id)}

        {:error, _reason} ->
          {:reply, {:error, :authority_unavailable}, drop_dispatch_claim(state, request_id)}
      end
    else
      {:error, request_id, reason} ->
        {:reply, {:error, reason}, drop_dispatch_claim(state, request_id)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp tag_dispatch_transition({:ok, data}, _request_id), do: {:ok, data}

  defp tag_dispatch_transition({:error, reason}, request_id),
    do: {:error, request_id, reason}

  defp validate_dispatch_claim(
         state,
         %{
           request_id: request_id,
           operation_id: operation_id,
           authority_epoch: authority_epoch,
           claim_id: claim_id
         } = claim
       )
       when map_size(claim) == 4 and is_binary(request_id) and is_binary(operation_id) and
              is_binary(authority_epoch) and is_reference(claim_id) do
    case {Map.get(state.dispatch_claims, request_id), Map.get(state.entries, request_id)} do
      {
        ^claim,
        %{
          durability: :node_restart,
          status: :pending,
          dispatch_status: :pending,
          operation_id: ^operation_id,
          authority_epoch: ^authority_epoch
        } = entry
      }
      when authority_epoch == state.authority_epoch ->
        {:ok, request_id, entry}

      _ ->
        {:error, :stale_dispatch_claim}
    end
  end

  defp validate_dispatch_claim(_state, _claim), do: {:error, :invalid_dispatch_claim}

  defp dispatch_claim_transition(entry, state, :accept) do
    DurableLifecycleCore.accept_dispatch(
      entry.record.data,
      Atom.to_string(state.authority_node),
      state.authority_epoch,
      now_ms()
    )
  end

  defp dispatch_claim_transition(entry, state, :release) do
    with {:ok, config} <- Config.durable_interaction_dispatch_config() do
      now = now_ms()
      attempt = min(entry.dispatch_attempts + 1, 1_000_000)
      retry_at = now + retry_delay(config.retry_base_ms, config.retry_max_ms, attempt)

      DurableLifecycleCore.release_dispatch(
        entry.record.data,
        Atom.to_string(state.authority_node),
        state.authority_epoch,
        retry_at,
        now
      )
    else
      {:error, _reason} -> {:error, :invalid_dispatch_config}
    end
  end

  defp retry_delay(base, maximum, attempt) do
    grow_retry_delay(base, maximum, max(attempt - 1, 0))
  end

  defp grow_retry_delay(delay, maximum, 0), do: min(delay, maximum)
  defp grow_retry_delay(delay, maximum, _remaining) when delay >= maximum, do: maximum

  defp grow_retry_delay(delay, maximum, remaining),
    do: grow_retry_delay(min(delay * 2, maximum), maximum, remaining - 1)

  defp refresh_after_dispatch_conflict(state, request_id) do
    with {:ok, %Record{} = record, data} <- load_normalized_record(request_id),
         true <- data["authority_node"] == Atom.to_string(state.authority_node),
         {:ok, interaction} <- DurableLifecycleCore.project_interaction(data),
         {:ok, entry} <- durable_entry(data, interaction),
         {:ok, next_state} <- state_after_durable_entry(state, record, entry) do
      next_state
    else
      _ -> state
    end
  end

  defp retain_valid_dispatch_claim(state, request_id, entry) do
    case Map.get(state.dispatch_claims, request_id) do
      %{
        operation_id: operation_id,
        authority_epoch: authority_epoch
      }
      when entry.status == :pending and entry.dispatch_status == :pending and
             entry.operation_id == operation_id and entry.authority_epoch == authority_epoch ->
        state

      _ ->
        drop_dispatch_claim(state, request_id)
    end
  end

  defp drop_dispatch_claim(state, request_id) do
    update_in(state.dispatch_claims, &Map.delete(&1, request_id))
  end

  defp durable_receipt(state, request_id) do
    case Map.get(state.entries, request_id) do
      %{
        durability: :node_restart,
        operation_id: operation_id,
        owner_deadline: owner_deadline_unix_ms
      }
      when is_binary(operation_id) and is_integer(owner_deadline_unix_ms) and
             owner_deadline_unix_ms >= 0 ->
        {:ok,
         %{
           request_id: request_id,
           operation_id: operation_id,
           owner_deadline_unix_ms: owner_deadline_unix_ms
         }}

      _ ->
        {:error, :interaction_identity_mismatch}
    end
  end

  defp schedule_durable_deadline(state, request_id, minimum_delay_ms \\ 0) do
    case Map.get(state.entries, request_id) do
      %{
        durability: :node_restart,
        status: :pending,
        operation_id: operation_id,
        authority_epoch: authority_epoch
      } = entry
      when is_binary(operation_id) and is_binary(authority_epoch) ->
        case DurableLifecycleCore.effective_deadline_unix_ms(entry.record.data) do
          {:ok, scheduled_deadline_unix_ms} when is_integer(scheduled_deadline_unix_ms) ->
            delay =
              scheduled_deadline_unix_ms
              |> Kernel.-(now_ms())
              |> max(minimum_delay_ms)
              |> min(@max_timer_delay_ms)

            timer_ref =
              Process.send_after(
                self(),
                {:durable_owner_deadline, request_id, operation_id, authority_epoch,
                 scheduled_deadline_unix_ms},
                delay
              )

            put_in(
              state.entries[request_id],
              %{entry | timer_ref: timer_ref, timer_deadline: scheduled_deadline_unix_ms}
            )

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp settle_or_rearm_durable_deadline(
         state,
         request_id,
         entry,
         _scheduled_deadline_unix_ms
       ) do
    cancel_entry_timer(entry)

    state =
      put_in(
        state.entries[request_id],
        %{entry | timer_ref: nil, timer_deadline: nil}
      )

    now = now_ms()

    case DurableLifecycleCore.due_decision(entry.record.data, now) do
      {:due, :expired} ->
        settle_due_or_retry(state, request_id, entry, :expired, :expires_at_elapsed)

      {:due, :abandoned} ->
        settle_due_or_retry(state, request_id, entry, :abandoned, :owner_timeout)

      :not_due ->
        schedule_durable_deadline(state, request_id)
    end
  end

  defp settle_due_or_retry(state, request_id, entry, status, reason) do
    case durable_due_transition(state, request_id, entry, status, reason) do
      {:ok, next_state} ->
        next_state

      {:retry, next_state} ->
        rearm_durable_deadline(next_state, request_id, @deadline_retry_ms)
    end
  end

  defp rearm_durable_deadline(state, request_id, minimum_delay_ms) do
    case Map.get(state.entries, request_id) do
      %{status: :pending} = entry ->
        cancel_entry_timer(entry)

        state =
          put_in(
            state.entries[request_id],
            %{entry | timer_ref: nil, timer_deadline: nil}
          )

        schedule_durable_deadline(state, request_id, minimum_delay_ms)

      _ ->
        state
    end
  end

  defp cancel_entry_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_entry_timer(_entry), do: :ok

  defp durable_capture(pid, request_id, entry, outcome) do
    %{
      authority_pid: pid,
      authority_node: node(),
      request_id: request_id,
      operation_id: entry.operation_id,
      authority_epoch: entry.authority_epoch,
      outcome: outcome
    }
  end

  defp terminal_for(state, request_id) do
    case Map.get(state.entries, request_id) do
      %{terminal: terminal} -> terminal
      _ -> nil
    end
  end

  defp publish_durable_terminal(state, request_id) do
    case Map.get(state.entries, request_id) do
      %{
        durability: :node_restart,
        status: status,
        interaction: %Interaction{response_topic: topic},
        operation_id: operation_id,
        owner_deadline: owner_deadline_unix_ms
      }
      when status != :pending ->
        Phoenix.PubSub.broadcast(
          state.pubsub,
          topic,
          {:interaction_terminal,
           %{
             request_id: request_id,
             operation_id: operation_id,
             owner_deadline_unix_ms: owner_deadline_unix_ms,
             status: status
           }}
        )

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[InteractionRegistry] terminal publication failed for #{request_id}: " <>
          Exception.message(error)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[InteractionRegistry] terminal publication exited for #{request_id}: #{inspect(reason)}"
      )

      :ok
  end

  defp mirror_durable_entry(tracker, %{status: :pending, interaction: interaction}),
    do: mirror_pending(tracker, interaction)

  defp mirror_durable_entry(tracker, %{
         status: status,
         terminal: terminal,
         interaction: interaction
       })
       when status != :pending,
       do: mirror_terminal(tracker, interaction.request_id, terminal)

  defp volatile_arm_timeout(state, request_id, entry, timeout_ms) do
    deadline = earliest_deadline(entry.owner_deadline, timeout_ms)
    state = put_in(state.entries[request_id].owner_deadline, deadline) |> expire_due_pending()

    outcome =
      case Map.get(state.entries, request_id) do
        %{status: :pending} -> :armed
        %{terminal: terminal} -> {:terminal, terminal}
        _ -> :armed
      end

    {:reply,
     {:ok,
      %{
        authority_pid: self(),
        authority_node: node(),
        request_id: request_id,
        outcome: outcome
      }}, state}
  end

  defp transition_volatile(state, request_id, terminal_builder, idempotent_status) do
    case Map.get(state.entries, request_id) do
      %{status: :pending, interaction: interaction} ->
        terminal = terminal_builder.(interaction, now_ms())

        entry = %{
          status: terminal.status,
          interaction: interaction,
          terminal: terminal,
          durability: :volatile,
          owner_deadline: nil
        }

        next_state = put_in(state.entries[request_id], entry)
        mirror_terminal(state.tracker, request_id, terminal)
        {:reply, {:ok, interaction}, next_state}

      %{status: status} when status == idempotent_status ->
        {:reply, {:ok, :already_abandoned}, state}

      %{status: status} ->
        {:reply, {:error, {:already_terminal, status}}, state}

      nil ->
        {:reply, :not_found, state}
    end
  end

  defp terminalize_volatile(state, request_id, interaction, status, reason, resolved_at \\ nil) do
    resolved_at = resolved_at || now_ms()

    terminal = %{
      status: status,
      decision: nil,
      response: nil,
      metadata: %{},
      reason: reason,
      resolved_at: resolved_at,
      authority_node: node()
    }

    entry = %{
      status: status,
      interaction: interaction,
      terminal: terminal,
      durability: :volatile,
      owner_deadline: nil
    }

    mirror_terminal(state.tracker, request_id, terminal)
    {terminal, put_in(state.entries[request_id], entry)}
  end

  defp expire_due_pending(state) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    Enum.reduce(state.entries, state, fn
      {request_id, %{status: :pending, durability: :node_restart} = entry}, acc ->
        case DurableLifecycleCore.due_decision(entry.record.data, now_ms) do
          {:due, :expired} ->
            settle_due_or_retry(acc, request_id, entry, :expired, :expires_at_elapsed)

          {:due, :abandoned} ->
            settle_due_or_retry(acc, request_id, entry, :abandoned, :owner_timeout)

          :not_due ->
            acc
        end

      {request_id, %{status: :pending, durability: :volatile, interaction: interaction} = entry},
      acc ->
        cond do
          expired?(interaction.expires_at, now) ->
            terminalize_volatile(
              acc,
              request_id,
              interaction,
              :expired,
              :expires_at_elapsed,
              now_ms
            )
            |> elem(1)

          deadline_elapsed?(entry.owner_deadline, System.monotonic_time(:millisecond)) ->
            terminalize_volatile(acc, request_id, interaction, :abandoned, :await_timeout, now_ms)
            |> elem(1)

          true ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp durable_due_transition(state, request_id, entry, status, reason) do
    transition = if status == :expired, do: {:expire, reason}, else: {:abandon, reason}

    case durable_apply_transition(state, request_id, entry, transition) do
      {:ok, next_state, _terminal} -> {:ok, next_state}
      {:already, next_state, _status} -> {:ok, next_state}
      {:conflict, next_state, _status} -> {:ok, next_state}
      {:error, _reason, next_state} -> {:retry, next_state}
    end
  end

  defp prune_terminals(state) do
    now = System.system_time(:millisecond)

    terminal_entries =
      state.entries
      |> Enum.flat_map(fn
        {request_id,
         %{durability: :volatile, status: status, terminal: %{resolved_at: resolved_at}}}
        when status != :pending and is_integer(resolved_at) ->
          [{request_id, resolved_at}]

        _ ->
          []
      end)
      |> Enum.sort_by(fn {_request_id, resolved_at} -> resolved_at end, :desc)

    expired =
      terminal_entries
      |> Enum.filter(fn {_request_id, resolved_at} -> now - resolved_at > @terminal_ttl_ms end)
      |> Enum.map(&elem(&1, 0))

    over_limit =
      terminal_entries
      |> Enum.reject(fn {request_id, _resolved_at} -> request_id in expired end)
      |> Enum.drop(@terminal_max_entries)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(Enum.uniq(expired ++ over_limit), state, fn request_id, acc ->
      safe_untrack(acc.tracker, @terminal_topic, request_id)
      update_in(acc.entries, &Map.delete(&1, request_id))
    end)
  end

  defp hydrate(state) do
    case DurableStore.readiness() do
      {:error, :disabled} ->
        {:ok, %{state | durable_status: {:error, :disabled}}}

      {:error, reason} ->
        {:ok, %{state | durable_status: {:error, reason}}}

      {:ok, _details} ->
        case DurableStore.inventory() do
          {:ok, keys} -> hydrate_keys(keys, %{state | durable_status: :ready})
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp hydrate_keys([], state), do: {:ok, state}

  defp hydrate_keys([request_id | rest], state) do
    case hydrate_key(state, request_id) do
      {:ok, next_state} -> hydrate_keys(rest, next_state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_key(state, request_id) do
    with {:ok, %Record{} = stored_record} <- DurableStore.get(request_id),
         {:ok, %Record{} = record, data} <- normalize_record_schema(stored_record),
         {:ok, interaction} <- DurableLifecycleCore.project_interaction(data) do
      cond do
        data["authority_node"] != Atom.to_string(state.authority_node) ->
          {:ok, state}

        data["status"] == "pending" ->
          with {:ok, claimed} <- claim_hydrated(state, record, data),
               {:ok, claimed_data} <- DurableLifecycleCore.decode(claimed.data),
               {:ok, entry} <- durable_entry(claimed_data, interaction) do
            next_state = install_durable_entry(state, claimed, entry)

            case mirror_durable_entry(next_state.tracker, next_state.entries[request_id]) do
              :ok -> {:ok, next_state}
              {:error, reason} -> {:error, reason}
            end
          end

        true ->
          with {:ok, entry} <- durable_entry(data, interaction) do
            next_state = install_durable_entry(state, record, entry)

            case mirror_durable_entry(next_state.tracker, next_state.entries[request_id]) do
              :ok -> {:ok, next_state}
              {:error, reason} -> {:error, reason}
            end
          end
      end
    else
      {:error, :not_found} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :malformed_record}
    end
  end

  defp claim_hydrated(state, %Record{} = record, data) do
    now = now_ms()

    with {:ok, claimed} <-
           DurableLifecycleCore.claim_epoch(
             data,
             Atom.to_string(state.authority_node),
             data["authority_epoch"],
             state.authority_epoch,
             now
           ),
         replacement = Record.update(record, claimed) do
      case DurableStore.compare_and_swap(record.key, record, replacement) do
        {:ok, %Record{} = stored} -> {:ok, stored}
        {:error, :conflict} -> {:error, :stale_authority}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  defp requested_durability(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :durability, :volatile) do
        :volatile -> {:ok, :volatile}
        :node_restart -> {:ok, :node_restart}
        _ -> {:error, :unsupported_durability}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp requested_durability(_opts), do: {:error, :invalid_options}

  defp same_admission_identity?(left, right) do
    case {admission_identity(left), admission_identity(right)} do
      {{:ok, left_identity}, {:ok, right_identity}} -> left_identity == right_identity
      _ -> false
    end
  end

  defp admission_identity(%Interaction{} = interaction) do
    case DurableLifecycleCore.serialize_interaction(interaction) do
      {:ok, data} ->
        {:ok, {:json, Map.delete(data, "submitted_at")}}

      {:error, _reason} ->
        identity =
          interaction
          |> Map.from_struct()
          |> Map.delete(:submitted_at)

        {:ok, {:term, identity}}
    end
  end

  defp admission_identity(serialized) when is_map(serialized),
    do: {:ok, {:json, Map.delete(serialized, "submitted_at")}}

  defp admission_identity(_value), do: {:error, :invalid_interaction}

  defp status_atom("pending"), do: :pending
  defp status_atom("responded"), do: :responded
  defp status_atom("abandoned"), do: :abandoned
  defp status_atom("expired"), do: :expired
  defp status_atom(_), do: :invalid

  defp dispatch_status_atom("pending"), do: :pending
  defp dispatch_status_atom("accepted"), do: :accepted
  defp dispatch_status_atom("cancelled"), do: :cancelled
  defp dispatch_status_atom(_), do: :invalid

  defp public_terminal(terminal) when is_map(terminal) do
    local_node = Atom.to_string(node())

    case Map.get(terminal, :authority_node) do
      ^local_node ->
        Map.put(terminal, :authority_node, node())

      _authority_node ->
        terminal
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp fresh_id(prefix),
    do: "#{prefix}_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"

  defp expired?(nil, _now), do: false

  defp expired?(%DateTime{} = expires_at, now),
    do: DateTime.compare(expires_at, now) in [:lt, :eq]

  defp expired?(expires_at, now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, parsed, _offset} -> expired?(parsed, now)
      _ -> false
    end
  end

  defp expired?(_expires_at, _now), do: false

  defp earliest_deadline(nil, timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp earliest_deadline(existing_deadline, timeout_ms) when is_integer(existing_deadline),
    do: min(existing_deadline, System.monotonic_time(:millisecond) + timeout_ms)

  defp deadline_elapsed?(nil, _monotonic_now), do: false
  defp deadline_elapsed?(deadline, monotonic_now), do: deadline <= monotonic_now

  defp mirror_pending(tracker, %Interaction{request_id: request_id} = interaction) do
    meta = %{interaction: interaction, authority_node: node()}

    case Phoenix.Tracker.track(tracker, self(), @pending_topic, request_id, meta) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _, _, _}} -> :ok
      {:error, reason} -> {:error, {:tracker_unavailable, reason}}
    end
  rescue
    error -> {:error, {:tracker_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:tracker_unavailable, reason}}
  end

  defp mirror_terminal(tracker, request_id, terminal) do
    case Phoenix.Tracker.track(tracker, self(), @terminal_topic, request_id, terminal) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _, _, _}} -> :ok
      {:error, reason} -> log_mirror_failure(request_id, reason)
    end

    safe_untrack(tracker, @pending_topic, request_id)
    :ok
  rescue
    error ->
      log_mirror_failure(request_id, Exception.message(error))
      :ok
  catch
    :exit, reason ->
      log_mirror_failure(request_id, reason)
      :ok
  end

  defp safe_untrack(tracker, topic, request_id) do
    Phoenix.Tracker.untrack(tracker, self(), topic, request_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_untrack_all(tracker) do
    Phoenix.Tracker.untrack(tracker, self())
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp log_mirror_failure(request_id, reason) do
    Logger.warning(
      "[InteractionRegistry.Authority] terminal mirror failed for #{request_id}: #{inspect(reason)}"
    )
  end

  defp approval_decision(%Interaction{kind: :approval}, response, metadata) do
    case ApprovalAnswer.normalize(response, metadata) do
      {:ok, :approve} -> :approved
      {:ok, :deny, _note} -> :rejected
      {:ok, :rework, _note} -> :rejected
      {:error, _reason} -> nil
    end
  end

  defp approval_decision(%Interaction{}, _response, _metadata), do: nil

  defp bound_metadata(metadata) when is_map(metadata) do
    note = Map.get(metadata, :note) || Map.get(metadata, "note")

    case note do
      value when is_binary(value) ->
        metadata |> Map.put(:note, bound_reason(value)) |> Map.delete("note")

      _ ->
        metadata
    end
  end

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_binary(reason) do
    case ApprovalAnswer.validate_note(reason, truncate: true, drop_invalid: true) do
      {:ok, bounded} -> bounded
      _ -> ""
    end
  end

  defp call(message), do: call(__MODULE__, message)

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :authority_unavailable}
  end
end
