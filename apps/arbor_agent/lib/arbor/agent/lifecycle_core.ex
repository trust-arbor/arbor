defmodule Arbor.Agent.LifecycleCore do
  @moduledoc """
  Pure decision core for agent-lifecycle **reconciliation**: desired (persisted)
  state vs actual (live) state → a list of reconcile intents. No processes, no IO,
  no GenServer calls — a pure function of two snapshots, so every orphan class is a
  table-test (the test surface the orphaned-heartbeat bugs never had).

  Sibling to `Arbor.Agent.ConfigCore`; the imperative shell is
  `Arbor.Agent.Reconciler`, which snapshots both sides and applies the intents.

  ## The orphan classes it decides (audit: agent-lifecycle-orphan-audit-2026-07-04)

    * **G1 — desired-running but absent.** An `auto_start` agent with no live
      process (node restarted, crashed past max-restarts, killed externally).
      → `:start` (honor `auto_start`; the continuous generalization of Bootstrap),
      or `:leave_alone` under a conservative policy.
    * **G2 — identity-gone zombie.** A live agent whose identity no longer exists.
      The heartbeat's `@max_no_identity_beats` makes it go quiet but leaves the
      process resident (quiet ≠ reaped). → `:reap`.

  Everything consistent (alive + identity present, or not-desired + not-running)
  produces no intent.

  ## Security posture

  Reaping the wrong agent is a fail-open, so the caller MUST resolve
  `identity_present` conservatively: on any error determining identity status,
  treat it as PRESENT (don't reap on uncertainty). This core only decides; it
  trusts the facts it's given.
  """

  # ── Types ──────────────────────────────────────────────────────────────────

  @type action :: :start | :reap | :leave_alone

  @typedoc "A persisted agent record's reconcile-relevant fields."
  @type desired :: %{required(:agent_id) => String.t(), required(:auto_start) => boolean()}

  @typedoc "A live agent's reconcile-relevant facts (already alive-filtered by the shell)."
  @type actual :: %{required(:agent_id) => String.t(), required(:identity_present) => boolean()}

  @type intent :: %{agent_id: String.t(), action: action(), reason: atom()}

  # ── Reduce ─────────────────────────────────────────────────────────────────

  @doc """
  Reconcile `desired` (persisted) against `actual` (live) → a list of intents.

  Options:
    * `:g1_policy` — what to do with a desired-but-absent `auto_start` agent:
      `:start` (default, honor auto_start) or `:leave_alone` (report-only).

  Only actionable intents are returned (`:start` / `:reap`); consistent agents
  produce nothing. Intents are duplicate-free: G1 requires absence-from-actual and
  G2 requires presence-in-actual, so no agent yields both.
  """
  @spec reconcile([desired()], [actual()], keyword()) :: [intent()]
  def reconcile(desired, actual, opts \\ []) when is_list(desired) and is_list(actual) do
    g1_policy = Keyword.get(opts, :g1_policy, :start)
    actual_ids = MapSet.new(actual, & &1.agent_id)

    g1 =
      for %{agent_id: id, auto_start: true} <- desired,
          not MapSet.member?(actual_ids, id),
          g1_policy == :start do
        %{agent_id: id, action: :start, reason: :desired_running_but_absent}
      end

    g2 =
      for %{agent_id: id, identity_present: false} <- actual do
        %{agent_id: id, action: :reap, reason: :identity_gone}
      end

    g1 ++ g2
  end

  # ── Convert ────────────────────────────────────────────────────────────────

  @doc "Summarize a set of intents by action, for logging/observability."
  @spec summarize([intent()]) :: %{start: non_neg_integer(), reap: non_neg_integer()}
  def summarize(intents) when is_list(intents) do
    Enum.reduce(intents, %{start: 0, reap: 0}, fn
      %{action: :start}, acc -> Map.update!(acc, :start, &(&1 + 1))
      %{action: :reap}, acc -> Map.update!(acc, :reap, &(&1 + 1))
      _, acc -> acc
    end)
  end
end
