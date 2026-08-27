defmodule Arbor.Orchestrator.CrossAppContinuation.Journal do
  @moduledoc false

  use GenServer

  alias Arbor.Actions
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.CrossAppContinuation.Envelope
  alias Arbor.Orchestrator.CrossAppContinuation.Store

  @call_timeout_ms 5_000
  @fresh_keys ~w(identities planned_batches per_batch_budget_ms static_stage_receipt_digest)
  @claim_caller_keys ~w(operation_id owner_id identities)
  @injected_keys ~w(now claimed_at expires_at fence_token fence_generation)
  @fenced_transitions ~w(
    accept_passed_receipt accept_capacity_handoff fail cancel expire_claim revoke_claim complete
  )
  @numeric_start_opts ~w(max_items max_data_bytes claim_ttl_ms hydration_timeout_ms)a
  @config_start_opts [
    :backend,
    :store_name,
    :backend_opts,
    :start_store,
    :store_child_opts,
    :max_items,
    :max_data_bytes,
    :claim_ttl_ms,
    :hydration_timeout_ms
  ]
  @start_opts [:name, :clock, :token_fun | @config_start_opts]

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def open(input, opts \\ []), do: call(opts, {:open, input})
  def get(continuation_id, opts \\ []), do: call(opts, {:get, continuation_id})

  def claim(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "claim", continuation_id, input})

  def accept_passed_receipt(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "accept_passed_receipt", continuation_id, input})

  def accept_capacity_handoff(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "accept_capacity_handoff", continuation_id, input})

  def fail(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "fail", continuation_id, input})

  def cancel(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "cancel", continuation_id, input})

  def expire_claim(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "expire_claim", continuation_id, input})

  def revoke_claim(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "revoke_claim", continuation_id, input})

  def complete(continuation_id, input, opts \\ []),
    do: call(opts, {:mutate, "complete", continuation_id, input})

  def durability_status(opts \\ []), do: call(opts, :durability_status)
  def refresh(opts \\ []), do: call(opts, :refresh)

  defp call(opts, message) do
    server = Keyword.get(opts, :server, __MODULE__)

    try do
      GenServer.call(server, message, @call_timeout_ms)
    catch
      :exit, {:noproc, _} -> {:error, :not_ready}
      :exit, {:timeout, _} -> {:error, :not_ready}
    end
  end

  @impl true
  def init(opts) do
    with {:ok, resolved} <- resolve_opts(opts) do
      table = :ets.new(:cross_app_continuation_hot, [:set, :private])

      state = %{
        store: resolved.store,
        table: table,
        ready: false,
        reason: "disabled",
        epoch: 0,
        worker: nil,
        poison_detail: nil,
        durability_class: nil,
        clock: resolved.clock,
        token_fun: resolved.token_fun,
        claim_ttl_ms: resolved.claim_ttl_ms,
        hydration_timeout_ms: resolved.hydration_timeout_ms,
        inventory_count: 0
      }

      cond do
        is_nil(resolved.store.backend) ->
          {:ok, %{state | reason: "disabled"}}

        true ->
          case Store.attest(resolved.store) do
            {:ok, class} ->
              {:ok, %{state | durability_class: class, reason: "hydrating"},
               {:continue, :hydrate}}

            {:error, :unsupported} ->
              {:ok, %{state | reason: "unsupported"}}

            {:error, :insufficient_durability} ->
              {:ok, %{state | reason: "insufficient_durability"}}

            {:error, _reason} ->
              {:ok, %{state | reason: "unsupported"}}
          end
      end
    else
      {:error, reason} -> {:stop, {:invalid_cross_app_continuation, reason}}
    end
  end

  @impl true
  def handle_continue(:hydrate, state) do
    {:noreply, start_worker(state)}
  end

  @impl true
  def handle_call(:durability_status, _from, state) do
    {:reply, status_map(state), state}
  end

  def handle_call(:refresh, _from, %{store: %{backend: nil}} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call(:refresh, _from, %{worker: worker} = state) when not is_nil(worker) do
    {:reply, {:error, :refresh_in_progress}, state}
  end

  def handle_call(:refresh, _from, %{durability_class: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call(:refresh, _from, state) do
    {:reply, :ok, start_worker(state)}
  end

  def handle_call(_message, _from, %{ready: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:open, input}, _from, state) do
    {reply, state} = do_open(input, state)
    {:reply, reply, state}
  end

  def handle_call({:get, continuation_id}, _from, state) do
    {reply, state} = do_get(continuation_id, state, :redact)
    {:reply, reply, state}
  end

  def handle_call({:mutate, transition, continuation_id, input}, _from, state) do
    {reply, state} = do_mutate(transition, continuation_id, input, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:hydration_result, epoch, result}, state) do
    if state.worker && state.worker.epoch == epoch do
      Process.demonitor(state.worker.monitor_ref, [:flush])
      {:noreply, apply_hydration(result, %{state | worker: nil})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:hydration_timeout, epoch, monitor_ref}, state) do
    if (state.worker && state.worker.epoch == epoch) and state.worker.monitor_ref == monitor_ref do
      Process.demonitor(monitor_ref, [:flush])
      Process.exit(state.worker.pid, :kill)
      {:noreply, poison(state, "hydration_timeout")}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    if state.worker && state.worker.monitor_ref == monitor_ref do
      {:noreply, poison(state, "hydration_worker_down")}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp resolve_opts(opts) when is_list(opts) do
    with :ok <- validate_start_opts(opts),
         runtime = allowed_start_opts(opts),
         {:ok, fetched} <- Config.fetch_cross_app_continuation(),
         {:ok, tightened} <-
           Config.tighten_cross_app_continuation(
             fetched,
             Keyword.take(runtime, @numeric_start_opts)
           ) do
      merged =
        Keyword.merge(
          tightened,
          Keyword.drop(runtime, @numeric_start_opts)
        )

      backend = Keyword.fetch!(merged, :backend)
      store_name = Keyword.fetch!(merged, :store_name)
      backend_opts = Keyword.fetch!(merged, :backend_opts)

      {:ok,
       %{
         store: %{
           backend: backend,
           store_name: store_name,
           backend_opts: backend_opts,
           max_items: Keyword.fetch!(merged, :max_items),
           max_data_bytes: Keyword.fetch!(merged, :max_data_bytes)
         },
         clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
         token_fun: Keyword.get(opts, :token_fun, &default_token/0),
         claim_ttl_ms: Keyword.fetch!(merged, :claim_ttl_ms),
         hydration_timeout_ms: Keyword.fetch!(merged, :hydration_timeout_ms)
       }}
    end
  end

  defp allowed_start_opts(opts) do
    Keyword.take(opts, @config_start_opts)
  end

  defp validate_start_opts(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) |> Enum.uniq() |> Enum.reject(&(&1 in @start_opts)) do
        [] -> :ok
        unknown -> {:error, {:unknown_start_opts, Enum.sort(unknown)}}
      end
    else
      {:error, :start_opts_not_keyword}
    end
  end

  defp do_open(input, state) do
    with :ok <- require_json_object(input),
         {:ok, operation_id} <- Envelope.operation_id(Map.get(input, "operation_id")),
         :ok <- require_allowed_keys(input, ["operation_id" | @fresh_keys]),
         :ok <- require_keys(input, ["operation_id" | @fresh_keys]),
         fresh = Map.take(input, @fresh_keys),
         {:ok, snapshot} <- Actions.coding_cross_app_continuation_new(fresh),
         {:ok, continuation_id} <- Actions.coding_cross_app_continuation_lineage_key(snapshot),
         {:ok, derived} <- Actions.coding_cross_app_continuation_retained_effects(snapshot),
         {:ok, payload_sha256} <- Actions.coding_cross_app_continuation_digest(fresh),
         {:ok, commit} <-
           Envelope.operation_receipt(
             operation_id,
             snapshot["identities"]["task_id"],
             continuation_id,
             "open",
             payload_sha256
           ),
         {:ok, data} <-
           Envelope.build(
             continuation_id,
             snapshot,
             derived["successor"],
             derived["terminal"],
             commit,
             nil,
             state.store.max_data_bytes
           ) do
      record = Record.new(continuation_id, data)

      open_with_capacity(record, operation_id, fresh, state)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp open_with_capacity(record, operation_id, fresh, state) do
    continuation_id = record.key

    case load_admitted(continuation_id, state) do
      {:ok, _record, _data} ->
        replay_or_conflict(continuation_id, "open", operation_id, fresh, state)

      {:error, :not_found} ->
        insert_open_if_capacity(record, operation_id, fresh, state)

      {:error, reason} ->
        {{:error, reason}, maybe_poison(state, reason)}
    end
  end

  defp insert_open_if_capacity(record, operation_id, fresh, state) do
    if state.inventory_count < state.store.max_items do
      case Store.insert_absent(state.store, record) do
        {:ok, stored} ->
          publish_stored(stored, operation_id, :redact, state)

        {:error, :conflict} ->
          replay_or_conflict(record.key, "open", operation_id, fresh, state)

        {:error, reason} ->
          {{:error, reason}, maybe_poison(state, reason)}
      end
    else
      {{:error, :capacity_exceeded}, state}
    end
  end

  defp do_get(continuation_id, state, token_mode) do
    with {:ok, continuation_id} <- Envelope.continuation_id(continuation_id),
         {:ok, record, data} <- load_admitted(continuation_id, state) do
      snapshot =
        if token_mode == :redact,
          do: Envelope.redact_snapshot(data["snapshot"]),
          else: data["snapshot"]

      {{:ok,
        Envelope.public_envelope(
          continuation_id,
          data["commit"]["operation_id"],
          snapshot,
          data["successor"],
          data["terminal"],
          record,
          state.durability_class
        )}, state}
    else
      {:error, :not_found} ->
        {{:error, :not_found}, state}

      {:error, reason} ->
        {{:error, reason}, maybe_poison(state, reason)}
    end
  end

  defp do_mutate(transition, continuation_id, input, state) do
    with {:ok, continuation_id} <- Envelope.continuation_id(continuation_id),
         :ok <- require_json_object(input),
         {:ok, operation_id} <- Envelope.operation_id(input["operation_id"]),
         :ok <- reject_injected(input, transition) do
      case load_admitted(continuation_id, state) do
        {:ok, record, data} ->
          snapshot = data["snapshot"]
          payload = caller_payload(input)
          fence = fence_fields(transition, input)

          cond do
            transition == "claim" and
                claim_binding_match?(data, continuation_id, operation_id, payload) ->
              {ok_public(record, operation_id, data, :keep_token, state), state}

            replay_match?(
              data["commit"],
              continuation_id,
              transition,
              operation_id,
              snapshot,
              payload
            ) ->
              {ok_public(record, operation_id, data, :redact, state), state}

            true ->
              apply_transition(
                transition,
                continuation_id,
                operation_id,
                input,
                payload,
                fence,
                record,
                data,
                state
              )
          end

        {:error, reason} ->
          {{:error, reason}, maybe_poison(state, reason)}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_transition(
         transition,
         continuation_id,
         operation_id,
         input,
         payload,
         fence,
         record,
         data,
         state
       ) do
    snapshot = data["snapshot"]

    with {:ok, core_input} <- core_input(transition, input, fence, state),
         result <- invoke_transition(transition, snapshot, core_input) do
      case result do
        {:ok, next_snapshot, effects} ->
          persist_and_cas(
            transition,
            continuation_id,
            operation_id,
            payload,
            record,
            data,
            next_snapshot,
            effects,
            state
          )

        {:error, :claim_active} ->
          {{:error, :conflict}, refresh_hot(state, record.key)}

        {:error, :terminal_state} ->
          {terminal_conflict_or_error(transition, operation_id, payload, record, data, state),
           refresh_hot(state, record.key)}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp persist_and_cas(
         transition,
         continuation_id,
         operation_id,
         payload,
         record,
         previous,
         next_snapshot,
         effects,
         state
       ) do
    with :ok <- require_persist_first(effects, next_snapshot),
         {:ok, derived} <- Actions.coding_cross_app_continuation_retained_effects(next_snapshot),
         :ok <- match_transition_effects(effects, derived),
         {:ok, payload_sha256} <- Actions.coding_cross_app_continuation_digest(payload),
         {:ok, commit} <-
           Envelope.operation_receipt(
             operation_id,
             next_snapshot["identities"]["task_id"],
             continuation_id,
             transition,
             payload_sha256
           ),
         claim_binding <-
           next_claim_binding(
             transition,
             next_snapshot,
             operation_id,
             next_snapshot["identities"]["task_id"],
             payload_sha256,
             commit,
             previous["claim_binding"]
           ),
         {:ok, data} <-
           Envelope.build(
             continuation_id,
             next_snapshot,
             derived["successor"],
             derived["terminal"],
             commit,
             claim_binding,
             state.store.max_data_bytes
           ) do
      replacement = Record.update(record, data)

      case Store.cas(state.store, continuation_id, {:value, record}, replacement) do
        {:ok, stored} ->
          token_mode = if transition == "claim", do: :keep_token, else: :redact

          publish_stored(stored, operation_id, token_mode, state)

        {:error, :conflict} ->
          replay_or_conflict(continuation_id, transition, operation_id, payload, state)

        {:error, reason} ->
          {{:error, reason}, maybe_poison(state, reason)}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp replay_or_conflict(continuation_id, transition, operation_id, payload, state) do
    case load_admitted(continuation_id, state) do
      {:ok, record, data} ->
        state = remember(state, record)

        cond do
          transition == "claim" and
              claim_binding_match?(data, continuation_id, operation_id, payload) ->
            {ok_public(record, operation_id, data, :keep_token, state), state}

          replay_match?(
            data["commit"],
            continuation_id,
            transition,
            operation_id,
            data["snapshot"],
            payload
          ) ->
            {ok_public(record, operation_id, data, :redact, state), state}

          true ->
            {{:error, :conflict}, state}
        end

      {:error, reason} ->
        {{:error, reason}, maybe_poison(state, reason)}
    end
  end

  defp terminal_conflict_or_error(transition, operation_id, payload, record, data, state) do
    stored = data["terminal"]

    cond do
      is_map(stored) and stored["status"] != terminal_status(transition) ->
        {:error, :terminal_conflict}

      replay_match?(
        data["commit"],
        data["continuation_id"],
        transition,
        operation_id,
        data["snapshot"],
        payload
      ) ->
        ok_public(record, operation_id, data, :redact, state)

      true ->
        {:error, :terminal_state}
    end
  end

  defp load_admitted(continuation_id, state) do
    case Store.get(state.store, continuation_id) do
      {:ok, record} -> Envelope.admit_record(record, state.store.max_data_bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_transition("claim", snapshot, input),
    do: Actions.coding_cross_app_continuation_claim(snapshot, input)

  defp invoke_transition("accept_passed_receipt", snapshot, input),
    do: Actions.coding_cross_app_continuation_accept_passed_receipt(snapshot, input)

  defp invoke_transition("accept_capacity_handoff", snapshot, input),
    do: Actions.coding_cross_app_continuation_accept_capacity_handoff(snapshot, input)

  defp invoke_transition("fail", snapshot, input),
    do: Actions.coding_cross_app_continuation_fail(snapshot, input)

  defp invoke_transition("cancel", snapshot, input),
    do: Actions.coding_cross_app_continuation_cancel(snapshot, input)

  defp invoke_transition("expire_claim", snapshot, input),
    do: Actions.coding_cross_app_continuation_expire_claim(snapshot, input)

  defp invoke_transition("revoke_claim", snapshot, input),
    do: Actions.coding_cross_app_continuation_revoke_claim(snapshot, input)

  defp invoke_transition("complete", snapshot, input),
    do: Actions.coding_cross_app_continuation_complete(snapshot, input)

  defp core_input("claim", input, _fence, state) do
    {now, expires} = claim_window(state)

    {:ok,
     input
     |> Map.take(["owner_id", "identities"])
     |> Map.merge(%{
       "fence_token" => state.token_fun.(),
       "claimed_at" => now,
       "expires_at" => expires,
       "now" => now
     })}
  end

  defp core_input(transition, input, fence, state) when transition in @fenced_transitions do
    with {:ok, token} <- require_binary(fence[:token]),
         {:ok, generation} <- require_generation(fence[:generation]) do
      core =
        input
        |> Map.take(["receipt", "handoff", "reason", "owner_id", "identities"])
        |> Map.merge(%{
          "fence_token" => token,
          "fence_generation" => generation,
          "now" => now_iso(state)
        })

      {:ok, core}
    end
  end

  defp reject_injected(input, "claim") do
    if Enum.any?(@injected_keys, &Map.has_key?(input, &1)) do
      {:error, :malformed_state}
    else
      require_allowed_keys(input, @claim_caller_keys)
    end
  end

  defp reject_injected(input, transition) when transition in @fenced_transitions do
    if Map.has_key?(input, "now") do
      {:error, :malformed_state}
    else
      extra_allowed =
        case transition do
          "accept_passed_receipt" -> ~w(receipt)
          "accept_capacity_handoff" -> ~w(handoff)
          "fail" -> ~w(reason)
          "cancel" -> ~w(reason)
          _ -> []
        end

      extra_required =
        case transition do
          "accept_passed_receipt" -> ~w(receipt)
          "accept_capacity_handoff" -> ~w(handoff)
          _ -> []
        end

      with :ok <-
             require_allowed_keys(
               input,
               extra_allowed ++ ~w(operation_id fence_token fence_generation owner_id identities)
             ),
           :ok <-
             require_keys(
               input,
               ["operation_id", "fence_token", "fence_generation"] ++ extra_required
             ) do
        :ok
      end
    end
  end

  defp caller_payload(input), do: Map.delete(input, "operation_id")

  defp fence_fields("claim", _input), do: %{token: nil, generation: nil}

  defp fence_fields(_transition, input) do
    %{token: input["fence_token"], generation: input["fence_generation"]}
  end

  defp replay_match?(commit, continuation_id, transition, operation_id, snapshot, payload) do
    with {:ok, digest} <- Actions.coding_cross_app_continuation_digest(payload),
         {:ok, expected} <-
           Envelope.operation_receipt(
             operation_id,
             snapshot["identities"]["task_id"],
             continuation_id,
             transition,
             digest
           ) do
      commit === expected
    else
      _other -> false
    end
  end

  defp claim_binding_match?(data, continuation_id, operation_id, payload) when is_map(data) do
    binding = data["claim_binding"]
    snapshot = data["snapshot"]

    with true <-
           is_map(binding) and is_map(snapshot) and snapshot["status"] == "claimed" and
             is_map(snapshot["claim"]),
         {:ok, digest} <- Actions.coding_cross_app_continuation_digest(payload),
         {:ok, expected} <-
           Envelope.operation_receipt(
             operation_id,
             snapshot["identities"]["task_id"],
             continuation_id,
             "claim",
             digest
           ) do
      binding === expected
    else
      _other -> false
    end
  end

  defp next_claim_binding(
         "claim",
         %{"status" => "claimed", "claim" => claim} = snapshot,
         operation_id,
         task_id,
         payload_sha256,
         commit,
         _previous
       )
       when is_map(claim) do
    if commit["operation_id"] == operation_id and
         commit["task_id"] == (task_id || snapshot["identities"]["task_id"]) and
         commit["payload_sha256"] == payload_sha256,
       do: commit,
       else: nil
  end

  defp next_claim_binding(
         _transition,
         %{"status" => "claimed", "claim" => claim},
         _op,
         _task,
         _digest,
         _commit,
         previous
       )
       when is_map(claim) and is_map(previous) do
    previous
  end

  defp next_claim_binding(
         _transition,
         _snapshot,
         _op,
         _task,
         _digest,
         _commit,
         _previous
       ),
       do: nil

  defp require_persist_first([%{"op" => "persist", "snapshot" => snapshot} | _rest], next)
       when snapshot === next,
       do: :ok

  defp require_persist_first(_effects, _next), do: {:error, :malformed_record}

  defp match_transition_effects([%{"op" => "persist"}], _derived), do: :ok

  defp match_transition_effects(
         [%{"op" => "persist"}, %{"op" => "mint_successor"} = mint],
         derived
       ) do
    if derived["successor"] === mint, do: :ok, else: {:error, :malformed_record}
  end

  defp match_transition_effects([%{"op" => "persist"}, %{"op" => "terminal"} = terminal], derived) do
    if derived["terminal"] === terminal, do: :ok, else: {:error, :malformed_record}
  end

  defp match_transition_effects(_effects, _derived), do: {:error, :malformed_record}

  defp ok_public(record, operation_id, data, token_mode, state) do
    snapshot =
      if token_mode == :redact,
        do: Envelope.redact_snapshot(data["snapshot"]),
        else: data["snapshot"]

    {:ok,
     Envelope.public_envelope(
       data["continuation_id"],
       operation_id,
       snapshot,
       data["successor"],
       data["terminal"],
       record,
       state.durability_class
     )}
  end

  defp publish_stored(record, operation_id, token_mode, state) do
    case Envelope.admit_record(record, state.store.max_data_bytes) do
      {:ok, admitted, data} ->
        {
          ok_public(admitted, operation_id, data, token_mode, state),
          remember(state, admitted)
        }

      {:error, reason} ->
        {{:error, reason}, maybe_poison(state, reason)}
    end
  end

  defp remember(state, %Record{} = record) do
    existed? = :ets.member(state.table, record.key)

    :ets.insert(
      state.table,
      {record.key, %{id: record.id, generation: record.generation, revision: record.revision}}
    )

    count =
      if existed?, do: state.inventory_count, else: state.inventory_count + 1

    %{state | inventory_count: count}
  end

  defp refresh_hot(state, key) do
    case Store.get(state.store, key) do
      {:ok, %Record{} = record} -> remember(state, record)
      _other -> state
    end
  end

  defp start_worker(state) do
    if state.worker do
      Process.demonitor(state.worker.monitor_ref, [:flush])
      Process.exit(state.worker.pid, :kill)
    end

    epoch = state.epoch + 1
    parent = self()
    store = state.store

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {:hydration_result, epoch, collect_inventory(store)})
      end)

    Process.send_after(
      self(),
      {:hydration_timeout, epoch, monitor_ref},
      state.hydration_timeout_ms
    )

    %{
      state
      | epoch: epoch,
        ready: false,
        reason: "hydrating",
        poison_detail: nil,
        worker: %{pid: pid, monitor_ref: monitor_ref, epoch: epoch}
    }
  end

  defp collect_inventory(store) do
    with {:ok, keys} <- Store.list(store),
         :ok <- bound_inventory(keys, store.max_items) do
      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
        case load_hot_entry(store, key, acc) do
          {:ok, acc2} -> {:cont, {:ok, acc2}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp load_hot_entry(store, key, acc) do
    with {:ok, record} <- Store.get(store, key),
         {:ok, admitted, data} <- Envelope.admit_record(record, store.max_data_bytes),
         true <- admitted.key == key,
         true <- data["continuation_id"] == key,
         false <- Map.has_key?(acc, key) do
      {:ok,
       Map.put(acc, key, %{
         id: admitted.id,
         generation: admitted.generation,
         revision: admitted.revision
       })}
    else
      {:error, :not_found} -> {:error, :malformed_record}
      false -> {:error, :malformed_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bound_inventory(keys, max_items) when is_list(keys) do
    cond do
      length(keys) > max_items -> {:error, :inventory_too_large}
      length(keys) != length(Enum.uniq(keys)) -> {:error, :malformed_record}
      true -> :ok
    end
  end

  defp apply_hydration({:ok, hot}, state) when is_map(hot) do
    :ets.delete_all_objects(state.table)
    Enum.each(hot, fn {key, meta} -> :ets.insert(state.table, {key, meta}) end)

    %{
      state
      | ready: true,
        reason: nil,
        poison_detail: nil,
        inventory_count: map_size(hot),
        worker: nil
    }
  end

  defp apply_hydration({:error, reason}, state) do
    poison(state, poison_reason(reason))
  end

  defp maybe_poison(state, reason)
       when reason in [:malformed_record, :oversized_state, :malformed_state] do
    poison(state, poison_reason(reason))
  end

  defp maybe_poison(state, _reason), do: state

  defp poison(state, detail) do
    :ets.delete_all_objects(state.table)

    %{
      state
      | ready: false,
        reason: "poisoned",
        poison_detail: bound_detail(detail),
        inventory_count: 0,
        epoch: state.epoch + 1,
        worker: nil
    }
  end

  defp status_map(state) do
    %{
      "ready" => state.ready,
      "reason" => state.reason,
      "durability_class" =>
        if(state.durability_class, do: Atom.to_string(state.durability_class), else: nil),
      "fenced_cas" => state.durability_class == :node_restart and state.ready,
      "backend" => backend_name(state.store.backend),
      "store_name" => Atom.to_string(state.store.store_name),
      "inventory_count" => state.inventory_count,
      "poison_detail" => state.poison_detail
    }
  end

  defp backend_name(nil), do: nil
  defp backend_name(module) when is_atom(module), do: Atom.to_string(module)

  defp now_iso(state) do
    state.clock.()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp claim_window(state) do
    now = DateTime.truncate(state.clock.(), :microsecond)
    expires = DateTime.add(now, state.claim_ttl_ms, :millisecond)
    {DateTime.to_iso8601(now), DateTime.to_iso8601(expires)}
  end

  defp default_token do
    Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end

  defp require_json_object(value) when is_map(value) and not is_struct(value), do: :ok
  defp require_json_object(_value), do: {:error, :malformed_state}

  defp require_allowed_keys(map, allowed) do
    allowed_set = MapSet.new(allowed)

    if Enum.all?(Map.keys(map), &MapSet.member?(allowed_set, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_keys(map, keys) do
    if Enum.all?(keys, &Map.has_key?(map, &1)), do: :ok, else: {:error, :malformed_state}
  end

  defp require_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_value), do: {:error, :malformed_state}

  defp require_generation(value) when is_integer(value) and value >= 1, do: {:ok, value}
  defp require_generation(_value), do: {:error, :malformed_state}

  defp terminal_status("fail"), do: "failed"
  defp terminal_status("cancel"), do: "cancelled"
  defp terminal_status("complete"), do: "completed"
  defp terminal_status(_transition), do: nil

  defp poison_reason(:inventory_too_large), do: "inventory_too_large"
  defp poison_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp poison_reason(_reason), do: "poisoned"

  defp bound_detail(detail) when is_binary(detail) do
    if byte_size(detail) <= 256, do: detail, else: binary_part(detail, 0, 256)
  end

  defp bound_detail(detail), do: bound_detail(inspect(detail))
end
