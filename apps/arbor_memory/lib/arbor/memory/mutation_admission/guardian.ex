defmodule Arbor.Memory.MutationAdmission.Guardian do
  @moduledoc false

  # Per-root local effect owner. Registry registration is owned by this process.
  #
  # Protocol (non-cyclic — Guardian never GenServer.call's MutationAdmission):
  #   reenter / release_depth / begin_handoff / finalize_handoff / abort_handoff /
  #   claim_release / release_attempt_result / reconnect_admission / assert_holder
  #     are shell → guardian calls only; every mutating call authenticates
  #     GenServer.from as state.admission (in addition to holder/target checks).
  #     assert_holder is read-only and also authenticates the admission shell.
  #   Holder death / release recovery:
  #     guardian → cast {:holder_down_release, guardian_pid} wake-up only → shell
  #     shell resolves Registry, call claim_release (derived identity), durable CAS
  #     shell → call {:release_attempt_result, result} → guardian (retry forever)
  #
  # Handoff fields are explicit and exact-matched:
  #   pending_source, pending_target, pending_source_mon, pending_target_mon
  # Target DOWN before finalize → fail closed (no remonitor/ack).
  # Source DOWN during pending handoff → exactly one durable release.

  use GenServer

  @registry Arbor.Memory.MutationAdmission.Registry
  @base_backoff_ms 10
  @max_backoff_ms 5_000

  defstruct [
    :lease_hash,
    :agent_id,
    :token,
    :holder,
    :source_mon,
    :admission,
    # Registered MutationAdmission name for reconnect whereis binding.
    :admission_name,
    :registry,
    :max_depth,
    depth: 1,
    # :holding | :handing_off | :releasing
    phase: :holding,
    pending_source: nil,
    pending_target: nil,
    pending_source_mon: nil,
    pending_target_mon: nil,
    target_down?: false,
    source_down?: false,
    release_attempt: 0
  ]

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %{
      id: {:mutation_admission_guardian, Keyword.fetch!(opts, :lease_hash)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  def reenter(pid, caller), do: GenServer.call(pid, {:reenter, caller})

  @doc false
  def release_depth(pid, caller), do: GenServer.call(pid, {:release_depth, caller})

  @doc false
  def begin_handoff(pid, caller, target),
    do: GenServer.call(pid, {:begin_handoff, caller, target})

  @doc false
  def finalize_handoff(pid, caller, target),
    do: GenServer.call(pid, {:finalize_handoff, caller, target})

  @doc false
  def abort_handoff(pid, caller), do: GenServer.call(pid, {:abort_handoff, caller})

  @doc false
  # Shell-only: admit a durable release claim derived solely from guardian state.
  def claim_release(pid), do: GenServer.call(pid, :claim_release)

  @doc false
  # Shell-only authenticated release-result acknowledgement (not a cast).
  def release_attempt_result(pid, result),
    do: GenServer.call(pid, {:release_attempt_result, result})

  @doc false
  # Shell-only read-only holder assertion. Does not change guardian state.
  def assert_holder(pid, caller), do: GenServer.call(pid, {:assert_holder, caller})

  @doc false
  def holder(pid), do: GenServer.call(pid, :holder)

  @doc false
  def info(pid), do: GenServer.call(pid, :info)

  @doc false
  # Replace admission owner after MutationAdmission restart. Accepts only when
  # caller == proposed == whereis(admission_name) and prior admission is dead or
  # already self — never steals from a different live shell.
  def reconnect_admission(pid, new_admission) when is_pid(new_admission),
    do: GenServer.call(pid, {:reconnect_admission, new_admission})

  def reconnect_admission(_, _), do: {:error, :invalid_request}

  @impl true
  def init(opts) do
    lease_hash = Keyword.fetch!(opts, :lease_hash)
    agent_id = Keyword.fetch!(opts, :agent_id)
    token = Keyword.fetch!(opts, :token)
    holder = Keyword.fetch!(opts, :holder)
    admission = Keyword.fetch!(opts, :admission)
    admission_name = Keyword.fetch!(opts, :admission_name)
    registry = Keyword.get(opts, :registry, @registry)
    max_depth = Keyword.get(opts, :max_depth, 32)

    case Registry.register(registry, {:guardian, lease_hash}, %{agent_id: agent_id}) do
      {:ok, _} ->
        source_mon = Process.monitor(holder)

        {:ok,
         %__MODULE__{
           lease_hash: lease_hash,
           agent_id: agent_id,
           token: token,
           holder: holder,
           source_mon: source_mon,
           admission: admission,
           admission_name: admission_name,
           registry: registry,
           max_depth: max_depth
         }}

      {:error, {:already_registered, _}} ->
        {:stop, :already_registered}
    end
  end

  # ---------------------------------------------------------------------------
  # Shell → guardian (local only; never call admission)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:reenter, caller}, from, %{phase: :holding} = state) do
    with :ok <- authenticate_admission(from, state) do
      cond do
        caller != state.holder -> {:reply, {:error, :not_owner}, state}
        state.depth >= state.max_depth -> {:reply, {:error, :capacity_exceeded}, state}
        true -> {:reply, :ok, %{state | depth: state.depth + 1}}
      end
    end
  end

  def handle_call({:reenter, _}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:assert_holder, caller}, from, %{phase: :holding} = state) do
    with :ok <- authenticate_admission(from, state) do
      if caller == state.holder do
        {:reply, :ok, state}
      else
        {:reply, {:error, :not_owner}, state}
      end
    end
  end

  def handle_call({:assert_holder, _caller}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:release_depth, caller}, from, %{phase: :holding} = state) do
    with :ok <- authenticate_admission(from, state) do
      cond do
        caller != state.holder ->
          {:reply, {:error, :not_owner}, state}

        state.depth > 1 ->
          {:reply, {:ok, :nested}, %{state | depth: state.depth - 1}}

        true ->
          # Outermost: shell performs durable CAS. Mark releasing so DOWN cannot
          # double-cast a concurrent release while shell holds the call stack.
          # Identity for CAS is re-derived via claim_release / shell lease — not
          # trusted from a third-party payload.
          {:reply, {:ok, {:outermost, state.lease_hash, state.agent_id}},
           %{state | phase: :releasing, depth: 1}}
      end
    end
  end

  def handle_call({:release_depth, _}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:begin_handoff, caller, target}, from, %{phase: :holding} = state) do
    with :ok <- authenticate_admission(from, state) do
      cond do
        caller != state.holder ->
          {:reply, {:error, :not_owner}, state}

        # Move-only handoff is valid only at guardian depth exactly one.
        # Nested depth returns closed :busy before monitors or shell CAS.
        state.depth != 1 ->
          {:reply, {:error, :busy}, state}

        not is_pid(target) or node(target) != node() or not Process.alive?(target) ->
          {:reply, {:error, :invalid_target}, state}

        true ->
          target_mon = Process.monitor(target)

          {:reply, :ok,
           %{
             state
             | phase: :handing_off,
               pending_source: caller,
               pending_target: target,
               pending_source_mon: state.source_mon,
               pending_target_mon: target_mon,
               target_down?: false,
               source_down?: false
           }}
      end
    end
  end

  def handle_call({:begin_handoff, _, _}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:finalize_handoff, caller, target}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      with :handing_off <- state.phase,
           true <- state.pending_source == caller,
           true <- state.pending_target == target,
           true <- is_reference(state.pending_target_mon) do
        target_mon = state.pending_target_mon
        source_mon = state.pending_source_mon
        {target_down?, state} = drain_matching_down(state, target_mon, target, :target)

        cond do
          state.source_down? ->
            # Source died during pending CAS window — durable release already cast.
            # Stay :releasing (never reset_holding — that would re-open ownership).
            clear_pending_monitors(state)
            {:reply, {:error, :not_owner}, enter_releasing(state)}

          target_down? or not Process.alive?(target) ->
            # Dead target after handoff CAS remains :releasing until durable release settles.
            if is_reference(target_mon), do: Process.demonitor(target_mon, [:flush])
            request_release(state)
            {:reply, {:error, :invalid_target}, enter_releasing(state)}

          true ->
            if is_reference(source_mon), do: Process.demonitor(source_mon, [:flush])

            {:reply, :ok,
             %{
               state
               | holder: target,
                 source_mon: target_mon,
                 phase: :holding,
                 pending_source: nil,
                 pending_target: nil,
                 pending_source_mon: nil,
                 pending_target_mon: nil,
                 target_down?: false,
                 source_down?: false,
                 depth: 1
             }}
        end
      else
        _ -> {:reply, {:error, :invalid_request}, state}
      end
    end
  end

  def handle_call({:abort_handoff, caller}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      cond do
        state.phase != :handing_off ->
          {:reply, :ok, state}

        state.pending_source != caller ->
          {:reply, {:error, :not_owner}, state}

        true ->
          if is_reference(state.pending_target_mon) do
            Process.demonitor(state.pending_target_mon, [:flush])
          end

          if state.source_down? do
            # Source already died; release path owns the root — stay :releasing.
            {:reply, :ok, enter_releasing(state)}
          else
            {:reply, :ok,
             %{
               state
               | phase: :holding,
                 pending_source: nil,
                 pending_target: nil,
                 pending_source_mon: nil,
                 pending_target_mon: nil,
                 target_down?: false,
                 source_down?: false
             }}
          end
      end
    end
  end

  def handle_call(:claim_release, from, state) do
    with :ok <- authenticate_admission(from, state) do
      if state.phase == :releasing do
        {:reply, {:ok, %{lease_hash: state.lease_hash, agent_id: state.agent_id}}, state}
      else
        {:reply, {:error, :busy}, state}
      end
    end
  end

  def handle_call({:release_attempt_result, result}, from, state) do
    with :ok <- authenticate_admission(from, state) do
      case result do
        :ok ->
          {:stop, :normal, :ok, state}

        :stale_lease ->
          {:stop, :normal, :ok, state}

        :retry ->
          # Temporarily unavailable durable release — keep scheduling forever with
          # bounded per-attempt backoff. Never strand a current-runtime root.
          state = bump_release_attempt(%{state | phase: :releasing})
          schedule_release_retry(state)
          {:reply, :ok, state}

        _ ->
          {:reply, {:error, :invalid_request}, state}
      end
    end
  end

  def handle_call(:holder, _from, state), do: {:reply, {:ok, state.holder}, state}

  def handle_call(:info, _from, state) do
    {:reply,
     {:ok,
      %{
        lease_hash: state.lease_hash,
        agent_id: state.agent_id,
        holder: state.holder,
        depth: state.depth,
        phase: state.phase,
        pending_target: state.pending_target,
        target_down?: state.target_down?,
        source_down?: state.source_down?,
        admission: state.admission
      }}, state}
  end

  def handle_call({:reconnect_admission, proposed}, {caller, _} = _from, state)
      when is_pid(proposed) do
    registered = registered_admission_pid(state.admission_name)

    cond do
      # Caller must be the proposed pid and the live registered admission process.
      caller != proposed ->
        {:reply, {:error, :not_owner}, state}

      registered != caller ->
        {:reply, {:error, :not_owner}, state}

      state.admission == proposed ->
        {:reply, :ok, maybe_flush_pending_release(state)}

      not is_pid(state.admission) or not Process.alive?(state.admission) ->
        new_state = %{state | admission: proposed}
        {:reply, :ok, maybe_flush_pending_release(new_state)}

      true ->
        # Another live MutationAdmission still owns this guardian — refuse steal.
        {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :invalid_request}, state}

  # Legacy unauthenticated cast path — ignore (release results must be calls).
  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Monitors / retries
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.phase do
      :handing_off ->
        cond do
          ref == state.pending_target_mon and pid == state.pending_target ->
            {:noreply, %{state | target_down?: true}}

          ref == state.pending_source_mon and pid == state.pending_source ->
            # Source DOWN during pending CAS: converge to single release, not handoff.
            if is_reference(state.pending_target_mon) do
              Process.demonitor(state.pending_target_mon, [:flush])
            end

            request_release(state)

            {:noreply,
             %{
               state
               | source_down?: true,
                 phase: :releasing,
                 pending_target: nil,
                 pending_target_mon: nil,
                 depth: 1
             }}

          ref == state.source_mon and pid == state.holder ->
            request_release(state)
            {:noreply, %{state | phase: :releasing, depth: 1}}

          true ->
            {:noreply, state}
        end

      :holding ->
        if ref == state.source_mon and pid == state.holder do
          request_release(state)
          {:noreply, %{state | phase: :releasing, depth: 1}}
        else
          {:noreply, state}
        end

      :releasing ->
        {:noreply, state}
    end
  end

  def handle_info(:retry_release, %{phase: :releasing} = state) do
    request_release(state)
    {:noreply, state}
  end

  def handle_info(:retry_release, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals — wake cast only to admission (never call shell; never trust payload)
  # ---------------------------------------------------------------------------

  defp authenticate_admission({caller, _ref}, state) when is_pid(caller) do
    if caller == state.admission do
      :ok
    else
      {:reply, {:error, :not_owner}, state}
    end
  end

  defp authenticate_admission(_from, state), do: {:reply, {:error, :not_owner}, state}

  defp registered_admission_pid(name) when is_atom(name) or is_tuple(name) do
    GenServer.whereis(name)
  end

  defp registered_admission_pid(_), do: nil

  defp request_release(state) do
    admission = state.admission

    if is_pid(admission) and Process.alive?(admission) do
      # Wake-up only — lease_hash/agent_id are never taken from this message.
      GenServer.cast(admission, {:holder_down_release, self()})
    else
      # Shell is down (pre-reconnect). Retry until reconnect_admission flushes.
      schedule_release_retry(state)
    end
  end

  defp schedule_release_retry(state) do
    exp = min(state.release_attempt, 9)
    backoff = min(@base_backoff_ms * trunc(:math.pow(2, exp)), @max_backoff_ms)
    Process.send_after(self(), :retry_release, backoff)
    :ok
  end

  defp bump_release_attempt(state) do
    %{state | release_attempt: state.release_attempt + 1}
  end

  defp maybe_flush_pending_release(%{phase: :releasing} = state) do
    request_release(state)
    state
  end

  defp maybe_flush_pending_release(state), do: state

  defp drain_matching_down(state, mon, pid, :target) do
    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} ->
        {true, %{state | target_down?: true}}
    after
      0 ->
        {state.target_down?, state}
    end
  end

  defp clear_pending_monitors(state) do
    if is_reference(state.pending_target_mon) do
      Process.demonitor(state.pending_target_mon, [:flush])
    end
  end

  # Clear handoff pending fields while remaining a durable release blocker.
  # Must not re-enter :holding — that would drop the post-CAS dead-target fence.
  defp enter_releasing(state) do
    %{
      state
      | phase: :releasing,
        pending_source: nil,
        pending_target: nil,
        pending_source_mon: nil,
        pending_target_mon: nil,
        target_down?: true,
        depth: 1
    }
  end
end
