defmodule Arbor.Signals.SignalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Signals.Signal

  describe "new/4" do
    test "creates signal with category, type, and data" do
      signal = Signal.new(:activity, :started, %{name: "test"})

      assert signal.category == :activity
      assert signal.type == :started
      assert signal.data == %{name: "test"}
      assert String.starts_with?(signal.id, "sig_")
      assert %DateTime{} = signal.timestamp
    end

    test "creates signal with default empty data" do
      signal = Signal.new(:security, :auth_attempt)

      assert signal.data == %{}
    end

    test "accepts source option" do
      signal = Signal.new(:activity, :started, %{}, source: "agent_001")

      assert signal.source == "agent_001"
    end

    test "accepts cause_id option" do
      signal = Signal.new(:activity, :started, %{}, cause_id: "sig_parent")

      assert signal.cause_id == "sig_parent"
    end

    test "accepts correlation_id option" do
      signal = Signal.new(:activity, :started, %{}, correlation_id: "corr_123")

      assert signal.correlation_id == "corr_123"
    end

    test "accepts metadata option" do
      signal = Signal.new(:activity, :started, %{}, metadata: %{priority: :high})

      assert signal.metadata == %{priority: :high}
    end

    test "defaults metadata to empty map" do
      signal = Signal.new(:activity, :started)

      assert signal.metadata == %{}
    end

    test "defaults optional fields to nil" do
      signal = Signal.new(:activity, :started)

      assert signal.source == nil
      assert signal.cause_id == nil
      assert signal.correlation_id == nil
    end
  end

  describe "matches?/2" do
    setup do
      signal =
        Signal.new(:activity, :agent_started, %{agent_id: "a1"},
          source: "orchestrator",
          correlation_id: "corr_abc"
        )

      {:ok, signal: signal}
    end

    test "matches with empty filters", %{signal: signal} do
      assert Signal.matches?(signal, [])
    end

    test "matches by single category", %{signal: signal} do
      assert Signal.matches?(signal, category: :activity)
      refute Signal.matches?(signal, category: :security)
    end

    test "matches by category list", %{signal: signal} do
      assert Signal.matches?(signal, category: [:activity, :security])
      refute Signal.matches?(signal, category: [:security, :metrics])
    end

    test "matches by single type", %{signal: signal} do
      assert Signal.matches?(signal, type: :agent_started)
      refute Signal.matches?(signal, type: :agent_stopped)
    end

    test "matches by type list", %{signal: signal} do
      assert Signal.matches?(signal, type: [:agent_started, :agent_stopped])
      refute Signal.matches?(signal, type: [:agent_stopped, :task_completed])
    end

    test "matches by source", %{signal: signal} do
      assert Signal.matches?(signal, source: "orchestrator")
      refute Signal.matches?(signal, source: "other")
    end

    test "matches by correlation_id", %{signal: signal} do
      assert Signal.matches?(signal, correlation_id: "corr_abc")
      refute Signal.matches?(signal, correlation_id: "corr_xyz")
    end

    test "matches by since filter", %{signal: signal} do
      past = DateTime.add(signal.timestamp, -60, :second)
      future = DateTime.add(signal.timestamp, 60, :second)

      assert Signal.matches?(signal, since: past)
      assert Signal.matches?(signal, since: signal.timestamp)
      refute Signal.matches?(signal, since: future)
    end

    test "matches by until filter", %{signal: signal} do
      past = DateTime.add(signal.timestamp, -60, :second)
      future = DateTime.add(signal.timestamp, 60, :second)

      assert Signal.matches?(signal, until: future)
      assert Signal.matches?(signal, until: signal.timestamp)
      refute Signal.matches?(signal, until: past)
    end

    test "ignores unknown filter keys", %{signal: signal} do
      assert Signal.matches?(signal, unknown_key: "value")
    end

    test "combines multiple filters with AND logic", %{signal: signal} do
      assert Signal.matches?(signal, category: :activity, type: :agent_started)
      refute Signal.matches?(signal, category: :activity, type: :agent_stopped)
      refute Signal.matches?(signal, category: :security, type: :agent_started)
    end
  end
end
