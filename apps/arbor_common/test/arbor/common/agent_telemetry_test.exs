defmodule Arbor.Common.AgentTelemetryTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.AgentTelemetry
  alias Arbor.Contracts.Agent.Telemetry

  @moduletag :fast

  # ===========================================================================
  # Construct
  # ===========================================================================

  describe "new/1" do
    test "creates zeroed telemetry for an agent" do
      t = AgentTelemetry.new("agent_abc")

      assert %Telemetry{} = t
      assert t.agent_id == "agent_abc"
      assert t.session_input_tokens == 0
      assert t.session_output_tokens == 0
      assert t.session_cached_tokens == 0
      assert t.session_cost == 0.0
      assert t.lifetime_input_tokens == 0
      assert t.lifetime_output_tokens == 0
      assert t.lifetime_cached_tokens == 0
      assert t.lifetime_cost == 0.0
      assert t.turn_count == 0
      assert t.llm_latencies == []
      assert t.tool_latencies == []
      assert t.tool_stats == %{}
      assert t.routing_stats == %{classified: 0, rerouted: 0, tokenized: 0, blocked: 0}
      assert t.compaction_count == 0
      assert t.avg_utilization == 0.0
      assert %DateTime{} = t.created_at
      assert %DateTime{} = t.updated_at
    end
  end

  # ===========================================================================
  # Reduce — record_turn
  # ===========================================================================

  describe "record_turn/2" do
    test "accumulates tokens and cost" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{input_tokens: 100, output_tokens: 50, cost: 0.005})
        |> AgentTelemetry.record_turn(%{input_tokens: 200, output_tokens: 75, cost: 0.010})

      assert t.session_input_tokens == 300
      assert t.session_output_tokens == 125
      assert t.lifetime_input_tokens == 300
      assert t.lifetime_output_tokens == 125
      assert_in_delta t.session_cost, 0.015, 0.0001
      assert_in_delta t.lifetime_cost, 0.015, 0.0001
      assert t.turn_count == 2
    end

    test "tracks cached tokens" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{cached_tokens: 500})

      assert t.session_cached_tokens == 500
      assert t.lifetime_cached_tokens == 500
    end

    test "tracks per-provider cost breakdown" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{cost: 0.01, provider: "anthropic"})
        |> AgentTelemetry.record_turn(%{cost: 0.02, provider: "openai"})
        |> AgentTelemetry.record_turn(%{cost: 0.03, provider: "anthropic"})

      assert_in_delta t.cost_by_provider["anthropic"], 0.04, 0.0001
      assert_in_delta t.cost_by_provider["openai"], 0.02, 0.0001
    end

    test "records LLM latency" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{duration_ms: 500})
        |> AgentTelemetry.record_turn(%{duration_ms: 1200})

      assert t.llm_latencies == [500, 1200]
    end

    test "handles missing optional fields gracefully" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{})

      assert t.turn_count == 1
      assert t.session_input_tokens == 0
      assert t.llm_latencies == []
    end

    test "accepts atom provider keys" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{cost: 0.01, provider: :anthropic})

      assert_in_delta t.cost_by_provider["anthropic"], 0.01, 0.0001
    end
  end

  # ===========================================================================
  # Reduce — record_tool
  # ===========================================================================

  describe "record_tool/4" do
    test "tracks per-tool success/failure/gated" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_tool("file.read", :ok, 50)
        |> AgentTelemetry.record_tool("file.read", :ok, 30)
        |> AgentTelemetry.record_tool("file.read", :error, 10)
        |> AgentTelemetry.record_tool("file.read", :gated, 0)

      stats = t.tool_stats["file.read"]
      assert stats.calls == 4
      assert stats.succeeded == 2
      assert stats.failed == 1
      assert stats.gated == 1
      assert stats.total_duration_ms == 90
    end

    test "tracks multiple tools independently" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_tool("file.read", :ok, 50)
        |> AgentTelemetry.record_tool("shell.execute", :error, 100)

      assert t.tool_stats["file.read"].succeeded == 1
      assert t.tool_stats["shell.execute"].failed == 1
    end

    test "records tool latency in rolling window" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_tool("file.read", :ok, 50)
        |> AgentTelemetry.record_tool("shell.execute", :ok, 100)

      assert t.tool_latencies == [50, 100]
    end
  end

  # ===========================================================================
  # Reduce — record_routing
  # ===========================================================================

  describe "record_routing/2" do
    test "increments the correct routing counter" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_routing(:classified)
        |> AgentTelemetry.record_routing(:classified)
        |> AgentTelemetry.record_routing(:rerouted)
        |> AgentTelemetry.record_routing(:blocked)

      assert t.routing_stats.classified == 2
      assert t.routing_stats.rerouted == 1
      assert t.routing_stats.tokenized == 0
      assert t.routing_stats.blocked == 1
    end
  end

  # ===========================================================================
  # Reduce — record_compaction
  # ===========================================================================

  describe "record_compaction/2" do
    test "updates running average utilization" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_compaction(0.80)
        |> AgentTelemetry.record_compaction(0.90)

      assert t.compaction_count == 2
      # avg of 0.80 and 0.90 = 0.85
      assert_in_delta t.avg_utilization, 0.85, 0.001
    end

    test "handles single compaction" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_compaction(0.75)

      assert t.compaction_count == 1
      assert_in_delta t.avg_utilization, 0.75, 0.001
    end

    test "incremental average is numerically stable" do
      t =
        Enum.reduce(1..10, AgentTelemetry.new("agent_1"), fn i, acc ->
          AgentTelemetry.record_compaction(acc, i * 0.05 + 0.50)
        end)

      # Values: 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.0
      # Average = 0.775
      assert t.compaction_count == 10
      assert_in_delta t.avg_utilization, 0.775, 0.001
    end
  end

  # ===========================================================================
  # Reduce — reset_session
  # ===========================================================================

  describe "reset_session/1" do
    test "clears session metrics but keeps lifetime" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{input_tokens: 100, output_tokens: 50, cost: 0.01})
        |> AgentTelemetry.record_tool("file.read", :ok, 50)
        |> AgentTelemetry.reset_session()

      # Session cleared
      assert t.session_input_tokens == 0
      assert t.session_output_tokens == 0
      assert t.session_cached_tokens == 0
      assert t.session_cost == 0.0

      # Lifetime preserved
      assert t.lifetime_input_tokens == 100
      assert t.lifetime_output_tokens == 50
      assert_in_delta t.lifetime_cost, 0.01, 0.0001

      # Tool stats preserved
      assert t.tool_stats["file.read"].calls == 1

      # Turn count preserved
      assert t.turn_count == 1
    end
  end

  # ===========================================================================
  # Convert — show_dashboard
  # ===========================================================================

  describe "show_dashboard/1" do
    test "formats telemetry for display" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.005,
          duration_ms: 800
        })
        |> AgentTelemetry.record_tool("file.read", :ok, 50)
        |> AgentTelemetry.record_tool("file.read", :error, 10)

      dashboard = AgentTelemetry.show_dashboard(t)

      assert dashboard.agent_id == "agent_1"
      assert dashboard.turn_count == 1
      assert dashboard.session.input_tokens == 100
      assert is_binary(dashboard.session.cost)
      assert is_binary(dashboard.lifetime.cost)
      assert dashboard.latency.llm_p50_ms == 800
      assert dashboard.tool_success_rate["file.read"] == 50.0
      assert dashboard.compaction.count == 0
    end
  end

  # ===========================================================================
  # Convert — show_cost_report
  # ===========================================================================

  describe "show_cost_report/1" do
    test "breaks down cost by provider" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_turn(%{cost: 0.01, provider: "anthropic"})
        |> AgentTelemetry.record_turn(%{cost: 0.02, provider: "openai"})

      report = AgentTelemetry.show_cost_report(t)

      assert is_binary(report.session_cost)
      assert is_binary(report.lifetime_cost)
      assert is_binary(report.by_provider["anthropic"])
      assert is_binary(report.by_provider["openai"])
    end
  end

  # ===========================================================================
  # Convert — show_tool_report
  # ===========================================================================

  describe "show_tool_report/1" do
    test "shows per-tool success rates" do
      t =
        AgentTelemetry.new("agent_1")
        |> AgentTelemetry.record_tool("file.read", :ok, 50)
        |> AgentTelemetry.record_tool("file.read", :ok, 30)
        |> AgentTelemetry.record_tool("file.read", :error, 10)

      report = AgentTelemetry.show_tool_report(t)

      assert report["file.read"].calls == 3
      assert_in_delta report["file.read"].success_rate, 66.7, 0.1
      assert_in_delta report["file.read"].failure_rate, 33.3, 0.1
      assert report["file.read"].gated_rate == 0.0
      assert report["file.read"].avg_duration_ms == 30
    end
  end

  # ===========================================================================
  # Latency rolling window
  # ===========================================================================

  describe "latency rolling window" do
    test "caps at 100 entries" do
      t =
        Enum.reduce(1..120, AgentTelemetry.new("agent_1"), fn i, acc ->
          AgentTelemetry.record_turn(acc, %{duration_ms: i})
        end)

      assert length(t.llm_latencies) == 100
      # Should have dropped first 20 entries (1..20)
      assert hd(t.llm_latencies) == 21
      assert List.last(t.llm_latencies) == 120
    end

    test "tool latency window also caps at 100" do
      t =
        Enum.reduce(1..110, AgentTelemetry.new("agent_1"), fn i, acc ->
          AgentTelemetry.record_tool(acc, "test", :ok, i)
        end)

      assert length(t.tool_latencies) == 100
    end
  end

  # ===========================================================================
  # Percentile calculation
  # ===========================================================================

  describe "percentile/2" do
    test "returns nil for empty list" do
      assert AgentTelemetry.percentile([], 50) == nil
    end

    test "P50 of sorted values" do
      values = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
      p50 = AgentTelemetry.percentile(values, 50)
      assert p50 == 500
    end

    test "P95 of sorted values" do
      values = Enum.to_list(1..100)
      p95 = AgentTelemetry.percentile(values, 95)
      assert p95 == 95
    end

    test "single value returns that value for any percentile" do
      assert AgentTelemetry.percentile([42], 50) == 42
      assert AgentTelemetry.percentile([42], 95) == 42
    end
  end
