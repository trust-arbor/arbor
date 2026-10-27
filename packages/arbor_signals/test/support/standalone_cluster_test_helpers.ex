defmodule Arbor.Signals.TestSupport.ClusterHelpers do
  @moduledoc false

  def start_signal_children do
    Application.put_env(:arbor_signals, :relay_enabled, true)
    Application.put_env(:arbor_signals, :relay_batch_interval_ms, 10)
    Application.put_env(:arbor_signals, :supervision_root, {:application, :arbor_signals})
    Application.put_env(:arbor_signals, :supervision_path, [])
    {:ok, _apps} = Application.ensure_all_started(:arbor_signals)
    :ok = Arbor.Signals.restore_runtime_fixture()
  end

  def subscribe_and_forward(pattern, target_pid, label) do
    caller = self()
    ready_ref = make_ref()

    spawn(fn ->
      result =
        Arbor.Signals.Bus.subscribe(pattern, fn signal ->
          send(target_pid, {label, signal})
          :ok
        end)

      send(caller, {ready_ref, result})

      case result do
        {:ok, _subscription_id} ->
          target_ref = Process.monitor(target_pid)

          receive do
            {:DOWN, ^target_ref, :process, ^target_pid, _reason} -> :ok
          end

        _error ->
          :ok
      end
    end)

    receive do
      {^ready_ref, result} -> result
    after
      5_000 -> {:error, :subscription_start_timeout}
    end
  end

  def emit_cluster_signal(category, type, data),
    do: Arbor.Signals.emit(category, type, data, scope: :cluster)

  def emit_local_signal(category, type, data), do: Arbor.Signals.emit(category, type, data)
  def relay_stats, do: Arbor.Signals.Relay.stats()
end
