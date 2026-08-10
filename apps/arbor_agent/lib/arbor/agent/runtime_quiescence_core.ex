defmodule Arbor.Agent.RuntimeQuiescenceCore do
  @moduledoc """
  Pure decision core for runtime ownership classification and bounded quiescence.

  All functions are pure (no IO, no GenServer, no `Process`, no `System`, no
  `node/0`). The imperative shells — `Arbor.Agent.Registry` for observation and
  `Arbor.Agent.RuntimeQuiescence` for the drain loop — gather the facts and
  interpret the decisions. This is the CRC "Construct-Reduce-Convert" core for
  Phase 4C C2B; it is NOT a graph.

  ## Facts (gathered by the shell)

    * `local_fact` — the local ETS registry observation:
      `{:ok, pid}` (one live local entry) | `:absent` (no entry) |
      `:inconsistent` (a present-but-remote/dead/malformed entry) |
      `:unavailable` (table gone / malformed shape).
    * `pg_fact` — the exact `:pg` group observation:
      `{:ok, {[pid_local], remote_count}}` | `:unavailable`.

  ## Classification invariant

  Absence requires positive empty observations from BOTH sources. A present but
  bad ETS entry is inconsistency → `:ambiguous` (never `:absent`), so a pg-empty
  observation cannot falsely prove absence.
  """

  @type local_fact :: {:ok, pid()} | :absent | :inconsistent | :unavailable
  @type pg_fact :: {:ok, {[pid()], non_neg_integer()}} | :unavailable

  @type class :: :absent | :local_owner | :remote_owner | :ambiguous | :unavailable

  @type fail_reason ::
          :drain_timeout | :remote_owner | :ambiguous_ownership | :observation_unavailable

  # ── Classify ────────────────────────────────────────────────────────

  @doc """
  Classify exact-target runtime ownership from a local registry fact and a pg
  membership fact.

  Never returns `:absent` unless BOTH sources positively observe empty. A
  present-but-remote/dead/malformed local entry yields `:ambiguous` (or
  `:unavailable` when either source is unobservable).
  """
  @spec classify_ownership(local_fact(), pg_fact()) :: class()
  def classify_ownership(:unavailable, _pg_fact), do: :unavailable
  def classify_ownership(_local_fact, :unavailable), do: :unavailable
  def classify_ownership(:inconsistent, _pg_fact), do: :ambiguous

  def classify_ownership(local_fact, {:ok, {locals, remote_count}}) do
    classify_available(local_fact, locals, remote_count)
  end

  defp classify_available({:ok, entry_pid}, [member_pid], 0) when member_pid == entry_pid,
    do: :local_owner

  defp classify_available({:ok, _entry_pid}, _locals, _remote_count), do: :ambiguous
  defp classify_available(:absent, [], 0), do: :absent
  defp classify_available(:absent, [], 1), do: :remote_owner
  defp classify_available(:absent, _locals, _remote_count), do: :ambiguous

  # ── Pre-stop decision ───────────────────────────────────────────────

  @doc """
  Decide the pre-stop action for a classification.

  `:absent` succeeds without stopping (`was_running: false`); `:local_owner`
  stops once; every other class fails closed without stopping.
  """
  @spec pre_stop_decision(class()) ::
          {:succeed, false} | :stop | {:fail, fail_reason()}
  def pre_stop_decision(:absent), do: {:succeed, false}
  def pre_stop_decision(:local_owner), do: :stop
  def pre_stop_decision(:remote_owner), do: {:fail, :remote_owner}
  def pre_stop_decision(:ambiguous), do: {:fail, :ambiguous_ownership}
  def pre_stop_decision(:unavailable), do: {:fail, :observation_unavailable}

  # ── Drain step ──────────────────────────────────────────────────────

  @doc """
  Decide one drain iteration after a confirmed local stop.

  `:absent` drains (success); `:remote_owner` and `:unavailable` fail
  immediately (clear bad signal / blind); `:local_owner` and `:ambiguous` poll
  — after a confirmed local stop the ETS entry is unregistered immediately but
  `:pg` removes the now-dead member via an asynchronous DOWN, so a bounded
  number of iterations legitimately observe `:ambiguous` before `:absent`.
  Polling tolerates that convergence lag; the bounded deadline turns persistence
  into `:drain_timeout`. Never succeeds on non-absence.
  """
  @spec drain_step(class(), boolean()) ::
          :drained | :poll | {:fail, fail_reason()}
  def drain_step(:absent, _deadline_exceeded?), do: :drained
  def drain_step(:remote_owner, _deadline_exceeded?), do: {:fail, :remote_owner}

  def drain_step(:unavailable, _deadline_exceeded?), do: {:fail, :observation_unavailable}

  def drain_step(:local_owner, true), do: {:fail, :drain_timeout}
  def drain_step(:local_owner, false), do: :poll
  def drain_step(:ambiguous, true), do: {:fail, :drain_timeout}
  def drain_step(:ambiguous, false), do: :poll
end
