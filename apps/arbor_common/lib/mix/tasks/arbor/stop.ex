defmodule Mix.Tasks.Arbor.Stop do
  @shortdoc "Stop the running Arbor server"
  @moduledoc """
  Gracefully stops the Arbor background server.

      $ mix arbor.stop

  Resolves the *persisted* managed node identity (from
  `~/.arbor/arbor-dev.meta.json`, or the legacy PID file when no metadata
  exists) rather than a freshly re-detected host, and verifies the PID
  through an exact, bounded process-identity check before ever signaling
  it. Sends `:init.stop/1` to the resolved node for a clean OTP shutdown,
  falling back to SIGTERM only against a *verified* PID. If the recorded
  PID cannot be verified either way, nothing is signaled — the state is
  reported as ambiguous and requires manual inspection.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.LifecycleIdentity

  @shutdown_timeout_ms 10_000
  @poll_interval_ms 500

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    case Config.with_lock(fn -> stop_locked(args) end) do
      {:refuse, reason, detail} ->
        Mix.shell().error(Config.describe_lock_refusal(reason, detail))
        exit({:shutdown, 1})

      {:ambiguous, _reason} ->
        exit({:shutdown, 1})

      {:unconfirmed, _reason} ->
        exit({:shutdown, 1})

      outcome when outcome == :already_stopped or elem(outcome, 0) == :stopped ->
        :ok
    end
  end

  @doc false
  # Called directly by `Mix.Tasks.Arbor.Restart`, which already holds the
  # lifecycle lock — must never re-acquire it. Returns the *post-effect*
  # outcome (not the pre-effect `LifecycleIdentity.decide_stop/1` decision)
  # so Restart can tell a confirmed stop apart from one that was merely
  # attempted — an unconfirmed SIGTERM must abort Restart just as surely
  # as an outright ambiguous state, or Restart could launch a replacement
  # alongside a daemon that never actually exited.
  @spec stop_locked(list()) ::
          {:stopped, String.t()}
          | :already_stopped
          | {:unconfirmed, atom()}
          | {:ambiguous, atom()}
  def stop_locked(_args) do
    facts = gather_stop_facts()

    case LifecycleIdentity.decide_stop(facts) do
      {:stop_via_verified, node, pid, try_rpc?} ->
        perform_stop(node, pid, try_rpc?)

      {:already_stopped, cleanup} ->
        report_already_stopped(cleanup)
        :already_stopped

      {:ambiguous, detail} ->
        report_ambiguous(detail)
        {:ambiguous, detail.reason}
    end
  end

  defp gather_stop_facts do
    metadata = Config.read_metadata()

    metadata_pid_check =
      case metadata do
        {:ok, meta} -> Config.verify_pid_as_arbor_node(meta.pid)
        _ -> nil
      end

    {legacy_pid_present?, legacy_pid, legacy_pid_check} =
      if metadata == :absent, do: legacy_pid_facts(), else: {false, nil, nil}

    %{
      metadata: metadata,
      metadata_pid_check: metadata_pid_check,
      legacy_pid_present?: legacy_pid_present?,
      legacy_pid: legacy_pid,
      legacy_pid_check: legacy_pid_check,
      node_ping: node_ping(metadata, legacy_pid_check)
    }
  end

  # A malformed legacy PID file is present-but-untrustworthy, never :absent
  # — admission/stop decisions must fail closed (ambiguous) rather than
  # concluding nothing is tracked.
  defp legacy_pid_facts do
    case Config.read_pid() do
      :absent -> {false, nil, nil}
      {:error, :malformed} -> {true, nil, :unverified}
      {:ok, pid} -> {true, pid, Config.verify_pid_as_arbor_node(pid)}
    end
  end

  defp node_ping({:ok, meta}, _legacy_check) do
    if Config.node_alive?(meta.node), do: :pong, else: :pang
  end

  defp node_ping(_metadata, {:verified_arbor, node}) do
    if Config.node_alive?(node), do: :pong, else: :pang
  end

  defp node_ping(_metadata, _legacy_check), do: :not_attempted

  defp perform_stop(node, pid, try_rpc?) do
    Mix.shell().info("Stopping Arbor server...")

    if try_rpc? do
      :rpc.call(Config.node_atom(node), :init, :stop, [0])

      case await_graceful_stop(node, pid, @shutdown_timeout_ms) do
        :confirmed_stopped ->
          cleanup_tracking_files()
          Mix.shell().info("Arbor server stopped.")
          {:stopped, node}

        :escalate_to_signal ->
          Mix.shell().info("Clean stop not confirmed; re-verifying and sending SIGTERM...")
          signal_and_cleanup(pid, node)
      end
    else
      signal_and_cleanup(pid, node)
    end
  end

  # Confirm the signaled process has actually exited before deleting
  # tracking state — SIGTERM is not guaranteed to be immediate (or heeded
  # at all), so cleaning up unconditionally right after sending it could
  # discard the only record of a daemon that's still alive.
  @force_stop_confirm_timeout_ms 5_000

  # Reverifies `pid`'s identity as `expected_node` immediately before ever
  # signaling it (via the shared `Config.signal_if_verified/3` boundary,
  # the only place either Start or Stop ever delivers a real signal), then
  # confirms actual OS-level exit before cleaning up tracking state.
  defp signal_and_cleanup(pid, expected_node) do
    case Config.signal_if_verified(pid, expected_node, :sigterm) do
      {:signaled, _check} ->
        if Config.await_exit?(pid, @force_stop_confirm_timeout_ms) do
          cleanup_tracking_files()
          Mix.shell().info("Arbor server stopped (forced).")
          {:stopped, expected_node}
        else
          Mix.shell().error("""

          Sent SIGTERM to pid #{pid}, but it has not exited after
          #{div(@force_stop_confirm_timeout_ms, 1000)}s. Tracking state was
          left in place so this daemon remains discoverable — verify manually
          and re-run `mix arbor.stop` once it has actually exited.
          """)

          {:unconfirmed, :sigterm_not_confirmed}
        end

      {:refused, check} ->
        Mix.shell().error("""

        PID #{pid} could not be reverified as #{expected_node} immediately
        before signaling (#{inspect(check)}). Nothing was signaled — tracking
        state left in place; inspect manually.
        """)

        {:ambiguous, :signal_identity_check_failed}
    end
  end

  # `node_unreachable?` (distributed-Erlang reachability) is necessary but
  # not sufficient proof the OS process exited — a partition, an EPMD
  # hiccup, or net_ticktime expiry can all make a node stop answering
  # `net_adm:ping` while its OS PID is still very much alive. Both facts
  # are gathered and handed to the pure `decide_stop_confirmation/1` table;
  # anything short of "unreachable AND OS-confirmed-exited" escalates to a
  # reverified SIGTERM rather than being cleaned up as if already stopped.
  defp await_graceful_stop(_node, _pid, remaining) when remaining <= 0 do
    LifecycleIdentity.decide_stop_confirmation(%{node_unreachable?: false, os_exited?: false})
  end

  defp await_graceful_stop(node, pid, remaining) do
    Process.sleep(@poll_interval_ms)

    if Config.node_alive?(node) do
      await_graceful_stop(node, pid, remaining - @poll_interval_ms)
    else
      LifecycleIdentity.decide_stop_confirmation(%{
        node_unreachable?: true,
        os_exited?: Config.await_exit?(pid, @force_stop_confirm_timeout_ms)
      })
    end
  end

  defp report_already_stopped(cleanup) do
    if :pid_file in cleanup, do: File.rm(Config.pid_file())
    if :metadata_file in cleanup, do: File.rm(Config.metadata_file())
    Mix.shell().info("Arbor is not running.")
  end

  defp cleanup_tracking_files do
    File.rm(Config.pid_file())
    File.rm(Config.metadata_file())
  end

  defp report_ambiguous(%{reason: :node_identity_mismatch}) do
    Mix.shell().error("""

    Persisted metadata's node does not match the live process at its
    recorded PID. Nothing was signaled — inspect #{Config.metadata_file()}
    manually.
    """)
  end

  defp report_ambiguous(%{reason: :ambiguous_metadata_pid}) do
    Mix.shell().error("""

    Cannot verify whether the PID recorded in #{Config.metadata_file()}
    belongs to a managed Arbor daemon. Nothing was signaled.
    """)
  end

  defp report_ambiguous(%{reason: :ambiguous_legacy_state}) do
    Mix.shell().error("""

    Cannot verify the process recorded in #{Config.pid_file()}.
    Nothing was signaled.
    """)
  end

  defp report_ambiguous(%{reason: :malformed_canonical_metadata}) do
    Mix.shell().error("""

    #{Config.metadata_file()} exists but is malformed or fails local
    identity validation. It has been left untouched — nothing was
    signaled, and it was not treated as "not running." Inspect it
    manually before retrying.
    """)
  end

  defp report_ambiguous(detail) do
    Mix.shell().error(
      "Cannot safely determine whether a managed Arbor daemon is running (#{inspect(detail)}). Nothing was signaled."
    )
  end
end
