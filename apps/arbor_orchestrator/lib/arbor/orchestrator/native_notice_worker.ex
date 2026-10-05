defmodule Arbor.Orchestrator.NativeNoticeWorker do
  @moduledoc false
  # Mechanical ownership handshake, not graph data or a new execution handler.
  def open_source(nil), do: nil

  def open_source(authority) do
    case Arbor.Security.open_native_notice_source(authority) do
      {:ok, source} -> source
      _ -> nil
    end
  end

  def release(worker, reference, source) do
    # Never queue an opaque bootstrap before its actual receiver acknowledges
    # sensitive startup. The fresh private reference is mechanical correlation.
    receive do
      {:native_notice_worker_ready, ^reference, ^worker} ->
        release_ready(worker, reference, source)
    after
      5_000 -> exit(:native_notice_worker_ready_timeout)
    end
  end

  defp release_ready(worker, reference, source) do
    bootstrap =
      case source do
        nil ->
          nil

        source ->
          case Arbor.Security.delegate_native_notice_worker(source, worker) do
            {:ok, bootstrap} -> bootstrap
            _ -> nil
          end
      end

    send(worker, {:native_notice_worker, reference, bootstrap})
    :ok
  end

  def await(reference, owner) do
    Process.flag(:sensitive, true)
    monitor = Process.monitor(owner)
    send(owner, {:native_notice_worker_ready, reference, self()})

    try do
      receive do
        {:native_notice_worker, ^reference, nil} ->
          :ok

        {:native_notice_worker, ^reference, bootstrap} ->
          case Arbor.Security.claim_native_notice_worker(bootstrap) do
            :ok -> :ok
            _ -> exit(:native_notice_worker_refused)
          end

        {:DOWN, ^monitor, :process, ^owner, _} ->
          exit(:native_notice_source_lost)
      after
        5_000 -> exit(:native_notice_worker_timeout)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end
end