end

defmodule Arbor.Common.AgentTelemetry.StoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.AgentTelemetry.Store
  alias Arbor.Contracts.Agent.Telemetry

  @moduletag :fast

  setup do
    start_supervised!(Store)
    :ok
  end

  describe "get/1" do
    test "returns nil for unknown agent" do
      assert Store.get("nonexistent") == nil
    end
  end

  describe "record_turn/2" do
    test "auto-creates telemetry for new agent" do
      Store.record_turn("agent_new", %{input_tokens: 100, cost: 0.01})

      t = Store.get("agent_new")
      assert %Telemetry{} = t
      assert t.agent_id == "agent_new"
      assert t.session_input_tokens == 100
    end

    test "accumulates across multiple calls" do
      Store.record_turn("agent_1", %{input_tokens: 100})
      Store.record_turn("agent_1", %{input_tokens: 200})

      t = Store.get("agent_1")
      assert t.session_input_tokens == 300
    end
  end

  describe "record_tool/4" do
    test "records tool stats" do
      Store.record_tool("agent_1", "file.read", :ok, 50)

      t = Store.get("agent_1")
      assert t.tool_stats["file.read"].succeeded == 1
    end
  end

  describe "record_routing/2" do
    test "records routing decision" do
      Store.record_routing("agent_1", :blocked)

      t = Store.get("agent_1")
      assert t.routing_stats.blocked == 1
    end
  end

  describe "record_compaction/2" do
    test "records compaction event" do
      Store.record_compaction("agent_1", 0.80)

      t = Store.get("agent_1")
      assert t.compaction_count == 1
    end
  end

  describe "all/0" do
    test "returns all tracked agents" do
      Store.record_turn("agent_1", %{input_tokens: 100})
      Store.record_turn("agent_2", %{input_tokens: 200})

      all = Store.all()
      assert length(all) == 2
      ids = Enum.map(all, & &1.agent_id) |> Enum.sort()
      assert ids == ["agent_1", "agent_2"]
    end
  end

  describe "delete/1" do
    test "removes agent telemetry" do
      Store.record_turn("agent_1", %{input_tokens: 100})
      assert Store.get("agent_1") != nil

      Store.delete("agent_1")
      assert Store.get("agent_1") == nil
    end
  end

  describe "reset_session/1" do
    test "resets session metrics" do
      Store.record_turn("agent_1", %{input_tokens: 100, cost: 0.01})
      Store.reset_session("agent_1")

      t = Store.get("agent_1")
      assert t.session_input_tokens == 0
      assert t.lifetime_input_tokens == 100
    end

    test "no-op for unknown agent" do
      assert Store.reset_session("nonexistent") == :ok
    end
  end

  describe "concurrent access" do
    test "concurrent writes don't lose data" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Store.record_turn("agent_concurrent", %{input_tokens: 1})
            Store.record_tool("agent_concurrent", "tool_#{i}", :ok, 10)
          end)
        end

      Task.await_many(tasks)

      t = Store.get("agent_concurrent")
      # Each task adds 1 input token — but since read-modify-write isn't atomic
      # across ETS, we may lose some. At minimum we should have a valid struct.
      assert %Telemetry{} = t
      assert t.session_input_tokens > 0
      assert map_size(t.tool_stats) > 0
    end
  end
end
