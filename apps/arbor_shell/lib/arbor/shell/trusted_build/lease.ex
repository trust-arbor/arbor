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

  alias Arbor.Common.SafePath
  alias Arbor.Shell.Executor
  alias Arbor.Shell.OwnedTree
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.TrustedBuild.FallbackOwner
  alias Arbor.Shell.TrustedBuild.Inventory
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuild.PostPhase
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @fallback_kill_grace_ms 2_000
  @fallback_timeout_ms 3_000
  @cleanup_retry_ms 1_000
  @max_cleanup_attempts 8

  @supervisor Arbor.Shell.TrustedBuild.LeaseSupervisor

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

  @spec inventory_release(Handle.t()) :: {:ok, map()} | {:error, term()}
  def inventory_release(%Handle{} = lease), do: call(lease, :inventory_release)

  @spec release_root(Handle.t()) :: {:ok, String.t()} | {:error, term()}
  def release_root(%Handle{} = lease), do: call(lease, :release_root)

  @spec stage_native(Handle.t()) :: {:ok, map()} | {:error, term()}
  def stage_native(%Handle{} = lease), do: call(lease, :stage_native_cache)

  @spec inventory_deps(Handle.t()) :: {:ok, map()} | {:error, term()}
  def inventory_deps(%Handle{} = lease), do: call(lease, :inventory_deps)

  @spec remove_release_cookie(Handle.t()) :: {:ok, map()} | {:error, term()}
  def remove_release_cookie(%Handle{} = lease), do: call(lease, :remove_release_cookie)

  @spec read_descriptor(Handle.t(), term()) :: {:ok, map()} | {:error, term()}
  def read_descriptor(%Handle{} = lease, selector),
    do: call(lease, {:read_descriptor, selector})

  @spec abort_unattached_phase(Handle.t()) :: :ok | {:error, term()}
  def abort_unattached_phase(%Handle{} = lease), do: call(lease, :abort_unattached_phase)

  @spec release(Handle.t()) :: :ok | {:error, term()}
  def release(%Handle{} = lease), do: call(lease, :release)

  @spec cancel_in_flight(Handle.t()) :: :ok
  def cancel_in_flight(%Handle{} = lease) do
    _ = call(lease, :cancel_in_flight)
    :ok
  end

  @spec checkout_launch(pid(), reference()) :: {:ok, map()} | {:error, term()}
  def checkout_launch(lease_pid, launch_ticket)
      when is_pid(lease_pid) and is_reference(launch_ticket) do
    phase_call(lease_pid, {:checkout_launch, launch_ticket})
  end

  @spec take_launch(pid(), reference()) :: {:ok, map()} | {:error, term()}
  def take_launch(lease_pid, launch_permit)
      when is_pid(lease_pid) and is_reference(launch_permit) do
    port_owner_call(lease_pid, {:take_launch, launch_permit})
  end

  @spec register_port_owner(pid(), pid()) :: :ok | {:error, term()}
  def register_port_owner(lease_pid, owner_pid) when is_pid(lease_pid) and is_pid(owner_pid) do
    phase_call(lease_pid, {:register_port_owner, owner_pid})
  end

  @spec commit_phase_result(pid(), term()) :: :ok | {:error, term()}
  def commit_phase_result(lease_pid, result) when is_pid(lease_pid) do
    phase_call(lease_pid, {:commit_phase_result, result})
  end

  @spec checkout_fallback(pid(), reference()) :: {:ok, map()} | {:error, term()}
  def checkout_fallback(lease_pid, permit)
      when is_pid(lease_pid) and is_reference(permit) do
    port_owner_call(lease_pid, {:checkout_fallback, permit})
  end

  def checkout_fallback(_lease_pid, _permit), do: {:error, :trusted_build_launch_unauthorized}

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
       owner_dead: false,
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
       launch_permit: nil,
       launch_descriptor: nil,
       launch_released: false,
       fallback_used: false,
       fallback_pending: false,
       fallback_pid: nil,
       fallback_ref: nil,
       fallback_permit: nil,
       fallback_claimed: false,
       fallback_descriptor: nil,
       fallback_timer: nil,
       port_owner_pid: nil,
       port_owner_ref: nil,
       port_owner_group_id: nil,
       port_owner_registered: false,
       port_owner_exhausted: false,
       release_from: nil,
       workspace_cleaned: false,
       source_unbound: false,
       cleanup_attempts: 0,
       cleanup_dormant: false,
       cleanup_timer: nil,
       cleanup_reason: nil,
       cleanup_attested: false,
       cleanup_attestation_reason: nil,
       released: false,
       native_staged: false,
       deps_inventory: nil,
       cookie_removed: false,
       release_inventory: nil
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

      state.launch_released != true ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      state.launch_ticket != launch_ticket ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      true ->
        permit = make_ref()
        descriptor = Map.put(build_launch_descriptor(state), :launch_permit, permit)

        {:reply, {:ok, descriptor},
         %{
           state
           | launch_ticket: :consumed,
             launch_permit: permit,
             launch_descriptor: descriptor
         }}
    end
  end

  def handle_call({:take_launch, launch_permit}, {caller, _}, state) do
    cond do
      caller != state.port_owner_pid or not is_pid(state.port_owner_pid) ->
        {:reply, {:error, :foreign_caller}, state}

      state.launch_permit != launch_permit or not is_reference(launch_permit) ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      not is_map(state.launch_descriptor) ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      true ->
        {:reply, {:ok, state.launch_descriptor}, %{state | launch_permit: :consumed}}
    end
  end

  def handle_call({:checkout_fallback, permit}, {caller, _}, state) do
    cond do
      caller != state.fallback_pid or not is_pid(state.fallback_pid) ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      state.fallback_claimed == true ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      state.fallback_permit != permit or not is_reference(permit) ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      not is_map(state.fallback_descriptor) ->
        {:reply, {:error, :trusted_build_launch_unauthorized}, state}

      true ->
        {:reply, {:ok, state.fallback_descriptor}, %{state | fallback_claimed: true}}
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

      success_result?(result) and state.port_owner_exhausted != true ->
        {:reply, {:error, :trusted_build_exhaustion_unproven}, lock_without_reset(state, result)}

      true ->
        case complete_phase(state, result) do
          {:ok, next} -> reply_after_phase(:ok, next)
          {:error, reason, next} -> reply_after_phase({:error, reason}, next)
        end
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :invalid_trusted_build_lease_op}, state}
  end

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
        send(phase_pid, {:trusted_build_phase_go, state.launch_ticket})

        next = %{state | phase_pid: phase_pid, phase_ref: ref, launch_released: true}
        {:reply, :ok, next}
    end
  end

  defp dispatch_owner_request(:release_root, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      not state.done or state.cookie_removed != true or not is_map(state.release_inventory) ->
        {:reply, {:error, :trusted_build_release_absent}, state}

      true ->
        {:reply, pin_release_root(state), state}
    end
  end

  defp dispatch_owner_request(:inventory_release, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      state.locked ->
        {:reply, {:error, :trusted_build_phase_locked}, state}

      not state.done or state.cookie_removed != true ->
        {:reply, {:error, :trusted_build_release_absent}, state}

      is_map(state.release_inventory) ->
        {:reply, {:ok, state.release_inventory}, state}

      true ->
        finish_release_inventory(state)
    end
  end

  defp dispatch_owner_request(:stage_native_cache, {caller, _}, state) do
    run_post_phase(state, caller, :stage_native_cache, fn admitted ->
      cond do
        admitted.completed != [:deps_get] ->
          {:error, :trusted_build_phase_rejected, admitted}

        is_map(admitted.native_staged) ->
          {:error, :trusted_build_op_repeat, admitted}

        true ->
          case PostPhase.stage(admitted) do
            {:ok, evidence, dest} -> {:ok, evidence, %{admitted | native_staged: dest}}
            {:error, reason} -> {:error, reason, admitted}
            {:lock, reason} -> {:error, reason, %{admitted | locked: true}}
          end
      end
    end)
  end

  defp dispatch_owner_request(:inventory_deps, {caller, _}, state) do
    run_post_phase(state, caller, :inventory_deps, fn admitted ->
      cond do
        not is_map(admitted.native_staged) ->
          {:error, :trusted_build_phase_rejected, admitted}

        is_map(admitted.deps_inventory) ->
          {:error, :trusted_build_op_repeat, admitted}

        true ->
          case PostPhase.rescan_deps_document(admitted) do
            {:ok, document} ->
              {:ok, document, %{admitted | deps_inventory: document}}

            {:error, reason} ->
              {:error, reason, %{admitted | locked: true}}
          end
      end
    end)
  end

  defp dispatch_owner_request(:remove_release_cookie, {caller, _}, state) do
    run_post_phase(state, caller, :remove_release_cookie, fn admitted ->
      cond do
        not admitted.done ->
          {:error, :trusted_build_phase_rejected, admitted}

        admitted.cookie_removed ->
          {:error, :trusted_build_op_repeat, admitted}

        true ->
          case PostPhase.remove_cookie(admitted) do
            {:ok, evidence} -> {:ok, evidence, %{admitted | cookie_removed: true}}
            {:error, reason} -> {:error, reason, admitted}
            {:lock, reason} -> {:error, reason, %{admitted | locked: true}}
          end
      end
    end)
  end

  defp dispatch_owner_request({:read_descriptor, selector}, {caller, _}, state) do
    run_post_phase(state, caller, :read_descriptor, fn admitted ->
      if is_map(admitted.release_inventory) do
        case PostPhase.read_descriptor(admitted, selector) do
          {:ok, evidence} -> {:ok, evidence, admitted}
          {:error, reason} -> {:error, reason, admitted}
          {:lock, reason} -> {:error, reason, %{admitted | locked: true}}
        end
      else
        {:error, :trusted_build_release_absent, admitted}
      end
    end)
  end

  defp dispatch_owner_request(:abort_unattached_phase, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      is_pid(state.phase_pid) ->
        {:reply, {:error, :trusted_build_phase_in_flight}, state}

      state.in_flight == nil ->
        {:reply, {:error, :trusted_build_phase_not_started}, state}

      true ->
        {:reply, :ok,
         %{
           state
           | in_flight: nil,
             cancel_id: nil,
             launch_ticket: nil,
             launch_permit: nil,
             launch_descriptor: nil,
             launch_released: false,
             locked: true
         }}
    end
  end

  defp dispatch_owner_request(:cancel_in_flight, _from, state) do
    {:reply, :ok, signal_cancel(state)}
  end

  defp dispatch_owner_request(:release, {caller, _} = from, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_release}, state}

      is_tuple(state.release_from) ->
        {:reply, {:error, :trusted_build_release_in_flight}, state}

      true ->
        state = signal_cancel(state)

        if children_pending?(state) do
          {:noreply, %{state | release_from: from}}
        else
          finish_release_call(state)
        end
    end
  end

  defp dispatch_owner_request(_request, _from, state) do
    {:reply, {:error, :invalid_trusted_build_lease_op}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      ref == state.owner_ref and pid == state.owner ->
        state = signal_cancel(%{state | owner_dead: true})
        maybe_settle(state)

      ref == state.phase_ref and pid == state.phase_pid ->
        maybe_settle(lock_after_phase_loss(state))

      ref == state.port_owner_ref and pid == state.port_owner_pid ->
        maybe_settle(handle_port_owner_loss(state))

      ref == state.fallback_ref and pid == state.fallback_pid ->
        maybe_settle(handle_fallback_down(state))

      ref == state.authority_ref or ref == state.registry_ref ->
        {:noreply, signal_cancel(%{state | locked: true})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:trusted_build_fallback_done, pid, permit, result}, state) do
    if pid == state.fallback_pid and matching_fallback_permit?(state, permit) do
      maybe_settle(complete_fallback(state, result))
    else
      {:noreply, state}
    end
  end

  def handle_info({:trusted_build_fallback_timeout, permit}, state) do
    if matching_fallback_permit?(state, permit) and state.fallback_pending do
      maybe_settle(fail_fallback(state))
    else
      {:noreply, state}
    end
  end

  def handle_info(:trusted_build_cleanup_retry, state) do
    state = %{state | cleanup_timer: nil}

    cond do
      state.cleanup_dormant ->
        {:noreply, state}

      children_pending?(state) ->
        {:noreply, state}

      true ->
        maybe_settle(state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = cancel_all_timers(state)

    if not state.released and not children_pending?(state) do
      _ = signal_cancel(state)
      _ = advance_cleanup(state)
    else
      _ = signal_cancel(state)
    end

    :ok
  end

  defp run_post_phase(state, caller, _op, fun) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :foreign_caller}, state}

      state.released or state.locked ->
        {:reply, {:error, :trusted_build_phase_locked}, state}

      state.in_flight != nil ->
        {:reply, {:error, :trusted_build_phase_in_flight}, state}

      true ->
        case admit_post_phase(state) do
          {:ok, admitted} ->
            case fun.(admitted) do
              {:ok, evidence, next} -> {:reply, {:ok, evidence}, next}
              {:error, reason, next} -> {:reply, {:error, reason}, next}
            end

          {:error, reason, next} ->
            {:reply, {:error, reason}, next}
        end
    end
  end

  defp admit_post_phase(state) do
    with :ok <- PostPhase.verify_pinned_source_tree(state.identities),
         :ok <- checkout_generations(state) do
      {:ok, state}
    else
      {:error, reason} ->
        {:error, reason, %{state | locked: true}}
    end
  end

  defp checkout_generations(state) do
    with {:ok, _binding, authority_pid, generation} <-
           TrustedBuildToolchainAuthority.checkout_generation(
             state.authority_pid,
             state.authority_gen
           ),
         {:ok, registry_pid, registry_gen} <- OwnedTreeRegistry.checkout(),
         true <- authority_pid == state.authority_pid and generation == state.authority_gen,
         true <- registry_pid == state.registry_pid and registry_gen == state.registry_gen do
      :ok
    else
      false -> {:error, :trusted_build_toolchain_generation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_release_inventory(state) do
    case admit_post_phase(state) do
      {:ok, admitted} ->
        retain_release_inventory(admitted)

      {:error, reason, next} ->
        {:reply, {:error, reason}, next}
    end
  end

  defp retain_release_inventory(state) do
    case cleanup_deps_attestation(state) do
      :ok -> scan_release_inventory(state)
      {:error, reason} -> {:reply, {:error, reason}, %{state | locked: true}}
    end
  end

  defp scan_release_inventory(state) do
    case PostPhase.scan_release_document(state) do
      {:ok, document} -> retain_release_document(state, document)
      {:error, reason} -> {:reply, {:error, reason}, %{state | locked: true}}
    end
  end

  defp retain_release_document(state, document) do
    if Inventory.cookie_present?(document) do
      {:reply, {:error, :trusted_build_cookie_replacement}, %{state | locked: true}}
    else
      {:reply, {:ok, document}, %{state | release_inventory: document}}
    end
  end

  defp compare_deps_inventory(%{deps_inventory: nil}), do: :ok

  defp compare_deps_inventory(%{deps_inventory: retained} = state) do
    case PostPhase.rescan_deps_document(state) do
      {:ok, ^retained} -> :ok
      {:ok, _other} -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_phase(state, phase) do
    case Plan.admit_order(phase, state.completed) do
      # Plan.admit_order policy rejection is recoverable; later identity,
      # registry, generation, and launch integrity failures still lock.
      {:error, :trusted_build_phase_rejected} ->
        {:error, :trusted_build_phase_rejected, state}

      :ok ->
        with :ok <- PostPhase.verify_pinned_source_tree(state.identities),
             :ok <- compile_and_deps_gate(phase, state),
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
              launch_permit: nil,
              launch_descriptor: nil,
              launch_released: false,
              fallback_used: false,
              fallback_pending: false,
              fallback_pid: nil,
              fallback_ref: nil,
              fallback_permit: nil,
              fallback_claimed: false,
              fallback_descriptor: nil,
              binding: binding
          }

          {:ok, session, next}
        else
          {:error, :trusted_build_phase_rejected} ->
            {:error, :trusted_build_phase_rejected, state}

          false ->
            {:error, :trusted_build_toolchain_generation_mismatch, %{state | locked: true}}

          {:error, reason} ->
            {:error, reason, %{state | locked: true}}
        end
    end
  end

  defp compile_and_deps_gate(:compile, state) do
    if is_map(state.native_staged) and is_map(state.deps_inventory) do
      compare_deps_inventory(state)
    else
      {:error, :trusted_build_phase_rejected}
    end
  end

  defp compile_and_deps_gate(:release, _state), do: :ok
  defp compile_and_deps_gate(_phase, _state), do: :ok

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
      project: identities.project,
      overlay: identities.overlay,
      source_tree_digest: identities.source_tree_digest,
      native_staged: state.native_staged,
      phase: phase,
      erlang_root: binding.erlang_root,
      elixir_root: binding.elixir_root,
      archives: identities.archives,
      archives_digest: identities.archives_digest,
      roots: Map.put(roots, :archives, identities.archives),
      env: Plan.closed_env(roots, binding),
      argv: Plan.argv(phase),
      timeout_ms: phase_timeout_ms(state, phase),
      max_output_bytes: phase_max_output_bytes(state),
      cancel_id: state.cancel_id,
      fault: state.fault
    }
  end

  defp phase_timeout_ms(%{fault: :force_phase_timeout}, _phase), do: 1
  defp phase_timeout_ms(_state, phase), do: Plan.timeout_ms(phase)

  defp phase_max_output_bytes(%{fault: :force_output_overflow}), do: 32
  defp phase_max_output_bytes(_state), do: Executor.default_max_output_bytes()

  defp success_result?({:ok, %{exit_code: 0, timed_out: false, killed: false}}), do: true
  defp success_result?(_result), do: false

  defp complete_phase(state, result) do
    if success_result?(result) do
      case after_mix_success(state) do
        :ok ->
          state = demonitor_phase(state)
          state = reset_port_owner(demonitor_port_owner_ref(state))
          completed = state.completed ++ [state.in_flight]

          {:ok,
           clear_launch(%{
             state
             | completed: completed,
               in_flight: nil,
               cancel_id: nil,
               done: completed == [:deps_get, :compile, :release]
           })}

        {:error, reason} ->
          {:error, reason, lock_without_reset(state, result)}
      end
    else
      {:ok, lock_without_reset(state, result)}
    end
  end

  defp after_mix_success(%{fault: :force_source_overlay_drift_after_mix} = state) do
    _ = drift_pinned_overlay(state)
    verify_after_mix(state)
  end

  defp after_mix_success(state), do: verify_after_mix(state)

  # Source must stay frozen after every Mix phase. The deps tree is a writable
  # sandbox root: `deps.get` plus native compilers (elixir_make, sqlite_vec,
  # exqlite) write into it. Inventory equality is enforced at compile *start*
  # (`compile_and_deps_gate/2`) so the two-build compare stays meaningful;
  # requiring it again after compile/release rejects a legitimate Mix.
  defp verify_after_mix(%{in_flight: phase} = state) when phase in [:compile, :release] do
    PostPhase.verify_pinned_source_tree(state.identities)
  end

  defp verify_after_mix(state) do
    with :ok <- PostPhase.verify_pinned_source_tree(state.identities) do
      compare_deps_inventory(state)
    end
  end

  defp drift_pinned_overlay(%{identities: %{overlay: %{path: path, size: size}}})
       when is_binary(path) and is_integer(size) and size > 0 do
    File.write(path, :binary.copy(<<1>>, size))
  end

  defp drift_pinned_overlay(_state), do: :ok

  defp lock_without_reset(state, _result) do
    state = demonitor_phase(state)

    clear_launch(%{
      state
      | in_flight: nil,
        cancel_id: nil,
        locked: true
    })
  end

  defp lock_after_phase_loss(%{in_flight: nil} = state) do
    %{state | phase_pid: nil, phase_ref: nil}
  end

  defp lock_after_phase_loss(state) do
    state = signal_cancel(state)

    clear_launch(%{
      state
      | locked: true,
        in_flight: nil,
        phase_pid: nil,
        phase_ref: nil,
        cancel_id: nil
    })
  end

  defp handle_port_owner_loss(%{port_owner_exhausted: true} = state) do
    %{state | port_owner_pid: nil, port_owner_ref: nil}
  end

  defp handle_port_owner_loss(
         %{
           port_owner_registered: true,
           port_owner_group_id: group_id,
           fallback_used: false
         } = state
       )
       when is_integer(group_id) and group_id > 0 do
    spawn_fallback(%{state | port_owner_pid: nil, port_owner_ref: nil})
  end

  defp handle_port_owner_loss(%{port_owner_registered: true} = state) do
    %{state | port_owner_pid: nil, port_owner_ref: nil, locked: true}
  end

  defp handle_port_owner_loss(state) do
    %{state | port_owner_pid: nil, port_owner_ref: nil}
  end

  defp spawn_fallback(state) do
    lease_pid = self()
    state = %{state | fallback_used: true}
    pid = spawn(fn -> FallbackOwner.run(lease_pid) end)
    ref = Process.monitor(pid)
    permit = make_ref()
    descriptor = build_fallback_descriptor(state)

    timer =
      Process.send_after(self(), {:trusted_build_fallback_timeout, permit}, @fallback_timeout_ms)

    send(pid, {:trusted_build_fallback_go, permit})

    %{
      state
      | fallback_pending: true,
        fallback_pid: pid,
        fallback_ref: ref,
        fallback_permit: permit,
        fallback_claimed: false,
        fallback_descriptor: descriptor,
        fallback_timer: timer
    }
  end

  defp build_fallback_descriptor(state) do
    %{
      launcher: pinned_launcher_path(),
      group_id: state.port_owner_group_id,
      grace_ms: @fallback_kill_grace_ms,
      fault: state.fault
    }
  end

  defp pinned_launcher_path do
    case :code.priv_dir(:arbor_shell) do
      path when is_list(path) ->
        Path.join(List.to_string(path), "arbor_shell_launcher")

      _other ->
        ""
    end
  end

  defp matching_fallback_permit?(state, permit) do
    is_reference(permit) and permit == state.fallback_permit
  end

  defp complete_fallback(state, :ok) do
    state = cancel_fallback_timer(state)

    %{
      state
      | port_owner_exhausted: true,
        fallback_pending: false,
        fallback_pid: nil,
        fallback_ref: demonitor_ref(state.fallback_ref),
        fallback_permit: nil,
        fallback_claimed: true,
        fallback_descriptor: nil
    }
  end

  defp complete_fallback(state, _result), do: fail_fallback(state)

  defp handle_fallback_down(%{fallback_pending: true} = state), do: fail_fallback(state)

  defp handle_fallback_down(state) do
    %{state | fallback_pid: nil, fallback_ref: nil}
  end

  defp fail_fallback(state) do
    state = cancel_fallback_timer(state)
    _ = demonitor_ref(state.fallback_ref)

    %{
      state
      | locked: true,
        fallback_pending: false,
        fallback_pid: nil,
        fallback_ref: nil,
        fallback_permit: nil,
        fallback_claimed: true,
        fallback_descriptor: nil
    }
  end

  defp cancel_fallback_timer(%{fallback_timer: timer} = state) when is_reference(timer) do
    flush_timer(timer, {:trusted_build_fallback_timeout, :any})
    %{state | fallback_timer: nil}
  end

  defp cancel_fallback_timer(state), do: state

  defp demonitor_ref(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    nil
  end

  defp demonitor_ref(_ref), do: nil

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

  defp children_pending?(state) do
    is_pid(state.phase_pid) or is_pid(state.port_owner_pid) or state.fallback_pending == true
  end

  defp maybe_settle(state) do
    cond do
      children_pending?(state) ->
        {:noreply, state}

      is_tuple(state.release_from) ->
        settle_release(state)

      state.owner_dead ->
        settle_owner_death(state)

      true ->
        {:noreply, maybe_schedule_retry(state)}
    end
  end

  defp reply_after_phase(reply, %{owner_dead: true} = state) do
    case maybe_settle(state) do
      {:noreply, next} -> {:reply, reply, next}
      {:stop, reason, next} -> {:stop, reason, reply, next}
    end
  end

  defp reply_after_phase(reply, state), do: {:reply, reply, state}

  defp finish_release_call(state) do
    {state, result} = advance_cleanup(state)

    case result do
      :ok ->
        {:stop, :normal, :ok, mark_released(state)}

      {:error, reason} ->
        if cleanup_complete?(state) do
          {:stop, :normal, {:error, reason}, mark_released(%{state | locked: true})}
        else
          {:reply, {:error, reason},
           maybe_schedule_retry(%{state | locked: true, released: false})}
        end
    end
  end

  defp settle_release(state) do
    from = state.release_from
    {state, result} = advance_cleanup(%{state | release_from: nil})

    case result do
      :ok ->
        GenServer.reply(from, :ok)
        {:stop, :normal, mark_released(state)}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})

        if cleanup_complete?(state) do
          {:stop, :normal, mark_released(%{state | locked: true})}
        else
          {:noreply, maybe_schedule_retry(%{state | locked: true, released: false})}
        end
    end
  end

  defp settle_owner_death(state) do
    {state, result} = advance_cleanup(state)

    case result do
      :ok ->
        {:stop, :normal, mark_released(state)}

      {:error, _reason} ->
        if cleanup_complete?(state) do
          {:stop, :normal, mark_released(%{state | locked: true})}
        else
          {:noreply, maybe_schedule_retry(%{state | locked: true, released: false})}
        end
    end
  end

  defp maybe_schedule_retry(state) do
    cond do
      state.workspace_cleaned and state.source_unbound ->
        state

      state.cleanup_dormant ->
        state

      is_reference(state.cleanup_timer) ->
        state

      true ->
        attempts = state.cleanup_attempts + 1

        if attempts >= @max_cleanup_attempts do
          %{state | cleanup_attempts: attempts, cleanup_dormant: true, locked: true}
        else
          timer = Process.send_after(self(), :trusted_build_cleanup_retry, @cleanup_retry_ms)
          %{state | cleanup_attempts: attempts, cleanup_timer: timer, locked: true}
        end
    end
  end

  defp advance_cleanup(state) do
    state =
      state
      |> maybe_attest_cleanup()
      |> maybe_clean_workspace()
      |> maybe_unbind_source()

    cond do
      cleanup_complete?(state) and not is_nil(state.cleanup_attestation_reason) ->
        {state,
         {:error, {:trusted_build_cleanup_attestation_failed, state.cleanup_attestation_reason}}}

      cleanup_complete?(state) ->
        {state, :ok}

      true ->
        {state,
         {:error,
          {:cleanup_retained, state.cleanup_reason || :incomplete, cleanup_evidence(state)}}}
    end
  end

  defp maybe_attest_cleanup(%{cleanup_attestation_reason: reason} = state)
       when not is_nil(reason),
       do: state

  # Freeze the successful pre-cleanup attestation before the first destructive
  # removal step. OwnedTree removal is progressive, so a retry cannot distinguish
  # Arbor's own partial deletion from external drift.
  defp maybe_attest_cleanup(%{cleanup_attested: true} = state), do: state

  defp maybe_attest_cleanup(state) do
    with :ok <- PostPhase.verify_pinned_source_tree(state.identities),
         :ok <- verify_staged_native_for_cleanup(state),
         :ok <- cleanup_deps_attestation(state) do
      %{state | cleanup_attested: true}
    else
      {:error, reason} ->
        %{state | locked: true, cleanup_attestation_reason: reason}
    end
  end

  # Compile may write into the writable deps root. Once compile has completed,
  # the pre-compile inventory is no longer an after-the-fact pin.
  defp cleanup_deps_attestation(%{completed: completed} = state) do
    if :compile in completed do
      :ok
    else
      compare_deps_inventory(state)
    end
  end

  defp verify_staged_native_for_cleanup(%{native_staged: dest} = state) when is_map(dest),
    do: PostPhase.verify_staged_native(state)

  defp verify_staged_native_for_cleanup(_state), do: :ok

  defp cleanup_complete?(state), do: state.workspace_cleaned and state.source_unbound

  defp maybe_clean_workspace(%{workspace_cleaned: true} = state), do: state

  defp maybe_clean_workspace(%{fault: :force_cleanup_failure} = state) do
    %{state | cleanup_reason: :forced_cleanup_failure, locked: true}
  end

  defp maybe_clean_workspace(
         %{port_owner_registered: true, port_owner_exhausted: exhausted} = state
       )
       when exhausted != true do
    %{state | cleanup_reason: :exhaustion_unproven, locked: true}
  end

  defp maybe_clean_workspace(state) do
    parent = state.roots.parent
    identity = Map.take(parent, [:path, :type, :device, :minor_device, :inode])

    case OwnedTree.remove(identity) do
      :ok ->
        _ = OwnedTreeRegistry.delete(identity)
        %{state | workspace_cleaned: true, cleanup_reason: nil}

      {:error, reason} ->
        %{state | cleanup_reason: reason, locked: true}
    end
  end

  defp maybe_unbind_source(%{source_unbound: true} = state), do: state
  defp maybe_unbind_source(%{workspace_cleaned: false} = state), do: state

  defp maybe_unbind_source(state) do
    source = state.identities.source_owned

    case OwnedTreeRegistry.fetch(source) do
      {:ok, :unbound, gen} when gen == state.registry_gen ->
        %{state | source_unbound: true, cleanup_reason: nil}

      {:ok, :trusted_build_source, gen} when gen == state.registry_gen ->
        cas_unbind_source(state, source)

      {:ok, _purpose, _gen} ->
        %{state | cleanup_reason: :owned_tree_purpose_mismatch, locked: true}

      {:error, :owned_tree_not_registered} ->
        prove_source_absent(state, source)

      {:error, reason} ->
        %{state | cleanup_reason: reason, locked: true}
    end
  end

  defp cas_unbind_source(state, source) do
    case OwnedTreeRegistry.cas(source, :trusted_build_source, :unbound) do
      :ok ->
        %{state | source_unbound: true, cleanup_reason: nil}

      {:error, :owned_tree_purpose_mismatch} ->
        case OwnedTreeRegistry.fetch(source) do
          {:ok, :unbound, gen} when gen == state.registry_gen ->
            %{state | source_unbound: true, cleanup_reason: nil}

          {:error, reason} ->
            %{state | cleanup_reason: reason, locked: true}

          _other ->
            %{state | cleanup_reason: :owned_tree_purpose_mismatch, locked: true}
        end

      {:error, reason} ->
        %{state | cleanup_reason: reason, locked: true}
    end
  end

  defp prove_source_absent(state, source) do
    case File.lstat(source.path, time: :posix) do
      {:error, :enoent} ->
        %{state | source_unbound: true, cleanup_reason: nil}

      {:ok, %File.Stat{type: :directory}} ->
        %{state | cleanup_reason: :owned_tree_not_registered, locked: true}

      {:ok, %File.Stat{}} ->
        %{state | cleanup_reason: :owned_tree_not_registered, locked: true}

      {:error, reason} ->
        %{state | cleanup_reason: reason, locked: true}
    end
  end

  defp mark_released(state) do
    cancel_all_timers(%{state | released: true})
  end

  defp cancel_all_timers(state) do
    state
    |> cancel_fallback_timer()
    |> cancel_cleanup_timer()
  end

  defp cancel_cleanup_timer(%{cleanup_timer: timer} = state) when is_reference(timer) do
    flush_timer(timer, :trusted_build_cleanup_retry)
    %{state | cleanup_timer: nil}
  end

  defp cancel_cleanup_timer(state), do: state

  defp flush_timer(timer, :trusted_build_cleanup_retry) do
    case Process.cancel_timer(timer) do
      false ->
        receive do
          :trusted_build_cleanup_retry -> :ok
        after
          0 -> :ok
        end

      _ms ->
        :ok
    end
  end

  defp flush_timer(timer, {:trusted_build_fallback_timeout, _}) do
    case Process.cancel_timer(timer) do
      false ->
        receive do
          {:trusted_build_fallback_timeout, _permit} -> :ok
        after
          0 -> :ok
        end

      _ms ->
        :ok
    end
  end

  defp cleanup_evidence(state) do
    parent = state.roots.parent

    %{
      path: parent.path,
      device: parent.device,
      minor_device: parent.minor_device,
      inode: parent.inode
    }
  end

  defp clear_launch(state) do
    %{
      state
      | launch_ticket: nil,
        launch_permit: nil,
        launch_descriptor: nil,
        launch_released: false
    }
  end

  defp demonitor_phase(%{phase_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | phase_pid: nil, phase_ref: nil}
  end

  defp demonitor_phase(state), do: %{state | phase_pid: nil, phase_ref: nil}

  defp demonitor_port_owner_ref(%{port_owner_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | port_owner_ref: nil, port_owner_pid: nil}
  end

  defp demonitor_port_owner_ref(state), do: %{state | port_owner_pid: nil, port_owner_ref: nil}

  defp reset_port_owner(state) do
    %{
      state
      | port_owner_pid: nil,
        port_owner_ref: nil,
        port_owner_group_id: nil,
        port_owner_registered: false,
        port_owner_exhausted: false,
        fallback_used: false,
        fallback_pending: false,
        fallback_claimed: false
    }
  end

  defp pin_release_root(state) do
    build = state.roots.build.path
    path = Path.join([build, "rel", "arbor_trust"])

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case SafePath.resolve_real(path) do
          {:ok, real} -> {:ok, real}
          {:error, reason} -> {:error, {:release_root_unresolved, reason}}
        end

      {:ok, %{type: :symlink}} ->
        {:error, :release_root_symlink}

      {:ok, _} ->
        {:error, :release_root_not_directory}

      {:error, :enoent} ->
        {:error, :trusted_build_release_absent}

      {:error, reason} ->
        {:error, {:release_root_unreadable, reason}}
    end
  end

  defp render_view(state) do
    %{
      "schema" => "arbor.shell.trusted_build.lease.v1",
      "state" => view_state(state),
      "completed_phases" => Enum.map(state.completed, &Atom.to_string/1),
      "locked" => state.locked,
      "native_staged" => is_map(state.native_staged),
      "deps_inventoried" => is_map(state.deps_inventory),
      "cookie_removed" => state.cookie_removed == true,
      "release_inventoried" => is_map(state.release_inventory)
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
      # Long tree scans carry their own bounded deadlines. A GenServer timeout
      # would not cancel the request and could report failure before it commits.
      GenServer.call(worker, {:owner_request, token, request}, :infinity)
    end
  catch
    :exit, _ -> {:error, :invalid_lease}
  end

  defp phase_call(lease_pid, request) do
    GenServer.call(lease_pid, request, :infinity)
  catch
    :exit, _ -> {:error, :invalid_lease}
  end

  defp port_owner_call(lease_pid, request) do
    GenServer.call(lease_pid, request, :infinity)
  catch
    :exit, _ -> {:error, :invalid_lease}
  end
end
