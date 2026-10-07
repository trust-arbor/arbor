defmodule Arbor.Signals.FacadeCallbackIsolationSecurityRegressionTest do
  @moduledoc """
  Behavioral regressions for the public Signals facade.

  Subscriber code is caller supplied. A raising filter or a blocking
  synchronous handler must not crash or stall the Bus that carries ordinary
  telemetry and the load-bearing security synchronization events.
  """

  use Arbor.Signals.TestCase
  @moduletag spec: "KSEC-009"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Signals

  @tag spec: "KSEC-009"
  test "security regression: public facade isolates raising and throwing filters" do
    parent = self()

    {:ok, raising_handle} =
      Signals.subscribe("activity.facade_filter_guard", fn _signal -> :ok end,
        filter: fn _signal -> raise "filter crash" end
      )

    {:ok, throwing_handle} =
      Signals.subscribe("activity.facade_filter_guard", fn _signal -> :ok end,
        filter: fn _signal -> throw(:filter_escape) end
      )

    {:ok, healthy_handle} =
      Signals.subscribe(
        "activity.facade_filter_guard",
        fn signal ->
          send(parent, {:facade_filter_guard_delivered, signal.type})
          :ok
        end,
        async: false
      )

    on_exit(fn ->
      _ = Signals.unsubscribe(raising_handle)
      _ = Signals.unsubscribe(throwing_handle)
      _ = Signals.unsubscribe(healthy_handle)
    end)

    assert :ok = Signals.emit(:activity, :facade_filter_guard, %{}, async: false)
    assert_receive {:facade_filter_guard_delivered, :facade_filter_guard}, 1_000
    assert Signals.healthy?()

    # A callback that violates its contract is retired without affecting the
    # owner-bound handle of a healthy subscription.
    assert {:error, :not_found} = Signals.unsubscribe(raising_handle)
    assert {:error, :not_found} = Signals.unsubscribe(throwing_handle)
    assert :ok = Signals.unsubscribe(healthy_handle)
  end

  test "security regression: public facade bounds a blocking synchronous handler" do
    parent = self()

    {:ok, blocking_handle} =
      Signals.subscribe(
        "activity.facade_handler_deadline",
        fn _signal ->
          receive do
            :never_sent -> :ok
          end
        end,
        async: false
      )

    {:ok, healthy_handle} =
      Signals.subscribe(
        "activity.facade_handler_deadline",
        fn signal ->
          send(parent, {:facade_handler_deadline_delivered, signal.type})
          :ok
        end,
        async: false
      )

    on_exit(fn ->
      _ = Signals.unsubscribe(blocking_handle)
      _ = Signals.unsubscribe(healthy_handle)
    end)

    emit_task =
      Task.async(fn ->
        Signals.emit(:activity, :facade_handler_deadline, %{}, async: false)
      end)

    assert {:ok, :ok} = Task.yield(emit_task, 1_000)
    assert_receive {:facade_handler_deadline_delivered, :facade_handler_deadline}, 1_000
    assert Signals.healthy?()
    assert {:error, :not_found} = Signals.unsubscribe(blocking_handle)
    assert :ok = Signals.unsubscribe(healthy_handle)
  end
end
