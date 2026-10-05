defmodule Arbor.Security.NativeNoticeBroker do
  @moduledoc """
  Ephemeral native-worker custody for local private conversation notices.

  Source acquisition is owner/topology verified outside this actor. A held
  worker claims a one-use bootstrap before running any Engine node. Only that
  live PID AND its private opaque custody can prepare, activate, reconcile
  or consume an admission; GenServer from alone is not identity. No
  admission is a transferable public bearer or part of action/context JSON.

  Reservations serialize same-scope/notice-id effects inside this broker. An
  unresolved effect remains uncertain and permits readonly reconciliation only;
  it never becomes permission to replay. Broker loss retires all native leases.
  This is one host's local publication boundary, not a distributed message bus.
  """
  use GenServer

  alias Arbor.Security.{
    Config,
    ConversationNoticeCore,
    NativeConversationNotices,
    SigningAuthorityBroker
  }

  alias Arbor.Security.Identity.Verifier

  @max_sources 256
  @max_workers 1_024
  @max_reservations 4_096
  @prepare_ms 5_000
  @acquire_ms 5_000
  @max_acquisitions 256
  @max_mutations 1_024
  @max_generations 2_048

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def open(source, authority, proof, ticket), do: call({:open, source, authority, proof, ticket})
  def begin_acquisition(principal), do: call({:begin_acquisition, principal})
  def cancel_acquisition(ticket), do: call({:cancel_acquisition, ticket})
  def begin_profile_mutation(principal), do: call({:begin_profile_mutation, principal})
  def finish_profile_mutation(ticket), do: call({:finish_profile_mutation, ticket})
  def delegate_worker(source, worker), do: call({:delegate, source, worker})
  def claim_worker(bootstrap), do: call({:claim, bootstrap})
  def resource(params, custody), do: worker_call(custody, {:resource, params})
  def prepare(params, taints, custody), do: worker_call(custody, {:prepare, params, taints})
  def activate(token, custody), do: worker_call(custody, {:activate, token})
  def peek(params, custody), do: worker_call(custody, {:peek, params})

  def consume_value(scope, value, custody),
    do: worker_call(custody, {:consume_value, scope, value})

  def reconcile_value(scope, value, custody),
    do: worker_call(custody, {:reconcile_value, scope, value})

  def finish(params, outcome, custody), do: worker_call(custody, {:finish, params, outcome})
  def discard(custody), do: worker_call(custody, :discard)
  def close_worker(custody), do: worker_call(custody, :close)

  defp worker_call(custody, message), do: call({:worker, custody, message})

  def retire_source_generation(principal) do
    if Process.whereis(__MODULE__), do: call({:retire_principal, principal}), else: :ok
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, 5_000)
  rescue
    _ -> {:error, :notice_unavailable}
  catch
    :exit, _ -> {:error, :notice_unavailable}
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    Process.send_after(self(), :sweep, 1_000)
    private = :ets.new(__MODULE__, [:set, :private])

    :ets.insert(
      private,
      {:state,
       %{
         sources: %{},
         workers: %{},
         reservations: %{},
         monitors: %{},
         generations: %{},
         acquisitions: %{},
         mutations: %{}
       }}
    )

    {:ok, %{private: private}}
  end

  # Ordinary state/status introspection sees only a non-authoritative private
  # ETS locator. Source, bootstrap, custody and mutation handles remain owned by
  # this actor; a copied locator cannot be read by any other PID.
  @impl true
  def handle_call(message, from, %{private: private} = carrier) do
    [{:state, state}] = :ets.lookup(private, :state)
    {:reply, reply, next} = handle_private_call(message, from, state)
    :ets.insert(private, {:state, next})
    {:reply, reply, carrier}
  end

  defp handle_private_call({:open, facts, authority, proof, ticket}, {caller, _}, state) do
    acquisition = state.acquisitions[ticket]
    state = retire_ticket(state, :acquisitions, ticket)

    with %{owner: ^caller, principal: principal, generation: generation, deadline: deadline} <-
           acquisition,
         true <- Process.alive?(caller) and deadline >= System.monotonic_time(:millisecond),
         true <- state.generations[principal] == generation and not mutating?(state, principal),
         true <- valid_source?(facts, caller) and facts.principal_id == principal,
         true <-
           map_size(state.sources) < @max_sources or
             Enum.any?(state.sources, fn {_token, row} -> row.owner == caller end),
         {:ok, %{principal_id: principal, purpose: purpose}} <-
           SigningAuthorityBroker.recorded_identity(authority, caller),
         true <-
           principal == facts.principal_id and
             ((purpose == :session and facts.role == :session) or
                (purpose == :heartbeat and facts.role == :heartbeat_service)),
         true <- proof.payload == NativeConversationNotices.acquisition_payload(facts),
         {:ok, ^principal} <- Verifier.verify(proof) do
      case Enum.find(state.sources, fn {_token, row} ->
             row.owner == caller and
               row.facts == facts and row.authority == authority
           end) do
        {token, _row} ->
          {:reply, {:ok, token}, state}

        nil ->
          previous = for {token, %{owner: ^caller}} <- state.sources, do: token
          state = Enum.reduce(previous, state, &retire_source(&2, &1))
          token = make_ref()
          source = %{facts: facts, authority: authority, owner: caller, generation: generation}
          state = %{state | sources: Map.put(state.sources, token, source)}
          state = monitor(state, caller, {:source, token})
          state = monitor(state, facts.branch_pid, {:source, token})
          {:reply, {:ok, token}, state}
      end
    else
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_private_call({:begin_acquisition, principal}, {caller, _}, state) do
    with true <- valid_principal?(principal) and Process.alive?(caller),
         false <- mutating?(state, principal),
         true <- map_size(state.acquisitions) < @max_acquisitions,
         true <- generation_capacity?(state, principal) do
      {generation, state} = ensure_generation(state, principal)
      ticket = make_ref()

      row = %{
        owner: caller,
        principal: principal,
        generation: generation,
        deadline: System.monotonic_time(:millisecond) + @acquire_ms
      }

      state = %{state | acquisitions: Map.put(state.acquisitions, ticket, row)}
      {:reply, {:ok, ticket}, monitor(state, caller, {:acquisition, ticket})}
    else
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_private_call({:cancel_acquisition, ticket}, {caller, _}, state) do
    state =
      case state.acquisitions[ticket] do
        %{owner: ^caller} -> retire_ticket(state, :acquisitions, ticket)
        _ -> state
      end

    {:reply, :ok, state}
  end

  defp handle_private_call({:begin_profile_mutation, principal}, {caller, _}, state) do
    if valid_principal?(principal) and Process.alive?(caller) and
         map_size(state.mutations) < @max_mutations and generation_capacity?(state, principal) do
      state = retire_principal(state, principal)
      generation = make_ref()
      ticket = make_ref()
      row = %{owner: caller, principal: principal, generation: generation}

      state = %{
        state
        | generations: Map.put(state.generations, principal, generation),
          mutations: Map.put(state.mutations, ticket, row)
      }

      {:reply, {:ok, ticket}, monitor(state, caller, {:mutation, ticket})}
    else
      {:reply, {:error, :notice_unavailable}, state}
    end
  end

  defp handle_private_call({:finish_profile_mutation, ticket}, {caller, _}, state) do
    case state.mutations[ticket] do
      %{owner: ^caller} -> {:reply, :ok, retire_ticket(state, :mutations, ticket)}
      _ -> {:reply, {:error, :notice_unavailable}, state}
    end
  end

  defp handle_private_call({:delegate, source_token, worker}, {caller, _}, state) do
    with true <- Process.alive?(caller),
         %{owner: ^caller} = source <- state.sources[source_token],
         true <- state.generations[source.facts.principal_id] == source.generation,
         false <- mutating?(state, source.facts.principal_id),
         true <- is_pid(worker) and node(worker) == node() and Process.alive?(worker),
         true <- worker != caller and not Map.has_key?(state.workers, worker),
         true <- map_size(state.workers) < @max_workers do
      bootstrap = make_ref()

      row = %{
        source: source_token,
        bootstrap: bootstrap,
        claimed: false,
        custody: nil,
        admission: nil
      }

      state = %{state | workers: Map.put(state.workers, worker, row)}
      {:reply, {:ok, bootstrap}, monitor(state, worker, {:worker, worker})}
    else
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_private_call({:claim, bootstrap}, {caller, _}, state) do
    with true <- Process.alive?(caller),
         %{bootstrap: ^bootstrap, claimed: false} = worker <- state.workers[caller],
         true <- is_reference(bootstrap),
         {:ok, _source} <- source_for(state, worker) do
      custody = make_ref()

      {:reply, {:ok, custody},
       put_worker(state, caller, %{worker | claimed: true, bootstrap: nil, custody: custody})}
    else
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_private_call({:worker, custody, message}, {caller, _} = from, state) do
    with true <- is_reference(custody) and Process.alive?(caller),
         %{claimed: true, custody: ^custody} <- state.workers[caller] do
      handle_worker_call(message, from, state)
    else
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_private_call({:retire_principal, principal}, _from, state) do
    state = retire_principal(state, principal)
    {:reply, :ok, %{state | generations: Map.put(state.generations, principal, make_ref())}}
  end

  # GenServer from is protocol data. A forged victim PID/reply alias without
  # the worker's private opaque custody is never a native publication call.
  defp handle_private_call(_message, _from, state),
    do: {:reply, {:error, :native_notice_source_required}, state}

  defp handle_worker_call({:resource, params}, {caller, _}, state) do
    reply =
      with {:ok, _worker, source, mailbox, scope} <- binding(state, caller, params),
           :ok <- source_current(source, mailbox, nil),
           {:ok, value} <-
             ConversationNoticeCore.new(scope, mailbox["recipient_subject_id"], params),
           do: ConversationNoticeCore.resource(scope, value)

    {:reply, reply, state}
  end

  defp handle_worker_call({:prepare, params, taints}, {caller, _}, state) do
    with {:ok, %{admission: nil} = worker, source, mailbox, scope} <-
           binding(state, caller, params),
         :ok <- source_current(source, mailbox, nil),
         {:ok, value} <-
           ConversationNoticeCore.new(scope, mailbox["recipient_subject_id"], params, taints),
         {:ok, payload} <- ConversationNoticeCore.payload(scope, value),
         {:ok, resource} <- ConversationNoticeCore.resource(scope, value),
         {:ok, proof} <- SigningAuthorityBroker.sign(source.authority, payload),
         {:ok, decision} <-
           Arbor.Security.prepare_native_notice_capability(
             source.facts.principal_id,
             resource,
             payload,
             proof
           ),
         {:ok, digest} <- ConversationNoticeCore.digest(scope, value) do
      token = make_ref()

      admission = %{
        token: token,
        phase: :prepared,
        params: params,
        scope: scope,
        value: value,
        mailbox: mailbox,
        decision: decision,
        digest: digest,
        resource: resource,
        deadline: System.monotonic_time(:millisecond) + @prepare_ms,
        key: {scope.owner_id, scope.target_agent_id, scope.engagement_id, value.notice_id}
      }

      result = %{
        prepared: token,
        principal_id: source.facts.principal_id,
        resource: resource,
        capability: decision.capability
      }

      {:reply, {:ok, result}, put_worker(state, caller, %{worker | admission: admission})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call({:activate, token}, {caller, _}, state) do
    with {:ok, worker, source, %{token: ^token, phase: :prepared} = admission} <-
           admission(state, caller),
         :ok <- current(source, admission),
         :ok <- reservation_available(state, admission, caller),
         true <-
           map_size(state.reservations) < @max_reservations or
             Map.has_key?(state.reservations, admission.key) do
      previous = state.reservations[admission.key]
      phase = if previous && previous.phase == :uncertain, do: :uncertain, else: :active
      reservation = %{owner: caller, digest: admission.digest, phase: phase}
      state = %{state | reservations: Map.put(state.reservations, admission.key, reservation)}

      {:reply, :ok,
       put_worker(state, caller, %{worker | admission: %{admission | phase: :active}})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call({:peek, params}, {caller, _}, state) do
    reply =
      with {:ok, _worker, source, %{phase: :active, params: ^params} = admission} <-
             admission(state, caller),
           :ok <- current(source, admission),
           do: {:ok, %{scope: admission.scope, value: admission.value}}

    {:reply, reply, state}
  end

  defp handle_worker_call({:consume, params}, {caller, _}, state) do
    with {:ok, worker, source, %{phase: :active, params: ^params} = admission} <-
           admission(state, caller),
         %{owner: ^caller, phase: :active} <- state.reservations[admission.key],
         :ok <- current(source, admission),
         {:ok, :authorized} <- Arbor.Security.consume_native_notice_capability(admission.decision) do
      reservation = %{state.reservations[admission.key] | phase: :publishing}
      state = %{state | reservations: Map.put(state.reservations, admission.key, reservation)}
      state = put_worker(state, caller, %{worker | admission: %{admission | phase: :publishing}})
      {:reply, {:ok, %{scope: admission.scope, value: admission.value}}, state}
    else
      %{phase: :uncertain} -> {:reply, {:error, :notice_publication_uncertain}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call({:consume_value, scope, value}, from, state) do
    caller = elem(from, 0)

    case admission(state, caller) do
      {:ok, _worker, _source, %{scope: ^scope, value: ^value, params: params}} ->
        case handle_worker_call({:consume, params}, from, state) do
          {:reply, {:ok, _private_value}, next} -> {:reply, :ok, next}
          other -> other
        end

      _ ->
        {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call({:reconcile_value, scope, value}, {caller, _}, state) do
    with {:ok, worker, source, %{phase: :active, scope: ^scope, value: ^value} = admission} <-
           admission(state, caller),
         :ok <- current(source, admission) do
      {:reply, :ok,
       put_worker(state, caller, %{worker | admission: %{admission | phase: :reconciled}})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call({:reconciled, params}, {caller, _}, state) do
    with {:ok, worker, source, %{phase: :active, params: ^params} = admission} <-
           admission(state, caller),
         :ok <- current(source, admission) do
      {:reply, :ok, retire_admission(state, caller, worker, admission, :known)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call({:finish, params, outcome}, {caller, _}, state) do
    with {:ok, worker, _source, %{phase: phase, params: ^params} = admission} <-
           admission(state, caller),
         true <- phase in [:publishing, :reconciled] do
      disposition = if outcome in [:stored, :refused], do: :known, else: :uncertain
      {:reply, :ok, retire_admission(state, caller, worker, admission, disposition)}
    else
      _ -> {:reply, {:error, :native_notice_source_required}, state}
    end
  end

  defp handle_worker_call(:discard, {caller, _}, state) do
    state =
      case state.workers[caller] do
        %{admission: %{phase: phase} = admission} = worker ->
          retire_admission(
            state,
            caller,
            worker,
            admission,
            if(phase == :publishing, do: :uncertain, else: :known)
          )

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  defp handle_worker_call(:close, {caller, _}, state),
    do: {:reply, :ok, retire_worker(state, caller)}

  defp handle_worker_call(_message, _from, state),
    do: {:reply, {:error, :native_notice_source_required}, state}

  @impl true
  def handle_info(message, %{private: private} = carrier) do
    [{:state, state}] = :ets.lookup(private, :state)
    {:noreply, next} = handle_private_info(message, state)
    :ets.insert(private, {:state, next})
    {:noreply, carrier}
  end

  @impl true
  def format_status(status) when is_map(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)

  defp handle_private_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    expired = for {ticket, row} <- state.acquisitions, row.deadline < now, do: ticket
    state = Enum.reduce(expired, state, &retire_ticket(&2, :acquisitions, &1))

    principals =
      Enum.map(state.sources, fn {_token, row} -> row.facts.principal_id end) ++
        Enum.map(state.acquisitions, fn {_token, row} -> row.principal end) ++
        Enum.map(state.mutations, fn {_token, row} -> row.principal end)

    Process.send_after(self(), :sweep, 1_000)
    {:noreply, %{state | generations: Map.take(state.generations, principals)}}
  end

  defp handle_private_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{:source, token}, monitors} ->
        {:noreply, retire_source(%{state | monitors: monitors}, token)}

      {{:worker, pid}, monitors} ->
        {:noreply, retire_worker(%{state | monitors: monitors}, pid)}

      {{:acquisition, ticket}, monitors} ->
        {:noreply, retire_ticket(%{state | monitors: monitors}, :acquisitions, ticket)}

      {{:mutation, ticket}, monitors} ->
        principal = state.mutations[ticket].principal
        state = retire_ticket(%{state | monitors: monitors}, :mutations, ticket)
        {:noreply, retire_principal(state, principal)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp source_for(state, worker) do
    case state.sources[worker.source] do
      nil ->
        {:error, :native_notice_source_required}

      source ->
        with {:ok, %{principal_id: principal}} <-
               SigningAuthorityBroker.recorded_identity(source.authority, source.owner),
             true <-
               principal == source.facts.principal_id and
                 Process.alive?(source.owner) and Process.alive?(source.facts.branch_pid),
             true <-
               state.generations[principal] == source.generation and
                 not mutating?(state, principal) do
          {:ok, source}
        else
          _ -> {:error, :native_notice_source_required}
        end
    end
  end

  defp binding(state, caller, params) do
    with true <- Process.alive?(caller),
         {:ok, _} <- ConversationNoticeCore.params(params),
         %{claimed: true} = worker <- state.workers[caller],
         {:ok, source} <- source_for(state, worker),
         mailbox when is_map(mailbox) <-
           Enum.find(
             source.facts.mailboxes,
             &(&1["mailbox_id"] == params.mailbox_id)
           ),
         scope = %{
           owner_id: mailbox["owner_id"],
           target_agent_id: source.facts.principal_id,
           engagement_id: mailbox["engagement_id"]
         } do
      {:ok, worker, source, mailbox, scope}
    else
      _ -> {:error, :native_notice_source_required}
    end
  end

  defp admission(state, caller) do
    with true <- Process.alive?(caller),
         %{claimed: true, admission: admission} = worker <- state.workers[caller],
         true <- is_map(admission),
         {:ok, source} <- source_for(state, worker) do
      {:ok, worker, source, admission}
    else
      _ -> {:error, :native_notice_source_required}
    end
  end

  defp current(source, admission) do
    with true <- admission.deadline >= System.monotonic_time(:millisecond),
         :ok <- source_current(source, admission.mailbox, admission.decision.capability),
         :ok <- Arbor.Security.recheck_native_notice_capability(admission.decision) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp source_current(source, mailbox, cap) do
    adapter = Config.native_notice_source_authorizer()

    with true <- is_atom(adapter) and adapter not in [nil, true, false],
         :ok <- apply(adapter, :recheck, [source.facts, mailbox, cap]),
         do: :ok
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp reservation_available(state, admission, caller) do
    case state.reservations[admission.key] do
      nil -> :ok
      %{owner: ^caller, digest: digest} when digest == admission.digest -> :ok
      %{phase: :uncertain, digest: digest} when digest == admission.digest -> :ok
      %{digest: digest} when digest != admission.digest -> {:error, :notice_conflict}
      _ -> {:error, :notice_in_progress}
    end
  end

  defp retire_admission(state, caller, worker, admission, disposition) do
    reservations =
      case state.reservations[admission.key] do
        %{owner: ^caller} = reservation when disposition == :uncertain ->
          Map.put(state.reservations, admission.key, %{
            reservation
            | owner: nil,
              phase: :uncertain
          })

        %{owner: ^caller} ->
          Map.delete(state.reservations, admission.key)

        _ ->
          state.reservations
      end

    put_worker(%{state | reservations: reservations}, caller, %{worker | admission: nil})
  end

  defp retire_worker(state, pid) do
    case state.workers[pid] do
      %{admission: %{phase: phase} = admission} = worker ->
        state =
          retire_admission(
            state,
            pid,
            worker,
            admission,
            if(phase == :publishing, do: :uncertain, else: :known)
          )

        %{state | workers: Map.delete(state.workers, pid)}

      _ ->
        %{state | workers: Map.delete(state.workers, pid)}
    end
  end

  defp retire_source(state, token) do
    affected = for {pid, %{source: ^token}} <- state.workers, do: pid
    state = Enum.reduce(affected, state, &retire_worker(&2, &1))

    monitors =
      Enum.reduce(state.monitors, state.monitors, fn
        {ref, {:source, ^token}}, acc ->
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)

        _, acc ->
          acc
      end)

    %{state | sources: Map.delete(state.sources, token), monitors: monitors}
  end

  defp generation_capacity?(state, principal),
    do:
      Map.has_key?(state.generations, principal) or map_size(state.generations) < @max_generations

  defp valid_principal?(principal),
    do: is_binary(principal) and byte_size(principal) in 1..256

  defp mutating?(state, principal),
    do: Enum.any?(state.mutations, fn {_token, row} -> row.principal == principal end)

  defp ensure_generation(state, principal) do
    case state.generations[principal] do
      nil ->
        generation = make_ref()
        {generation, %{state | generations: Map.put(state.generations, principal, generation)}}

      generation ->
        {generation, state}
    end
  end

  defp retire_principal(state, principal) do
    sources =
      for {token, source} <- state.sources, source.facts.principal_id == principal, do: token

    acquisitions = for {token, row} <- state.acquisitions, row.principal == principal, do: token
    state = Enum.reduce(sources, state, &retire_source(&2, &1))
    Enum.reduce(acquisitions, state, &retire_ticket(&2, :acquisitions, &1))
  end

  defp retire_ticket(state, field, ticket) do
    kind = if field == :acquisitions, do: :acquisition, else: :mutation

    monitors =
      Enum.reduce(state.monitors, state.monitors, fn
        {ref, {^kind, ^ticket}}, acc ->
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)

        _, acc ->
          acc
      end)

    %{Map.put(state, field, Map.delete(Map.fetch!(state, field), ticket)) | monitors: monitors}
  end

  defp monitor(state, pid, value),
    do: %{state | monitors: Map.put(state.monitors, Process.monitor(pid), value)}

  defp put_worker(state, pid, worker), do: %{state | workers: Map.put(state.workers, pid, worker)}

  defp valid_source?(facts, caller) do
    is_map(facts) and not is_struct(facts) and
      Enum.sort(Map.keys(facts)) ==
        Enum.sort([:principal_id, :owner_pid, :branch_pid, :role, :mailboxes]) and
      facts.owner_pid == caller and is_pid(facts.branch_pid) and
      Process.alive?(facts.branch_pid) and facts.role in [:session, :heartbeat_service] and
      is_list(facts.mailboxes) and length(facts.mailboxes) in 1..16 and
      Enum.all?(
        facts.mailboxes,
        &match?({:ok, _}, Arbor.Security.validate_native_notice_mailbox(facts.principal_id, &1))
      )
  rescue
    _ -> false
  end
end
