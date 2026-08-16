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

  alias Arbor.Shell.OwnedTree
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.TrustedBuild.Inventory
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @supervisor Arbor.Shell.TrustedBuild.LeaseSupervisor
  @token_bytes 32
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

  @spec finish_phase(Handle.t(), map(), term()) :: :ok | {:error, term()}
  def finish_phase(%Handle{} = lease, session, result) when is_map(session) do
    call(lease, {:finish_phase, session, result})
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
       released: false
     }}
  end

  @impl true
  def handle_call(:view, {caller, _}, state) do
    if caller == state.owner do
      {:reply, {:ok, render_view(state)}, state}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:begin_phase, phase, caller}, {caller, _}, state) do
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

  def handle_call({:begin_phase, _phase, _caller}, _from, state) do
    {:reply, {:error, :foreign_caller}, state}
  end

  def handle_call({:attach_phase, phase_pid}, {caller, _}, state) do
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

  def handle_call({:finish_phase, session, result}, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      state.in_flight == nil ->
        {:reply, {:error, :trusted_build_phase_not_started}, state}

      session[:cancel_id] != state.cancel_id ->
        {:reply, {:error, :invalid_trusted_build_session}, state}

      true ->
        {:reply, :ok, complete_phase(state, result)}
    end
  end

  def handle_call(:inventory_release, {caller, _}, state) do
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

  def handle_call({:reserved, op}, {caller, _}, state) when op in @reserved_ops do
    if caller == state.owner do
      {:reply, {:error, :trusted_build_op_reserved}, state}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call(:cancel_in_flight, _from, state) do
    {:reply, :ok, signal_cancel(state)}
  end

  def handle_call(:release, {caller, _}, state) do
    if caller == state.owner do
      finalize_release(state)
    else
      {:reply, {:error, :foreign_release}, state}
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :invalid_trusted_build_lease_op}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      ref == state.owner_ref and pid == state.owner ->
        state = signal_cancel(state)
        _ = await_phase_exit(state)
        _ = cleanup_workspace(state)
        {:stop, :normal, %{state | released: true, locked: true}}

      ref == state.phase_ref and pid == state.phase_pid ->
        {:noreply, lock_after_phase_loss(state)}

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
      _ = await_phase_exit(state)
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

      session = %{
        lease_pid: self(),
        owner_pid: state.owner,
        authority_pid: authority_pid,
        authority_gen: generation,
        registry_pid: registry_pid,
        registry_gen: registry_gen,
        cancel_id: cancel_id,
        phase: phase,
        argv: Plan.argv(phase),
        timeout_ms: Plan.timeout_ms(phase),
        identities: state.identities,
        roots: state.roots,
        binding: binding
      }

      next = %{state | in_flight: phase, cancel_id: cancel_id, binding: binding}
      {:ok, session, next}
    else
      false ->
        {:error, :trusted_build_toolchain_generation_mismatch, %{state | locked: true}}

      {:error, reason} ->
        {:error, reason, %{state | locked: true}}
    end
  end

  defp complete_phase(state, result) do
    state = demonitor_phase(state)

    case result do
      {:ok, %{exit_code: 0, timed_out: false, killed: false}} ->
        completed = state.completed ++ [state.in_flight]

        %{
          state
          | completed: completed,
            in_flight: nil,
            cancel_id: nil,
            done: completed == [:deps_get, :compile, :release]
        }

      _other ->
        %{state | in_flight: nil, cancel_id: nil, locked: true}
    end
  end

  defp lock_after_phase_loss(state) do
    %{
      state
      | locked: true,
        in_flight: nil,
        phase_pid: nil,
        phase_ref: nil,
        cancel_id: nil
    }
  end

  defp signal_cancel(%{cancel_id: cancel_id, phase_pid: phase_pid} = state) do
    if is_reference(cancel_id) do
      send(self(), {:cancel_shell_execution, cancel_id})

      if is_pid(phase_pid) do
        send(phase_pid, {:cancel_shell_execution, cancel_id})
      end
    end

    state
  end

  defp await_phase_exit(%{phase_pid: pid, phase_ref: ref}) when is_pid(pid) do
    if Process.alive?(pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          Process.exit(pid, :kill)
          :ok
      end
    else
      :ok
    end
  end

  defp await_phase_exit(_state), do: :ok

  defp demonitor_phase(%{phase_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | phase_pid: nil, phase_ref: nil}
  end

  defp demonitor_phase(state), do: %{state | phase_pid: nil, phase_ref: nil}

  defp finalize_release(state) do
    state = signal_cancel(state)
    _ = await_phase_exit(state)

    case cleanup_workspace(state) do
      :ok ->
        {:stop, :normal, :ok, %{state | released: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | released: false, locked: true}}
    end
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
      GenServer.call(worker, request)
    end
  catch
    :exit, _ -> {:error, :invalid_lease}
  after
    _ = token
  end
end
