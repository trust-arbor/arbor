defmodule Arbor.Scheduler.RunLease do
  @moduledoc false

  use GenServer, restart: :transient

  require Logger

  alias __MODULE__.Store

  alias Arbor.Scheduler.OwnedRoutines
  alias Arbor.Scheduler.CapsFile.Attestation

  @call_timeout 30_000
  @admission_retry_ms 10
  @admission_max_attempts 100

  @type id :: String.t()

  def child_spec({mode, lease_id, _creation_token} = init_arg)
      when mode in [:activate] and is_binary(lease_id) do
    %{
      id: {__MODULE__, lease_id},
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :transient
    }
  end

  def child_spec(lease_id) when is_binary(lease_id) do
    %{
      id: {__MODULE__, lease_id},
      start: {__MODULE__, :start_link, [{:recover, lease_id}]},
      restart: :transient
    }
  end

  def start(owner, %Attestation{} = attestation, opts)
      when owner == self() and is_list(opts) do
    lease_id = "lease_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case Store.create(lease_id, owner, attestation, opts) do
      {:ok, creation_token} ->
        case DynamicSupervisor.start_child(
               __MODULE__.DynamicSupervisor,
               {__MODULE__, {:activate, lease_id, creation_token}}
             ) do
          {:ok, pid} ->
            case Arbor.Common.authenticated_call(pid, :await_ready, @call_timeout) do
              :ok ->
                {:ok, lease_id}

              {:error, _reason} = error ->
                Store.discard_unstarted(lease_id, creation_token)
                error
            end

          {:error, reason} = error ->
            Store.discard_unstarted(lease_id, creation_token)
            if reason == :already_present, do: {:error, :lease_id_collision}, else: error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def start(owner, %Attestation{}, opts) when is_pid(owner) and is_list(opts),
    do: {:error, :unauthorized}

  def start(_owner, _attestation, _opts), do: {:error, :verified_attestation_required}

  def start(_owner, _opts), do: {:error, :verified_attestation_required}

  def start_link({mode, lease_id} = init_arg)
      when mode == :recover and is_binary(lease_id) do
    GenServer.start_link(__MODULE__, init_arg, name: via(lease_id))
  end

  def start_link({mode, lease_id, creation_token} = init_arg)
      when mode == :activate and is_binary(lease_id) and is_reference(creation_token) do
    GenServer.start_link(__MODULE__, init_arg, name: via(lease_id))
  end

  def register_identity(lease_id, identity, security),
    do: call(lease_id, {:register_identity, identity, security})

  def grant_capability(lease_id, opts, security),
    do: call(lease_id, {:grant_capability, opts, security})

  def open_authority(lease_id, identity, security),
    do: call(lease_id, {:open_authority, identity, security})

  def bind_routine(lease_id, binding), do: call(lease_id, {:bind_routine, binding})

  def authorize_routine_effect(%{lease: lease, token: token} = reference, effect)
      when map_size(reference) == 2 and is_binary(lease) and byte_size(lease) == 30 and
             is_binary(token) and byte_size(token) == 43 do
    case call(lease, {:routine_effect, token, effect}) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :routine_effect_unavailable}
    end
  rescue
    _ -> {:error, :routine_effect_unavailable}
  catch
    _, _ -> {:error, :routine_effect_unavailable}
  end

  def authorize_routine_effect(_, _), do: {:error, :invalid_routine_effect_token}

  def routine_requirement(principal) do
    Store.routine_requirement(principal)
  rescue
    _ -> {:error, :routine_lease_unavailable}
  catch
    _, _ -> {:error, :routine_lease_unavailable}
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, %{lease: :owned})
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
  end

  def revoke(nil), do: :ok
  def revoke(lease_id), do: call(lease_id, :revoke, restart_for_cleanup: true)

  @doc false
  @spec active_agent_ids() :: MapSet.t(String.t()) | {:error, :run_lease_store_unavailable}
  def active_agent_ids, do: Store.active_agent_ids()

  @doc false
  def whereis(lease_id) do
    case Registry.lookup(__MODULE__.Registry, lease_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init({:activate, lease_id, creation_token}) do
    Process.flag(:sensitive, true)

    {:ok,
     %{
       lease_id: lease_id,
       admission: {:activate, creation_token},
       admission_ref: make_ref(),
       admission_attempts: 0,
       ready_waiters: [],
       authenticated_calls: Arbor.Common.new_authenticated_call_custody()
     }, {:continue, :admit}}
  end

  def init({:recover, lease_id}) do
    Process.flag(:sensitive, true)

    {:ok,
     %{
       lease_id: lease_id,
       admission: :recover,
       admission_ref: make_ref(),
       admission_attempts: 0,
       ready_waiters: [],
       authenticated_calls: Arbor.Common.new_authenticated_call_custody()
     }, {:continue, :admit}}
  end

  @impl true
  def handle_continue(:admit, state), do: admit_lease(state)

  def handle_continue(:cleanup, state), do: begin_cleanup(state)

  @impl true
  def handle_info(
        {:admit, admission_ref},
        %{admission_ref: admission_ref} = state
      ),
      do: admit_lease(state)

  def handle_info({:admit, _unknown_ref}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    begin_cleanup(state)
  end

  def handle_info({:expire, expiry_token}, %{expiry_token: expiry_token} = state) do
    Logger.warning("[RunLease] per-run identity lease expired; revoking run authority")
    begin_cleanup(state)
  end

  def handle_info({:expire, _unknown_token}, state), do: {:noreply, state}

  def handle_info({:cleanup, cleanup_token}, %{cleanup_token: cleanup_token} = state),
    do: run_cleanup(state)

  def handle_info({:cleanup, _unknown_token}, state), do: {:noreply, state}

  def handle_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        handle_authenticated_request(request, caller, reply_to, state)

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  defp admit_lease(%{lease_id: lease_id} = state) do
    case Store.admit_worker(lease_id, state.admission) do
      {:ok, lease} ->
        expiry_token = make_ref()

        admitted_state = %{
          lease_id: lease_id,
          phase: :ready,
          owner_ref: Process.monitor(lease.owner),
          expiry_ref: schedule_expiry(lease.expires_at, expiry_token),
          expiry_token: expiry_token,
          cleanup_token: make_ref(),
          waiters: state.ready_waiters,
          authenticated_calls: state.authenticated_calls,
          owner: lease.owner
        }

        reply_waiters(state.ready_waiters, :ok)
        {:noreply, %{admitted_state | waiters: []}}

      {:cleanup, lease} ->
        expiry_token = make_ref()

        cleanup_state = %{
          lease_id: lease_id,
          phase: :cleaning,
          owner_ref: Process.monitor(lease.owner),
          expiry_ref: nil,
          expiry_token: expiry_token,
          cleanup_token: make_ref(),
          waiters: [],
          authenticated_calls: state.authenticated_calls,
          owner: lease.owner
        }

        reply_waiters(state.ready_waiters, {:error, :lease_closing})
        begin_cleanup(cleanup_state)

      {:error, :not_found} ->
        reply_waiters(state.ready_waiters, {:error, :lease_not_found})
        {:stop, :normal, state}

      {:error, :unauthorized} ->
        reply_waiters(state.ready_waiters, {:error, :unauthorized})
        {:stop, :normal, state}

      {:error, :lease_worker_not_admitted} ->
        retry_admission(state, :lease_worker_not_admitted)

      {:error, reason} ->
        retry_admission(state, reason)
    end
  end

  defp retry_admission(
         %{admission_attempts: attempts, admission_ref: admission_ref} = state,
         reason
       )
       when attempts < @admission_max_attempts do
    Process.send_after(self(), {:admit, admission_ref}, @admission_retry_ms)
    {:noreply, %{state | admission_attempts: attempts + 1, admission_error: reason}}
  end

  defp retry_admission(state, reason) do
    reply_waiters(state.ready_waiters, {:error, {:lease_admission_failed, reason}})
    {:stop, {:lease_admission_failed, reason}, state}
  end

  @impl true
  def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  defp handle_authenticated_request(:await_ready, _caller, reply_to, %{phase: :ready} = state) do
    :ok = Arbor.Common.reply_authenticated_call(reply_to, :ok)
    {:noreply, state}
  end

  defp handle_authenticated_request(:await_ready, _caller, reply_to, %{phase: :cleaning} = state) do
    :ok = Arbor.Common.reply_authenticated_call(reply_to, {:error, :lease_closing})
    {:noreply, state}
  end

  defp handle_authenticated_request(:await_ready, _caller, reply_to, state) do
    {:noreply, %{state | ready_waiters: [reply_to | state.ready_waiters]}}
  end

  defp handle_authenticated_request(
         {:register_identity, identity, security},
         caller,
         reply_to,
         %{owner: caller} = state
       ) do
    reply_store_mutation(
      Store.register_identity(state.lease_id, identity, security),
      reply_to,
      state
    )
  end

  defp handle_authenticated_request(
         {:grant_capability, opts, security},
         caller,
         reply_to,
         %{owner: caller} = state
       ) do
    reply_store_mutation(Store.grant_capability(state.lease_id, opts, security), reply_to, state)
  end

  defp handle_authenticated_request(
         {:open_authority, identity, security},
         caller,
         reply_to,
         %{owner: caller} = state
       ) do
    reply_store_mutation(
      Store.open_authority(state.lease_id, identity, security),
      reply_to,
      state
    )
  end

  defp handle_authenticated_request(
         {:bind_routine, binding},
         caller,
         reply_to,
         %{owner: caller} = state
       ) do
    reply_store_mutation(Store.bind_routine(state.lease_id, binding), reply_to, state)
  end

  defp handle_authenticated_request(
         :revoke,
         caller,
         reply_to,
         %{owner: caller, waiters: waiters} = state
       ) do
    begin_cleanup(%{state | waiters: [reply_to | waiters]})
  end

  defp handle_authenticated_request(:revoke, _caller, reply_to, state) do
    :ok = Arbor.Common.reply_authenticated_call(reply_to, {:error, :unauthorized})
    {:noreply, state}
  end

  defp handle_authenticated_request(
         {:routine_effect, token, effect},
         _caller,
         reply_to,
         %{owner_ref: _owner_ref} = state
       ) do
    result =
      with {:ok, binding} <- current_routine_binding(state.lease_id, token),
           :ok <- OwnedRoutines.check_effect(binding, effect),
           {:ok, ^binding} <- current_routine_binding(state.lease_id, token) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :routine_lease_not_current}
      end

    :ok = Arbor.Common.reply_authenticated_call(reply_to, result)
    {:noreply, state}
  end

  defp handle_authenticated_request({:routine_effect, _token, _effect}, _caller, reply_to, state) do
    :ok =
      Arbor.Common.reply_authenticated_call(reply_to, {:error, :lease_admission_pending})

    {:noreply, state}
  end

  defp handle_authenticated_request(_request, _caller, reply_to, state) do
    :ok = Arbor.Common.reply_authenticated_call(reply_to, {:error, :unauthorized})
    {:noreply, state}
  end

  defp reply_store_mutation(result, reply_to, state) do
    :ok = Arbor.Common.reply_authenticated_call(reply_to, result)

    case result do
      {:error, :lease_closing} -> begin_cleanup(state)
      _other -> {:noreply, state}
    end
  end

  defp current_routine_binding(lease_id, token) do
    with {:ok,
          %{
            status: :active,
            owner: owner,
            expires_at: expires_at,
            routine_binding: %{token: ^token} = binding
          }} <- Store.fetch_for_lease(lease_id),
         true <- Process.alive?(owner),
         true <- System.monotonic_time(:millisecond) < expires_at do
      {:ok, binding}
    else
      _ -> {:error, :routine_lease_not_current}
    end
  end

  defp begin_cleanup(state) do
    :ok = Store.begin_cleanup(state.lease_id)
    send(self(), {:cleanup, state.cleanup_token})
    {:noreply, Map.put(state, :phase, :cleaning)}
  end

  defp run_cleanup(state) do
    case Store.cleanup_snapshot(state.lease_id) do
      {:ok, snapshot} ->
        failures = cleanup(state.lease_id, snapshot)

        case Store.finish_attempt(state.lease_id, snapshot.generation, failures) do
          :complete ->
            reply_waiters(state.waiters, :ok)
            Store.discard(state.lease_id)
            {:stop, :normal, %{state | waiters: []}}

          {:retry, delay_ms} ->
            Process.send_after(self(), {:cleanup, state.cleanup_token}, delay_ms)
            {:noreply, state}

          {:reconcile, terminal_failures, delay_ms} ->
            error = {:error, {:cleanup_failed, terminal_failures}}

            Logger.error(
              "[RunLease] cleanup threshold reached; reconciliation remains active: #{inspect(terminal_failures)}"
            )

            reply_waiters(state.waiters, error)
            Process.send_after(self(), {:cleanup, state.cleanup_token}, delay_ms)
            {:noreply, %{state | waiters: []}}
        end

      {:error, :not_found} ->
        reply_waiters(state.waiters, :ok)
        {:stop, :normal, %{state | waiters: []}}
    end
  end

  defp cleanup(lease_id, snapshot) do
    []
    |> cleanup_authority(snapshot)
    |> cleanup_caps(lease_id, snapshot)
    |> cleanup_trust(snapshot)
    |> cleanup_identity(lease_id, snapshot)
  end

  defp cleanup_authority(failures, %{authority: nil}), do: failures

  defp cleanup_authority(failures, snapshot) do
    run_operation(failures, :authority, fn ->
      snapshot.security.close_signing_authority(snapshot.authority)
    end)
  end

  defp cleanup_caps(failures, lease_id, snapshot) do
    Enum.reduce(snapshot.cap_ids, failures, fn cap_id, acc ->
      run_operation(acc, {:capability, cap_id}, fn ->
        Store.revoke_capability(lease_id, cap_id)
      end)
    end)
  end

  defp cleanup_trust(failures, %{agent_id: nil}), do: failures
  defp cleanup_trust(failures, %{trust_pending: false}), do: failures

  defp cleanup_trust(failures, snapshot) do
    run_operation(failures, :trust_profile, fn ->
      snapshot.trust.delete_trust_profile(snapshot.agent_id)
    end)
  end

  defp cleanup_identity(failures, _lease_id, %{agent_id: nil}), do: failures
  defp cleanup_identity(failures, _lease_id, %{identity_pending: false}), do: failures

  defp cleanup_identity(failures, lease_id, snapshot) do
    run_operation(failures, :identity, fn ->
      Store.deregister_identity(lease_id, snapshot.agent_id)
    end)
  end

  defp run_operation(failures, operation, fun) do
    case safe_call(fun) do
      :ok ->
        Store.operation_succeeded(self_lease_id(), operation)
        failures

      {:error, reason} ->
        [{operation, reason} | failures]
    end
  end

  defp safe_call(fun) do
    case fun.() do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :authority_not_found} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp call(lease_id, message, opts \\ []) when is_binary(lease_id),
    do: do_call(lease_id, message, 2, opts)

  defp do_call(lease_id, message, attempts, opts) do
    with :ok <- maybe_ensure_lease_process(lease_id, opts),
         {:ok, pid} <- await_pid(lease_id, 50) do
      Arbor.Common.authenticated_call(pid, message, @call_timeout)
    else
      {:error, :lease_not_found} -> absent_lease_result(message)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> recover_call(lease_id, message, attempts, opts, reason)
  end

  defp recover_call(_lease_id, _message, 0, _opts, reason),
    do: {:error, {:lease_unavailable, reason}}

  defp recover_call(lease_id, message, attempts, opts, reason) do
    case Store.exists?(lease_id) do
      false ->
        absent_lease_result(message)

      true ->
        Process.sleep(10)
        do_call(lease_id, message, attempts - 1, opts)

      {:error, store_reason} ->
        {:error, {:lease_unavailable, {reason, store_reason}}}
    end
  end

  # Cleanup is idempotent; effect admission is never successful without a
  # current owned lease. Both initial lookup and owner-death retry use this.
  defp absent_lease_result(:revoke), do: :ok

  defp absent_lease_result({:routine_effect, _token, _effect}),
    do: {:error, :routine_lease_not_current}

  defp absent_lease_result(_message), do: {:error, :lease_closing}

  defp maybe_ensure_lease_process(lease_id, opts) do
    if Keyword.get(opts, :restart_for_cleanup, false) do
      ensure_lease_process(lease_id)
    else
      case exact_lease_pid(lease_id) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> {:error, :lease_not_found}
      end
    end
  end

  defp ensure_lease_process(lease_id) do
    case exact_lease_pid(lease_id) do
      {:ok, _pid} ->
        :ok

      {:error, _reason} ->
        case Store.exists?(lease_id) do
          true ->
            case DynamicSupervisor.start_child(
                   __MODULE__.DynamicSupervisor,
                   {__MODULE__, lease_id}
                 ) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
              {:error, reason} -> {:error, {:lease_restart_failed, reason}}
            end

          false ->
            {:error, :lease_not_found}

          {:error, reason} ->
            {:error, {:lease_journal_unavailable, reason}}
        end
    end
  end

  defp await_pid(_lease_id, 0), do: {:error, :lease_unavailable}

  defp await_pid(lease_id, attempts) do
    case exact_lease_pid(lease_id) do
      {:error, _reason} ->
        Process.sleep(10)
        await_pid(lease_id, attempts - 1)

      {:ok, pid} ->
        {:ok, pid}
    end
  end

  defp exact_lease_pid(lease_id) do
    with [{pid, _value}] <- Registry.lookup(__MODULE__.Registry, lease_id),
         {:ok, supervisor} <-
           Arbor.Common.supervised_registered_child_pid(
             :arbor_scheduler,
             [
               Arbor.Scheduler.RuntimeSupervisor,
               Arbor.Scheduler.RunLeaseSupervisor,
               Arbor.Scheduler.RunLease.DynamicSupervisor
             ],
             Arbor.Scheduler.RunLease.DynamicSupervisor
           ),
         true <-
           Enum.any?(DynamicSupervisor.which_children(supervisor), fn
             {_child_id, ^pid, :worker, modules} when is_list(modules) ->
               __MODULE__ in modules

             _child ->
               false
           end) do
      {:ok, pid}
    else
      _other -> {:error, :lease_not_found}
    end
  rescue
    _exception -> {:error, :lease_not_found}
  catch
    :exit, _reason -> {:error, :lease_not_found}
  end

  defp schedule_expiry(expires_at, expiry_token) do
    delay = max(expires_at - System.monotonic_time(:millisecond), 0)
    Process.send_after(self(), {:expire, expiry_token}, delay)
  end

  defp reply_waiters(waiters, result) do
    Enum.each(waiters, &Arbor.Common.reply_authenticated_call(&1, result))
  end

  defp self_lease_id do
    [lease_id] = Registry.keys(__MODULE__.Registry, self())
    lease_id
  end

  defp via(lease_id), do: {:via, Registry, {__MODULE__.Registry, lease_id}}

  defmodule JournalOwner do
    @moduledoc false

    use GenServer

    @table Arbor.Scheduler.RunLease.StateOwner

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def fetch(id), do: call({:fetch, id})
    def put(id, lease), do: call({:put, id, lease})
    def delete(id), do: call({:delete, id})
    def all_ids, do: call(:all_ids)
    def all_leases, do: call(:all_leases)
    def recovery_snapshot, do: call(:recovery_snapshot)
    def complete_recovery, do: call(:complete_recovery)

    def open_authority(lease_id, identity, security),
      do: call({:open_authority, lease_id, identity, security}, 30_000)

    @impl true
    def init(:ok) do
      Process.flag(:sensitive, true)
      :ets.new(@table, [:named_table, :private, :set])

      {:ok,
       %{
         table: @table,
         recovery_required: true,
         authenticated_calls: Arbor.Common.new_authenticated_call_custody()
       }}
    end

    @impl true
    # The caller PID in a raw `$gen_call` is attacker-controlled message data.
    # Every journal operation crosses the authenticated StateOwner boundary.
    def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

    @impl true
    def handle_cast(_request, state), do: {:noreply, state}

    @impl true
    def handle_info(message, state) do
      case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
        {:authenticated, caller, request, reply_to} ->
          {reply, state} = dispatch_authenticated(request, caller, state)
          :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
          {:noreply, state}

        result when result in [:pending, :expired, :rejected, :unrecognized] ->
          {:noreply, state}
      end
    end

    defp handle_state_owner_call({:fetch, id}, state) do
      reply =
        case :ets.lookup(@table, id) do
          [{^id, lease}] -> {:ok, lease}
          [] -> :error
        end

      {:reply, reply, state}
    end

    defp handle_state_owner_call({:put, id, lease}, state) do
      true = :ets.insert(@table, {id, lease})
      {:reply, :ok, state}
    end

    defp handle_state_owner_call({:delete, id}, state) do
      true = :ets.delete(@table, id)
      {:reply, :ok, state}
    end

    defp handle_state_owner_call(:all_ids, state) do
      {:reply, {:ok, Enum.map(:ets.tab2list(@table), &elem(&1, 0))}, state}
    end

    defp handle_state_owner_call(:all_leases, state) do
      {:reply, {:ok, Enum.map(:ets.tab2list(@table), &elem(&1, 1))}, state}
    end

    defp handle_state_owner_call(:recovery_snapshot, state) do
      leases = :ets.tab2list(@table)

      snapshot = %{
        lease_ids: Enum.map(leases, fn {id, _lease} -> id end),
        active_cap_ids: active_cap_ids(leases),
        journal_lost: state.recovery_required
      }

      {:reply, {:ok, snapshot}, state}
    end

    defp handle_state_owner_call(:complete_recovery, state) do
      {:reply, :ok, %{state | recovery_required: false}}
    end

    defp handle_state_owner_call({:open_authority, lease_id, identity, security}, state) do
      result =
        mutate_active_lease(lease_id, fn lease ->
          with true <- is_nil(lease.authority),
               true <- lease.agent_id == identity.agent_id,
               {:ok, proof} <-
                 safe_external(fn ->
                   security.build_signing_authority_acquisition_proof(
                     identity.agent_id,
                     identity.private_key,
                     purpose: :pipeline_run,
                     owner: self()
                   )
                 end),
               {:ok, authority} <-
                 safe_external(fn ->
                   security.open_ephemeral_signing_authority(proof, identity.private_key)
                 end) do
            updated = %{lease | authority: authority, generation: lease.generation + 1}
            true = :ets.insert(@table, {lease_id, updated})
            {:ok, authority}
          else
            false -> {:error, :lease_authority_binding_denied}
            {:error, reason} -> {:error, reason}
          end
        end)

      {:reply, result, state}
    end

    defp dispatch_authenticated(request, caller, state) do
      if caller == supervised_state_owner_pid() do
        case handle_state_owner_call(request, state) do
          {:reply, reply, state} -> {reply, state}
        end
      else
        {{:error, :unauthorized}, state}
      end
    end

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{journal: :owned})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    defp supervised_state_owner_pid do
      case Arbor.Common.supervised_registered_child_pid(
             :arbor_scheduler,
             [
               Arbor.Scheduler.RuntimeSupervisor,
               Arbor.Scheduler.RunLeaseSupervisor,
               Arbor.Scheduler.RunLease.StateOwner
             ],
             Arbor.Scheduler.RunLease.StateOwner
           ) do
        {:ok, pid} -> pid
        _error -> nil
      end
    end

    defp call(request, timeout \\ 5_000) do
      with {:ok, pid} <-
             Arbor.Common.supervised_registered_child_pid(
               :arbor_scheduler,
               [__MODULE__],
               __MODULE__
             ) do
        Arbor.Common.authenticated_call(pid, request, timeout)
      else
        _error -> {:error, :journal_owner_unavailable}
      end
    rescue
      _exception -> {:error, :journal_owner_unavailable}
    catch
      :exit, _reason -> {:error, :journal_owner_unavailable}
    end

    defp active_cap_ids(leases) do
      Enum.reduce(leases, %{}, fn
        {_id, %{status: :active, owner: owner, agent_id: agent_id, cap_ids: cap_ids}}, acc
        when is_pid(owner) and is_binary(agent_id) ->
          if Process.alive?(owner),
            do: Map.put(acc, agent_id, MapSet.new(cap_ids)),
            else: acc

        _entry, acc ->
          acc
      end)
    end

    defp mutate_active_lease(lease_id, fun) do
      case :ets.lookup(@table, lease_id) do
        [{^lease_id, %{status: :active} = lease}] -> fun.(lease)
        [{^lease_id, _lease}] -> {:error, :lease_closing}
        [] -> {:error, :lease_closing}
      end
    end

    defp safe_external(fun) do
      fun.()
    rescue
      exception -> {:error, {:exception, Exception.message(exception)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defmodule StateOwner do
    @moduledoc false

    use GenServer

    alias Arbor.Scheduler.RunLease.JournalOwner

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def fetch(id), do: call({:fetch, id})
    def put(id, lease), do: call({:put, id, lease})
    def delete(id), do: call({:delete, id})
    def all_ids, do: call(:all_ids)
    def all_leases, do: call(:all_leases)
    def recovery_snapshot, do: call(:recovery_snapshot)
    def complete_recovery, do: call(:complete_recovery)

    def register_identity(lease_id, identity, security),
      do: call({:register_identity, lease_id, identity, security}, 30_000)

    def grant_capability(lease_id, grant_admission),
      do: call({:grant_capability, lease_id, grant_admission}, 30_000)

    def revoke_capability(lease_id, capability_id),
      do: call({:revoke_capability, lease_id, capability_id}, 30_000)

    def deregister_identity(lease_id, agent_id),
      do: call({:deregister_identity, lease_id, agent_id}, 30_000)

    def open_authority(lease_id, identity, security),
      do: call({:open_authority, lease_id, identity, security}, 30_000)

    @impl true
    def init(opts) do
      Process.flag(:sensitive, true)

      case Keyword.get(opts, :scheduler_mutation_token) do
        token when is_reference(token) ->
          {:ok,
           %{
             journal: JournalOwner,
             scheduler_mutation_token: token,
             authenticated_calls: Arbor.Common.new_authenticated_call_custody()
           }}

        _ ->
          {:stop, :scheduler_mutation_token_required}
      end
    end

    @impl true
    # Every request contains lease state or performs a protected mutation. Raw
    # GenServer caller metadata is forgeable, so only AuthenticatedCall enters.
    def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

    @impl true
    def handle_cast(_request, state), do: {:noreply, state}

    @impl true
    def handle_info(message, state) do
      case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
        {:authenticated, caller, request, reply_to} ->
          {reply, state} = dispatch_authenticated(request, caller, state)
          :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
          {:noreply, state}

        result when result in [:pending, :expired, :rejected, :unrecognized] ->
          {:noreply, state}
      end
    end

    defp handle_store_call({:fetch, id}, state), do: {:reply, JournalOwner.fetch(id), state}

    defp handle_store_call({:put, id, lease}, state) do
      {:reply, JournalOwner.put(id, lease), state}
    end

    defp handle_store_call({:delete, id}, state), do: {:reply, JournalOwner.delete(id), state}
    defp handle_store_call(:all_ids, state), do: {:reply, JournalOwner.all_ids(), state}
    defp handle_store_call(:all_leases, state), do: {:reply, JournalOwner.all_leases(), state}

    defp handle_store_call(:recovery_snapshot, state) do
      {:reply, JournalOwner.recovery_snapshot(), state}
    end

    defp handle_store_call(:complete_recovery, state) do
      {:reply, JournalOwner.complete_recovery(), state}
    end

    defp handle_store_call({:register_identity, lease_id, identity, _security}, state) do
      result =
        mutate_active_lease(lease_id, fn lease ->
          if is_nil(lease.agent_id) do
            case safe_external(fn ->
                   register_run_identity(lease, identity, state.scheduler_mutation_token)
                 end) do
              :ok ->
                updated =
                  lease
                  |> put_operation({:identity, identity.agent_id})
                  |> bump_generation()

                :ok = JournalOwner.put(lease_id, updated)
                :ok

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:error, :lease_identity_already_bound}
          end
        end)

      {:reply, result, state}
    end

    defp handle_store_call({:grant_capability, lease_id, grant_admission}, state) do
      result =
        mutate_active_lease(lease_id, fn lease ->
          with {:ok, admitted_lease, opts} <-
                 consume_grant_admission(lease, grant_admission),
               {:ok, cap} <-
                 safe_external(fn ->
                   grant_run_capability(
                     lease,
                     opts,
                     state.scheduler_mutation_token
                   )
                 end) do
            updated =
              admitted_lease
              |> put_operation({:capability, cap.id})
              |> bump_generation()

            :ok = JournalOwner.put(lease_id, updated)
            {:ok, cap}
          else
            {:error, reason} -> {:error, reason}
          end
        end)

      {:reply, result, state}
    end

    defp handle_store_call({:revoke_capability, lease_id, capability_id}, state) do
      result =
        mutate_lease(lease_id, fn lease ->
          if capability_id in lease.cap_ids do
            safe_external(fn ->
              revoke_run_capability(
                lease,
                capability_id,
                state.scheduler_mutation_token
              )
            end)
          else
            {:error, :capability_not_owned_by_lease}
          end
        end)

      {:reply, result, state}
    end

    defp handle_store_call({:deregister_identity, lease_id, agent_id}, state) do
      result =
        mutate_lease(lease_id, fn lease ->
          if lease.agent_id == agent_id do
            safe_external(fn ->
              deregister_run_identity(
                lease,
                agent_id,
                state.scheduler_mutation_token
              )
            end)
          else
            {:error, :identity_not_owned_by_lease}
          end
        end)

      {:reply, result, state}
    end

    defp handle_store_call({:open_authority, lease_id, identity, security}, state) do
      {:reply, JournalOwner.open_authority(lease_id, identity, security), state}
    end

    defp dispatch_authenticated(request, caller, state) do
      if caller == supervised_store_pid() do
        case handle_store_call(request, state) do
          {:reply, reply, state} -> {reply, state}
        end
      else
        {{:error, :unauthorized}, state}
      end
    end

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{journal: :external})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    defp supervised_store_pid do
      case Arbor.Common.supervised_registered_child_pid(
             :arbor_scheduler,
             [
               Arbor.Scheduler.RuntimeSupervisor,
               Arbor.Scheduler.RunLeaseSupervisor,
               Arbor.Scheduler.RunLease.Store
             ],
             Arbor.Scheduler.RunLease.Store
           ) do
        {:ok, pid} -> pid
        _error -> nil
      end
    end

    defp call(request, timeout \\ 5_000) do
      with {:ok, pid} <-
             Arbor.Common.supervised_registered_child_pid(
               :arbor_scheduler,
               [
                 Arbor.Scheduler.RuntimeSupervisor,
                 Arbor.Scheduler.RunLeaseSupervisor,
                 __MODULE__
               ],
               __MODULE__
             ) do
        Arbor.Common.authenticated_call(pid, request, timeout)
      else
        _error -> {:error, :state_owner_unavailable}
      end
    rescue
      _exception -> {:error, :state_owner_unavailable}
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end

    defp mutate_active_lease(lease_id, fun) do
      case JournalOwner.fetch(lease_id) do
        {:ok, %{status: :active} = lease} -> fun.(lease)
        {:ok, _lease} -> {:error, :lease_closing}
        :error -> {:error, :lease_closing}
        {:error, reason} -> {:error, reason}
      end
    end

    defp mutate_lease(lease_id, fun) do
      case JournalOwner.fetch(lease_id) do
        {:ok, lease} -> fun.(lease)
        :error -> {:error, :lease_closing}
        {:error, reason} -> {:error, reason}
      end
    end

    defp put_operation(lease, {:identity, agent_id}) do
      %{lease | agent_id: agent_id, trust_pending: true, identity_pending: true}
    end

    defp put_operation(lease, {:capability, cap_id}) do
      %{lease | cap_ids: Enum.uniq([cap_id | lease.cap_ids])}
    end

    defp consume_grant_admission(%{lobby_granted: false} = lease, :lobby) do
      opts =
        build_grant_opts(
          lease,
          "arbor://orchestrator/execute",
          %{},
          %{}
        )

      {:ok, %{lease | lobby_granted: true}, opts}
    end

    defp consume_grant_admission(
           %{remaining_capabilities: remaining} = lease,
           {:attested, index, descriptor}
         )
         when is_integer(index) and index >= 0 do
      case List.pop_at(remaining, index) do
        {^descriptor, rest} ->
          opts =
            build_grant_opts(
              lease,
              descriptor.resource_uri,
              descriptor.constraints,
              lease.grant_metadata
            )

          {:ok, %{lease | remaining_capabilities: rest}, opts}

        _other ->
          {:error, :capability_admission_stale}
      end
    end

    defp consume_grant_admission(_lease, _grant_admission),
      do: {:error, :capability_admission_stale}

    defp build_grant_opts(lease, resource, constraints, metadata) do
      [
        principal: lease.agent_id,
        resource: resource,
        expires_at: lease.capability_expires_at,
        constraints: constraints,
        metadata: metadata
      ]
    end

    defp bump_generation(lease), do: Map.update!(lease, :generation, &(&1 + 1))

    if Mix.env() == :test do
      defp register_run_identity(%{security: Arbor.Security}, identity, token),
        do: Arbor.Scheduler.Identity.register_run_identity(identity, token)

      defp register_run_identity(%{security: security}, identity, _token),
        do: security.register_identity(identity)

      defp grant_run_capability(%{security: Arbor.Security}, opts, token),
        do: Arbor.Scheduler.Identity.grant_run_capability(opts, token)

      defp grant_run_capability(%{security: security}, opts, _token),
        do: security.grant(opts)

      defp revoke_run_capability(%{security: Arbor.Security}, capability_id, token),
        do: Arbor.Scheduler.Identity.revoke_run_capability(capability_id, token)

      defp revoke_run_capability(%{security: security}, capability_id, _token),
        do: security.revoke(capability_id)

      defp deregister_run_identity(%{security: Arbor.Security}, agent_id, token),
        do: Arbor.Scheduler.Identity.deregister_run_identity(agent_id, token)

      defp deregister_run_identity(%{security: security}, agent_id, _token),
        do: security.deregister_identity(agent_id)
    else
      defp register_run_identity(_lease, identity, token),
        do: Arbor.Scheduler.Identity.register_run_identity(identity, token)

      defp grant_run_capability(_lease, opts, token),
        do: Arbor.Scheduler.Identity.grant_run_capability(opts, token)

      defp revoke_run_capability(_lease, capability_id, token),
        do: Arbor.Scheduler.Identity.revoke_run_capability(capability_id, token)

      defp deregister_run_identity(_lease, agent_id, token),
        do: Arbor.Scheduler.Identity.deregister_run_identity(agent_id, token)
    end

    defp safe_external(fun) do
      fun.()
    rescue
      exception -> {:error, {:exception, Exception.message(exception)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defmodule Reconciler do
    @moduledoc false

    use GenServer

    @startup_retry_ms 10

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Process.flag(:sensitive, true)

      state = %{
        scheduler_mutation_token: Keyword.fetch!(opts, :scheduler_mutation_token),
        reconcile_ref: make_ref(),
        status: :pending
      }

      send(self(), {:reconcile, state.reconcile_ref})
      {:ok, state}
    end

    @impl true
    def handle_info(
          {:reconcile, reconcile_ref},
          %{
            reconcile_ref: reconcile_ref,
            scheduler_mutation_token: scheduler_mutation_token
          } = state
        ) do
      case reconcile(scheduler_mutation_token) do
        {:ok, snapshot} ->
          {:noreply,
           %{
             lease_count: length(snapshot.lease_ids),
             journal_lost: snapshot.journal_lost,
             status: :ready
           }}

        {:retry, _reason} ->
          Process.send_after(self(), {:reconcile, reconcile_ref}, @startup_retry_ms)
          {:noreply, state}

        {:error, reason} ->
          {:stop, {:lease_reconciliation_failed, reason}, state}
      end
    end

    def handle_info({:reconcile, _unknown_ref}, state), do: {:noreply, state}
    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

    @impl true
    def handle_cast(_request, state), do: {:noreply, state}

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{reconciliation: :protected})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    defp reconcile(scheduler_mutation_token) do
      with :ok <- Arbor.Scheduler.RunLease.Store.begin_recovery(),
           {:ok, snapshot} <- Arbor.Scheduler.RunLease.Store.recovery_snapshot(),
           :ok <- reconcile_orphans(snapshot, scheduler_mutation_token),
           :ok <- Arbor.Scheduler.RunLease.Store.complete_recovery(),
           :ok <- restart_leases(snapshot.lease_ids) do
        {:ok, snapshot}
      else
        {:error, :run_lease_store_unavailable} = error -> {:retry, error}
        {:error, :state_owner_unavailable} = error -> {:retry, error}
        {:error, :journal_owner_unavailable} = error -> {:retry, error}
        {:error, reason} -> {:error, reason}
      end
    end

    defp reconcile_orphans(snapshot, scheduler_mutation_token) do
      Arbor.Scheduler.RunIdentityReaper.reconcile(
        active_agent_ids: snapshot.active_cap_ids |> Map.keys() |> MapSet.new(),
        active_cap_ids: snapshot.active_cap_ids,
        scheduler_mutation_token: scheduler_mutation_token
      )
    end

    defp restart_leases(lease_ids) do
      Enum.reduce_while(lease_ids, :ok, fn lease_id, :ok ->
        case DynamicSupervisor.start_child(
               Arbor.Scheduler.RunLease.DynamicSupervisor,
               {Arbor.Scheduler.RunLease, lease_id}
             ) do
          {:ok, _pid} -> {:cont, :ok}
          {:error, {:already_started, _pid}} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {lease_id, reason}}}
        end
      end)
    end
  end

  defmodule Store do
    @moduledoc false

    use GenServer

    alias Arbor.Scheduler.CapsFile
    alias Arbor.Scheduler.RunLease.StateOwner

    @default_retry_base_ms 25
    @default_retry_max_ms 1_000
    @default_max_attempts 5
    @default_reconcile_base_ms 5_000
    @default_reconcile_max_ms 60_000
    @default_max_lease_ttl_ms :timer.hours(24)
    @max_cleanup_attempts 100
    @max_cleanup_delay_ms :timer.hours(1)
    @test_env Mix.env() == :test
    @orchestrator_execute_uri "arbor://orchestrator/execute"
    @creation_opt_keys [
      :ttl_ms,
      :security_facade,
      :trust_facade,
      :cleanup_max_attempts,
      :cleanup_retry_base_ms,
      :cleanup_retry_max_ms,
      :cleanup_reconcile_base_ms,
      :cleanup_reconcile_max_ms
    ]

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    def create(id, owner, attestation, opts),
      do: call({:create, id, owner, attestation, opts})

    def admit_worker(id, admission), do: call({:admit_worker, id, admission})
    def fetch_for_lease(id), do: call({:fetch, id})
    def exists?(id), do: call({:exists, id})

    def register_identity(id, identity, security),
      do: call({:register_identity, id, identity, security}, 30_000)

    def grant_capability(id, opts, security),
      do: call({:grant_capability, id, opts, security}, 30_000)

    def revoke_capability(id, capability_id),
      do: call({:revoke_capability, id, capability_id}, 30_000)

    def deregister_identity(id, agent_id),
      do: call({:deregister_identity, id, agent_id}, 30_000)

    def open_authority(id, identity, security),
      do: call({:open_authority, id, identity, security}, 30_000)

    def bind_routine(id, binding), do: call({:bind_routine, id, binding})

    def routine_requirement(principal),
      do: GenServer.call(__MODULE__, {:routine_requirement, principal})

    def begin_cleanup(id), do: call({:begin_cleanup, id})
    def cleanup_snapshot(id), do: call({:snapshot, id})

    def operation_succeeded(id, operation),
      do: call({:operation_succeeded, id, operation})

    def finish_attempt(id, generation, failures),
      do: call({:finish_attempt, id, generation, failures})

    def active_agent_ids, do: GenServer.call(__MODULE__, :active_agent_ids)
    def all_ids, do: call(:all_ids)
    def begin_recovery, do: call(:begin_recovery)
    def recovery_snapshot, do: call(:recovery_snapshot, 30_000)
    def complete_recovery, do: call(:complete_recovery)
    def discard(id), do: call({:discard, id})

    def discard_unstarted(id, creation_token),
      do: call({:discard_unstarted, id, creation_token})

    @impl true
    def init(:ok) do
      Process.flag(:sensitive, true)

      {:ok,
       %{
         table: Arbor.Scheduler.RunLease.StateOwner,
         ready: false,
         authenticated_calls: Arbor.Common.new_authenticated_call_custody()
       }}
    end

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{journal: :external})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    @impl true
    def handle_call({:routine_requirement, _principal}, _from, %{ready: false} = state),
      do: {:reply, {:error, :recovery_in_progress}, state}

    def handle_call({:routine_requirement, principal}, _from, state) do
      result =
        case StateOwner.all_leases() do
          {:ok, leases} ->
            {:ok,
             Enum.any?(leases, fn lease ->
               lease.agent_id == principal and live_active_lease?(lease) and
                 is_map(Map.get(lease, :routine_binding))
             end)}

          _ ->
            {:error, :routine_lease_unavailable}
        end

      {:reply, result, state}
    end

    def handle_call(:active_agent_ids, _from, %{ready: false} = state),
      do: {:reply, {:error, :recovery_in_progress}, state}

    def handle_call(:active_agent_ids, _from, state) do
      # Deliberately public to local callers: this is a principal-only
      # reconciliation view and never returns lease or bearer state.
      ids =
        case StateOwner.all_leases() do
          {:ok, leases} ->
            leases
            |> Enum.filter(&live_active_lease?/1)
            |> Enum.map(& &1.agent_id)
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()

          _error ->
            {:error, :run_lease_store_unavailable}
        end

      {:reply, ids, state}
    end

    # All other lease requests either disclose protected journal state or
    # mutate security-owned state and permanently reject legacy raw calls.
    def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

    @impl true
    def handle_cast(_request, state), do: {:noreply, state}

    @impl true
    def handle_info({:lease_expired, id, creation_token}, state) do
      expire_lease(id, creation_token)
      {:noreply, state}
    end

    def handle_info(message, state) do
      case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
        {:authenticated, caller, request, reply_to} ->
          {reply, state} = dispatch_authenticated(request, caller, state)
          :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
          {:noreply, state}

        result when result in [:pending, :expired, :rejected, :unrecognized] ->
          {:noreply, state}
      end
    end

    defp handle_authenticated_call(:begin_recovery, caller, state) do
      if caller == supervised_reconciler_pid() do
        {:reply, :ok, %{state | ready: false}}
      else
        {:reply, {:error, :lease_worker_not_admitted}, state}
      end
    end

    defp handle_authenticated_call(:recovery_snapshot, caller, state) do
      if caller == supervised_reconciler_pid() do
        {:reply, StateOwner.recovery_snapshot(), state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(:complete_recovery, caller, state) do
      if caller == supervised_reconciler_pid() do
        case StateOwner.complete_recovery() do
          :ok -> {:reply, :ok, %{state | ready: true}}
          {:error, _reason} = error -> {:reply, error, state}
        end
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(_request, _caller, %{ready: false} = state) do
      {:reply, {:error, :recovery_in_progress}, state}
    end

    defp handle_authenticated_call(
           {:create, id, owner, attestation, opts},
           caller,
           %{table: table} = state
         ) do
      with true <- caller == owner,
           :ok <- CapsFile.verify_attestation(attestation),
           {:ok, opts} <- validate_creation_opts(opts) do
        create_lease(table, id, owner, attestation, opts, state)
      else
        false -> {:reply, {:error, :unauthorized}, state}
        {:error, reason} -> {:reply, {:error, {:lease_admission_denied, reason}}, state}
        _other -> {:reply, {:error, :verified_attestation_required}, state}
      end
    end

    defp handle_authenticated_call(
           {:admit_worker, id, admission},
           caller,
           %{table: table} = state
         ) do
      if lease_process?(caller, id) do
        case admit_worker_lease(table, id, caller, admission) do
          {:ok, lease} -> {:reply, {:ok, lease}, state}
          {:cleanup, lease} -> {:reply, {:cleanup, lease}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      else
        {:reply, {:error, :lease_worker_not_admitted}, state}
      end
    end

    defp handle_authenticated_call(
           {:bind_routine, id, binding},
           caller,
           %{table: table} = state
         ) do
      result =
        with {:ok, lease} <- active_worker_lease(table, id, caller),
             nil <- Map.get(lease, :routine_binding),
             true <- is_map(binding) and binding.execution_principal == lease.agent_id do
          put(table, id, Map.put(lease, :routine_binding, binding))
          :ok
        else
          _ -> {:error, :routine_lease_binding_denied}
        end

      {:reply, result, state}
    end

    defp handle_authenticated_call({:fetch, id}, caller, %{table: table} = state) do
      if lease_process?(caller, id) do
        case lookup(table, id) do
          {:ok, lease} -> {:reply, {:ok, lease}, state}
          _error -> {:reply, {:error, :not_found}, state}
        end
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call({:exists, id}, caller, %{table: table} = state) do
      reply =
        case lookup(table, id) do
          {:ok, %{owner: ^caller}} ->
            true

          {:ok, _lease} ->
            if lease_process?(caller, id), do: true, else: {:error, :unauthorized}

          _error ->
            false
        end

      {:reply, reply, state}
    end

    defp handle_authenticated_call(
           {:register_identity, id, identity, security},
           caller,
           %{table: table} = state
         ) do
      with {:ok, lease} <- active_worker_lease(table, id, caller),
           :ok <- admit_identity_registration(lease, identity, security),
           :ok <- StateOwner.register_identity(id, identity, security) do
        {:reply, :ok, state}
      else
        {:error, :lease_closing} -> {:reply, {:error, :lease_closing}, state}
        {:error, reason} -> {:reply, {:error, {:identity_registration_failed, reason}}, state}
      end
    end

    defp handle_authenticated_call(
           {:grant_capability, id, opts, security},
           caller,
           %{table: table} = state
         ) do
      with {:ok, lease} <- active_worker_lease(table, id, caller),
           {:ok, grant_admission} <- admit_capability_grant(lease, opts, security),
           {:ok, cap} <- StateOwner.grant_capability(id, grant_admission) do
        {:reply, {:ok, cap}, state}
      else
        {:error, :lease_closing} ->
          {:reply, {:error, :lease_closing}, state}

        {:error, reason} ->
          resource = if is_list(opts) and Keyword.keyword?(opts), do: Keyword.get(opts, :resource)
          {:reply, {:error, {:grant_failed, resource, reason}}, state}
      end
    end

    defp handle_authenticated_call(
           {:open_authority, id, identity, security},
           caller,
           %{table: table} = state
         ) do
      with {:ok, lease} <- active_worker_lease(table, id, caller),
           :ok <- admit_authority_open(lease, identity, security),
           {:ok, authority} <- StateOwner.open_authority(id, identity, security) do
        {:reply, {:ok, authority}, state}
      else
        {:error, :lease_closing} -> {:reply, {:error, :lease_closing}, state}
        {:error, reason} -> {:reply, {:error, {:authority_open_failed, reason}}, state}
      end
    end

    defp handle_authenticated_call(
           {:revoke_capability, id, capability_id},
           caller,
           %{table: table} = state
         ) do
      with true <- lease_process?(caller, id),
           {:ok, %{cap_ids: cap_ids}} <- lookup(table, id),
           true <- capability_id in cap_ids do
        {:reply, StateOwner.revoke_capability(id, capability_id), state}
      else
        _ -> {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(
           {:deregister_identity, id, agent_id},
           caller,
           %{table: table} = state
         ) do
      with true <- lease_process?(caller, id),
           {:ok, %{agent_id: ^agent_id}} <- lookup(table, id) do
        {:reply, StateOwner.deregister_identity(id, agent_id), state}
      else
        _ -> {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call({:begin_cleanup, id}, caller, %{table: table} = state) do
      if lease_process?(caller, id) do
        update(table, id, fn lease -> %{lease | status: :cleaning} end)
        {:reply, :ok, state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call({:snapshot, id}, caller, %{table: table} = state) do
      if lease_process?(caller, id) do
        case lookup(table, id) do
          {:ok, lease} -> {:reply, {:ok, lease}, state}
          _error -> {:reply, {:error, :not_found}, state}
        end
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(
           {:operation_succeeded, id, operation},
           caller,
           %{table: table} = state
         ) do
      if lease_process?(caller, id) do
        update(table, id, &clear_operation(&1, operation))
        {:reply, :ok, state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(
           {:finish_attempt, id, generation, failures},
           caller,
           %{table: table} = state
         ) do
      if lease_process?(caller, id) do
        finish_attempt(table, id, generation, failures, state)
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(:all_ids, caller, state) do
      if caller == supervised_reconciler_pid() do
        {:reply, StateOwner.all_ids(), state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call({:discard, id}, caller, state) do
      if lease_process?(caller, id) do
        case StateOwner.delete(id) do
          :ok -> {:reply, :ok, state}
          {:error, _reason} = error -> {:reply, error, state}
        end
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(
           {:discard_unstarted, id, creation_token},
           caller,
           %{table: table} = state
         ) do
      case lookup(table, id) do
        {:ok,
         %{
           owner: ^caller,
           creation_token: ^creation_token,
           agent_id: nil,
           cap_ids: [],
           authority: nil
         }} ->
          case StateOwner.delete(id) do
            :ok -> {:reply, :ok, state}
            {:error, _reason} = error -> {:reply, error, state}
          end

        _other ->
          {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_authenticated_call(_request, _caller, state),
      do: {:reply, {:error, :unauthorized}, state}

    defp validate_creation_opts(opts) when is_list(opts) do
      keys = Keyword.keys(opts)
      ttl_ms = Keyword.get(opts, :ttl_ms)
      max_ttl_ms = configured_max_lease_ttl_ms()
      retry_base_ms = Keyword.get(opts, :cleanup_retry_base_ms, @default_retry_base_ms)
      retry_max_ms = Keyword.get(opts, :cleanup_retry_max_ms, @default_retry_max_ms)

      reconcile_base_ms =
        Keyword.get(opts, :cleanup_reconcile_base_ms, @default_reconcile_base_ms)

      reconcile_max_ms = Keyword.get(opts, :cleanup_reconcile_max_ms, @default_reconcile_max_ms)

      numeric_opts = [
        Keyword.get(opts, :cleanup_max_attempts, @default_max_attempts),
        retry_base_ms,
        retry_max_ms,
        reconcile_base_ms,
        reconcile_max_ms
      ]

      if Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
           Enum.all?(keys, &(&1 in @creation_opt_keys)) and
           is_integer(ttl_ms) and ttl_ms > 0 and ttl_ms <= max_ttl_ms and
           is_atom(Keyword.get(opts, :security_facade)) and
           is_atom(Keyword.get(opts, :trust_facade)) and
           production_facades?(opts) and cleanup_overrides_allowed?(keys) and
           Enum.all?(numeric_opts, &(is_integer(&1) and &1 > 0)) and
           Keyword.get(opts, :cleanup_max_attempts, @default_max_attempts) <=
             @max_cleanup_attempts and
           Enum.all?(
             [retry_base_ms, retry_max_ms, reconcile_base_ms, reconcile_max_ms],
             &(&1 <= @max_cleanup_delay_ms)
           ) and retry_base_ms <= retry_max_ms and reconcile_base_ms <= reconcile_max_ms do
        {:ok, opts}
      else
        {:error, :invalid_lease_options}
      end
    rescue
      _exception -> {:error, :invalid_lease_options}
    end

    defp validate_creation_opts(_opts), do: {:error, :invalid_lease_options}

    defp configured_max_lease_ttl_ms do
      case Application.get_env(
             :arbor_scheduler,
             :run_identity_max_lease_ttl_ms,
             @default_max_lease_ttl_ms
           ) do
        value when is_integer(value) and value > 0 -> value
        _invalid -> @default_max_lease_ttl_ms
      end
    end

    if @test_env do
      defp production_facades?(_opts), do: true
      defp cleanup_overrides_allowed?(_keys), do: true
    else
      @cleanup_opt_keys @creation_opt_keys -- [:ttl_ms, :security_facade, :trust_facade]

      defp production_facades?(opts) do
        Keyword.get(opts, :security_facade) == Arbor.Security and
          Keyword.get(opts, :trust_facade) == Arbor.Trust
      end

      defp cleanup_overrides_allowed?(keys) do
        Enum.all?(keys, &(&1 not in @cleanup_opt_keys))
      end
    end

    defp admit_identity_registration(
           %{agent_id: nil, security: security},
           %Arbor.Contracts.Security.Identity{agent_id: agent_id, private_key: private_key},
           security
         )
         when is_binary(agent_id) and is_binary(private_key),
         do: :ok

    defp admit_identity_registration(%{agent_id: agent_id}, _identity, _security)
         when is_binary(agent_id),
         do: {:error, :lease_identity_already_bound}

    defp admit_identity_registration(_lease, _identity, _security),
      do: {:error, :lease_identity_binding_denied}

    defp admit_capability_grant(lease, opts, security)
         when is_list(opts) and security == lease.security and is_binary(lease.agent_id) do
      keys = Keyword.keys(opts)
      allowed_keys = [:principal, :resource, :constraints]
      principal = Keyword.get(opts, :principal)
      resource = Keyword.get(opts, :resource)
      constraints = Keyword.get(opts, :constraints, %{})

      with true <- Keyword.keyword?(opts),
           true <- length(keys) == length(Enum.uniq(keys)),
           true <- Enum.all?(keys, &(&1 in allowed_keys)),
           true <- principal == lease.agent_id,
           true <- is_binary(resource),
           true <- is_map(constraints) and not is_struct(constraints),
           :ok <- CapsFile.verify_attestation(lease.attestation),
           true <- attestation_digest(lease.attestation) == lease.attestation_digest do
        admit_signed_descriptor(lease, resource, constraints)
      else
        _other -> {:error, :lease_capability_binding_denied}
      end
    rescue
      _exception -> {:error, :lease_capability_binding_denied}
    end

    defp admit_capability_grant(_lease, _opts, _security),
      do: {:error, :lease_capability_binding_denied}

    defp admit_signed_descriptor(
           %{lobby_granted: false},
           @orchestrator_execute_uri,
           constraints
         )
         when constraints == %{} do
      {:ok, :lobby}
    end

    defp admit_signed_descriptor(lease, resource, constraints) do
      case Enum.find_index(lease.remaining_capabilities, fn descriptor ->
             descriptor.resource_uri == resource and descriptor.constraints == constraints
           end) do
        index when is_integer(index) ->
          {:ok, {:attested, index, Enum.at(lease.remaining_capabilities, index)}}

        _other ->
          {:error, :unsigned_capability_descriptor}
      end
    end

    defp attestation_metadata(attestation) do
      %{
        provenance: %{
          source: :caps_file,
          manifest_version: attestation.version,
          issuer_id: attestation.issuer_id,
          pipeline_root: attestation.pipeline_root,
          pipeline_path: attestation.pipeline_path,
          graph_hash: attestation.graph_hash
        }
      }
    end

    defp attestation_digest(attestation) do
      :crypto.hash(:sha256, CapsFile.signing_payload(attestation))
    end

    defp admit_authority_open(
           %{agent_id: agent_id, authority: nil, security: security},
           %Arbor.Contracts.Security.Identity{agent_id: agent_id, private_key: private_key},
           security
         )
         when is_binary(agent_id) and is_binary(private_key),
         do: :ok

    defp admit_authority_open(%{authority: authority}, _identity, _security)
         when not is_nil(authority),
         do: {:error, :lease_authority_already_open}

    defp admit_authority_open(_lease, _identity, _security),
      do: {:error, :lease_authority_binding_denied}

    defp create_lease(table, id, owner, attestation, opts, state) do
      if lookup(table, id) != :error do
        {:reply, {:error, :already_present}, state}
      else
        now = System.monotonic_time(:millisecond)
        ttl_ms = Keyword.fetch!(opts, :ttl_ms)
        creation_token = make_ref()

        lease = %{
          id: id,
          owner: owner,
          creation_token: creation_token,
          worker_pid: nil,
          expires_at: now + ttl_ms,
          capability_expires_at: DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond),
          security: Keyword.fetch!(opts, :security_facade),
          trust: Keyword.fetch!(opts, :trust_facade),
          attestation: attestation,
          attestation_digest: attestation_digest(attestation),
          grant_metadata: attestation_metadata(attestation),
          remaining_capabilities: attestation.capabilities,
          lobby_granted: false,
          agent_id: nil,
          trust_pending: false,
          identity_pending: false,
          cap_ids: [],
          authority: nil,
          generation: 0,
          status: :pending,
          attempts: 0,
          max_attempts: Keyword.get(opts, :cleanup_max_attempts, @default_max_attempts),
          retry_base_ms: Keyword.get(opts, :cleanup_retry_base_ms, @default_retry_base_ms),
          retry_max_ms: Keyword.get(opts, :cleanup_retry_max_ms, @default_retry_max_ms),
          reconcile_base_ms:
            Keyword.get(opts, :cleanup_reconcile_base_ms, @default_reconcile_base_ms),
          reconcile_max_ms:
            Keyword.get(opts, :cleanup_reconcile_max_ms, @default_reconcile_max_ms),
          failures: []
        }

        put(table, id, lease)
        Process.send_after(self(), {:lease_expired, id, creation_token}, ttl_ms)
        {:reply, {:ok, creation_token}, state}
      end
    end

    defp admit_worker_lease(table, id, caller, admission) do
      now = System.monotonic_time(:millisecond)

      case lookup(table, id) do
        {:ok, %{creation_token: token, status: :pending} = lease}
        when admission == {:activate, token} ->
          if Process.alive?(lease.owner) and now < lease.expires_at do
            updated = %{lease | status: :active, worker_pid: caller}
            :ok = put(table, id, updated)
            {:ok, updated}
          else
            updated = %{lease | status: :cleaning, worker_pid: caller}
            :ok = put(table, id, updated)
            {:cleanup, updated}
          end

        {:ok, %{creation_token: token, status: :active} = lease}
        when admission == :recover or admission == {:activate, token} ->
          if Process.alive?(lease.owner) and now < lease.expires_at do
            updated = %{lease | worker_pid: caller}
            :ok = put(table, id, updated)
            {:ok, updated}
          else
            updated = %{lease | status: :cleaning, worker_pid: caller}
            :ok = put(table, id, updated)
            {:cleanup, updated}
          end

        {:ok, %{creation_token: token, status: :cleaning} = lease}
        when admission == :recover or admission == {:activate, token} ->
          updated = %{lease | worker_pid: caller}
          :ok = put(table, id, updated)
          {:cleanup, updated}

        {:ok, %{status: :pending} = lease} when admission == :recover ->
          updated = %{lease | status: :cleaning, worker_pid: caller}
          :ok = put(table, id, updated)
          {:cleanup, updated}

        {:ok, _lease} ->
          {:error, :unauthorized}

        :error ->
          {:error, :not_found}
      end
    end

    defp expire_lease(id, creation_token) do
      case lookup(Arbor.Scheduler.RunLease.StateOwner, id) do
        {:ok, %{creation_token: ^creation_token, status: :pending}} ->
          StateOwner.delete(id)

        {:ok, %{creation_token: ^creation_token} = lease} ->
          :ok = put(Arbor.Scheduler.RunLease.StateOwner, id, %{lease | status: :cleaning})
          ensure_cleanup_worker(id)

        _other ->
          :ok
      end
    end

    defp ensure_cleanup_worker(id) do
      case lease_process_pid(id) do
        {:ok, _pid} ->
          :ok

        {:error, _reason} ->
          case DynamicSupervisor.start_child(
                 Arbor.Scheduler.RunLease.DynamicSupervisor,
                 {Arbor.Scheduler.RunLease, id}
               ) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, _reason} -> :ok
          end
      end
    rescue
      _exception -> :ok
    catch
      :exit, _reason -> :ok
    end

    defp dispatch_authenticated(request, caller, state) do
      case handle_authenticated_call(request, caller, state) do
        {:reply, reply, state} -> {reply, state}
      end
    end

    defp finish_attempt(table, id, generation, failures, state) do
      case lookup(table, id) do
        {:ok, %{generation: current_generation} = lease}
        when current_generation != generation ->
          updated = %{lease | attempts: 0, failures: failures}
          put(table, id, updated)
          {:reply, {:retry, 0}, state}

        {:ok, _lease} when failures == [] ->
          {:reply, :complete, state}

        {:ok, lease} ->
          attempts = lease.attempts + 1
          updated = %{lease | attempts: attempts, failures: failures, status: :cleaning}
          put(table, id, updated)

          if attempts >= lease.max_attempts do
            reconciliation_attempt = attempts - lease.max_attempts

            delay =
              bounded_backoff(
                lease.reconcile_base_ms,
                lease.reconcile_max_ms,
                reconciliation_attempt
              )

            {:reply, {:reconcile, Enum.reverse(failures), delay}, state}
          else
            delay = bounded_backoff(lease.retry_base_ms, lease.retry_max_ms, attempts - 1)
            {:reply, {:retry, delay}, state}
          end

        :error ->
          {:reply, :complete, state}
      end
    end

    defp active_worker_lease(table, id, worker) do
      case lookup(table, id) do
        {:ok, %{status: :active, worker_pid: ^worker} = lease} ->
          if lease_process?(worker, id) and Process.alive?(lease.owner) and
               System.monotonic_time(:millisecond) < lease.expires_at do
            {:ok, lease}
          else
            :ok = put(table, id, %{lease | status: :cleaning})
            {:error, :lease_closing}
          end

        {:ok, _lease} ->
          {:error, :lease_closing}

        :error ->
          {:error, :lease_closing}
      end
    end

    defp lease_process_pid(id) do
      case Registry.lookup(Arbor.Scheduler.RunLease.Registry, id) do
        [{pid, _value}] when is_pid(pid) ->
          if lease_process?(pid, id), do: {:ok, pid}, else: {:error, :lease_not_found}

        _other ->
          {:error, :lease_not_found}
      end
    rescue
      _exception -> {:error, :lease_not_found}
    catch
      :exit, _reason -> {:error, :lease_not_found}
    end

    defp live_active_lease?(%{
           id: id,
           status: :active,
           owner: owner,
           worker_pid: worker_pid,
           expires_at: expires_at
         }) do
      is_pid(owner) and Process.alive?(owner) and is_pid(worker_pid) and
        System.monotonic_time(:millisecond) < expires_at and lease_process?(worker_pid, id)
    end

    defp live_active_lease?(_lease), do: false

    defp lease_process?(caller, id) when is_pid(caller) and is_binary(id) do
      with [{^caller, _value}] <- Registry.lookup(Arbor.Scheduler.RunLease.Registry, id),
           {:ok, supervisor} <- supervised_dynamic_supervisor_pid(),
           true <-
             Enum.any?(DynamicSupervisor.which_children(supervisor), fn
               {_child_id, ^caller, :worker, modules} when is_list(modules) ->
                 Arbor.Scheduler.RunLease in modules

               _child ->
                 false
             end) do
        true
      else
        _other -> false
      end
    rescue
      _exception -> false
    catch
      :exit, _reason -> false
    end

    defp lease_process?(_caller, _id), do: false

    defp supervised_dynamic_supervisor_pid do
      Arbor.Common.supervised_registered_child_pid(
        :arbor_scheduler,
        [
          Arbor.Scheduler.RuntimeSupervisor,
          Arbor.Scheduler.RunLeaseSupervisor,
          Arbor.Scheduler.RunLease.DynamicSupervisor
        ],
        Arbor.Scheduler.RunLease.DynamicSupervisor
      )
    end

    defp supervised_reconciler_pid do
      case Arbor.Common.supervised_registered_child_pid(
             :arbor_scheduler,
             [
               Arbor.Scheduler.RuntimeSupervisor,
               Arbor.Scheduler.RunLeaseSupervisor,
               Arbor.Scheduler.RunLease.Reconciler
             ],
             Arbor.Scheduler.RunLease.Reconciler
           ) do
        {:ok, pid} -> pid
        _error -> nil
      end
    end

    defp call(request, timeout \\ 5_000) do
      with {:ok, pid} <-
             Arbor.Common.supervised_registered_child_pid(
               :arbor_scheduler,
               [
                 Arbor.Scheduler.RuntimeSupervisor,
                 Arbor.Scheduler.RunLeaseSupervisor,
                 __MODULE__
               ],
               __MODULE__
             ) do
        Arbor.Common.authenticated_call(pid, request, timeout)
      else
        _error -> {:error, :run_lease_store_unavailable}
      end
    rescue
      _exception -> {:error, :run_lease_store_unavailable}
    catch
      :exit, _reason -> {:error, :run_lease_store_unavailable}
    end

    defp bounded_backoff(base, maximum, exponent) do
      shifts = min(exponent, 30)
      min(base * Integer.pow(2, shifts), maximum)
    end

    defp lookup(_table, id), do: Arbor.Scheduler.RunLease.StateOwner.fetch(id)

    defp put(_table, id, lease), do: Arbor.Scheduler.RunLease.StateOwner.put(id, lease)

    defp update(table, id, fun) do
      case lookup(table, id) do
        {:ok, lease} -> put(table, id, fun.(lease))
        :error -> :ok
      end
    end

    defp clear_operation(nil, _operation), do: nil
    defp clear_operation(lease, :authority), do: %{lease | authority: nil}

    defp clear_operation(lease, {:capability, cap_id}) do
      %{lease | cap_ids: List.delete(lease.cap_ids, cap_id)}
    end

    defp clear_operation(lease, :trust_profile), do: %{lease | trust_pending: false}
    defp clear_operation(lease, :identity), do: %{lease | identity_pending: false}
  end
end
