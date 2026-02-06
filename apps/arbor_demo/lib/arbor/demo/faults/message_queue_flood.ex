defmodule Arbor.Demo.Faults.MessageQueueFlood do
  @moduledoc """
  Fault that floods a process's message queue.

  Spawns a process that receives timer ticks and sends itself messages
  it never reads, causing its message_queue_len to grow continuously.
  Detected by the monitor's `:processes` skill via message queue length threshold.

  ## Remediation (for DebugAgent to discover)

  The fix is to kill the process with the bloated message queue. The DebugAgent
  must identify which process has the problem through BEAM inspection, not by
  knowing this is a "MessageQueueFlood" fault.
  """
  @behaviour Arbor.Demo.Fault

  @default_interval_ms 50
  @default_batch_size 20

  @impl Arbor.Demo.Fault
  def name, do: :message_queue_flood

  @impl Arbor.Demo.Fault
  def description, do: "Floods a process message queue with unprocessed messages"

  @impl Arbor.Demo.Fault
  def detectable_by, do: [:processes]

  @impl Arbor.Demo.Fault
  def inject(opts \\ []) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    correlation_id = generate_correlation_id()

    # Use sync handshake to ensure process is initialized before returning
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        # Store correlation_id in process dictionary for tracing
        Process.put(:arbor_correlation_id, correlation_id)
        Process.put(:arbor_fault_type, :message_queue_flood)
        # Signal parent that we're ready
        send(parent, {ref, :ready})
        flood_loop(interval, batch_size)
      end)

    # Wait for process to finish initialization
    receive do
      {^ref, :ready} -> :ok
    after
      5_000 -> raise "MessageQueueFlood process failed to start"
    end

    # Emit signal for Historian tracing
    emit_injection_signal(correlation_id, pid)

    {:ok, pid, correlation_id}
  end

  defp flood_loop(interval, batch_size) do
    # Send batch_size messages to self that will never be received
    for _ <- 1..batch_size do
      send(self(), {:flood, :erlang.monotonic_time()})
    end

    # Only receive the timer tick, never the :flood messages
    Process.send_after(self(), :tick, interval)

    receive do
      :tick -> flood_loop(interval, batch_size)
    end
  end

  defp generate_correlation_id do
    "fault_mqf_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_injection_signal(correlation_id, pid) do
    Arbor.Signals.emit(:demo, :fault_injected, %{
      fault: :message_queue_flood,
      correlation_id: correlation_id,
      pid: inspect(pid),
      injected_at: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
