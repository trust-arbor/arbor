defmodule Arbor.Agent.Reconciler do
  @moduledoc """
  Imperative shell for agent-lifecycle **reconciliation** — the continuous
  generalization of `Arbor.Agent.Bootstrap`.

  On a periodic tick (and on-demand via `reconcile_now/0`) it:

    1. Snapshots **desired** state — persisted profiles (`ProfileStore`) reduced to
       `%{agent_id, auto_start}`.
    2. Snapshots **actual** state — live agents (`Arbor.Agent.Registry.list/0`,
       already alive-filtered) reduced to `%{agent_id, identity_present}`.
    3. Asks the pure decision core, `Arbor.Agent.LifecycleCore.reconcile/3`, for the
       list of intents (`:start` / `:reap`).
    4. Applies each intent as a side effect and logs a one-line summary.

  The core decides; this shell only gathers facts and executes. The two orphan
  classes it closes (see `LifecycleCore`):

    * **G1 — desired-running but absent** (`auto_start` profile with no live
      process) → `:start` via `Manager.resume_agent/2`, **rate-limited** to at most
      #{3} starts per agent per 10 minutes so a crash-looping agent can't be
      restarted forever.
    * **G2 — identity-gone zombie** (live agent whose identity no longer exists) →
      `:reap` via `Manager.stop_agent/1`.

  ## Security posture — fail SAFE on identity

  Reaping the wrong agent is a fail-open. `identity_present?/1` therefore treats
  **any** error determining identity status as PRESENT (never reap on
  uncertainty), mirroring `HeartbeatService.identity_registered?/1`.

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

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start the Reconciler.

  ## Options

    * `:name` — GenServer name (default `#{inspect(__MODULE__)}`)
    * `:enabled` — schedule periodic ticks (default from config, then `true`)
    * `:interval_ms` — tick interval (default from config, then #{@default_interval_ms})
    * `:g1_policy` — `:start` | `:leave_alone` (default from config, then `:start`)
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
      start_attempts: %{}
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
  def handle_info(:reconcile, state) do
    {_intents, state} = run_reconcile(state)
    {:noreply, schedule_tick(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Reconcile pass ──────────────────────────────────────────────────

  defp run_reconcile(state) do
    desired = snapshot_desired()
    actual = snapshot_actual()

    intents = LifecycleCore.reconcile(desired, actual, g1_policy: state.g1_policy)

    if intents != [] do
      summary = LifecycleCore.summarize(intents)
      Logger.info("[Reconciler] #{summary.start} start(s), #{summary.reap} reap(s)")
    end

    state = Enum.reduce(intents, state, &apply_intent/2)
    {intents, state}
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

  # ACTUAL: live agents (already alive-filtered) → %{agent_id, identity_present}.
  defp snapshot_actual do
    entries =
      case safe_registry_list() do
        {:ok, entries} -> entries
        _ -> []
      end

    Enum.map(entries, fn e ->
      %{agent_id: e.agent_id, identity_present: identity_present?(e.agent_id)}
    end)
  end

  defp safe_registry_list do
    Arbor.Agent.Registry.list()
  rescue
    _ -> {:ok, []}
  catch
    :exit, _ -> {:ok, []}
  end

  # SECURITY CRITICAL, fail-SAFE: on any error determining identity, treat as
  # PRESENT so we do NOT reap. Mirrors HeartbeatService.identity_registered?/1.
  defp identity_present?(agent_id) do
    match?({:ok, _}, Arbor.Security.identity_status(agent_id))
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # ── Intent application ──────────────────────────────────────────────

  defp apply_intent(%{action: :reap, agent_id: agent_id, reason: reason}, state) do
    Logger.warning("[Reconciler] reaping zombie agent #{agent_id} (#{reason})")

    safe_manager(fn -> Arbor.Agent.Manager.stop_agent(agent_id) end)
    emit(:agent_reaped, %{agent_id: agent_id, reason: reason})

    state
  end

  defp apply_intent(%{action: :start, agent_id: agent_id, reason: reason}, state) do
    now = System.monotonic_time(:millisecond)
    recent = recent_attempts(state, agent_id, now)

    if length(recent) < @start_limit_max do
      safe_manager(fn -> Arbor.Agent.Manager.resume_agent(agent_id, []) end)
      emit(:agent_restarted, %{agent_id: agent_id, reason: reason})
      record_attempt(state, agent_id, [now | recent])
    else
      Logger.warning(
        "[Reconciler] rate-limited start for #{agent_id} " <>
          "(#{length(recent)} attempts within #{div(@start_limit_window_ms, 60_000)}m)"
      )

      # Keep the (windowed) list so the limit stays enforced next tick.
      record_attempt(state, agent_id, recent)
    end
  end

  defp apply_intent(_other, state), do: state

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

  # ── Config ──────────────────────────────────────────────────────────

  # start_link opt wins, then application config, then hardcoded default.
  defp opt(opts, config, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(config, key, default)
    end
  end
end
