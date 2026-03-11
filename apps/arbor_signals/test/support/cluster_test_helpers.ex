defmodule Arbor.Signals.ClusterTestHelpers do
  @moduledoc """
  Helper functions that run on remote nodes during cluster integration tests.

  These are compiled on the remote node via LocalCluster's `files:` option,
  making them available for :erpc.call.
  """

  @doc "Start signal infrastructure children on the current node."
  def start_signal_children do
    children = [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.Bus, []},
      {Arbor.Signals.Relay, []}
    ]

    Application.put_env(:arbor_signals, :relay_enabled, true)
    Application.put_env(:arbor_signals, :relay_batch_interval_ms, 10)

    for child <- children do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} ->
          {mod, _} = child
          Supervisor.delete_child(Arbor.Signals.Supervisor, mod)
          Supervisor.start_child(Arbor.Signals.Supervisor, child)
        _ -> :ok
      end
    end

    :ok
  end

  @doc "Subscribe to a pattern and forward matching signals to the given pid."
  def subscribe_and_forward(pattern, target_pid, label) do
    Arbor.Signals.Bus.subscribe(pattern, fn signal ->
      send(target_pid, {label, signal})
      :ok
    end)
  end

  @doc "Emit a cluster-scoped signal."
  def emit_cluster_signal(category, type, data) do
    Arbor.Signals.emit(category, type, data, scope: :cluster)
  end

  @doc "Emit a local-scoped signal (default)."
  def emit_local_signal(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  end

  @doc "Get relay stats."
  def relay_stats do
    Arbor.Signals.Relay.stats()
  end
end
