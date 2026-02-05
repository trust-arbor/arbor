defmodule Arbor.Demo.Faults.MessageQueueFlood do
  @moduledoc """
  Fault that floods a process's message queue.

  Spawns a process that receives timer ticks and sends itself messages
  it never reads, causing its message_queue_len to grow continuously.
  Detected by the monitor's `:processes` skill via message queue length threshold.
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

    pid =
      spawn_link(fn ->
        flood_loop(interval, batch_size)
      end)

    {:ok, pid}
  end

  @impl Arbor.Demo.Fault
  def clear(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    :ok
  end

  def clear(_), do: :ok

  defp flood_loop(interval, batch_size) do
    # Send batch_size messages to self that will never be received
    for _ <- 1..batch_size do
      send(self(), {:flood, :erlang.monotonic_time()})
    end

    # Only receive the timer tick, never the :flood messages
    Process.send_after(self(), :tick, interval)

    receive do
      :tick -> flood_loop(interval, batch_size)
      :stop -> :ok
    end
  end
end
