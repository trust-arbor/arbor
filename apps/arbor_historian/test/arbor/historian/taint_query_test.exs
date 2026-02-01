defmodule Arbor.Historian.TaintQueryTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Historian.TaintQuery
  alias Arbor.Historian.TestHelpers

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"taint_query_#{System.unique_integer([:positive])}")

    # Seed taint events
    seed_taint_events(ctx)

    %{ctx: ctx}
  end

  defp seed_taint_events(ctx) do
    # taint_blocked events
    TestHelpers.insert_event(ctx, %{
      id: "taint_1",
      category: :security,
      type: :taint_blocked,
      timestamp: DateTime.utc_now(),
      source: "arbor://test/taint",
      data: %{
        action: "Shell.Execute",
        parameter: "command",
        parameter_role: :control,
        taint_level: :untrusted,
        taint_source: nil,
        agent_id: "agent_001",
        blocked_value_preview: nil
      },
      metadata: %{signal_id: "taint_1", source: "arbor://test/taint"}
    })

    TestHelpers.insert_event(ctx, %{
      id: "taint_2",
      category: :security,
      type: :taint_blocked,
      timestamp: DateTime.add(DateTime.utc_now(), 1, :second),
      source: "arbor://test/taint",
      data: %{
        action: "File.Write",
        parameter: "path",
        parameter_role: :control,
        taint_level: :hostile,
        taint_source: nil,
        agent_id: "agent_001",
        blocked_value_preview: nil
      },
      metadata: %{signal_id: "taint_2", source: "arbor://test/taint"}
    })

    # taint_propagated events (forming a chain)
    TestHelpers.insert_event(ctx, %{
      id: "prop_1",
      category: :security,
      type: :taint_propagated,
      timestamp: DateTime.add(DateTime.utc_now(), 2, :second),
      source: "arbor://test/taint",
      data: %{
        action: "AI.GenerateText",
        input_taint: :untrusted,
        output_taint: :derived,
        taint_source: "external_input",
        taint_chain: [],
        agent_id: "agent_002"
      },
      metadata: %{signal_id: "prop_1", source: "arbor://test/taint"}
    })

    TestHelpers.insert_event(ctx, %{
      id: "prop_2",
      category: :security,
      type: :taint_propagated,
      timestamp: DateTime.add(DateTime.utc_now(), 3, :second),
      source: "arbor://test/taint",
      data: %{
        action: "File.Read",
        input_taint: :derived,
        output_taint: :derived,
        taint_source: "prop_1",
        taint_chain: ["external_input"],
        agent_id: "agent_002"
      },
      metadata: %{signal_id: "prop_2", source: "arbor://test/taint"}
    })

    # taint_audited event
    TestHelpers.insert_event(ctx, %{
      id: "audit_1",
      category: :security,
      type: :taint_audited,
      timestamp: DateTime.add(DateTime.utc_now(), 4, :second),
      source: "arbor://test/taint",
      data: %{
        action: "Shell.Execute",
        parameter: "args",
        taint_level: :derived,
        taint_source: nil,
        agent_id: "agent_001",
        taint_policy: :permissive
      },
      metadata: %{signal_id: "audit_1", source: "arbor://test/taint"}
    })

    # taint_reduced event
    TestHelpers.insert_event(ctx, %{
      id: "reduced_1",
      category: :security,
      type: :taint_reduced,
      timestamp: DateTime.add(DateTime.utc_now(), 5, :second),
      source: "arbor://test/taint",
      data: %{
        from_level: :untrusted,
        to_level: :derived,
        reason: :human_review,
        agent_id: "agent_003"
      },
      metadata: %{signal_id: "reduced_1", source: "arbor://test/taint"}
    })

    # Non-taint security event (should be filtered out)
    TestHelpers.insert_event(ctx, %{
      id: "auth_1",
      category: :security,
      type: :authorization,
      timestamp: DateTime.add(DateTime.utc_now(), 6, :second),
      source: "arbor://test/auth",
      data: %{
        resource: "arbor://actions/execute/shell",
        action: :execute,
        granted: true
      },
      metadata: %{signal_id: "auth_1", source: "arbor://test/auth"}
    })
  end

  describe "query_taint_events/1" do
    test "returns all taint events from security stream", %{ctx: ctx} do
      {:ok, events} = TaintQuery.query_taint_events(event_log: ctx.event_log)

      # Should include: 2 blocked, 2 propagated, 1 audited, 1 reduced = 6 taint events
      # Should NOT include: 1 authorization event
      assert length(events) == 6

      types = events |> Enum.map(& &1.type) |> Enum.frequencies()
      assert types[:taint_blocked] == 2
      assert types[:taint_propagated] == 2
      assert types[:taint_audited] == 1
      assert types[:taint_reduced] == 1
    end

    test "filters by taint_level", %{ctx: ctx} do
      {:ok, events} =
        TaintQuery.query_taint_events(event_log: ctx.event_log, taint_level: :untrusted)

      # untrusted appears in: 1 blocked event, 1 propagated (as input_taint)
      assert length(events) == 2
    end

    test "filters by event_type (:taint_blocked)", %{ctx: ctx} do
      {:ok, events} =
        TaintQuery.query_taint_events(event_log: ctx.event_log, event_type: :taint_blocked)

      assert length(events) == 2
      assert Enum.all?(events, &(&1.type == :taint_blocked))
    end

    test "filters by event_type (:taint_propagated)", %{ctx: ctx} do
      {:ok, events} =
        TaintQuery.query_taint_events(event_log: ctx.event_log, event_type: :taint_propagated)

      assert length(events) == 2
      assert Enum.all?(events, &(&1.type == :taint_propagated))
    end

    test "filters by agent_id", %{ctx: ctx} do
      {:ok, events} =
        TaintQuery.query_taint_events(event_log: ctx.event_log, agent_id: "agent_001")

      # agent_001: 2 blocked, 1 audited = 3
      assert length(events) == 3
    end

    test "respects limit option", %{ctx: ctx} do
      {:ok, events} = TaintQuery.query_taint_events(event_log: ctx.event_log, limit: 2)
      assert length(events) == 2
    end

    test "returns empty list when no taint events", %{ctx: ctx} do
      {:ok, events} =
        TaintQuery.query_taint_events(event_log: ctx.event_log, agent_id: "nonexistent_agent")

      assert events == []
    end

    test "combines multiple filters", %{ctx: ctx} do
      {:ok, events} =
        TaintQuery.query_taint_events(
          event_log: ctx.event_log,
          agent_id: "agent_001",
          event_type: :taint_blocked
        )

      assert length(events) == 2
      assert Enum.all?(events, &(&1.type == :taint_blocked))
    end
  end

  describe "trace_backward/2" do
    test "follows taint chain from endpoint to origin", %{ctx: ctx} do
      {:ok, chain} = TaintQuery.trace_backward("prop_2", event_log: ctx.event_log)

      # prop_2 links back to prop_1 via taint_source
      assert length(chain) >= 1
    end

    test "returns single event for chain of length 1", %{ctx: ctx} do
      {:ok, chain} = TaintQuery.trace_backward("prop_1", event_log: ctx.event_log)

      # prop_1 has taint_source "external_input" which isn't a signal_id
      # so chain should be just this event
      assert length(chain) == 1
      assert hd(chain).signal_id == "prop_1"
    end

    test "handles missing signal_id gracefully", %{ctx: ctx} do
      {:ok, chain} = TaintQuery.trace_backward("nonexistent_signal", event_log: ctx.event_log)
      assert chain == []
    end

    test "caps at max depth", %{ctx: ctx} do
      {:ok, chain} = TaintQuery.trace_backward("prop_2", event_log: ctx.event_log, max_depth: 1)

      # With max_depth 1, should get at most 1 event
      assert length(chain) <= 1
    end
  end

  describe "trace_forward/2" do
    test "follows taint flow downstream", %{ctx: ctx} do
      # prop_1 is the source for prop_2
      {:ok, downstream} = TaintQuery.trace_forward("prop_1", event_log: ctx.event_log)

      # prop_2 has taint_source: "prop_1"
      assert length(downstream) >= 1

      downstream_ids = Enum.map(downstream, & &1.signal_id)
      assert "prop_2" in downstream_ids
    end

    test "handles no downstream events", %{ctx: ctx} do
      {:ok, downstream} = TaintQuery.trace_forward("prop_2", event_log: ctx.event_log)

      # prop_2 has no downstream events
      assert downstream == []
    end

    test "caps at max depth", %{ctx: ctx} do
      {:ok, downstream} = TaintQuery.trace_forward("prop_1", event_log: ctx.event_log, max_depth: 1)

      # With max_depth 1, should get at most a few events
      assert length(downstream) <= 5
    end
  end

  describe "taint_summary/2" do
    test "returns correct counts by event type", %{ctx: ctx} do
      {:ok, summary} = TaintQuery.taint_summary("agent_001", event_log: ctx.event_log)

      assert summary.blocked_count == 2
      assert summary.audited_count == 1
      assert summary.propagated_count == 0
      assert summary.reduced_count == 0
      assert summary.total_count == 3
    end

    test "returns taint_level_distribution", %{ctx: ctx} do
      {:ok, summary} = TaintQuery.taint_summary("agent_001", event_log: ctx.event_log)

      # agent_001 has: untrusted (blocked), hostile (blocked), derived (audited)
      assert summary.taint_level_distribution[:untrusted] == 1
      assert summary.taint_level_distribution[:hostile] == 1
      assert summary.taint_level_distribution[:derived] == 1
    end

    test "returns recent_blocks", %{ctx: ctx} do
      {:ok, summary} = TaintQuery.taint_summary("agent_001", event_log: ctx.event_log)

      assert length(summary.recent_blocks) == 2

      # Most recent first
      [first | _] = summary.recent_blocks
      assert first.action != nil
      assert first.parameter != nil
      assert first.taint_level != nil
      assert first.timestamp != nil
    end

    test "returns most_common_blocked_actions", %{ctx: ctx} do
      {:ok, summary} = TaintQuery.taint_summary("agent_001", event_log: ctx.event_log)

      # Should have Shell.Execute and File.Write each with count 1
      assert is_map(summary.most_common_blocked_actions)
      assert Map.has_key?(summary.most_common_blocked_actions, "Shell.Execute") or
               Map.has_key?(summary.most_common_blocked_actions, "File.Write")
    end

    test "returns empty summary for agent with no taint events", %{ctx: ctx} do
      {:ok, summary} = TaintQuery.taint_summary("nonexistent_agent", event_log: ctx.event_log)

      assert summary.blocked_count == 0
      assert summary.propagated_count == 0
      assert summary.audited_count == 0
      assert summary.reduced_count == 0
      assert summary.total_count == 0
      assert summary.recent_blocks == []
      assert summary.most_common_blocked_actions == %{}
    end

    test "returns summary for agent with only propagated events", %{ctx: ctx} do
      {:ok, summary} = TaintQuery.taint_summary("agent_002", event_log: ctx.event_log)

      assert summary.blocked_count == 0
      assert summary.propagated_count == 2
      assert summary.audited_count == 0
      assert summary.total_count == 2
    end
  end
end
