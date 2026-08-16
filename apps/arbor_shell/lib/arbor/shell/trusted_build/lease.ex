defmodule Arbor.Shell.TrustedBuild.Lease do
  @moduledoc false

  use GenServer

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:token, :worker, :owner]
    defstruct [:token, :worker, :owner]
  end

  defimpl Inspect, for: Handle do
    def inspect(_lease, _opts), do: "#Arbor.Shell.TrustedBuild.Lease<redacted>"
  end

  alias Arbor.Shell.Executor
  alias Arbor.Shell.OwnedTree
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.ProcessGroup
  alias Arbor.Shell.TrustedBuild.Inventory
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @supervisor Arbor.Shell.TrustedBuild.LeaseSupervisor
  @reserved_ops [
    :stage_native_cache,
    :inventory_deps,
    :remove_release_cookie,
    :read_descriptor
  ]

  @spec supervisor_child_spec() :: Supervisor.child_spec()
  def supervisor_child_spec do
    %{
      id: @supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [[name: @supervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @spec start_worker(map()) :: {:ok, pid()} | {:error, term()}
  def start_worker(attrs) when is_map(attrs) do
    spec = %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [attrs]},
      restart: :temporary,
      type: :worker,
      shutdown: 10_000
    }

    DynamicSupervisor.start_child(@supervisor, spec)
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(attrs) when is_map(attrs) do
    GenServer.start_link(__MODULE__, attrs)
  end

  @spec handle(pid(), binary(), pid()) :: Handle.t()
  def handle(worker, token, owner)
      when is_pid(worker) and is_binary(token) and is_pid(owner) do
    %Handle{token: token, worker: worker, owner: owner}
  end

  # -- Owner-scoped API (Handle + token authorized) ---------------------------

  @spec view(Handle.t()) :: {:ok, map()} | {:error, term()}
  def view(%Handle{} = lease), do: call(lease, :view)

  @spec begin_phase(Handle.t(), atom(), pid()) :: {:ok, map()} | {:error, term()}
  def begin_phase(%Handle{} = lease, phase, caller)
      when is_atom(phase) and is_pid(caller) do
    call(lease, {:begin_phase, phase, caller})
  end

  @spec attach_phase(Handle.t(), pid()) :: :ok | {:error, term()}
  def attach_phase(%Handle{} = lease, phase_pid) when is_pid(phase_pid) do
    call(lease, {:attach_phase, phase_pid})
  end

  @spec inventory_release(Handle.t()) :: {:ok, map()} | {:error, term()}
  def inventory_release(%Handle{} = lease), do: call(lease, :inventory_release)

  @spec reserved(Handle.t(), atom()) :: {:error, term()}
  def reserved(%Handle{} = lease, op) when op in @reserved_ops do
    call(lease, {:reserved, op})
  end

  def reserved(_lease, _op), do: {:error, :invalid_trusted_build_lease_op}

  @spec release(Handle.t()) :: :ok | {:error, term()}
  def release(%Handle{} = lease), do: call(lease, :release)

  @spec cancel_in_flight(Handle.t()) :: :ok
  def cancel_in_flight(%Handle{} = lease) do
    _ = call(lease, :cancel_in_flight)
    :ok
  end

  # -- Phase-scoped API (process-identity authorized: caller must be the -----
  # -- registered phase_pid; no Handle token available at this layer) --------

  @spec checkout_launch(pid(), reference()) :: {:ok, map()} | {:error, term()}
  def checkout_launch(lease_pid, launch_ticket)
      when is_pid(lease_pid) and is_reference(launch_ticket) do
    phase_call(lease_pid, {:checkout_launch, launch_ticket})
  end

  @spec register_port_owner(pid(), pid()) :: :ok | {:error, term()}
  def register_port_owner(lease_pid, owner_pid) when is_pid(lease_pid) and is_pid(owner_pid) do
    phase_call(lease_pid, {:register_port_owner, owner_pid})
  end

  @spec commit_phase_result(pid(), term()) :: :ok | {:error, term()}
  def commit_phase_result(lease_pid, result) when is_pid(lease_pid) do
    phase_call(lease_pid, {:commit_phase_result, result})
  end

  # -- Port-owner-scoped API (process-identity authorized: caller must be ----
  # -- the registered port_owner_pid) -----------------------------------------

  @spec record_group_id(pid(), pos_integer()) :: :ok | {:error, term()}
  def record_group_id(lease_pid, group_id)
      when is_pid(lease_pid) and is_integer(group_id) and group_id > 0 do
    port_owner_call(lease_pid, {:record_group_id, group_id})
  end

  @spec record_exhaustion(pid(), term()) :: :ok | {:error, term()}
  def record_exhaustion(lease_pid, terminal_reason) when is_pid(lease_pid) do
    port_owner_call(lease_pid, {:record_exhaustion, terminal_reason})
  end

  @impl true
  def init(attrs) do
    Process.flag(:trap_exit, true)
    owner = Map.fetch!(attrs, :owner)
    owner_ref = Process.monitor(owner)
    {registry_pid, registry_gen} = Map.fetch!(attrs, :registry)
    {authority_pid, authority_gen} = Map.fetch!(attrs, :authority)
    registry_ref = Process.monitor(registry_pid)
    authority_ref = Process.monitor(authority_pid)

    {:ok,
     %{
       token: Map.fetch!(attrs, :token),
       owner: owner,
       owner_ref: owner_ref,
       registry_pid: registry_pid,
       registry_gen: registry_gen,
       registry_ref: registry_ref,
       authority_pid: authority_pid,
       authority_gen: authority_gen,
       authority_ref: authority_ref,
       identities: Map.fetch!(attrs, :identities),
       roots: Map.fetch!(attrs, :roots),
       binding: Map.fetch!(attrs, :binding),
       fault: Map.get(attrs, :fault, :none),
       completed: [],
       done: false,
       locked: false,
       in_flight: nil,
       phase_pid: nil,
       phase_ref: nil,
       cancel_id: nil,
       launch_ticket: nil,
       port_owner_pid: nil,
       port_owner_ref: nil,
       port_owner_group_id: nil,
       port_owner_registered: false,
       port_owner_exhausted: false,
       released: false
     }}
  end

  @impl true
  def handle_call({:owner_request, token, request}, from, state) do
    if token == state.token do
      dispatch_owner_request(request, from, state)
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:checkout_launch, launch_ticket}, {caller, _}, state) do
    cond do
      caller != state.phase_pid or not is_pid(state.phase_pid) ->
        {:reply, {:error, :foreign_caller}, state}

      state.launch_ticket != launch_ticket ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      true ->
        descriptor = build_launch_descriptor(state)
        {:reply, {:ok, descriptor}, %{state | launch_ticket: :consumed}}
    end
  end

  def handle_call({:register_port_owner, owner_pid}, {caller, _}, state) do
    cond do
      caller != state.phase_pid or not is_pid(state.phase_pid) ->
        {:reply, {:error, :foreign_caller}, state}

      state.in_flight == nil ->
        {:reply, {:error, :trusted_build_phase_not_started}, state}

      true ->
        ref = Process.monitor(owner_pid)

        next = %{
          state
          | port_owner_pid: owner_pid,
            port_owner_ref: ref,
            port_owner_group_id: nil,
            port_owner_registered: true,
            port_owner_exhausted: false
        }

        {:reply, :ok, next}
    end
  end

  def handle_call({:record_group_id, group_id}, {caller, _}, state) do
    if caller == state.port_owner_pid and is_pid(state.port_owner_pid) do
      {:reply, :ok, %{state | port_owner_group_id: group_id}}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:record_exhaustion, _terminal_reason}, {caller, _}, state) do
    if caller == state.port_owner_pid and is_pid(state.port_owner_pid) do
      {:reply, :ok, %{state | port_owner_exhausted: true}}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:commit_phase_result, result}, {caller, _}, state) do
    cond do
      caller != state.phase_pid or not is_pid(state.phase_pid) ->
        {:reply, {:error, :foreign_caller}, state}

      state.in_flight == nil ->
        {:reply, {:error, :trusted_build_phase_not_started}, state}

      true ->
        {:reply, :ok, complete_phase(state, result)}
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :invalid_trusted_build_lease_op}, state}
  end

  # -- Owner-scoped dispatch (token already verified by handle_call above) ---

  defp dispatch_owner_request(:view, {caller, _}, state) do
    if caller == state.owner do
      {:reply, {:ok, render_view(state)}, state}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  defp dispatch_owner_request({:begin_phase, phase, caller}, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      state.released or state.locked or state.done ->
        {:reply, {:error, :trusted_build_phase_locked}, state}

      state.in_flight != nil ->
        {:reply, {:error, :trusted_build_phase_in_flight}, state}

      true ->
        case start_phase(state, phase) do
          {:ok, session, next} -> {:reply, {:ok, session}, next}
          {:error, reason, next} -> {:reply, {:error, reason}, next}
        end
    end
  end

  defp dispatch_owner_request({:begin_phase, _phase, _caller}, _from, state) do
    {:reply, {:error, :foreign_caller}, state}
  end

  defp dispatch_owner_request({:attach_phase, phase_pid}, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      state.in_flight == nil ->
        {:reply, {:error, :trusted_build_phase_not_started}, state}

      true ->
        ref = Process.monitor(phase_pid)
        {:reply, :ok, %{state | phase_pid: phase_pid, phase_ref: ref}}
    end
  end

  defp dispatch_owner_request(:inventory_release, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      state.locked ->
        {:reply, {:error, :trusted_build_phase_locked}, state}

      not state.done ->
        {:reply, {:error, :trusted_build_release_absent}, state}

      true ->
        {:reply, Inventory.release_document(state.roots.build.path), state}
    end
  end

  defp dispatch_owner_request({:reserved, op}, {caller, _}, state) when op in @reserved_ops do
    if caller == state.owner do
      {:reply, {:error, :trusted_build_op_reserved}, state}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  defp dispatch_owner_request(:cancel_in_flight, _from, state) do
    {:reply, :ok, signal_cancel(state)}
  end

  defp dispatch_owner_request(:release, {caller, _}, state) do
    if caller == state.owner do
      finalize_release(state)
    else
      {:reply, {:error, :foreign_release}, state}
    end
  end

  defp dispatch_owner_request(_request, _from, state) do
    {:reply, {:error, :invalid_trusted_build_lease_op}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      ref == state.owner_ref and pid == state.owner ->
        state = signal_cancel(state)
        state = await_phase_exit(state)
        _ = cleanup_workspace(state)
        {:stop, :normal, %{state | released: true, locked: true}}

      ref == state.phase_ref and pid == state.phase_pid ->
        {:noreply, lock_after_phase_loss(state)}

      ref == state.port_owner_ref and pid == state.port_owner_pid ->
        {:noreply, handle_port_owner_loss(state)}

      ref == state.authority_ref or ref == state.registry_ref ->
        state = signal_cancel(%{state | locked: true})
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if not state.released do
      state = signal_cancel(state)
      state = await_phase_exit(state)
      _ = cleanup_workspace(state)
    end

    :ok
  end

  defp start_phase(state, phase) do
    with :ok <- Plan.admit_order(phase, state.completed),
         {:ok, binding, authority_pid, generation} <-
           TrustedBuildToolchainAuthority.checkout_generation(
             state.authority_pid,
             state.authority_gen
           ),
         {:ok, registry_pid, registry_gen} <- OwnedTreeRegistry.checkout(),
         true <- authority_pid == state.authority_pid and generation == state.authority_gen,
         true <- registry_pid == state.registry_pid and registry_gen == state.registry_gen do
      cancel_id = make_ref()
      launch_ticket = make_ref()

      session = %{
        lease_pid: self(),
        owner_pid: state.owner,
        authority_pid: authority_pid,
        authority_gen: generation,
        registry_pid: registry_pid,
        registry_gen: registry_gen,
        cancel_id: cancel_id,
        launch_ticket: launch_ticket,
        phase: phase
      }

      next = %{
        state
        | in_flight: phase,
          cancel_id: cancel_id,
          launch_ticket: launch_ticket,
          binding: binding
      }

      {:ok, session, next}
    else
      false ->
        {:error, :trusted_build_toolchain_generation_mismatch, %{state | locked: true}}

      {:error, reason} ->
        {:error, reason, %{state | locked: true}}
    end
  end

  # Built entirely from Lease's own trusted state; the caller (phase_pid) never
  # supplies any of these fields. Timeout/argv/env are derived purely from the
  # already-admitted `state.in_flight` phase atom via Plan, never from the caller.
  defp build_launch_descriptor(state) do
    identities = state.identities
    roots = state.roots
    binding = state.binding
    phase = state.in_flight

    %{
      wrapper: identities.wrapper,
      erl: binding.erl,
      elixir: binding.elixir,
      elixir_mix: binding.elixir_mix,
      source: identities.source,
      source_owned: identities.source_owned,
      erlang_root: binding.erlang_root,
      elixir_root: binding.elixir_root,
      archives: identities.archives,
      archives_digest: identities.archives_digest,
      roots: Map.put(roots, :archives, identities.archives),
      env: Plan.closed_env(roots, binding),
      argv: Plan.argv(phase),
      timeout_ms: Plan.timeout_ms(phase),
      max_output_bytes: Executor.default_max_output_bytes(),
      cancel_id: state.cancel_id
    }
  end

  defp complete_phase(state, result) do
    state = demonitor_phase(state)
    state = demonitor_port_owner(state)

    case result do
      {:ok, %{exit_code: 0, timed_out: false, killed: false}} ->
        completed = state.completed ++ [state.in_flight]

        %{
          state
          | completed: completed,
            in_flight: nil,
            cancel_id: nil,
            launch_ticket: nil,
            done: completed == [:deps_get, :compile, :release]
        }

      _other ->
        %{state | in_flight: nil, cancel_id: nil, launch_ticket: nil, locked: true}
    end
  end

  defp lock_after_phase_loss(state) do
    %{
      state
      | locked: true,
        in_flight: nil,
        phase_pid: nil,
        phase_ref: nil,
        cancel_id: nil,
        launch_ticket: nil
    }
  end

  # An unacked owner death: either the process genuinely crashed mid-flight
  # (record_exhaustion never landed) or exhaustion already landed and this DOWN
  # is just the ordinary follow-on exit. If a group_id was ever recorded, make
  # one honest, idempotent last-resort native re-containment attempt before
  # accepting exhaustion; otherwise no native process could ever have existed.
  defp handle_port_owner_loss(%{port_owner_exhausted: true} = state) do
    %{state | port_owner_pid: nil, port_owner_ref: nil}
  end

  defp handle_port_owner_loss(%{port_owner_group_id: group_id} = state)
       when is_integer(group_id) do
    case fallback_kill_group(group_id) do
      :ok ->
        %{state | port_owner_exhausted: true, port_owner_pid: nil, port_owner_ref: nil}

      {:error, _reason} ->
        %{state | port_owner_pid: nil, port_owner_ref: nil, locked: true}
    end
  end

  defp handle_port_owner_loss(state) do
    %{state | port_owner_exhausted: true, port_owner_pid: nil, port_owner_ref: nil}
  end

  defp fallback_kill_group(group_id), do: ProcessGroup.kill_group(group_id)

  defp signal_cancel(%{cancel_id: cancel_id} = state) do
    if is_reference(cancel_id) do
      send(self(), {:cancel_shell_execution, cancel_id})

      if is_pid(state.phase_pid) do
        send(state.phase_pid, {:cancel_shell_execution, cancel_id})
      end

      if is_pid(state.port_owner_pid) do
        send(state.port_owner_pid, {:cancel_shell_execution, cancel_id})
      end
    end

    state
  end

  # Unbounded retry: waits for the phase process and (if one was ever
  # registered) the actual port-owner process to be positively confirmed gone
  # before returning, re-delivering cancel on each tick instead of ever forcing
  # a kill or giving up. A raw $gen_call arriving in this window (a phase/owner
  # process that has not yet observed cancellation trying to reach this same
  # lease) is rejected immediately rather than left to block its sender
  # indefinitely -- the sender is expected to fail closed and still exit,
  # which is exactly what unblocks this loop.
  defp await_phase_exit(state) do
    if phase_still_pending?(state) or port_owner_still_pending?(state) do
      receive do
        {:DOWN, ref, :process, pid, _reason}
        when ref == state.phase_ref and pid == state.phase_pid ->
          await_phase_exit(demonitor_phase(state))

        {:DOWN, ref, :process, pid, _reason}
        when ref == state.port_owner_ref and pid == state.port_owner_pid ->
          await_phase_exit(handle_port_owner_loss(state))

        {:"$gen_call", from, _request} ->
          GenServer.reply(from, {:error, :trusted_build_lease_terminating})
          await_phase_exit(state)
      after
        5_000 ->
          await_phase_exit(signal_cancel(state))
      end
    else
      state
    end
  end

  defp phase_still_pending?(%{phase_pid: pid}), do: is_pid(pid)
  defp port_owner_still_pending?(%{port_owner_pid: pid}), do: is_pid(pid)

  defp demonitor_phase(%{phase_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | phase_pid: nil, phase_ref: nil}
  end

  defp demonitor_phase(state), do: %{state | phase_pid: nil, phase_ref: nil}

  defp demonitor_port_owner(%{port_owner_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    reset_port_owner(state)
  end

  defp demonitor_port_owner(state), do: reset_port_owner(state)

  defp reset_port_owner(state) do
    %{
      state
      | port_owner_pid: nil,
        port_owner_ref: nil,
        port_owner_group_id: nil,
        port_owner_registered: false,
        port_owner_exhausted: false
    }
  end

  defp finalize_release(state) do
    state = signal_cancel(state)
    state = await_phase_exit(state)

    case cleanup_workspace(state) do
      :ok ->
        {:stop, :normal, :ok, %{state | released: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | released: false, locked: true}}
    end
  end

  # A port owner was registered for the current cycle but exhaustion was never
  # proven (no ack, and the fallback re-containment attempt -- if one ran --
  # failed too): retain the workspace identity, never touch the filesystem,
  # and never report success.
  defp cleanup_workspace(%{port_owner_registered: true, port_owner_exhausted: exhausted} = state)
       when exhausted != true do
    parent = state.roots.parent

    {:error,
     {:cleanup_retained, :exhaustion_unproven,
      %{
        path: parent.path,
        device: parent.device,
        minor_device: parent.minor_device,
        inode: parent.inode
      }}}
  end

  defp cleanup_workspace(%{fault: :force_cleanup_failure} = state) do
    parent = state.roots.parent

    {:error,
     {:cleanup_retained, :forced_cleanup_failure,
      %{
        path: parent.path,
        device: parent.device,
        minor_device: parent.minor_device,
        inode: parent.inode
      }}}
  end

  defp cleanup_workspace(state) do
    parent = state.roots.parent
    identity = Map.take(parent, [:path, :type, :device, :minor_device, :inode])

    case OwnedTree.remove(identity) do
      :ok ->
        case OwnedTreeRegistry.delete(identity) do
          :ok -> :ok
          {:error, :owned_tree_not_registered} -> :ok
          {:error, :owned_tree_registry_unavailable} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error,
         {:cleanup_retained, reason,
          %{
            path: identity.path,
            device: identity.device,
            minor_device: identity.minor_device,
            inode: identity.inode
          }}}
    end
  end

  defp render_view(state) do
    %{
      "schema" => "arbor.shell.trusted_build.lease.v1",
      "state" => view_state(state),
      "completed_phases" => Enum.map(state.completed, &Atom.to_string/1),
      "locked" => state.locked
    }
  end

  defp view_state(%{released: true}), do: "released"
  defp view_state(%{locked: true}), do: "locked"
  defp view_state(%{done: true}), do: "done"
  defp view_state(%{in_flight: phase}) when not is_nil(phase), do: "running"
  defp view_state(_state), do: "ready"

  defp call(%Handle{token: token, worker: worker, owner: owner}, request) do
    if self() != owner do
      {:error, :foreign_caller}
    else
      GenServer.call(worker, {:owner_request, token, request})
    end
  catch
    :exit, _ -> {:error, :invalid_lease}
  end

  defp phase_call(lease_pid, request) do
    GenServer.call(lease_pid, request)
  catch
    :exit, _ -> {:error, :invalid_lease}
  end

  defp port_owner_call(lease_pid, request) do
    GenServer.call(lease_pid, request)
  catch
    :exit, _ -> {:error, :invalid_lease}
  end
end
