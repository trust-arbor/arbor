defmodule Arbor.Orchestrator.HeartbeatRefresher do
  @moduledoc """
  Keeps a pipeline's heartbeat fresh during long-blocking operations.

  The engine touches the heartbeat once per node boundary
  (`Engine.maybe_touch_heartbeat/1`). For nodes that block for longer
  than the RecoveryCoordinator's stale threshold (90s today) — long
  reasoning-model calls, HITL approval waits, multi-minute tool loops —
  the heartbeat goes stale even though everything is healthy. The
  RecoveryCoordinator's owner-still-connected check prevents false
  recovery, but the log noise drowns out real warnings.

  This module wraps a blocking call with a background ticker that
  periodically calls `JobRegistry.touch_heartbeat/1` so the pipeline
  stays visibly alive. The ticker:

    - Runs in a separate, unlinked process so a failure in the
      blocking call can't take the ticker down (and vice versa)
    - Self-terminates when the caller's `after` clause kills it
    - Is a no-op when `run_id` is `nil` (out-of-engine call sites)
    - Catches and swallows JobRegistry errors — refreshing is
      best-effort, never the failure axis

  See
  `.arbor/roadmap/0-inbox/recovery-coordinator-stale-heartbeat-during-llm-calls.md`.
  """

  require Logger

  alias Arbor.Orchestrator.JobRegistry

  @default_interval_ms 30_000

  @doc """
  Run `fun` while periodically refreshing the heartbeat for `run_id`.

  Returns whatever `fun` returns. Exceptions from `fun` propagate
  normally; the ticker is always cleaned up via the `after` clause.

  When `run_id` is `nil`, `fun` is invoked directly with no ticker
  overhead — useful for call sites that don't have an engine run
  context (manual RPC, test fixtures, etc.).

  Options:
    - `:interval_ms` — how often to touch the heartbeat. Default
      30_000 ms (one third of the 90s stale threshold, so two
      consecutive misses still leaves the pipeline healthy).
  """
  @spec with_heartbeat_refresh(String.t() | nil, (-> result), keyword()) :: result
        when result: term()
  def with_heartbeat_refresh(run_id, fun, opts \\ [])

  def with_heartbeat_refresh(nil, fun, _opts) when is_function(fun, 0) do
    fun.()
  end

  def with_heartbeat_refresh(run_id, fun, opts)
      when is_binary(run_id) and is_function(fun, 0) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    ticker_pid = start_ticker(run_id, interval_ms)

    try do
      fun.()
    after
      stop_ticker(ticker_pid)
    end
  end

  # ----------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------

  # Spawned unlinked so a crash here can't bring down the caller.
  # The caller's `after` clause is the only thing that stops it.
  defp start_ticker(run_id, interval_ms) do
    spawn(fn -> tick_loop(run_id, interval_ms) end)
  end

  defp stop_ticker(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp tick_loop(run_id, interval_ms) do
    Process.sleep(interval_ms)

    try do
      JobRegistry.touch_heartbeat(run_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    tick_loop(run_id, interval_ms)
  end
end
