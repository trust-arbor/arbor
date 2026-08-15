defmodule Arbor.SignalsSyncEmitTest do
  use ExUnit.Case, async: false

  alias Arbor.Signals
  alias Arbor.Signals.Store

  @moduletag :fast

  test "async: false does not return until the signal is queryable" do
    store = Process.whereis(Store)
    type = :sync_emit_regression
    correlation_id = "sync-#{System.unique_integer([:positive])}"

    :ok = :sys.suspend(store)
    on_exit(fn -> resume_if_suspended(store) end)

    task =
      Task.async(fn ->
        Signals.emit(:activity, type, %{}, async: false, correlation_id: correlation_id)
      end)

    assert Task.yield(task, 50) == nil

    :ok = :sys.resume(store)
    assert {:ok, :ok} = Task.yield(task, 1_000)

    assert {:ok, [signal]} =
             Signals.query(category: :activity, type: type, correlation_id: correlation_id)

    assert signal.correlation_id == correlation_id
  end

  defp resume_if_suspended(store) do
    if Process.alive?(store) do
      _ = :sys.resume(store)
    end
  catch
    :exit, _reason -> :ok
  end
end
