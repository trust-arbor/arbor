defmodule Arbor.Agent.Reconciler do
  @moduledoc """
  Imperative shell for agent-lifecycle **reconciliation** — the continuous
  generalization of `Arbor.Agent.Bootstrap`.

  On a periodic tick (and on-demand via `reconcile_now/0`) it:

    1. Snapshots **desired** state — persisted profiles (`ProfileStore`) reduced to
       `%{agent_id, auto_start}`.
    2. Snapshots **actual** state — live agents via the **strict**
       `Registry.list_strict/0` (fails closed to `:unavailable` rather than `[]`)
       reduced to `%{agent_id, identity_present}`.
    3. Asks the pure decision core, `Arbor.Agent.LifecycleCore.reconcile/3`, for the
       list of intents (`:start` / `:reap`).
    4. Applies each intent as a side effect and logs a one-line summary.

  The core decides; this shell only gathers facts and executes. The two orphan
  classes it closes (see `LifecycleCore`):

    * **G1 — desired-running but absent** (`auto_start` profile with no live
      process) → `:start` via `Manager.resume_agent/2`, **rate-limited** to at most
      #{3} starts per agent per 10 minutes so a crash-looping agent can't be
      restarted forever. **Fence-gated (C2B):** immediately before each resume the
      fixed production TaskStore `target_fenced?/1` projection must return
      `{:ok, false}`; a fence, fence-not-ready result, TaskStore exit/timeout,
      malformed reply, or any exception suppresses the start without consuming a
      rate-limit attempt, emitting a restarted signal, OR appearing in the pass
      summary / the intents returned by `reconcile_now/1` (which returns applied
      intents only).
    * **G2 — identity-gone zombie** (live agent whose identity no longer exists) →
      `:reap` via `Manager.stop_agent/1`.

  ## Security posture — fail SAFE on identity

  Reaping the wrong agent is a fail-open. `identity_class/2` therefore classifies
  identity status as determinate (`{:ok, true}` present / `{:ok, false}`
  not-found) or `:uncertain` (backend error / raise / exit). Determinate results
  proceed (not-found → G2 reap); `:uncertain` suppresses the whole pass — never
  reap on uncertainty, never start on uncertainty — mirroring the actual-snapshot
  fail-closed posture.

  ## Actual-snapshot + identity suppression (C2B)

  An unavailable actual-state snapshot (`list_strict/0` → `:observation_unavailable`,
  or any failure) suppresses the whole pass — the Reconciler returns no intents
  rather than substituting an empty actual set, so it never derives G1 start work
  from unknown actual state. The same suppression applies to an UNCERTAIN identity
  observation: a determinate present/not-found identity may proceed, but any
  backend/exception/exit uncertainty suppresses the whole pass (no G1 start, no
  G2 reap), never collapsing uncertainty to absence.

  ## Serialized synchronization barrier (C2B)

  `synchronize_target/3` runs in the Reconciler mailbox after any in-flight
  reconcile callback, then verifies exact operation-owned fence ownership through
  `TaskStore.verify_target_fence/3`, failing closed on every uncertain result.
  Runtime quiescence crosses this barrier before observing or stopping a target.

  ## Configuration

      config :arbor_agent, Arbor.Agent.Reconciler,
        enabled: true,
        interval_ms: 60_000,
        g1_policy: :start

  When `enabled: false` the GenServer starts but schedules no ticks (so it can be
  disabled in place without removing it from the tree). `interval_ms` and
  `g1_policy` may also be overridden via `start_link/1` opts (used by tests).
  """

  use GenServer

  require Logger

  alias Arbor.Agent.LifecycleCore
  alias Arbor.Agent.Orchestration.TaskStore

  @default_interval_ms 60_000
  @default_g1_policy :start

  # Rate limit for :start intents — at most @start_limit_max resumes per agent
  # within a sliding @start_limit_window_ms window.
  @start_limit_max 3
  @start_limit_window_ms 10 * 60 * 1_000

  # Reuse Lifecycle's durable emission mechanism (see
  # `Arbor.Agent.Lifecycle.dual_emit_lifecycle/2`): category `:agent`, durable,
  # on the shared "agent:lifecycle" stream.
  @lifecycle_stream_id "agent:lifecycle"

  # Fixed production collaborators. Test-build-only start opts may override these
  # for deterministic tests; in any other build they are forced to the defaults
  # (unavailable in production, not caller-selectable via the future public
  # reconciliation facade).
  @test_seams_enabled Mix.env() == :test
  @default_task_store Arbor.Agent.Orchestration.TaskStore
  @default_manager Arbor.Agent.Manager
  @default_registry Arbor.Agent.Registry
  @default_identity Arbor.Security

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start the Reconciler.

  ## Options

    * `:name` — GenServer name (default `#{inspect(__MODULE__)}`)
    * `:enabled` — schedule periodic ticks (default from config, then `true`)
    * `:interval_ms` — tick interval (default from config, then #{@default_interval_ms})
    * `:g1_policy` — `:start` | `:leave_alone` (default from config, then `:start`)

  Test-build-only collaborator overrides (unavailable in production):
  `:task_store`, `:manager`, `:registry`, `:identity`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Run one reconcile pass synchronously and return the applied intents.

  Much more testable than waiting on the timer — used by tests and any operator
  who wants an immediate pass.
  """
  @spec reconcile_now(GenServer.server()) :: [LifecycleCore.intent()]
  def reconcile_now(server \\ __MODULE__) do
    GenServer.call(server, :reconcile_now)
  end

  @doc """
  Serialized synchronization barrier for template-authority quiescence (C2B).

  Runs in the Reconciler mailbox AFTER any in-flight reconcile callback has fully
  returned (mailbox FIFO + synchronous `handle_call`), then verifies exact
  operation-owned fence ownership through `TaskStore.verify_target_fence/3`. Fails
  closed (`:fence_not_owned` / `:barrier_failed`) on every uncertain or malformed
  result. No local target/op validation — TaskStore returns typed `:invalid_*`
  errors which are propagated.

  Runtime quiescence must cross this barrier before observing or stopping a target.
  """
  @spec synchronize_target(String.t(), String.t(), GenServer.server()) ::
          :ok
          | {:error,
             :barrier_failed | :fence_not_owned | :invalid_target_agent_id | :invalid_operation_id}
  def synchronize_target(target_agent_id, operation_id, server \\ __MODULE__) do
    GenServer.call(server, {:synchronize_target, target_agent_id, operation_id})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    config = Application.get_env(:arbor_agent, __MODULE__, [])

    enabled = opt(opts, config, :enabled, true)
    interval_ms = opt(opts, config, :interval_ms, @default_interval_ms)
    g1_policy = opt(opts, config, :g1_policy, @default_g1_policy)

    state = %{
      enabled: enabled,
      interval_ms: interval_ms,
      g1_policy: g1_policy,
      timer_ref: nil,
      # agent_id => [monotonic_ms] recent start attempts (for rate limiting)
      start_attempts: %{},
      task_store: resolve_collaborator(opts, :task_store, @default_task_store),
      manager: resolve_collaborator(opts, :manager, @default_manager),
      registry: resolve_collaborator(opts, :registry, @default_registry),
      identity: resolve_collaborator(opts, :identity, @default_identity)
    }

    state = if enabled, do: schedule_tick(state), else: state
    {:ok, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) do
    {intents, state} = run_reconcile(state)
    {:reply, intents, state}
  end

  @impl true
  def handle_call({:synchronize_target, target_agent_id, operation_id}, _from, state) do
    reply = synchronize_reply(state, target_agent_id, operation_id)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {_intents, state} = run_reconcile(state)
    {:noreply, schedule_tick(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Reconcile pass ──────────────────────────────────────────────────

  defp run_reconcile(state) do
    desired = snapshot_desired()

    case snapshot_actual(state) do
      :unavailable ->
        # C2B: an unavailable actual-state snapshot suppresses the whole pass —
        # no G1 starts (and no G2 reaps) derived from unknown actual state.
        Logger.warning("[Reconciler] actual snapshot unavailable; suppressing pass")
        {[], state}

      {:ok, actual} ->
        computed = LifecycleCore.reconcile(desired, actual, g1_policy: state.g1_policy)
        # C2B: reconcile_now/1 returns APPLIED intents only. A fence-suppressed
        # (or rate-limited) start is applied to neither side effect nor the
        # returned list / summary — it consumes no rate-limit slot and emits no
        # restart signal. The pass summary counts applied intents only.
        {applied, state} = apply_intents(computed, state)

        if applied != [] do
          summary = LifecycleCore.summarize(applied)
          Logger.info("[Reconciler] #{summary.start} start(s), #{summary.reap} reap(s)")
        end

        {applied, state}
    end
  end

  # Apply each computed intent, collecting only those whose side effect actually
  # ran (:start admitted + within rate limit -> resume; :reap -> stop_agent). A
  # fence-suppressed or rate-limited start is :not_applied and dropped from the
  # returned list and summary without consuming a rate-limit slot.
  defp apply_intents(intents, state) do
    {applied, state} =
      Enum.reduce(intents, {[], state}, fn intent, {acc, s} ->
        {outcome, s2} = apply_intent(intent, s)

        case outcome do
          :applied -> {[intent | acc], s2}
          :not_applied -> {acc, s2}
        end
      end)

    {Enum.reverse(applied), state}
  end

  # DESIRED: persisted profiles → %{agent_id, auto_start}.
  defp snapshot_desired do
    Arbor.Agent.ProfileStore.list_profiles()
    |> Enum.map(fn p -> %{agent_id: p.agent_id, auto_start: p.auto_start} end)
  rescue
    e ->
      Logger.warning("[Reconciler] desired snapshot failed: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("[Reconciler] desired snapshot exited: #{inspect(reason)}")
      []
  end

  # ACTUAL (C2B strict): live agents → %{agent_id, identity_present}. An
  # unavailable actual snapshot OR any uncertain identity suppresses the whole
  # pass (:unavailable) — determinate present/not-found identity may proceed.
  defp snapshot_actual(state) do
    case state.registry.list_strict() do
      {:ok, entries} ->
        result =
          Enum.reduce_while(entries, {:ok, []}, fn e, {:ok, acc} ->
            case identity_class(state.identity, e.agent_id) do
              {:ok, present?} ->
                {:cont, {:ok, [%{agent_id: e.agent_id, identity_present: present?} | acc]}}

              :uncertain ->
                {:halt, :unavailable}
            end
          end)

        case result do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          :unavailable -> :unavailable
        end

      {:error, _} ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  # SECURITY CRITICAL, fail-SAFE + C2B suppression: determinate present/not-found
  # identity proceeds; any backend/exception/exit uncertainty is :uncertain and
  # suppresses the whole reconcile pass (no G1 start, no G2 reap).
  defp identity_class(identity, agent_id) do
    case identity.identity_status(agent_id) do
      {:ok, _} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} -> :uncertain
    end
  rescue
    _ -> :uncertain
  catch
    :exit, _ -> :uncertain
  end

  # ── Serialized barrier (C2B) ────────────────────────────────────────

  defp synchronize_reply(state, target_agent_id, operation_id) do
    case verify_target_fence(state, target_agent_id, operation_id) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  # Fail closed on every uncertain/malformed result. No local validation:
  # TaskStore validates target/op and returns typed :invalid_* errors.
  defp verify_target_fence(state, target_agent_id, operation_id) do
    case TaskStore.verify_target_fence(target_agent_id, operation_id, name: state.task_store) do
      :ok -> :ok
      {:error, :invalid_target_agent_id} -> {:error, :invalid_target_agent_id}
      {:error, :invalid_operation_id} -> {:error, :invalid_operation_id}
      {:error, _} -> {:error, :fence_not_owned}
      _ -> {:error, :fence_not_owned}
    end
  rescue
    _ -> {:error, :barrier_failed}
  catch
    :exit, _ -> {:error, :barrier_failed}
  end

  # ── Intent application ──────────────────────────────────────────────

  defp apply_intent(%{action: :reap, agent_id: agent_id, reason: reason}, state) do
    Logger.warning("[Reconciler] reaping zombie agent #{agent_id} (#{reason})")

    safe_manager(fn -> state.manager.stop_agent(agent_id) end)
    emit(:agent_reaped, %{agent_id: agent_id, reason: reason})

    {:applied, state}
  end

  defp apply_intent(%{action: :start, agent_id: agent_id, reason: reason}, state) do
    case start_admission(agent_id, state) do
      :admit ->
        now = System.monotonic_time(:millisecond)
        recent = recent_attempts(state, agent_id, now)

        if length(recent) < @start_limit_max do
          safe_manager(fn -> state.manager.resume_agent(agent_id, []) end)
          emit(:agent_restarted, %{agent_id: agent_id, reason: reason})
          {:applied, record_attempt(state, agent_id, [now | recent])}
        else
          Logger.warning(
            "[Reconciler] rate-limited start for #{agent_id} " <>
              "(#{length(recent)} attempts within #{div(@start_limit_window_ms, 60_000)}m)"
          )

          # Keep the (windowed) list so the limit stays enforced next tick. The
          # start did not apply (no resume), so it is absent from the returned
          # intents and summary without consuming a fresh rate-limit slot.
          {:not_applied, record_attempt(state, agent_id, recent)}
        end

      :suppressed ->
        # C2B: fence suppression is NOT a failed start attempt — no rate-limit
        # slot consumed, no :agent_restarted emitted, no resume, and the intent
        # is absent from the returned list and summary.
        Logger.debug("[Reconciler] fence suppressed start for #{agent_id}")
        {:not_applied, state}
    end
  end

  defp apply_intent(_other, state), do: {:not_applied, state}

  # C2B fence gate: ONLY {:ok, false} admits resume. A fence, fence-not-ready
  # result, TaskStore exit/timeout, malformed reply, or any exception suppresses.
  defp start_admission(agent_id, state) do
    case TaskStore.target_fenced?(agent_id, name: state.task_store) do
      {:ok, false} -> :admit
      {:ok, true} -> :suppressed
      {:error, _} -> :suppressed
      _ -> :suppressed
    end
  rescue
    _ -> :suppressed
  catch
    :exit, _ -> :suppressed
  end

  defp recent_attempts(state, agent_id, now) do
    cutoff = now - @start_limit_window_ms

    state.start_attempts
    |> Map.get(agent_id, [])
    |> Enum.filter(&(&1 > cutoff))
  end

  defp record_attempt(state, agent_id, attempts) do
    %{state | start_attempts: Map.put(state.start_attempts, agent_id, attempts)}
  end

  # A failing Manager op for one agent must not crash the whole pass.
  defp safe_manager(fun) do
    fun.()
  rescue
    e ->
      Logger.warning("[Reconciler] manager op failed: #{Exception.message(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[Reconciler] manager op exited: #{inspect(reason)}")
      :error
  end

  # ── Signals ─────────────────────────────────────────────────────────

  defp emit(type, data) do
    Arbor.Signals.durable_emit(:agent, type, data, stream_id: @lifecycle_stream_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Timer ───────────────────────────────────────────────────────────

  defp schedule_tick(state) do
    ref = Process.send_after(self(), :reconcile, state.interval_ms)
    %{state | timer_ref: ref}
  end

  # ── Config / collaborators ──────────────────────────────────────────

  # start_link opt wins, then application config, then hardcoded default.
  defp opt(opts, config, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(config, key, default)
    end
  end

  # Test-build-only collaborator override; forced to default in any other build.
  defp resolve_collaborator(opts, key, default) do
    if @test_seams_enabled and Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key)
    else
      default
    end
  end
end
