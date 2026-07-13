defmodule Arbor.Scheduler.RunLease do
  @moduledoc false

  use GenServer, restart: :transient

  require Logger

  alias __MODULE__.Store

  @call_timeout 30_000

  @type id :: String.t()

  def child_spec(lease_id) do
    %{
      id: {__MODULE__, lease_id},
      start: {__MODULE__, :start_link, [lease_id]},
      restart: :transient
    }
  end

  def start(owner, opts) when is_pid(owner) do
    lease_id = "lease_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    case Store.create(lease_id, owner, opts) do
      {:ok, creation_token} ->
        case DynamicSupervisor.start_child(__MODULE__.DynamicSupervisor, {__MODULE__, lease_id}) do
          {:ok, _pid} ->
            {:ok, lease_id}

          {:error, reason} = error ->
            Store.discard_unstarted(lease_id, creation_token)
            if reason == :already_present, do: {:error, :lease_id_collision}, else: error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def start_link(lease_id) when is_binary(lease_id) do
    GenServer.start_link(__MODULE__, lease_id, name: via(lease_id))
  end

  def record_identity(lease_id, agent_id), do: record(lease_id, {:identity, agent_id})
  def record_capability(lease_id, cap_id), do: record(lease_id, {:capability, cap_id})
  def record_authority(lease_id, authority), do: record(lease_id, {:authority, authority})

  def register_identity(lease_id, identity, security),
    do: Store.register_identity(lease_id, identity, security)

  def grant_capability(lease_id, opts, security),
    do: Store.grant_capability(lease_id, opts, security)

  def open_authority(lease_id, identity, security),
    do: Store.open_authority(lease_id, identity, security)

  def revoke(nil), do: :ok
  def revoke(lease_id), do: call(lease_id, :revoke)

  def active_agent_ids do
    Store.active_agent_ids()
  end

  @doc false
  def whereis(lease_id) do
    case Registry.lookup(__MODULE__.Registry, lease_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(lease_id) do
    case Store.fetch_for_lease(lease_id) do
      {:ok, lease} ->
        state = %{
          lease_id: lease_id,
          owner_ref: Process.monitor(lease.owner),
          expiry_ref: schedule_expiry(lease.expires_at),
          waiters: []
        }

        if Process.alive?(lease.owner),
          do: {:ok, state},
          else: {:ok, state, {:continue, :cleanup}}

      {:error, :not_found} ->
        :ignore
    end
  end

  @impl true
  def handle_continue(:cleanup, state), do: begin_cleanup(state)

  @impl true
  def handle_call(:revoke, from, state) do
    begin_cleanup(%{state | waiters: [from | state.waiters]})
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    begin_cleanup(state)
  end

  def handle_info(:expire, state) do
    Logger.warning("[RunLease] per-run identity lease expired; revoking run authority")
    begin_cleanup(state)
  end

  def handle_info(:cleanup, state), do: run_cleanup(state)

  defp begin_cleanup(state) do
    :ok = Store.begin_cleanup(state.lease_id)
    send(self(), :cleanup)
    {:noreply, state}
  end

  defp run_cleanup(state) do
    case Store.cleanup_snapshot(state.lease_id) do
      {:ok, snapshot} ->
        failures = cleanup(snapshot)

        case Store.finish_attempt(state.lease_id, snapshot.generation, failures) do
          :complete ->
            reply_waiters(state.waiters, :ok)
            Store.discard(state.lease_id)
            {:stop, :normal, %{state | waiters: []}}

          {:retry, delay_ms} ->
            Process.send_after(self(), :cleanup, delay_ms)
            {:noreply, state}

          {:reconcile, terminal_failures, delay_ms} ->
            error = {:error, {:cleanup_failed, terminal_failures}}

            Logger.error(
              "[RunLease] cleanup threshold reached; reconciliation remains active: #{inspect(terminal_failures)}"
            )

            reply_waiters(state.waiters, error)
            Process.send_after(self(), :cleanup, delay_ms)
            {:noreply, %{state | waiters: []}}
        end

      {:error, :not_found} ->
        reply_waiters(state.waiters, :ok)
        {:stop, :normal, %{state | waiters: []}}
    end
  end

  defp cleanup(snapshot) do
    []
    |> cleanup_authority(snapshot)
    |> cleanup_caps(snapshot)
    |> cleanup_trust(snapshot)
    |> cleanup_identity(snapshot)
  end

  defp cleanup_authority(failures, %{authority: nil}), do: failures

  defp cleanup_authority(failures, snapshot) do
    run_operation(failures, :authority, fn ->
      snapshot.security.close_signing_authority(snapshot.authority)
    end)
  end

  defp cleanup_caps(failures, snapshot) do
    Enum.reduce(snapshot.cap_ids, failures, fn cap_id, acc ->
      run_operation(acc, {:capability, cap_id}, fn -> snapshot.security.revoke(cap_id) end)
    end)
  end

  defp cleanup_trust(failures, %{agent_id: nil}), do: failures
  defp cleanup_trust(failures, %{trust_pending: false}), do: failures

  defp cleanup_trust(failures, snapshot) do
    run_operation(failures, :trust_profile, fn ->
      snapshot.trust.delete_trust_profile(snapshot.agent_id)
    end)
  end

  defp cleanup_identity(failures, %{agent_id: nil}), do: failures
  defp cleanup_identity(failures, %{identity_pending: false}), do: failures

  defp cleanup_identity(failures, snapshot) do
    run_operation(failures, :identity, fn ->
      snapshot.security.deregister_identity(snapshot.agent_id)
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

  defp record(lease_id, operation) when is_binary(lease_id) do
    case Store.record(lease_id, operation) do
      :ok ->
        :ok

      {:cleanup_started, pid} ->
        if is_pid(pid), do: send(pid, :cleanup)
        {:error, :lease_closing}

      {:error, _reason} = error ->
        error
    end
  end

  defp call(lease_id, message) when is_binary(lease_id), do: do_call(lease_id, message, 2)

  defp do_call(lease_id, message, attempts) do
    with :ok <- ensure_lease_process(lease_id),
         {:ok, pid} <- await_pid(lease_id, 50) do
      GenServer.call(pid, message, @call_timeout)
    else
      {:error, :lease_not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> recover_call(lease_id, message, attempts, reason)
  end

  defp recover_call(_lease_id, _message, 0, reason),
    do: {:error, {:lease_unavailable, reason}}

  defp recover_call(lease_id, message, attempts, reason) do
    case Store.exists?(lease_id) do
      false ->
        :ok

      true ->
        Process.sleep(10)
        do_call(lease_id, message, attempts - 1)

      {:error, store_reason} ->
        {:error, {:lease_unavailable, {reason, store_reason}}}
    end
  end

  defp ensure_lease_process(lease_id) do
    case whereis(lease_id) do
      pid when is_pid(pid) ->
        :ok

      nil ->
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
    case whereis(lease_id) do
      nil ->
        Process.sleep(10)
        await_pid(lease_id, attempts - 1)

      pid ->
        {:ok, pid}
    end
  end

  defp schedule_expiry(expires_at) do
    delay = max(expires_at - System.monotonic_time(:millisecond), 0)
    Process.send_after(self(), :expire, delay)
  end

  defp reply_waiters(waiters, result), do: Enum.each(waiters, &GenServer.reply(&1, result))

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
    def fetch(id), do: GenServer.call(__MODULE__, {:fetch, id})
    def put(id, lease), do: GenServer.call(__MODULE__, {:put, id, lease})
    def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
    def all_ids, do: GenServer.call(__MODULE__, :all_ids)
    def all_leases, do: GenServer.call(__MODULE__, :all_leases)

    @impl true
    def init(:ok) do
      :ets.new(@table, [:named_table, :private, :set])
      {:ok, %{table: @table}}
    end

    @impl true
    def handle_call(request, from, state) do
      if state_owner_caller?(from) do
        handle_state_owner_call(request, state)
      else
        {:reply, {:error, :unauthorized}, state}
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

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{journal: :owned})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    defp state_owner_caller?({pid, _tag}),
      do: pid == Process.whereis(Arbor.Scheduler.RunLease.StateOwner)
  end

  defmodule StateOwner do
    @moduledoc false

    use GenServer

    alias Arbor.Scheduler.RunLease.JournalOwner

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def fetch(id), do: GenServer.call(__MODULE__, {:fetch, id})
    def put(id, lease), do: GenServer.call(__MODULE__, {:put, id, lease})
    def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
    def all_ids, do: GenServer.call(__MODULE__, :all_ids)
    def all_leases, do: GenServer.call(__MODULE__, :all_leases)

    def register_identity(lease_id, identity, security),
      do: GenServer.call(__MODULE__, {:register_identity, lease_id, identity, security}, 30_000)

    def grant_capability(lease_id, opts, security),
      do: GenServer.call(__MODULE__, {:grant_capability, lease_id, opts, security}, 30_000)

    def open_authority(lease_id, identity, security),
      do: GenServer.call(__MODULE__, {:open_authority, lease_id, identity, security}, 30_000)

    @impl true
    def init(:ok), do: {:ok, %{journal: JournalOwner}}

    @impl true
    def handle_call(request, from, state) do
      if store_caller?(from) do
        handle_store_call(request, state)
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    defp handle_store_call({:fetch, id}, state), do: {:reply, JournalOwner.fetch(id), state}

    defp handle_store_call({:put, id, lease}, state) do
      {:reply, JournalOwner.put(id, lease), state}
    end

    defp handle_store_call({:delete, id}, state), do: {:reply, JournalOwner.delete(id), state}
    defp handle_store_call(:all_ids, state), do: {:reply, JournalOwner.all_ids(), state}
    defp handle_store_call(:all_leases, state), do: {:reply, JournalOwner.all_leases(), state}

    defp handle_store_call({:register_identity, lease_id, identity, security}, state) do
      result =
        mutate_active_lease(lease_id, fn lease ->
          case safe_external(fn -> security.register_identity(identity) end) do
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
        end)

      {:reply, result, state}
    end

    defp handle_store_call({:grant_capability, lease_id, opts, security}, state) do
      result =
        mutate_active_lease(lease_id, fn lease ->
          case safe_external(fn -> security.grant(opts) end) do
            {:ok, cap} ->
              updated = lease |> put_operation({:capability, cap.id}) |> bump_generation()
              :ok = JournalOwner.put(lease_id, updated)
              {:ok, cap}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      {:reply, result, state}
    end

    defp handle_store_call({:open_authority, lease_id, identity, security}, state) do
      result =
        mutate_active_lease(lease_id, fn lease ->
          with {:ok, proof} <-
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
            :ok = JournalOwner.put(lease_id, updated)
            {:ok, authority}
          end
        end)

      {:reply, result, state}
    end

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{journal: :external})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    defp store_caller?({pid, _tag}), do: pid == Process.whereis(Arbor.Scheduler.RunLease.Store)

    defp mutate_active_lease(lease_id, fun) do
      case JournalOwner.fetch(lease_id) do
        {:ok, %{status: :active} = lease} -> fun.(lease)
        {:ok, _lease} -> {:error, :lease_closing}
        :error -> {:error, :lease_closing}
      end
    end

    defp put_operation(lease, {:identity, agent_id}) do
      %{lease | agent_id: agent_id, trust_pending: true, identity_pending: true}
    end

    defp put_operation(lease, {:capability, cap_id}) do
      %{lease | cap_ids: Enum.uniq([cap_id | lease.cap_ids])}
    end

    defp bump_generation(lease), do: Map.update!(lease, :generation, &(&1 + 1))

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

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      case Arbor.Scheduler.RunLease.Store.all_ids() do
        {:ok, lease_ids} ->
          case restart_leases(lease_ids) do
            :ok -> {:ok, %{lease_count: length(lease_ids)}}
            {:error, reason} -> {:stop, {:lease_reconciliation_failed, reason}}
          end

        {:error, reason} ->
          {:stop, {:lease_journal_unavailable, reason}}
      end
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

    @default_retry_base_ms 25
    @default_retry_max_ms 1_000
    @default_max_attempts 5
    @default_reconcile_base_ms 5_000
    @default_reconcile_max_ms 60_000

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    def create(id, owner, opts), do: GenServer.call(__MODULE__, {:create, id, owner, opts})
    def fetch_for_lease(id), do: GenServer.call(__MODULE__, {:fetch, id})
    def exists?(id), do: GenServer.call(__MODULE__, {:exists, id})
    def record(id, operation), do: GenServer.call(__MODULE__, {:record, id, operation})

    def register_identity(id, identity, security),
      do: GenServer.call(__MODULE__, {:register_identity, id, identity, security}, 30_000)

    def grant_capability(id, opts, security),
      do: GenServer.call(__MODULE__, {:grant_capability, id, opts, security}, 30_000)

    def open_authority(id, identity, security),
      do: GenServer.call(__MODULE__, {:open_authority, id, identity, security}, 30_000)

    def begin_cleanup(id), do: GenServer.call(__MODULE__, {:begin_cleanup, id})
    def cleanup_snapshot(id), do: GenServer.call(__MODULE__, {:snapshot, id})

    def operation_succeeded(id, operation),
      do: GenServer.call(__MODULE__, {:operation_succeeded, id, operation})

    def finish_attempt(id, generation, failures),
      do: GenServer.call(__MODULE__, {:finish_attempt, id, generation, failures})

    def active_agent_ids, do: GenServer.call(__MODULE__, :active_agent_ids)
    def all_ids, do: GenServer.call(__MODULE__, :all_ids)
    def discard(id), do: GenServer.call(__MODULE__, {:discard, id})

    def discard_unstarted(id, creation_token),
      do: GenServer.call(__MODULE__, {:discard_unstarted, id, creation_token})

    @impl true
    def init(:ok), do: {:ok, %{table: Arbor.Scheduler.RunLease.StateOwner}}

    @impl true
    def format_status(status) when is_map(status) do
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{journal: :external})
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
    end

    @impl true
    def handle_call({:create, id, owner, opts}, {caller, _tag}, %{table: table} = state) do
      if caller != owner do
        {:reply, {:error, :unauthorized}, state}
      else
        create_lease(table, id, owner, opts, state)
      end
    end

    def handle_call({:fetch, id}, {caller, _tag}, %{table: table} = state) do
      if lease_process?(caller, id) do
        case lookup(table, id) do
          {:ok, lease} -> {:reply, {:ok, lease}, state}
          :error -> {:reply, {:error, :not_found}, state}
        end
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call({:exists, id}, _from, %{table: table} = state) do
      {:reply, lookup(table, id) != :error, state}
    end

    def handle_call({:record, id, operation}, {caller, _tag}, %{table: table} = state) do
      case owner_lease(table, id, caller) do
        {:ok, lease} ->
          updated = lease |> put_operation(operation) |> Map.update!(:generation, &(&1 + 1))
          put(table, id, updated)

          if lease.status == :active do
            {:reply, :ok, state}
          else
            {:reply, {:cleanup_started, Arbor.Scheduler.RunLease.whereis(id)}, state}
          end

        {:error, _reason} ->
          {:reply, {:error, :lease_not_found}, state}
      end
    end

    def handle_call(
          {:register_identity, id, identity, security},
          {caller, _tag},
          %{table: table} = state
        ) do
      with {:ok, _lease} <- active_owner_lease(table, id, caller),
           :ok <-
             Arbor.Scheduler.RunLease.StateOwner.register_identity(id, identity, security) do
        {:reply, :ok, state}
      else
        {:error, :lease_closing} -> {:reply, {:error, :lease_closing}, state}
        {:error, reason} -> {:reply, {:error, {:identity_registration_failed, reason}}, state}
      end
    end

    def handle_call(
          {:grant_capability, id, opts, security},
          {caller, _tag},
          %{table: table} = state
        ) do
      with {:ok, _lease} <- active_owner_lease(table, id, caller),
           {:ok, cap} <-
             Arbor.Scheduler.RunLease.StateOwner.grant_capability(id, opts, security) do
        {:reply, {:ok, cap}, state}
      else
        {:error, :lease_closing} ->
          {:reply, {:error, :lease_closing}, state}

        {:error, reason} ->
          resource = Keyword.fetch!(opts, :resource)
          {:reply, {:error, {:grant_failed, resource, reason}}, state}
      end
    end

    def handle_call(
          {:open_authority, id, identity, security},
          {caller, _tag},
          %{table: table} = state
        ) do
      with {:ok, _lease} <- active_owner_lease(table, id, caller),
           {:ok, authority} <-
             Arbor.Scheduler.RunLease.StateOwner.open_authority(id, identity, security) do
        {:reply, {:ok, authority}, state}
      else
        {:error, :lease_closing} -> {:reply, {:error, :lease_closing}, state}
        {:error, reason} -> {:reply, {:error, {:authority_open_failed, reason}}, state}
      end
    end

    def handle_call({:begin_cleanup, id}, {caller, _tag}, %{table: table} = state) do
      if lease_process?(caller, id) do
        update(table, id, fn lease -> %{lease | status: :cleaning} end)
        {:reply, :ok, state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call({:snapshot, id}, {caller, _tag}, %{table: table} = state) do
      if lease_process?(caller, id) do
        case lookup(table, id) do
          {:ok, lease} -> {:reply, {:ok, lease}, state}
          :error -> {:reply, {:error, :not_found}, state}
        end
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call(
          {:operation_succeeded, id, operation},
          {caller, _tag},
          %{table: table} = state
        ) do
      if lease_process?(caller, id) do
        update(table, id, &clear_operation(&1, operation))
        {:reply, :ok, state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call(
          {:finish_attempt, id, generation, failures},
          {caller, _tag},
          %{table: table} = state
        ) do
      if lease_process?(caller, id) do
        finish_attempt(table, id, generation, failures, state)
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call(:active_agent_ids, _from, %{table: table} = state) do
      ids =
        table
        |> all_leases()
        |> Enum.filter(&(&1.status == :active and Process.alive?(&1.owner)))
        |> Enum.map(& &1.agent_id)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      {:reply, ids, state}
    end

    def handle_call(:all_ids, {caller, _tag}, state) do
      if caller == Process.whereis(Arbor.Scheduler.RunLease.Reconciler) do
        {:reply, Arbor.Scheduler.RunLease.StateOwner.all_ids(), state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call({:discard, id}, {caller, _tag}, state) do
      if lease_process?(caller, id) do
        :ok = Arbor.Scheduler.RunLease.StateOwner.delete(id)
        {:reply, :ok, state}
      else
        {:reply, {:error, :unauthorized}, state}
      end
    end

    def handle_call(
          {:discard_unstarted, id, creation_token},
          {caller, _tag},
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
          :ok = Arbor.Scheduler.RunLease.StateOwner.delete(id)
          {:reply, :ok, state}

        _other ->
          {:reply, {:error, :unauthorized}, state}
      end
    end

    defp create_lease(table, id, owner, opts, state) do
      if lookup(table, id) != :error do
        {:reply, {:error, :already_present}, state}
      else
        now = System.monotonic_time(:millisecond)
        creation_token = make_ref()

        lease = %{
          owner: owner,
          creation_token: creation_token,
          expires_at: now + Keyword.fetch!(opts, :ttl_ms),
          security: Keyword.fetch!(opts, :security_facade),
          trust: Keyword.fetch!(opts, :trust_facade),
          agent_id: nil,
          trust_pending: false,
          identity_pending: false,
          cap_ids: [],
          authority: nil,
          generation: 0,
          status: :active,
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
        {:reply, {:ok, creation_token}, state}
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

    defp put_operation(lease, {:identity, agent_id}) do
      %{lease | agent_id: agent_id, trust_pending: true, identity_pending: true}
    end

    defp put_operation(lease, {:capability, cap_id}) do
      %{lease | cap_ids: Enum.uniq([cap_id | lease.cap_ids])}
    end

    defp put_operation(lease, {:authority, authority}), do: %{lease | authority: authority}

    defp active_owner_lease(table, id, owner) do
      case owner_lease(table, id, owner) do
        {:ok, %{status: :active} = lease} -> {:ok, lease}
        {:ok, _lease} -> {:error, :lease_closing}
        {:error, _reason} -> {:error, :lease_closing}
      end
    end

    defp owner_lease(table, id, owner) do
      case lookup(table, id) do
        {:ok, %{owner: ^owner} = lease} -> {:ok, lease}
        {:ok, _lease} -> {:error, :unauthorized}
        :error -> {:error, :lease_closing}
      end
    end

    defp lease_process?(caller, id), do: caller == Arbor.Scheduler.RunLease.whereis(id)

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

    defp all_leases(_table) do
      {:ok, leases} = Arbor.Scheduler.RunLease.StateOwner.all_leases()
      leases
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
