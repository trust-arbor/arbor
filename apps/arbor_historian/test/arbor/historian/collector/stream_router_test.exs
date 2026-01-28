defmodule Arbor.Historian.Collector.StreamRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.Collector.StreamRouter
  alias Arbor.Historian.TestHelpers

  describe "route/1" do
    test "always includes global stream" do
      signal = TestHelpers.build_signal()
      streams = StreamRouter.route(signal)
      assert "global" in streams
    end

    test "routes to category stream" do
      signal = TestHelpers.build_signal(category: :security, type: :authorization)
      streams = StreamRouter.route(signal)
      assert "category:security" in streams
    end

    test "routes to agent stream when agent_id in data" do
      signal = TestHelpers.build_agent_signal("agent_001")
      streams = StreamRouter.route(signal)
      assert "agent:agent_001" in streams
    end

    test "routes to agent stream when agent in source URI" do
      signal = TestHelpers.build_signal(source: "arbor://agent/agent_002/tool")
      streams = StreamRouter.route(signal)
      assert "agent:agent_002" in streams
    end

    test "routes to session stream when session_id in data" do
      signal = TestHelpers.build_session_signal("sess_xyz")
      streams = StreamRouter.route(signal)
      assert "session:sess_xyz" in streams
    end

    test "routes to correlation stream when correlation_id present" do
      signal = TestHelpers.build_signal(correlation_id: "corr_abc")
      streams = StreamRouter.route(signal)
      assert "correlation:corr_abc" in streams
    end

    test "routes to multiple streams at once" do
      signal =
        TestHelpers.build_signal(
          category: :activity,
          type: :task_completed,
          data: %{agent_id: "a1", session_id: "s1"},
          correlation_id: "c1"
        )

      streams = StreamRouter.route(signal)

      assert "global" in streams
      assert "category:activity" in streams
      assert "agent:a1" in streams
      assert "session:s1" in streams
      assert "correlation:c1" in streams
    end

    test "does not add correlation stream when correlation_id is nil" do
      signal = TestHelpers.build_signal(correlation_id: nil)
      streams = StreamRouter.route(signal)
      refute Enum.any?(streams, &String.starts_with?(&1, "correlation:"))
    end
  end

  describe "stream_id builders" do
    test "stream_id_for_agent/1" do
      assert StreamRouter.stream_id_for_agent("a1") == "agent:a1"
    end

    test "stream_id_for_category/1" do
      assert StreamRouter.stream_id_for_category(:security) == "category:security"
    end

    test "stream_id_for_session/1" do
      assert StreamRouter.stream_id_for_session("s1") == "session:s1"
    end

    test "stream_id_for_correlation/1" do
      assert StreamRouter.stream_id_for_correlation("c1") == "correlation:c1"
    end
  end
end
