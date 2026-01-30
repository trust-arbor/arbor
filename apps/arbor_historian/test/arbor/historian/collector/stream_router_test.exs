defmodule Arbor.Historian.Collector.StreamRouterTest do
  use ExUnit.Case, async: true

  @moduletag :fast

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

    test "does not add correlation stream when correlation_id is empty string" do
      signal = TestHelpers.build_signal(correlation_id: "")
      streams = StreamRouter.route(signal)
      refute Enum.any?(streams, &String.starts_with?(&1, "correlation:"))
    end

    test "does not add agent stream when data has no agent_id" do
      signal = TestHelpers.build_signal(data: %{foo: "bar"}, source: "arbor://test/no_agent")
      streams = StreamRouter.route(signal)
      refute Enum.any?(streams, &String.starts_with?(&1, "agent:"))
    end

    test "does not add session stream when data has no session_id" do
      signal = TestHelpers.build_signal(data: %{foo: "bar"})
      streams = StreamRouter.route(signal)
      refute Enum.any?(streams, &String.starts_with?(&1, "session:"))
    end
  end

  describe "route/1 edge cases" do
    test "handles signal with nil data for agent extraction" do
      signal = TestHelpers.build_signal(data: nil, source: "arbor://test/no_data")
      streams = StreamRouter.route(signal)
      assert "global" in streams
      refute Enum.any?(streams, &String.starts_with?(&1, "agent:"))
    end

    test "handles source with no agent path match" do
      signal = TestHelpers.build_signal(
        data: %{},
        source: "arbor://service/foo/bar"
      )

      streams = StreamRouter.route(signal)
      assert "global" in streams
      refute Enum.any?(streams, &String.starts_with?(&1, "agent:"))
    end

    test "handles source containing agent/ substring but data has agent_id" do
      # agent_id in data takes priority (checked first)
      signal = TestHelpers.build_signal(
        data: %{agent_id: "from_data"},
        source: "arbor://agent/from_source/tool"
      )

      streams = StreamRouter.route(signal)
      assert "agent:from_data" in streams
    end

    test "extracts agent from source when data has no agent_id" do
      signal = TestHelpers.build_signal(
        data: %{other: "value"},
        source: "arbor://agent/src_agent/action"
      )

      streams = StreamRouter.route(signal)
      assert "agent:src_agent" in streams
    end

    test "handles agent_id as string key in data" do
      signal = TestHelpers.build_signal(data: %{"agent_id" => "string_key_agent"})
      streams = StreamRouter.route(signal)
      assert "agent:string_key_agent" in streams
    end

    test "handles session_id as string key in data" do
      signal = TestHelpers.build_signal(data: %{"session_id" => "string_key_session"})
      streams = StreamRouter.route(signal)
      assert "session:string_key_session" in streams
    end

    test "handles signal with nil data for session extraction" do
      signal = TestHelpers.build_signal(data: nil)
      streams = StreamRouter.route(signal)
      assert "global" in streams
      refute Enum.any?(streams, &String.starts_with?(&1, "session:"))
    end

    test "maybe_add_correlation rescue handles signals without correlation fields" do
      # Build a minimal struct-like map that lacks correlation fields entirely.
      # The rescue clause in maybe_add_correlation handles this.
      bare_signal = %{
        id: "bare_sig",
        category: :activity,
        type: :agent_started,
        data: %{},
        source: "arbor://test",
        timestamp: DateTime.utc_now()
      }

      streams = StreamRouter.route(bare_signal)
      assert "global" in streams
      refute Enum.any?(streams, &String.starts_with?(&1, "correlation:"))
    end

    test "extract_category with CloudEvents string type (arbor. prefix)" do
      # Tests extract_category with binary type having "arbor." prefix
      signal = %{
        id: "ce_sig_1",
        category: nil,
        type: "arbor.security.authorization",
        data: %{},
        source: "arbor://test",
        timestamp: DateTime.utc_now(),
        correlation_id: nil
      }

      streams = StreamRouter.route(signal)
      assert "global" in streams
      assert "category:security" in streams
    end

    test "extract_category with CloudEvents string type (no arbor. prefix)" do
      # Tests extract_category with binary type without "arbor." prefix
      signal = %{
        id: "ce_sig_2",
        category: nil,
        type: "activity.task_completed",
        data: %{},
        source: "arbor://test",
        timestamp: DateTime.utc_now(),
        correlation_id: nil
      }

      streams = StreamRouter.route(signal)
      assert "global" in streams
      assert "category:activity" in streams
    end

    test "extract_category returns nil when category is nil and type is not binary" do
      # Tests the true -> nil fallback in extract_category
      signal = %{
        id: "nil_cat_sig",
        category: nil,
        type: 12345,
        data: %{},
        source: "arbor://test",
        timestamp: DateTime.utc_now(),
        correlation_id: nil
      }

      streams = StreamRouter.route(signal)
      assert streams == ["global"]
    end

    test "parse_agent_from_source returns nil for source without agent path" do
      # The source has "agent" but not in the "/agent/" pattern
      signal = TestHelpers.build_signal(
        data: %{},
        source: "arbor://myagent-service/foo"
      )

      streams = StreamRouter.route(signal)
      refute Enum.any?(streams, &String.starts_with?(&1, "agent:"))
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
