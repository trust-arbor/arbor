defmodule Mix.Tasks.Arbor.Restart do
  @shortdoc "Restart the Arbor server"
  @moduledoc """
  Stops and restarts the Arbor background server.

      $ mix arbor.restart

  Holds the exclusive lifecycle lock across the *entire* stop+start
  sequence (no other lifecycle command can interleave in the gap), and
  captures the persisted managed host *before* invoking Stop — which may
  delete the metadata file on a clean stop. That captured host is then
  passed into Start as an internal continuity host, distinct from an
  operator's `ARBOR_NODE_HOST` override: when `ARBOR_NODE_HOST` is not
  explicitly set, restart preserves the persisted running host instead of
  re-running interface auto-detection (the source of the 2026-08-02
  host-drift EPMD collision, where a WireGuard IP change made restart
  conclude the old daemon wasn't running and launch a duplicate). An
  explicit `ARBOR_NODE_HOST` still wins, relocating only after Stop has
  confirmed the old daemon is no longer live.

  If the old daemon's state cannot be safely determined (ambiguous PID
  identity), restart aborts before starting a replacement rather than risk
  a second daemon alongside an unconfirmed first one.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.Start
  alias Mix.Tasks.Arbor.Stop

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    case Config.with_lock(fn -> do_restart(args) end) do
      {:refuse, reason, detail} ->
        Mix.shell().error(Config.describe_lock_refusal(reason, detail))
        exit({:shutdown, 1})

      _ ->
        :ok
    end
  end

  defp do_restart(args) do
    captured_host = capture_persisted_host()

    Mix.shell().info("Restarting Arbor server...")

    # Exhaustive match on Stop's real post-effect outcome — not just its
    # pre-effect decision. An {:unconfirmed, _} (SIGTERM sent, exit never
    # confirmed) must abort restart exactly like {:ambiguous, _} does, or a
    # replacement could launch alongside a daemon that never actually died.
    case Stop.stop_locked(args) do
      {:ambiguous, reason} ->
        abort_restart("previous daemon state is ambiguous (#{inspect(reason)})")

      {:unconfirmed, reason} ->
        abort_restart(
          "stop signaled the previous daemon but its exit was not confirmed (#{inspect(reason)}) - refusing to risk a second daemon"
        )

      outcome
      when outcome == :already_stopped or (is_tuple(outcome) and elem(outcome, 0) == :stopped) ->
        # Brief pause to ensure the port is fully released.
        Process.sleep(500)
        Start.launch_locked(args, captured_host)
    end
  end

  defp abort_restart(reason) do
    Mix.shell().error("""

    Cannot safely restart: #{reason}. Aborting without starting a
    replacement — resolve this manually first.
    """)

    exit({:shutdown, 1})
  end

  @doc false
  def capture_persisted_host(home \\ Config.arbor_home()) do
    case Config.read_metadata(home) do
      {:ok, %{host: host}} ->
        host

      {:error, :malformed} ->
        # Ambiguous, not a crash — Start.launch_locked/2 independently
        # re-reads and refuses via decide_start/1 on :malformed_metadata;
        # this function only ever supplies a hint, never the admission
        # decision, so falling back to auto-detection here is safe.
        nil

      :absent ->
        case Config.read_pid(home) do
          {:ok, pid} ->
            case Config.verify_pid_as_arbor_node(pid) do
              {:verified_arbor, node} -> host_from_node(node)
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp host_from_node(node) do
    case String.split(node, "@", parts: 2) do
      [_id, host] -> host
      _ -> nil
    end
  end
end
