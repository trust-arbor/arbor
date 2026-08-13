defmodule Arbor.Memory.MutationAdmission do
  @moduledoc """
  Durable per-agent Memory mutation admission authority (VP-05D2C3I1A).

  Imperative shell over `Arbor.Memory.MutationAdmissionCore`. Reaches storage
  only through public `Arbor.Persistence` after linearizable-CAS and
  `:node_restart` durability attestation. Not exported on `Arbor.Memory`.
  """

  use GenServer

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Memory.Config
  alias Arbor.Memory.MutationAdmission.DrainFence
  alias Arbor.Memory.MutationAdmission.Guardian
  alias Arbor.Memory.MutationAdmission.GuardianSupervisor
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.MutationAdmission.RuntimeIdentity
  alias Arbor.Memory.MutationAdmissionCore, as: Core
  alias Arbor.Persistence

  @name __MODULE__
  @registry Arbor.Memory.MutationAdmission.Registry
  @token_bytes 32
  @hash_hex_length 64
  # Logical Record.id bound (namespace-owned; never unbounded).
  @max_record_id_bytes 128
  # :timeout_ms is not honored on acquire — only :lease is admitted.
  # :server is a test seam on every opts-bearing API (stripped before allowlist).
  @acquire_opts [:lease]
  @drain_opts [:timeout_ms]
  @empty_opts []
  @default_call_timeout 10_000
  # Bounded unlinked backend op deadline (attest / get / CAS).
  @backend_op_timeout_ms 2_000
  # After kill, wait this long for the monitor DOWN before flushing results.
  @backend_down_sync_ms 1_000

  # Bounded cross-authority drain recheck while waiters exist (ms).
  @drain_recheck_ms 50

  defstruct [
    # frozen_target: %{namespace, backend, opts} | :disabled
    :frozen_target,
    # :config — re-read Config each op for drift; :injected — startup test target,
    # compares only to itself (works while Application Config is :disabled)
    :target_source,
    :runtime_fp,
    :node_fp,
    :registry,
    :guardian_supervisor,
    # Registered GenServer name (reconnect / guardian whereis binding).
    :name,
    :bounds,
    drain_waiters: %{},
    pending_fences: %{},
    # agent_id => true while a recheck timer is outstanding
    drain_recheck_pending: %{}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    # Production default id remains the module. Multi-authority tests must pass
    # an explicit unique id via start_supervised!(..., id: ...) — do not weaken
    # the production child id to the registered name.
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    # :id is supervisor-only metadata from child_spec / start_supervised.
    init_opts = Keyword.delete(opts, :id)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @spec readiness(keyword()) :: {:ok, %{durability: :node_restart}} | {:error, atom()}
  def readiness(opts \\ []) do
    with :ok <- validate_opts(opts, @empty_opts) do
      call_server(opts, :readiness)
    end
  end

  @spec acquire(String.t(), keyword()) :: {:ok, Lease.t()} | {:error, atom()}
  def acquire(agent_id, opts \\ [])

  def acquire(agent_id, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @acquire_opts),
         :ok <- validate_agent_id(agent_id) do
      call_server(opts, {:acquire, agent_id, opts})
    end
  end

  def acquire(_agent_id, _opts), do: {:error, :invalid_request}

  @spec handoff(Lease.t(), pid(), keyword()) :: {:ok, Lease.t()} | {:error, atom()}
  def handoff(lease, target_pid, opts \\ [])

  def handoff(%Lease{} = lease, target_pid, opts)
      when is_pid(target_pid) and is_list(opts) do
    with :ok <- validate_opts(opts, @empty_opts) do
      call_server(opts, {:handoff, lease, target_pid})
    end
  end

  def handoff(_lease, _target_pid, opts) when is_list(opts) do
    case validate_opts(opts, @empty_opts) do
      :ok -> {:error, :invalid_lease}
      error -> error
    end
  end

  def handoff(_lease, _target_pid, _opts), do: {:error, :invalid_request}

  @spec release(Lease.t(), keyword()) :: :ok | {:error, atom()}
  def release(lease, opts \\ [])

  def release(%Lease{} = lease, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @empty_opts) do
      call_server(opts, {:release, lease})
    end
  end

  def release(_lease, opts) when is_list(opts) do
    case validate_opts(opts, @empty_opts) do
      :ok -> {:error, :invalid_lease}
      error -> error
    end
  end

  def release(_lease, _opts), do: {:error, :invalid_request}

  @doc false
  @spec assert_owner(Lease.t(), keyword()) :: :ok | {:error, atom()}
  def assert_owner(lease, opts \\ [])

  def assert_owner(%Lease{} = lease, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @empty_opts),
         :ok <- validate_lease_shape(lease) do
      call_server(opts, {:assert_owner, lease})
    end
  end

  def assert_owner(_lease, opts) when is_list(opts) do
    case validate_opts(opts, @empty_opts) do
      :ok -> {:error, :invalid_lease}
      error -> error
    end
  end

  def assert_owner(_lease, _opts), do: {:error, :invalid_request}

  @spec drain(String.t(), keyword()) :: {:ok, DrainFence.t()} | {:error, atom()}
  def drain(agent_id, opts \\ [])

  def drain(agent_id, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @drain_opts),
         :ok <- validate_agent_id(agent_id),
         {:ok, timeout} <- resolve_drain_timeout(opts) do
      call_server(opts, {:drain, agent_id, opts}, timeout + 1_000)
    end
  end

  def drain(_agent_id, _opts), do: {:error, :invalid_request}

  @spec mark_destroyed(DrainFence.t(), keyword()) :: :ok | {:error, atom()}
  def mark_destroyed(fence, opts \\ [])

  def mark_destroyed(%DrainFence{} = fence, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @empty_opts) do
      call_server(opts, {:mark_destroyed, fence})
    end
  end

  def mark_destroyed(_fence, opts) when is_list(opts) do
    case validate_opts(opts, @empty_opts) do
      :ok -> {:error, :invalid_fence}
      error -> error
    end
  end

  def mark_destroyed(_fence, _opts), do: {:error, :invalid_request}

  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def status(agent_id, opts \\ [])

  def status(agent_id, opts) when is_list(opts) do
    with :ok <- validate_opts(opts, @empty_opts),
         :ok <- validate_agent_id(agent_id) do
      call_server(opts, {:status, agent_id})
    end
  end

  def status(_agent_id, _opts), do: {:error, :invalid_request}

  defp call_server(opts, msg, timeout \\ @default_call_timeout) do
    server = Keyword.get(opts, :server, @name)

    try do
      GenServer.call(server, msg, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :unavailable}
      :exit, {:timeout, _} -> {:error, :unavailable}
      :exit, _ -> {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, @registry)
    guardian_sup = Keyword.get(opts, :guardian_supervisor, GuardianSupervisor.name())
    name = Keyword.get(opts, :name, @name)

    with {:ok, frozen_target, target_source} <- resolve_target_provenance(opts),
         {:ok, bounds} <- load_bounds(),
         {:ok, runtime_fp} <- resolve_runtime_fp(opts) do
      state = %__MODULE__{
        frozen_target: frozen_target,
        target_source: target_source,
        runtime_fp: runtime_fp,
        node_fp: resolve_node_fp(opts),
        registry: registry,
        guardian_supervisor: guardian_sup,
        name: name,
        bounds: bounds,
        drain_waiters: %{},
        pending_fences: %{},
        drain_recheck_pending: %{}
      }

      # Reconnect surviving guardians that still point at a dead shell pid.
      {:ok, state, {:continue, :reconnect_guardians}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:reconnect_guardians, state) do
    reconnect_surviving_guardians(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:readiness, _from, state) do
    reply =
      with :ok <- ensure_frozen_target(state) do
        attest(state)
      end

    {:reply, reply, state}
  end

  def handle_call({:acquire, agent_id, opts}, {caller, _}, state) do
    reply =
      with :ok <- validate_opts(opts, @acquire_opts),
           :ok <- validate_agent_id(agent_id),
           :ok <- ensure_local_pid(caller),
           :ok <- ensure_frozen_target(state) do
        case Keyword.get(opts, :lease) do
          nil ->
            do_acquire_new(state, agent_id, caller)

          %Lease{} = lease ->
            # Validate complete shape once before any compare/hash/backend work.
            with :ok <- validate_lease_shape(lease) do
              do_reenter(state, agent_id, caller, lease)
            end

          _ ->
            {:error, :invalid_lease}
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:handoff, lease, target}, {caller, _}, state) do
    reply =
      with :ok <- ensure_local_pid(caller),
           :ok <- ensure_frozen_target(state),
           :ok <- validate_lease_shape(lease),
           :ok <- validate_target(target) do
        do_handoff(state, lease, caller, target)
      end

    {:reply, reply, state}
  end

  def handle_call({:release, lease}, {caller, _}, state) do
    with :ok <- ensure_local_pid(caller),
         :ok <- ensure_frozen_target(state),
         :ok <- validate_lease_shape(lease) do
      case do_release(state, lease, caller) do
        {:ok, new_state} -> {:reply, :ok, new_state}
        :ok -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:drain, agent_id, opts}, from, state) do
    {caller, _} = from

    # Public API already validated opts/timeout/agent_id; re-check for safety.
    with :ok <- validate_opts(opts, @drain_opts),
         :ok <- validate_agent_id(agent_id),
         {:ok, timeout} <- resolve_drain_timeout(opts),
         :ok <- ensure_local_pid(caller),
         :ok <- ensure_frozen_target(state) do
      case begin_and_maybe_fence(state, agent_id, :drain_call) do
        {:ok, fence, new_state} ->
          {:reply, {:ok, fence}, new_state}

        {:wait, new_state} ->
          mon = Process.monitor(caller)
          waiters = Map.get(new_state.drain_waiters, agent_id, [])

          if length(waiters) >= new_state.bounds.max_drain_waiters do
            Process.demonitor(mon, [:flush])
            {:reply, {:error, :busy}, new_state}
          else
            entry = %{from: from, mon: mon}
            waiters = [entry | waiters]
            drain_waiters = Map.put(new_state.drain_waiters, agent_id, waiters)
            Process.send_after(self(), {:drain_timeout, agent_id, from, mon}, timeout)
            # Bounded rechecks so a peer authority's final release notifies us
            # before the caller deadline (the internal drain recheck starts here).
            new_state = %{new_state | drain_waiters: drain_waiters}
            new_state = schedule_drain_recheck(new_state, agent_id)
            {:noreply, new_state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_destroyed, fence}, _from, state) do
    reply =
      with :ok <- ensure_frozen_target(state),
           :ok <- validate_fence_shape(fence) do
        do_mark_destroyed(state, fence)
      end

    {:reply, reply, state}
  end

  def handle_call({:assert_owner, lease}, {caller, _}, state) do
    reply =
      with :ok <- ensure_local_pid(caller),
           :ok <- ensure_frozen_target(state),
           :ok <- validate_lease_shape(lease) do
        do_assert_owner(state, lease, caller)
      end

    {:reply, reply, state}
  end

  def handle_call({:status, agent_id}, _from, state) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- ensure_frozen_target(state),
         {:ok, _} <- attest(state),
         {:ok, core, _} <-
           cas_mutate(state, agent_id, fn _core ->
             # Reconcile-only: load path already reconciled; noop unless raw differed
             # (handled inside cas_mutate_loop via raw vs reconciled write).
             {:noop, :status}
           end) do
      view = Core.status_view(core)
      waiters = length(Map.get(state.drain_waiters, agent_id, []))
      {:reply, {:ok, Map.put(view, :drain_waiters, waiters)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :invalid_request}, state}

  @impl true
  def handle_cast({:holder_down_release, guardian_pid}, state) when is_pid(guardian_pid) do
    # Wake-up only. Never trust lease_hash/agent_id from the cast payload.
    # Resolve guardian via Registry, then synchronously claim release identity
    # (shell → guardian call; guardian never calls shell).
    case claim_holder_down_release(state, guardian_pid) do
      {:ok, lease_hash, agent_id} ->
        case durable_release_root(state, agent_id, lease_hash) do
          {:ok, new_state} ->
            notify_guardian_release(guardian_pid, :ok)
            {:noreply, new_state}

          {:error, :stale_lease} ->
            notify_guardian_release(guardian_pid, :stale_lease)
            {:noreply, state}

          {:error, _reason} ->
            # Temporary unavailability — guardian keeps retrying forever with backoff.
            notify_guardian_release(guardian_pid, :retry)
            {:noreply, state}
        end

      :ignore ->
        {:noreply, state}
    end
  end

  # Legacy forgeable 4-tuple payload — deliberately ignored (no durable effect).
  def handle_cast({:holder_down_release, _lease_hash, _agent_id, _guardian_pid}, state) do
    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info({:drain_timeout, agent_id, from, mon}, state) do
    waiters = Map.get(state.drain_waiters, agent_id, [])

    case Enum.split_with(waiters, &(&1.from == from and &1.mon == mon)) do
      {[_hit], rest} ->
        Process.demonitor(mon, [:flush])
        GenServer.reply(from, {:error, :drain_timeout})
        drain_waiters = put_waiters(state.drain_waiters, agent_id, rest)
        {:noreply, %{state | drain_waiters: drain_waiters}}

      {[], _} ->
        {:noreply, state}
    end
  end

  def handle_info({:drain_recheck, agent_id}, state) do
    pending = Map.delete(state.drain_recheck_pending, agent_id)
    state = %{state | drain_recheck_pending: pending}

    waiters = Map.get(state.drain_waiters, agent_id, [])

    if waiters == [] do
      {:noreply, state}
    else
      # Cross-authority convergence: re-read durable roots; if zero, issue fence
      # and reply waiters. Never fence while roots remain.
      new_state =
        with :ok <- ensure_frozen_target(state),
             {:ok, _} <- attest(state),
             {:ok, %{core: core}} <- load_snapshot(state, agent_id) do
          maybe_notify_drain(state, agent_id, core)
        else
          _ -> state
        end

      new_state =
        if Map.get(new_state.drain_waiters, agent_id, []) != [] do
          schedule_drain_recheck(new_state, agent_id)
        else
          new_state
        end

      {:noreply, new_state}
    end
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    # Drop drain waiters whose caller died; leave gate draining
    {drain_waiters, _dropped} =
      Enum.reduce(state.drain_waiters, {%{}, 0}, fn {agent_id, waiters}, {acc, n} ->
        {kept, dead} = Enum.split_with(waiters, &(&1.mon != mon))

        Enum.each(dead, fn w ->
          Process.demonitor(w.mon, [:flush])
        end)

        {put_waiters(acc, agent_id, kept), n + length(dead)}
      end)

    {:noreply, %{state | drain_waiters: drain_waiters}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Acquire / reenter / handoff / release
  # ---------------------------------------------------------------------------

  defp do_acquire_new(state, agent_id, caller) do
    token = random_token()
    lease_hash = hash_token("lease", token)

    with {:ok, _} <- attest(state),
         {:ok, core, _} <-
           cas_mutate(state, agent_id, fn core ->
             case Core.acquire_new(
                    core,
                    lease_hash,
                    lease_hash,
                    state.node_fp,
                    state.runtime_fp,
                    core_bounds(state)
                  ) do
               {:ok, new_core} -> {:write, new_core, :acquired}
               {:error, reason} -> {:error, reason}
             end
           end) do
      case start_guardian(state, agent_id, lease_hash, token, caller) do
        {:ok, _pid} ->
          {:ok,
           %Lease{
             token: token,
             agent_id: agent_id,
             admitted_gate_gen: core.gate_gen
           }}

        {:error, _reason} ->
          {:error, :indeterminate}
      end
    end
  end

  defp do_reenter(state, agent_id, caller, lease) do
    # Reentry is guardian-local; still verify durable root on current snapshot.
    with :ok <- ensure_same_agent(lease, agent_id),
         lease_hash <- hash_token("lease", lease.token),
         {:ok, _} <- attest(state),
         {:ok, snapshot} <- load_snapshot(state, agent_id),
         :ok <- Core.assert_reenterable(snapshot.core, lease_hash),
         {:ok, guardian} <- lookup_guardian(state, lease_hash),
         :ok <- Guardian.reenter(guardian, caller) do
      {:ok, lease}
    else
      {:error, :not_owner} -> {:error, :not_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_assert_owner(state, lease, caller) do
    lease_hash = hash_token("lease", lease.token)

    with {:ok, _} <- attest(state),
         {:ok, snapshot} <- load_snapshot(state, lease.agent_id),
         :ok <- Core.assert_reenterable(snapshot.core, lease_hash),
         {:ok, guardian} <- lookup_guardian(state, lease_hash),
         :ok <- Guardian.assert_holder(guardian, caller) do
      :ok
    end
  end

  defp do_handoff(state, lease, caller, target) do
    lease_hash = hash_token("lease", lease.token)

    with {:ok, _} <- attest(state),
         {:ok, guardian} <- lookup_guardian(state, lease_hash),
         :ok <- Guardian.begin_handoff(guardian, caller, target) do
      cas_result =
        cas_mutate(state, lease.agent_id, fn core ->
          case Core.handoff_root(core, lease_hash, state.node_fp, state.runtime_fp) do
            {:ok, new_core} -> {:write, new_core, :handed_off}
            {:error, reason} -> {:error, reason}
          end
        end)

      case cas_result do
        {:ok, _core, _} ->
          # Preserve exact closed guardian outcomes after durable transfer CAS.
          # Dead target → :invalid_target (phase :releasing); do not collapse to
          # :indeterminate when the shell knows the precise closed reason.
          case Guardian.finalize_handoff(guardian, caller, target) do
            :ok -> {:ok, lease}
            {:error, :invalid_target} -> {:error, :invalid_target}
            {:error, :not_owner} -> {:error, :not_owner}
            {:error, :busy} -> {:error, :busy}
            {:error, :invalid_request} -> {:error, :invalid_request}
            {:error, _} -> {:error, :indeterminate}
          end

        {:error, reason} ->
          _ = Guardian.abort_handoff(guardian, caller)
          {:error, reason}
      end
    else
      {:error, _} = err ->
        case lookup_guardian(state, lease_hash) do
          {:ok, g} -> Guardian.abort_handoff(g, caller)
          _ -> :ok
        end

        err
    end
  end

  defp do_release(state, lease, caller) do
    lease_hash = hash_token("lease", lease.token)

    with {:ok, _} <- attest(state),
         {:ok, guardian} <- lookup_guardian(state, lease_hash),
         {:ok, step} <- Guardian.release_depth(guardian, caller) do
      case step do
        :nested ->
          :ok

        {:outermost, ^lease_hash, agent_id} ->
          # agent_id must come from the authenticated Guardian response — never
          # from caller-controlled lease.agent_id (a holder can alter that field
          # while keeping a valid token and would strand the real root on
          # stale_lease + guardian stop).
          case durable_release_root(state, agent_id, lease_hash) do
            {:ok, new_state} ->
              notify_guardian_release(guardian, :ok)
              {:ok, new_state}

            {:error, :stale_lease} ->
              notify_guardian_release(guardian, :stale_lease)
              :ok

            {:error, reason} ->
              notify_guardian_release(guardian, :retry)
              {:error, reason}
          end
      end
    end
  end

  defp durable_release_root(state, agent_id, lease_hash) do
    # Cast-path entry: re-check frozen target + attest before any read/mutation.
    # cas_mutate also attests; keep explicit gate so failures never touch storage.
    with :ok <- ensure_frozen_target(state),
         {:ok, _} <- attest(state),
         {:ok, core, _} <-
           cas_mutate(state, agent_id, fn core ->
             case Core.release_root(core, lease_hash) do
               {:ok, new_core} -> {:write, new_core, :released}
               {:error, reason} -> {:error, reason}
             end
           end) do
      {:ok, maybe_notify_drain(state, agent_id, core)}
    end
  end

  # Wake-up → Registry resolve → synchronous claim (derived lease_hash/agent_id).
  defp claim_holder_down_release(state, guardian_pid) when is_pid(guardian_pid) do
    if not Process.alive?(guardian_pid) do
      :ignore
    else
      case Registry.keys(state.registry, guardian_pid) do
        [{:guardian, registry_hash}] when is_binary(registry_hash) ->
          case Guardian.claim_release(guardian_pid) do
            {:ok, %{lease_hash: ^registry_hash, agent_id: agent_id}}
            when is_binary(agent_id) ->
              {:ok, registry_hash, agent_id}

            _ ->
              :ignore
          end

        _ ->
          :ignore
      end
    end
  catch
    :exit, _ -> :ignore
  end

  defp claim_holder_down_release(_state, _), do: :ignore

  defp notify_guardian_release(guardian_pid, result) when is_pid(guardian_pid) do
    if Process.alive?(guardian_pid) do
      try do
        # Authenticated shell → guardian call (not a forgeable cast).
        Guardian.release_attempt_result(guardian_pid, result)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp notify_guardian_release(_, _), do: :ok

  # ---------------------------------------------------------------------------
  # Drain / destroy
  # ---------------------------------------------------------------------------

  defp begin_and_maybe_fence(state, agent_id, mode) do
    with {:ok, _} <- attest(state),
         {:ok, core, _} <-
           cas_mutate(state, agent_id, fn core ->
             case Core.begin_drain(core) do
               {:ok, new_core} ->
                 if core_data_equal?(core, new_core) do
                   {:noop, :draining}
                 else
                   {:write, new_core, :draining}
                 end

               {:error, reason} ->
                 {:error, reason}
             end
           end) do
      if map_size(core.roots) == 0 do
        issue_and_build_fence(state, agent_id, core, mode)
      else
        {:wait, state}
      end
    end
  end

  defp issue_and_build_fence(state, agent_id, core_before_issue, mode) do
    case {mode, Map.get(state.pending_fences, agent_id)} do
      {:share, %{fence_gen: gen, token: token}}
      when is_integer(gen) and gen == core_before_issue.fence_gen and gen > 0 ->
        fence = %DrainFence{token: token, agent_id: agent_id, fence_generation: gen}
        new_state = reply_all_waiters(state, agent_id, {:ok, fence})
        {:ok, fence, new_state}

      _ ->
        # Token fixed for this issuance attempt; on conflict the decide_fun re-runs
        # issue_fence against the reloaded current core (never reuses stale after).
        token = random_token()
        fence_hash = hash_token("fence", token)

        case cas_mutate(state, agent_id, fn core ->
               case Core.issue_fence(core, fence_hash) do
                 {:ok, new_core, %{fence_gen: fence_gen}} ->
                   {:write, new_core, {:fenced, fence_gen}}

                 {:error, reason} ->
                   {:error, reason}
               end
             end) do
          {:ok, _core, {:fenced, fence_gen}} ->
            fence = %DrainFence{
              token: token,
              agent_id: agent_id,
              fence_generation: fence_gen
            }

            pending =
              Map.put(state.pending_fences, agent_id, %{fence_gen: fence_gen, token: token})

            new_state = %{state | pending_fences: pending}
            new_state = reply_all_waiters(new_state, agent_id, {:ok, fence})
            {:ok, fence, new_state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_mark_destroyed(state, fence) do
    fence_hash = hash_token("fence", fence.token)

    with {:ok, _} <- attest(state),
         {:ok, _core, _kind} <-
           cas_mutate(state, fence.agent_id, fn core ->
             case Core.mark_destroyed(core, fence_hash, fence.fence_generation) do
               {:ok, new_core, :idempotent} ->
                 if core_data_equal?(core, new_core) do
                   {:noop, :idempotent}
                 else
                   {:write, new_core, :idempotent}
                 end

               {:ok, new_core, :committed} ->
                 {:write, new_core, :committed}

               {:error, reason} ->
                 {:error, reason}
             end
           end) do
      :ok
    end
  end

  defp maybe_notify_drain(state, agent_id, core_state) do
    waiters = Map.get(state.drain_waiters, agent_id, [])

    # Finding 5: no-waiter notifications do nothing — never mint/rotate a raw
    # fence when nobody is waiting to receive it (later drain calls rotate).
    if waiters == [] do
      state
    else
      if map_size(core_state.roots) == 0 and core_state.gate == :draining do
        case issue_and_build_fence(state, agent_id, core_state, :share) do
          {:ok, _fence, new_state} -> new_state
          {:error, _} -> state
        end
      else
        state
      end
    end
  end

  defp reply_all_waiters(state, agent_id, reply) do
    waiters = Map.get(state.drain_waiters, agent_id, [])

    Enum.each(waiters, fn %{from: from, mon: mon} ->
      Process.demonitor(mon, [:flush])
      GenServer.reply(from, reply)
    end)

    # Finding 5: raw fence retained only for the current waiter cohort.
    # After delivery the cohort is empty — drop pending raw fence state.
    %{
      state
      | drain_waiters: Map.delete(state.drain_waiters, agent_id),
        pending_fences: Map.delete(state.pending_fences, agent_id)
    }
  end

  # ---------------------------------------------------------------------------
  # Logical CAS: load+decode+reconcile → Core transition → CAS expected exact
  # On conflict: reload and re-run transition; never reuse stale core_after.
  # decide_fun.(core) -> {:write, new_core, extra} | {:noop, extra} | {:error, reason}
  # ---------------------------------------------------------------------------

  defp cas_mutate(state, agent_id, decide_fun) do
    # Packet: before every mutation, resolve frozen target and attest CAS +
    # :node_restart durability. Cast paths rely on this gate too.
    with :ok <- ensure_frozen_target(state),
         {:ok, _} <- attest(state) do
      key = storage_key(agent_id)
      t = state.frozen_target
      retries = state.bounds.cas_max_retries
      backoff = state.bounds.cas_backoff_base_ms
      cas_mutate_loop(state, t, key, decide_fun, retries, backoff)
    end
  end

  defp cas_mutate_loop(state, t, key, decide_fun, retries_left, backoff) do
    case load_snapshot_at(state, t, key) do
      {:error, reason} ->
        {:error, reason}

      {:ok, existing, raw_core, core} ->
        # `core` is reconcile(raw). Transitions run only against `core`.
        case decide_fun.(core) do
          {:error, reason} ->
            {:error, reason}

          {:noop, extra} ->
            if core_data_equal?(raw_core, core) do
              {:ok, core, extra}
            else
              # Persist reconcile-only drop of prior-local roots.
              attempt_cas_write(
                state,
                t,
                key,
                existing,
                core,
                extra,
                decide_fun,
                retries_left,
                backoff
              )
            end

          {:write, new_core, extra} ->
            attempt_cas_write(
              state,
              t,
              key,
              existing,
              new_core,
              extra,
              decide_fun,
              retries_left,
              backoff
            )
        end
    end
  end

  defp attempt_cas_write(
         state,
         t,
         key,
         existing,
         new_core,
         extra,
         decide_fun,
         retries_left,
         backoff
       ) do
    record = build_record(key, existing, new_core)
    expected = if is_nil(existing), do: :not_found, else: {:value, existing}

    case bounded_backend_op(fn ->
           Persistence.compare_and_swap(
             t.namespace,
             t.backend,
             key,
             expected,
             record,
             t.opts
           )
         end) do
      {:ok, stored} ->
        # Post-dispatch success must bind exact insert/update receipt semantics.
        case bind_cas_receipt(key, existing, record, stored) do
          :ok -> {:ok, new_core, extra}
          :error -> {:error, :indeterminate}
        end

      {:error, :conflict} when retries_left > 0 ->
        if backoff > 0, do: Process.sleep(backoff)
        # Full reload + re-decide — never reuse stale new_core
        cas_mutate_loop(state, t, key, decide_fun, retries_left - 1, backoff)

      {:error, :conflict} ->
        {:error, :busy}

      {:error, :unsupported} ->
        {:error, :unsupported}

      # Post-dispatch CAS timeout / malformed applied ambiguity → indeterminate
      {:error, :timeout} ->
        {:error, :indeterminate}

      {:error, :indeterminate} ->
        {:error, :indeterminate}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  # Admission schema uses empty JSON-clean metadata only (closed; no extras).
  defp build_record(key, nil, new_core),
    do: Record.new(key, Core.to_data(new_core), metadata: %{})

  defp build_record(_key, %Record{} = existing, new_core),
    do: Record.update(existing, Core.to_data(new_core), metadata: %{})

  defp load_snapshot(state, agent_id) do
    # Packet: before every read, re-check frozen target and attest durability.
    with :ok <- ensure_frozen_target(state),
         {:ok, _} <- attest(state) do
      key = storage_key(agent_id)
      t = state.frozen_target

      case load_snapshot_at(state, t, key) do
        {:ok, _existing, _raw, core} -> {:ok, %{core: core}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Returns {:ok, existing_record_or_nil, raw_core, reconciled_core} | {:error, atom}
  # CAS expected is always the exact loaded Record (or :not_found), never a
  # re-fetched "latest" after the decision.
  defp load_snapshot_at(state, t, key) do
    bounds = core_bounds(state)

    case bounded_backend_op(fn -> Persistence.get(t.namespace, t.backend, key, t.opts) end) do
      {:ok, %Record{} = record} ->
        with :ok <- bind_loaded_record(key, record),
             {:ok, raw} <- Core.new(record.data, bounds),
             {:ok, core} <- Core.reconcile(raw, state.node_fp, state.runtime_fp) do
          {:ok, record, raw, core}
        else
          {:error, :indeterminate} -> {:error, :indeterminate}
          {:error, _} -> {:error, :indeterminate}
          :error -> {:error, :indeterminate}
        end

      {:error, :not_found} ->
        with {:ok, raw} <- Core.new(nil, bounds),
             {:ok, core} <- Core.reconcile(raw, state.node_fp, state.runtime_fp) do
          {:ok, nil, raw, core}
        end

      {:error, :timeout} ->
        # Get has no durable side effect; still treat late ambiguity conservatively.
        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, :indeterminate} ->
        {:error, :indeterminate}

      {:error, _} ->
        {:error, :unavailable}

      # Non-Record "success" is a malformed applied reply.
      {:ok, _other} ->
        {:error, :indeterminate}
    end
  end

  # Loaded Record must bind key, logical id, data, metadata, gen/rev, ordered timestamps.
  defp bind_loaded_record(key, %Record{} = record) do
    with true <- is_binary(record.key) and record.key == key,
         true <- valid_logical_id?(record.id),
         true <- is_map(record.data) and not is_struct(record.data),
         true <- closed_empty_metadata?(record.metadata),
         true <- is_integer(record.generation) and record.generation >= 1,
         true <- is_integer(record.revision) and record.revision >= 1,
         true <- match?(%DateTime{}, record.inserted_at),
         true <- match?(%DateTime{}, record.updated_at),
         true <- DateTime.compare(record.inserted_at, record.updated_at) in [:lt, :eq] do
      :ok
    else
      _ -> :error
    end
  end

  defp bind_loaded_record(_, _), do: :error

  # Insert / reinsert after hidden tombstone (`expected == :not_found`):
  # generation may be >1 (tombstone reinsert); revision must be 1.
  # Match replacement id/key/data/metadata exactly; timestamps valid+ordered.
  # Update: preserve id/key/generation/inserted_at, match data/metadata, rev=prior+1,
  # nondecreasing updated_at.
  defp bind_cas_receipt(key, nil, %Record{} = replacement, %Record{} = stored) do
    with true <- stored.key == key and stored.key == replacement.key,
         true <- valid_logical_id?(stored.id) and stored.id == replacement.id,
         true <- stored.data == replacement.data,
         true <- closed_empty_metadata?(stored.metadata),
         true <- closed_empty_metadata?(replacement.metadata),
         true <- stored.metadata == replacement.metadata,
         true <- is_integer(stored.generation) and stored.generation >= 1,
         true <- stored.revision == 1,
         true <- match?(%DateTime{}, stored.inserted_at),
         true <- match?(%DateTime{}, stored.updated_at),
         true <- DateTime.compare(stored.inserted_at, stored.updated_at) in [:lt, :eq] do
      :ok
    else
      _ -> :error
    end
  end

  defp bind_cas_receipt(key, %Record{} = prior, %Record{} = replacement, %Record{} = stored) do
    with true <- stored.key == key and stored.key == prior.key and stored.key == replacement.key,
         true <- valid_logical_id?(stored.id),
         true <- stored.id == prior.id and stored.id == replacement.id,
         true <- stored.generation == prior.generation,
         true <- stored.revision == prior.revision + 1,
         true <- stored.data == replacement.data,
         true <- closed_empty_metadata?(stored.metadata),
         true <- closed_empty_metadata?(replacement.metadata),
         true <- stored.metadata == replacement.metadata,
         true <- stored.inserted_at == prior.inserted_at,
         true <- match?(%DateTime{}, stored.updated_at),
         true <- DateTime.compare(prior.updated_at, stored.updated_at) in [:lt, :eq] do
      :ok
    else
      _ -> :error
    end
  end

  defp bind_cas_receipt(_key, _existing, _replacement, _stored), do: :error

  defp valid_logical_id?(id) when is_binary(id) do
    byte_size(id) > 0 and byte_size(id) <= @max_record_id_bytes and String.valid?(id)
  end

  defp valid_logical_id?(_), do: false

  # Namespace-owned admission schema: metadata is exactly empty JSON-clean map.
  defp closed_empty_metadata?(meta) when is_map(meta) and not is_struct(meta), do: meta == %{}
  defp closed_empty_metadata?(_), do: false

  defp core_bounds(state) do
    %{
      max_active_roots: state.bounds.max_active_roots,
      max_record_encoded_bytes: 65_536
    }
  end

  defp core_data_equal?(a, b), do: Core.to_data(a) == Core.to_data(b)

  # ---------------------------------------------------------------------------
  # Guardians
  # ---------------------------------------------------------------------------

  defp reconnect_surviving_guardians(state) do
    # Discover only live Registry-owned guardians and offer this shell as owner.
    # Guardians refuse if their current admission pid is still alive and different.
    pattern = [
      {
        {{:guardian, :"$1"}, :"$2", :"$3"},
        [],
        [{{:"$1", :"$2"}}]
      }
    ]

    try do
      for {_lease_hash, pid} <- Registry.select(state.registry, pattern),
          is_pid(pid) and Process.alive?(pid) do
        # Ignore refuse/not_owner from guardians owned by another live authority.
        _ = Guardian.reconnect_admission(pid, self())
      end
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp schedule_drain_recheck(state, agent_id) do
    if Map.get(state.drain_recheck_pending, agent_id) do
      state
    else
      Process.send_after(self(), {:drain_recheck, agent_id}, @drain_recheck_ms)
      %{state | drain_recheck_pending: Map.put(state.drain_recheck_pending, agent_id, true)}
    end
  end

  defp start_guardian(state, agent_id, lease_hash, token, holder) do
    spec =
      {Guardian,
       [
         lease_hash: lease_hash,
         agent_id: agent_id,
         token: token,
         holder: holder,
         admission: self(),
         admission_name: state.name,
         registry: state.registry,
         max_depth: state.bounds.max_nested_depth
       ]}

    case DynamicSupervisor.start_child(state.guardian_supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_guardian(state, lease_hash) do
    # Discover only live Registry-owned guardians (shell indexes are never authority).
    case Registry.lookup(state.registry, {:guardian, lease_hash}) do
      [{pid, _meta}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :invalid_lease}

      [] ->
        {:error, :invalid_lease}

      _other ->
        {:error, :indeterminate}
    end
  end

  # ---------------------------------------------------------------------------
  # Target freeze, attestation, identity
  # ---------------------------------------------------------------------------

  # Returns {:ok, frozen_target, :config | :injected} | {:error, reason}
  # Public API never supplies backend/opts — only start_link may inject a test target.
  defp resolve_target_provenance(opts) do
    case Keyword.fetch(opts, :target) do
      {:ok, raw} ->
        case normalize_injected_target(raw) do
          {:ok, target} -> {:ok, target, :injected}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        case Config.mutation_admission_target() do
          {:ok, target} -> {:ok, target, :config}
          {:error, :disabled} -> {:ok, :disabled, :config}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp normalize_injected_target(%{backend: backend, opts: backend_opts} = t)
       when is_atom(backend) and not is_nil(backend) and is_list(backend_opts) do
    ns = Map.get(t, :namespace, Config.fixed_mutation_admission_namespace())

    if ns == Config.fixed_mutation_admission_namespace() and Keyword.keyword?(backend_opts) do
      {:ok, %{namespace: ns, backend: backend, opts: backend_opts}}
    else
      {:error, :invalid_config}
    end
  end

  defp normalize_injected_target(_), do: {:error, :invalid_config}

  defp ensure_frozen_target(%{frozen_target: :disabled}), do: {:error, :disabled}

  # Production Config provenance: re-read resolver every op; drift fails closed.
  defp ensure_frozen_target(%{target_source: :config, frozen_target: frozen}) do
    case Config.mutation_admission_target() do
      {:ok, current} ->
        if targets_equal?(current, frozen), do: :ok, else: {:error, :invalid_config}

      {:error, :disabled} ->
        {:error, :invalid_config}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Startup-injected immutable test target: compare only to itself. Does not require
  # Application Config (tests stay disabled). Never accepts per-call backend selection.
  defp ensure_frozen_target(%{target_source: :injected, frozen_target: frozen})
       when is_map(frozen) do
    if match?(%{namespace: _, backend: _, opts: _}, frozen) do
      :ok
    else
      {:error, :invalid_config}
    end
  end

  defp ensure_frozen_target(_), do: {:error, :invalid_config}

  defp targets_equal?(a, b) when is_map(a) and is_map(b) do
    a.namespace == b.namespace and a.backend == b.backend and a.opts == b.opts
  end

  defp targets_equal?(_, _), do: false

  defp attest(%{frozen_target: :disabled}), do: {:error, :disabled}

  # Static-review (2): supports_compare_and_swap?, supports_durability_class?, and
  # durability_class all run inside bounded unlinked backend execution — never as
  # direct potentially blocking/raising calls on the GenServer process.
  defp attest(state) do
    t = state.frozen_target

    if not is_map(t) or not is_atom(t.backend) or is_nil(t.backend) do
      {:error, :disabled}
    else
      backend = t.backend
      namespace = t.namespace
      opts = t.opts

      case bounded_backend_op(fn ->
             cond do
               not Persistence.supports_compare_and_swap?(backend) ->
                 {:error, :unsupported}

               not Persistence.supports_durability_class?(backend) ->
                 {:error, :unsupported}

               true ->
                 case Persistence.durability_class(namespace, backend, opts) do
                   {:ok, :node_restart} -> {:ok, :node_restart}
                   {:ok, _other} -> {:error, :insufficient_durability}
                   {:error, :unsupported} -> {:error, :unsupported}
                   {:error, _} -> {:error, :unavailable}
                 end
             end
           end) do
        {:ok, :node_restart} ->
          {:ok, %{durability: :node_restart}}

        {:error, :unsupported} ->
          {:error, :unsupported}

        {:error, :insufficient_durability} ->
          {:error, :insufficient_durability}

        {:error, :timeout} ->
          {:error, :unavailable}

        {:error, :unavailable} ->
          {:error, :unavailable}

        {:error, _} ->
          {:error, :unavailable}

        _other ->
          {:error, :unavailable}
      end
    end
  end

  # Test-only explicit identities remain process-local. Production reads only
  # from the protected BEAM-lifetime authority bootstrapped by the application.
  defp resolve_runtime_fp(opts) do
    case Keyword.fetch(opts, :runtime_fp) do
      {:ok, fingerprint} ->
        if RuntimeIdentity.valid?(fingerprint) do
          {:ok, fingerprint}
        else
          {:error, :invalid_runtime_identity}
        end

      :error ->
        RuntimeIdentity.current()
    end
  end

  defp resolve_node_fp(opts) do
    case Keyword.get(opts, :node_fp) do
      "ambiguous" ->
        "ambiguous"

      fp when is_binary(fp) and byte_size(fp) == @hash_hex_length ->
        fp

      _ ->
        case Node.self() do
          :nonode@nohost ->
            "ambiguous"

          n when is_atom(n) ->
            :crypto.hash(
              :sha256,
              "arbor.memory.mutation_admission.node:v1" <> Atom.to_string(n)
            )
            |> Base.encode16(case: :lower)
        end
    end
  end

  defp load_bounds do
    with {:ok, max_roots} <- Config.mutation_admission_max_active_roots(),
         {:ok, max_depth} <- Config.mutation_admission_max_nested_depth(),
         {:ok, max_waiters} <- Config.mutation_admission_max_drain_waiters(),
         {:ok, cas_retries} <- Config.mutation_admission_cas_max_retries(),
         {:ok, backoff} <- Config.mutation_admission_cas_backoff_base_ms() do
      {:ok,
       %{
         max_active_roots: max_roots,
         max_nested_depth: max_depth,
         max_drain_waiters: max_waiters,
         cas_max_retries: cas_retries,
         cas_backoff_base_ms: backoff
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation / crypto / util
  # ---------------------------------------------------------------------------

  defp validate_agent_id(id) when is_binary(id) do
    max = Config.mutation_admission_max_agent_id_bytes()

    if byte_size(id) > 0 and byte_size(id) <= max and String.valid?(id) and
         String.trim(id) == id and String.trim(id) != "" do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp validate_agent_id(_), do: {:error, :invalid_request}

  defp validate_lease_shape(%Lease{token: token, agent_id: agent_id, admitted_gate_gen: gen})
       when is_binary(token) and byte_size(token) == @token_bytes and is_binary(agent_id) and
              is_integer(gen) and gen > 0 do
    # Lease agent_id failures are always :invalid_lease (never leak :invalid_request).
    case validate_agent_id(agent_id) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_lease}
    end
  end

  defp validate_lease_shape(_), do: {:error, :invalid_lease}

  defp validate_fence_shape(%DrainFence{
         token: token,
         agent_id: agent_id,
         fence_generation: gen
       })
       when is_binary(token) and byte_size(token) == @token_bytes and is_binary(agent_id) and
              is_integer(gen) and gen > 0 do
    validate_agent_id(agent_id)
  end

  defp validate_fence_shape(_), do: {:error, :invalid_fence}

  defp validate_target(pid) when is_pid(pid) do
    cond do
      node(pid) != node() -> {:error, :invalid_target}
      not Process.alive?(pid) -> {:error, :invalid_target}
      true -> :ok
    end
  end

  defp validate_target(_), do: {:error, :invalid_target}

  defp ensure_local_pid(pid) when is_pid(pid) do
    if node(pid) == node(), do: :ok, else: {:error, :invalid_request}
  end

  defp ensure_local_pid(_), do: {:error, :invalid_request}

  defp ensure_same_agent(%Lease{agent_id: a}, agent_id) when a == agent_id, do: :ok
  defp ensure_same_agent(_, _), do: {:error, :invalid_lease}

  # Finding 2: reject malformed / duplicate / unknown opts before GenServer.call.
  # `:server` is retained only as a test seam and is never an admission control.
  defp validate_opts(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) -> {:error, :invalid_request}
        Enum.any?(keys, &(&1 not in allowed and &1 != :server)) -> {:error, :invalid_request}
        true -> :ok
      end
    else
      {:error, :invalid_request}
    end
  end

  defp validate_opts(_, _), do: {:error, :invalid_request}

  # Invalid drain timeout bounds fail even with no stored record.
  # Invalid configured default fails closed even when caller supplies :timeout_ms.
  defp resolve_drain_timeout(opts) do
    max = Config.mutation_admission_max_drain_timeout_ms()

    with {:ok, default} <- Config.mutation_admission_drain_default_timeout_ms() do
      case Keyword.fetch(opts, :timeout_ms) do
        :error ->
          {:ok, default}

        {:ok, n} when is_integer(n) and n > 0 and n <= max ->
          {:ok, n}

        {:ok, _} ->
          {:error, :invalid_request}
      end
    end
  end

  defp storage_key(agent_id) do
    Base.encode16(:crypto.hash(:sha256, agent_id), case: :lower)
  end

  defp random_token, do: :crypto.strong_rand_bytes(@token_bytes)

  defp hash_token(kind, token) when kind in ["lease", "fence"] do
    :crypto.hash(:sha256, "arbor.memory.mutation_admission." <> kind <> ":v1" <> token)
    |> Base.encode16(case: :lower)
  end

  defp put_waiters(map, agent_id, []), do: Map.delete(map, agent_id)
  defp put_waiters(map, agent_id, waiters), do: Map.put(map, agent_id, waiters)

  # Bounded unlinked monitored backend workers for attest/get/CAS.
  # Timeout cleanup: kill, then synchronize on monitor DOWN, then flush the
  # unique result ref. Immediate demonitor+zero-time flush can leave a late
  # result in the authority mailbox.
  # Callers map post-dispatch CAS timeout → :indeterminate.
  defp bounded_backend_op(fun) when is_function(fun, 0) do
    parent = self()
    result_ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            _ -> {:error, :unavailable}
          catch
            _, _ -> {:error, :unavailable}
          end

        send(parent, {result_ref, result})
      end)

    receive do
      {^result_ref, {:ok, value}} ->
        Process.demonitor(mon, [:flush])
        value

      {^result_ref, {:error, :unavailable}} ->
        Process.demonitor(mon, [:flush])
        {:error, :unavailable}

      {:DOWN, ^mon, :process, ^pid, _reason} ->
        flush_backend_result(result_ref)
        {:error, :unavailable}
    after
      @backend_op_timeout_ms ->
        Process.exit(pid, :kill)

        # Synchronize on DOWN, then always demonitor+flush so a late DOWN cannot
        # pollute the authority mailbox after we return to the GenServer loop.
        receive do
          {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
        after
          @backend_down_sync_ms -> :ok
        end

        Process.demonitor(mon, [:flush])
        flush_backend_result(result_ref)
        {:error, :timeout}
    end
  end

  defp flush_backend_result(result_ref) do
    receive do
      {^result_ref, _} -> :ok
    after
      0 -> :ok
    end
  end
end
