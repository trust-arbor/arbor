defmodule Arbor.Comms.InteractionRegistry.Authority do
  @moduledoc false

  use GenServer

  require Logger

  alias Arbor.Comms.InteractionRegistry.DurableLifecycleCore
  alias Arbor.Comms.InteractionRegistry.DurableStore
  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Comms.Interaction
  alias Arbor.Contracts.Persistence.Record

  @pending_topic "interactions"
  @terminal_topic "interactions:resolved"
  @terminal_ttl_ms 120_000
  @terminal_max_entries 512

  @type terminal_status :: :responded | :abandoned | :expired
  @type admission_disposition :: :inserted | :existing

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
      authority_node: node(),
      authority_epoch: fresh_id("epoch"),
      durable_status: :unknown
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
    _ = safe_untrack_all(state.tracker)
    {:reply, :ok, %{state | entries: %{}}}
  end

  defp admit_call(state, interaction, opts) do
    state = state |> expire_due_pending() |> prune_terminals()

    case requested_durability(opts) do
      {:ok, durability} -> admit_with_durability(state, interaction, durability)
      {:error, _reason} = error -> {:reply, error, state}
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
         durability
       ) do
    case Map.get(state.entries, request_id) do
      nil ->
        put_new(state, interaction, durability)

      entry ->
        classify_existing_admission(state, interaction, durability, entry)
    end
  end

  defp classify_existing_admission(state, interaction, durability, entry) do
    cond do
      entry.status != :pending ->
        {:reply, {:error, {:already_terminal, entry.status}}, state}

      entry.durability != durability ->
        {:reply, {:error, :already_tracked}, state}

      same_interaction?(entry.interaction, interaction, durability) ->
        admit_existing(state, entry)

      true ->
        {:reply, {:error, :already_tracked}, state}
    end
  end

  defp admit_existing(state, %{durability: :volatile, interaction: interaction}),
    do: {:reply, {:ok, :existing, interaction}, state}

  defp admit_existing(state, %{durability: :node_restart, interaction: interaction} = entry) do
    case mirror_durable_entry(state.tracker, entry) do
      :ok -> {:reply, {:ok, :existing, interaction}, state}
      {:error, _reason} -> {:reply, {:error, :tracker_unavailable}, state}
    end
  end

  defp put_new(state, interaction, :volatile), do: put_new_volatile(state, interaction)
  defp put_new(state, interaction, :node_restart), do: put_new_durable(state, interaction)

  defp put_new_volatile(state, %Interaction{request_id: request_id} = interaction) do
    case mirror_pending(state.tracker, interaction) do
      :ok ->
        entry = volatile_entry(interaction)
        next_state = put_in(state.entries[request_id], entry) |> expire_due_pending()
        {:reply, {:ok, :inserted, interaction}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp put_new_durable(%{durable_status: {:error, _reason}} = state, _interaction),
    do: {:reply, {:error, :durable_unavailable}, state}

  defp put_new_durable(state, %Interaction{request_id: request_id} = interaction) do
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
         {:ok, record} <- durable_insert(request_id, data) do
      adopt_durable_record(state, record, :inserted)
    else
      {:error, :conflict} -> durable_duplicate(state, interaction)
      {:error, _reason} -> {:reply, {:error, :durable_unavailable}, state}
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

  defp durable_duplicate(state, %Interaction{request_id: request_id} = interaction) do
    case DurableStore.get(request_id) do
      {:ok, %Record{} = record} ->
        with {:ok, data} <- DurableLifecycleCore.decode(record.data),
             true <- data["authority_node"] == Atom.to_string(state.authority_node) do
          cond do
            data["status"] != "pending" ->
              {:reply, {:error, {:already_terminal, status_atom(data["status"])}}, state}

            data["interaction"] != interaction_data(interaction) ->
              {:reply, {:error, :already_tracked}, state}

            true ->
              case ensure_current_epoch(state, record, data) do
                {:ok, current_record} ->
                  adopt_durable_record(state, current_record, :existing)

                {:error, _reason} ->
                  {:reply, {:error, :durable_unavailable}, state}
              end
          end
        else
          false -> {:reply, {:error, :already_tracked}, state}
          {:error, _reason} -> {:reply, {:error, :durable_unavailable}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :durable_unavailable}, state}
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

  defp adopt_durable_record(state, %Record{data: data} = record, disposition) do
    case DurableLifecycleCore.decode(data) do
      {:ok, decoded} ->
        with {:ok, projected_interaction} <- DurableLifecycleCore.project_interaction(decoded),
             {:ok, entry} <- durable_entry(data, projected_interaction) do
          entry = %{entry | record: record}
          next_state = put_in(state.entries[projected_interaction.request_id], entry)

          case mirror_durable_entry(state.tracker, entry) do
            :ok ->
              {:reply, {:ok, disposition, projected_interaction}, next_state}

            {:error, _reason} ->
              {:reply, {:error, :tracker_unavailable}, next_state}
          end
        else
          _ -> {:reply, {:error, :durable_unavailable}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :durable_unavailable}, state}
    end
  end

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
         terminal: terminal,
         owner_deadline: data["owner_deadline_unix_ms"]
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
      {:ok, next_state, _terminal} ->
        {:reply, {:ok, entry.interaction}, next_state}

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
             {:ok, entry} <- durable_entry(data, interaction),
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
         {:ok, entry} <- durable_entry(data, interaction),
         {:ok, next_state} <- state_after_durable_entry(state, record, entry) do
      {:ok, next_state}
    else
      _ -> {:error, :malformed_record}
    end
  end

  defp state_after_durable_entry(state, %Record{} = record, entry) do
    case mirror_durable_entry(state.tracker, entry) do
      :ok ->
        {:ok, put_in(state.entries[entry.interaction.request_id], %{entry | record: record})}

      {:error, _reason} ->
        {:ok, put_in(state.entries[entry.interaction.request_id], %{entry | record: record})}
    end
  end

  defp record_from_entry(%{record: %Record{} = record}), do: record

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
            durable_due_transition(acc, request_id, entry, :expired, :expires_at_elapsed)

          {:due, :abandoned} ->
            durable_due_transition(acc, request_id, entry, :abandoned, :await_timeout)

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
      {:ok, next_state, _terminal} -> next_state
      {:conflict, next_state, _status} -> next_state
      _ -> state
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
    with {:ok, %Record{} = record} <- DurableStore.get(request_id),
         {:ok, data} <- DurableLifecycleCore.decode(record.data),
         {:ok, interaction} <- DurableLifecycleCore.project_interaction(data) do
      cond do
        data["authority_node"] != Atom.to_string(state.authority_node) ->
          {:ok, state}

        data["status"] == "pending" ->
          with {:ok, claimed} <- claim_hydrated(state, record, data),
               {:ok, claimed_data} <- DurableLifecycleCore.decode(claimed.data),
               {:ok, entry} <- durable_entry(claimed_data, interaction) do
            case mirror_durable_entry(state.tracker, entry) do
              :ok -> {:ok, put_in(state.entries[request_id], %{entry | record: claimed})}
              {:error, reason} -> {:error, reason}
            end
          end

        true ->
          with {:ok, entry} <- durable_entry(data, interaction) do
            case mirror_durable_entry(state.tracker, entry) do
              :ok -> {:ok, put_in(state.entries[request_id], %{entry | record: record})}
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

  defp interaction_data(interaction) do
    case DurableLifecycleCore.serialize_interaction(interaction) do
      {:ok, data} -> data
      _ -> nil
    end
  end

  defp same_interaction?(existing, incoming, :volatile), do: existing == incoming

  defp same_interaction?(existing, incoming, :node_restart) do
    case {
      DurableLifecycleCore.serialize_interaction(existing),
      DurableLifecycleCore.serialize_interaction(incoming)
    } do
      {{:ok, existing_data}, {:ok, incoming_data}} -> existing_data == incoming_data
      _ -> false
    end
  end

  defp status_atom("pending"), do: :pending
  defp status_atom("responded"), do: :responded
  defp status_atom("abandoned"), do: :abandoned
  defp status_atom("expired"), do: :expired
  defp status_atom(_), do: :invalid

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
