defmodule Arbor.Agent.RuntimeQuiescence do
  @moduledoc """
  Agent-owned imperative shell for bounded runtime quiescence of a single target
  (Phase 4C C2B — the runtime half of template-authority reconciliation).

  It verifies the exact operation-owned dispatch fence, crosses the serialized
  Reconciler barrier, observes ownership through `Arbor.Agent.Registry`, stops a
  confirmed local owner via `Arbor.Agent.Manager`, and drains to confirmed
  absence with the fence re-verified every iteration.

  Lifecycle I/O runs in the caller or an owned bounded worker — never inside
  TaskStore or the durable operation store callbacks.

  ## Bounded + exact-owner stop invariant

  The supervised stop worker is ADMITTED under
  `Arbor.Agent.Orchestration.TaskSupervisor` BEFORE any destructive pre-effect,
  then parks on an unforgeable per-call release token (bounded by the absolute
  deadline) so it cannot call `Manager.stop_owner/1` until released. Only after
  admission does the shell re-verify the fence and atomically remove the
  registry row (`Registry.remove_owner_if_match/2`, a single
  `:ets.select_delete`) ONLY if it still maps the target to the observed owner
  pid, so a replaced/absent/malformed owner is never stopped (`:owner_replaced`);
  every pre-effect failure settles the parked child WITHOUT a stop side effect.
  Admission failure (supervisor down / max_children) leaves the live owner fully
  registered so a later retry can quiesce it. Stop and drain share ONE absolute
  deadline; admission and fence reads run in deadline-owned proxies, and a stop
  worker that does not settle by an earlier effect cutoff is killed and reported
  as `:stop_timeout` (fail closed, bounded). A timed-out admission can create only
  a release-gated child that monitors the caller and self-expires at the same
  deadline. No completion message is used for the stop itself — the monitor's
  DOWN is authoritative. The stop return is never trusted alone — the bounded
  positive-absence drain is authoritative.

  No authority mutation: the caller owns `install_target_fence/remove_target_fence`;
  this shell only VERIFIES ownership. It references only Registry, Reconciler,
  TaskStore, and Manager — no Security/Trust/capability/profile/template/durable-op
  facade.
  """

  alias Arbor.Agent.{Manager, Reconciler, Registry, RuntimeQuiescenceCore}
  alias Arbor.Agent.Orchestration.TaskStore

  # Bounded scalar policy (clamped, not arbitrary). Stop and drain share the
  # single drain_timeout_ms budget (overall quiescence deadline).
  @default_drain_timeout_ms 5_000
  @max_drain_timeout_ms 10_000
  @default_poll_interval_ms 50
  @min_poll_interval_ms 25
  @max_poll_interval_ms 500

  # Test-build-only collaborator overrides. In any other build the overrides are
  # ignored and the production collaborators are fixed. Not caller-selectable via
  # the future public reconciliation facade.
  @test_seams_enabled Mix.env() == :test

  @type quiesce_error ::
          :invalid_target_agent_id
          | :invalid_operation_id
          | :fence_not_owned
          | :barrier_failed
          | :remote_owner
          | :ambiguous_ownership
          | :observation_unavailable
          | :owner_replaced
          | :stop_unavailable
          | :stop_timeout
          | :drain_timeout
          | :fence_lost

  @doc """
  Quiesce `target_agent_id` under the exact `operation_id` dispatch fence.

  Returns `{:ok, %{was_running: boolean}}` on success — `was_running` is `true`
  iff a confirmed local owner was stopped, `false` iff the target was already
  absent (so C3 can persist and later restore that fact). Returns a typed error
  otherwise.

  ## Options

  Bounded policy: `:drain_timeout_ms`, `:poll_interval_ms` (clamped to the module
  bounds). Test-build-only collaborator overrides (unavailable in production):
  `:task_store`, `:manager`, `:runtime_probe`, `:reconciler`, `:stop_supervisor`.
  """
  @spec quiesce(String.t(), String.t(), keyword()) ::
          {:ok, %{was_running: boolean()}} | {:error, quiesce_error()}
  def quiesce(target_agent_id, operation_id, opts \\ []) do
    collaborators = resolve_collaborators(opts)
    drain_timeout_ms = clamp_drain_timeout(opts[:drain_timeout_ms])
    poll_interval_ms = clamp_poll_interval(opts[:poll_interval_ms])

    with :ok <- verify_fence(collaborators, target_agent_id, operation_id, :fence_not_owned),
         :ok <- run_barrier(collaborators, target_agent_id, operation_id) do
      observe_and_act(
        collaborators,
        target_agent_id,
        operation_id,
        drain_timeout_ms,
        poll_interval_ms
      )
    end
  end

  # ── Collaborators ───────────────────────────────────────────────────

  defp resolve_collaborators(opts) do
    %{
      task_store: resolve_seam(opts, :task_store, Arbor.Agent.Orchestration.TaskStore),
      manager: resolve_seam(opts, :manager, Manager),
      runtime_probe: resolve_seam(opts, :runtime_probe, Registry),
      reconciler: resolve_seam(opts, :reconciler, Reconciler),
      stop_supervisor:
        resolve_seam(opts, :stop_supervisor, Arbor.Agent.Orchestration.TaskSupervisor)
    }
  end

  defp resolve_seam(opts, key, default) do
    if @test_seams_enabled and Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key)
    else
      default
    end
  end

  # ── Fence verification ──────────────────────────────────────────────

  defp verify_fence(collaborators, target, operation_id, loss_error) do
    case safe_verify(collaborators.task_store, target, operation_id) do
      :ok -> :ok
      {:error, :invalid_target_agent_id} -> {:error, :invalid_target_agent_id}
      {:error, :invalid_operation_id} -> {:error, :invalid_operation_id}
      _ -> {:error, loss_error}
    end
  end

  defp safe_verify(task_store, target, operation_id) do
    TaskStore.verify_target_fence(target, operation_id, name: task_store)
  rescue
    _ -> :rescued
  catch
    :exit, _ -> :exited
  end

  # ── Serialized Reconciler barrier ───────────────────────────────────

  @barrier_reasons [
    :barrier_failed,
    :fence_not_owned,
    :invalid_target_agent_id,
    :invalid_operation_id
  ]

  @doc """
  Serialized synchronization barrier for runtime quiescence (Phase 4C C2B).

  Crosses the Reconciler mailbox barrier then verifies exact operation-owned
  fence ownership, exposing ONLY the declared closed reasons. Every unknown
  result/error/raise/exit is normalized to `{:error, :barrier_failed}`.
  """
  @spec barrier(String.t(), String.t(), keyword()) ::
          :ok
          | {:error,
             :barrier_failed | :fence_not_owned | :invalid_target_agent_id | :invalid_operation_id}
  def barrier(target_agent_id, operation_id, opts \\ []) do
    collaborators = resolve_collaborators(opts)
    run_barrier(collaborators, target_agent_id, operation_id)
  end

  defp run_barrier(collaborators, target, operation_id) do
    normalize_barrier(safe_sync(collaborators, target, operation_id))
  end

  # Expose ONLY declared closed reasons; normalize every other result/error to
  # :barrier_failed (unknown errors, non-conforming replies, rescued/exited).
  defp normalize_barrier(:ok), do: :ok

  defp normalize_barrier({:error, reason}) when reason in @barrier_reasons,
    do: {:error, reason}

  defp normalize_barrier(_), do: {:error, :barrier_failed}

  # The barrier reply is normalized: a malformed/raising/exiting reply is a typed
  # fail-closed error, never a crash and never a non-conforming return.
  defp safe_sync(collaborators, target, operation_id) do
    Reconciler.synchronize_target(target, operation_id, collaborators.reconciler)
  rescue
    _ -> :rescued
  catch
    :exit, _ -> :exited
  end

  # ── Observe + act ───────────────────────────────────────────────────

  defp observe_and_act(collaborators, target, operation_id, drain_timeout_ms, poll_interval_ms) do
    # One observation captures BOTH the class (for the pre-stop decision) and the
    # exact local owner pid (to bind the stop side effect). The probe returns the
    # pid only for a confirmed local owner (Registry.observe_target_owner/1).
    observed = observe_owner(collaborators.runtime_probe, target)

    case RuntimeQuiescenceCore.pre_stop_decision(owner_to_class(observed)) do
      {:succeed, false} ->
        finalize_absent(collaborators, target, operation_id)

      :stop ->
        {:local_owner, owner_pid} = observed

        stop_owner(
          collaborators,
          target,
          operation_id,
          owner_pid,
          drain_timeout_ms,
          poll_interval_ms
        )

      {:fail, reason} ->
        {:error, reason}
    end
  end

  # observe_target_owner returns {:ok, pid} (local owner) | {:error, reason}; map
  # it to the core's class space and carry the pid for :local_owner.
  defp observe_owner(probe, target) do
    case safe_observe_owner(probe, target) do
      {:ok, pid} -> {:local_owner, pid}
      {:error, :absent} -> :absent
      {:error, :remote_owner} -> {:class, :remote_owner}
      {:error, :ambiguous_ownership} -> {:class, :ambiguous}
      {:error, :observation_unavailable} -> {:class, :unavailable}
      _ -> {:class, :unavailable}
    end
  end

  defp owner_to_class({:local_owner, _pid}), do: :local_owner
  defp owner_to_class(:absent), do: :absent
  defp owner_to_class({:class, c}), do: c

  # A malformed/raising/exiting runtime_probe reply is normalized to
  # :unavailable so the caller fails closed instead of crashing.
  defp safe_observe_owner(probe, target) do
    probe.observe_target_owner(target)
  rescue
    _ -> :rescued
  catch
    :exit, _ -> :exited
  end

  # ── Exact-owner, bounded stop ───────────────────────────────────────

  defp stop_owner(
         collaborators,
         target,
         operation_id,
         owner_pid,
         drain_timeout_ms,
         poll_interval_ms
       ) do
    # Stop and drain share ONE absolute deadline so quiescence stays bounded even
    # if lifecycle shutdown blocks. The stop side effect is bound to BOTH current
    # fence ownership AND the exact observed owner pid (atomic compare-delete).
    deadline = System.monotonic_time(:millisecond) + drain_timeout_ms

    # (1) ADMIT the supervised worker BEFORE any destructive pre-effect. The
    # worker parks on an unforgeable per-call release token (bounded by this same
    # absolute deadline) so it cannot call Manager.stop_owner/1 until released and
    # never leaks if the caller exits or never releases it. Admission failure
    # leaves the live owner fully registered (ETS row + :pg intact) so a later
    # retry can quiesce it.
    case admit_stop_child(collaborators, owner_pid, deadline) do
      {:ok, child, release_ref} ->
        run_stop_after_admission(
          collaborators,
          target,
          operation_id,
          owner_pid,
          child,
          release_ref,
          deadline,
          poll_interval_ms
        )

      {:error, :stop_unavailable} = error ->
        error
    end
  end

  # Atomic exact-owner compare-delete: the registry row is removed ONLY if it
  # still maps the target to the observed owner pid. A replaced/absent/malformed
  # row (or unobservable table) aborts the stop without re-resolving by agent id.
  defp compare_delete_owner(collaborators, target, owner_pid) do
    case collaborators.runtime_probe.remove_owner_if_match(target, owner_pid) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :observation_unavailable}
  catch
    :exit, _ -> {:error, :observation_unavailable}
  end

  # Drive the admitted worker through the destructive pre-effects and the stop.
  # The worker is still parked on its release token, so no stop side effect can
  # occur until the caller re-verifies the fence and compare-deletes the exact
  # observed owner pid, then releases it. Every pre-effect failure settles the
  # waiting child WITHOUT a stop side effect (it never receives the token).
  defp run_stop_after_admission(
         collaborators,
         target,
         operation_id,
         owner_pid,
         child,
         release_ref,
         deadline,
         poll_interval_ms
       ) do
    mon = Process.monitor(child)

    case effect_cutoff(deadline) do
      {:ok, effect_cutoff} ->
        case pre_effects(
               collaborators,
               target,
               operation_id,
               owner_pid,
               child,
               effect_cutoff
             ) do
          :ok ->
            # Only now may the worker call Manager.stop_owner/1. The worker also
            # checks the effect cutoff, so a delayed release cannot start a stop.
            send(child, {:release, release_ref, effect_cutoff})

            case await_stop_settle(mon, child, effect_cutoff, deadline) do
              :ok ->
                drain(collaborators, target, operation_id, poll_interval_ms, deadline)

              {:error, :stop_timeout} = error ->
                error
            end

          {:error, _} = error ->
            settle_child(mon, child, deadline)
            error
        end

      {:error, :stop_timeout} = error ->
        settle_child(mon, child, deadline)
        error
    end
  end

  # Destructive pre-effects: re-verify the exact operation-owned fence, then
  # atomically compare-delete the exact observed owner pid. A replaced/absent/
  # malformed owner (or an unobservable table) aborts without re-resolving by
  # agent id and without stopping any pid.
  defp pre_effects(collaborators, target, operation_id, owner_pid, child, effect_cutoff) do
    with :ok <- verify_fence_until(collaborators, target, operation_id, effect_cutoff),
         :ok <- ensure_releasable(child, effect_cutoff) do
      compare_delete_owner(collaborators, target, owner_pid)
    end
  end

  defp verify_fence_until(
         collaborators,
         target,
         operation_id,
         deadline,
         timeout_error \\ :fence_lost
       ) do
    case run_until(deadline, fn ->
           verify_fence(collaborators, target, operation_id, :fence_lost)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _} = error} -> error
      {:error, :deadline_exceeded} -> {:error, timeout_error}
      {:error, _} -> {:error, :fence_lost}
    end
  end

  defp ensure_releasable(child, effect_cutoff) do
    if Process.alive?(child) and System.monotonic_time(:millisecond) < effect_cutoff do
      :ok
    else
      {:error, :stop_timeout}
    end
  end

  defp effect_cutoff(deadline) do
    budget = deadline - System.monotonic_time(:millisecond)

    if budget < 2 do
      {:error, :stop_timeout}
    else
      {:ok, deadline - settle_reserve(budget)}
    end
  end

  # Await the worker's natural settlement (DOWN) until an effect cutoff strictly
  # inside the deadline (deadline - reserve). The cutoff precedes the worker's
  # own :unreleased timeout at `deadline`, so a DOWN received here is provably
  # from a RELEASED stop, never an unreleased self-timeout. On cutoff the worker
  # is killed and its DOWN awaited only until the original deadline.
  defp await_stop_settle(mon, child, effect_cutoff, deadline) do
    receive do
      {:DOWN, ^mon, :process, ^child, _reason} ->
        Process.demonitor(mon, [:flush])
        :ok
    after
      max(0, effect_cutoff - System.monotonic_time(:millisecond)) ->
        _ = Process.exit(child, :kill)
        await_down_until(mon, child, deadline)
        {:error, :stop_timeout}
    end
  end

  # Settle a worker that must NOT run its stop side effect (a pre-effect failed,
  # or idempotent re-settlement after the stop-timeout path already killed it).
  # The child is killed only if still alive; its DOWN is awaited only until the
  # original deadline so settlement is bounded. No stop side effect occurs: a
  # pre-effect-failed child never received its release token.
  defp settle_child(mon, child, deadline) do
    if Process.alive?(child) do
      _ = Process.exit(child, :kill)
      await_down_until(mon, child, deadline)
    else
      Process.demonitor(mon, [:flush])
    end

    :ok
  end

  # Reserve a bounded settlement window INSIDE the deadline (>0 and < budget) so
  # a worker killed at the effect cutoff still has until the original deadline to
  # settle its DOWN.
  defp settle_reserve(budget) do
    budget
    |> div(4)
    |> max(1)
    |> min(budget - 1)
  end

  # Admit the supervised stop worker BEFORE any destructive pre-effect, and mint
  # the unforgeable per-call release token the worker waits on. The worker parks
  # on {:release, ^release_ref, effect_cutoff} and only then calls
  # Manager.stop_owner/1; if the token never arrives it self-exits at the absolute
  # deadline with no stop side effect. Admission failure (max_children) and any
  # exit/raise (dead supervisor) normalize to a typed fail-closed
  # :stop_unavailable. A synchronous rejection creates no child; a request that
  # completes after its caller times out can create only the release-gated worker,
  # which monitors its caller and self-expires at the same deadline. In either
  # case the live owner stays fully registered.
  defp admit_stop_child(collaborators, owner_pid, deadline) do
    manager = collaborators.manager
    release_ref = make_ref()
    caller = self()

    fun = fn ->
      caller_mon = Process.monitor(caller)

      receive do
        {:release, ^release_ref, effect_cutoff} ->
          Process.demonitor(caller_mon, [:flush])

          if Process.alive?(caller) and
               System.monotonic_time(:millisecond) < effect_cutoff do
            try do
              manager.stop_owner(owner_pid)
            catch
              _, _ -> :caught
            end
          else
            :unreleased
          end

        {:DOWN, ^caller_mon, :process, ^caller, _reason} ->
          :caller_down
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          Process.demonitor(caller_mon, [:flush])
          :unreleased
      end
    end

    case run_until(deadline, fn ->
           Task.Supervisor.start_child(collaborators.stop_supervisor, fun)
         end) do
      {:ok, {:ok, pid}} when is_pid(pid) -> admitted_child(pid, release_ref)
      {:ok, {:ok, pid, _info}} when is_pid(pid) -> admitted_child(pid, release_ref)
      _ -> {:error, :stop_unavailable}
    end
  end

  defp admitted_child(pid, release_ref) do
    if Process.alive?(pid),
      do: {:ok, pid, release_ref},
      else: {:error, :stop_unavailable}
  end

  # Execute a potentially blocking collaborator call in an owned proxy bounded by
  # an absolute deadline. The proxy has its own kill timer, so it cannot outlive a
  # caller that exits while waiting. A process alias drops any late reply after the
  # deadline; raises/exits and late completions all fail closed.
  defp run_until(deadline, fun) when is_function(fun, 0) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :deadline_exceeded}
    else
      reply_alias = :erlang.alias()
      reply_ref = make_ref()

      {runner, mon} =
        spawn_monitor(fn ->
          remaining = max(0, deadline - System.monotonic_time(:millisecond))
          {:ok, timer} = :timer.kill_after(remaining, self())

          result =
            try do
              {:ok, fun.()}
            rescue
              _ -> {:error, :operation_failed}
            catch
              _, _ -> {:error, :operation_failed}
            end

          completed_at = System.monotonic_time(:millisecond)
          _ = :timer.cancel(timer)
          send(reply_alias, {reply_ref, completed_at, result})
        end)

      receive do
        {^reply_ref, completed_at, result} ->
          :erlang.unalias(reply_alias)
          Process.demonitor(mon, [:flush])

          if completed_at < deadline and System.monotonic_time(:millisecond) < deadline,
            do: result,
            else: {:error, :deadline_exceeded}

        {:DOWN, ^mon, :process, ^runner, _reason} ->
          :erlang.unalias(reply_alias)
          {:error, :operation_failed}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          :erlang.unalias(reply_alias)
          _ = Process.exit(runner, :kill)
          await_down_until(mon, runner, deadline)
          {:error, :deadline_exceeded}
      end
    end
  end

  defp await_down_until(ref, child, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:DOWN, ^ref, :process, ^child, _reason} ->
        :ok
    after
      max(0, remaining) ->
        :ok
    end

    Process.demonitor(ref, [:flush])
  end

  # ── Bounded drain ───────────────────────────────────────────────────

  defp drain(collaborators, target, operation_id, poll_interval_ms, deadline) do
    case verify_fence_until(collaborators, target, operation_id, deadline, :drain_timeout) do
      :ok ->
        class = owner_to_class(observe_owner(collaborators.runtime_probe, target))
        # Deadline equality is terminal: >= (not strict >). Polling never sleeps
        # beyond the single absolute deadline.
        exceeded? = System.monotonic_time(:millisecond) >= deadline

        case RuntimeQuiescenceCore.drain_step(class, exceeded?) do
          :drained ->
            {:ok, %{was_running: true}}

          :poll ->
            now = System.monotonic_time(:millisecond)
            remaining = max(0, deadline - now)
            sleep_for = min(poll_interval_ms, remaining)

            if sleep_for > 0 do
              Process.sleep(sleep_for)
            end

            drain(collaborators, target, operation_id, poll_interval_ms, deadline)

          {:fail, reason} ->
            {:error, reason}
        end

      {:error, _} = error ->
        error
    end
  end

  defp finalize_absent(collaborators, target, operation_id) do
    case verify_fence(collaborators, target, operation_id, :fence_lost) do
      :ok -> {:ok, %{was_running: false}}
      {:error, _} = error -> error
    end
  end

  # ── Bounded policy ──────────────────────────────────────────────────

  defp clamp_drain_timeout(nil), do: @default_drain_timeout_ms

  defp clamp_drain_timeout(ms) when is_integer(ms) and ms > 0 do
    min(ms, @max_drain_timeout_ms)
  end

  defp clamp_drain_timeout(_), do: @default_drain_timeout_ms

  defp clamp_poll_interval(nil), do: @default_poll_interval_ms

  defp clamp_poll_interval(ms) when is_integer(ms) and ms > 0 do
    ms |> max(@min_poll_interval_ms) |> min(@max_poll_interval_ms)
  end

  defp clamp_poll_interval(_), do: @default_poll_interval_ms
end
