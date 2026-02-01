defmodule Arbor.Memory.ActionPatternsTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{ActionPatterns, KnowledgeGraph, Proposal}

  @moduletag :fast

  setup do
    # Ensure ETS tables exist
    if :ets.whereis(:arbor_memory_graphs) == :undefined do
      :ets.new(:arbor_memory_graphs, [:named_table, :public, :set])
    end

    if :ets.whereis(:arbor_memory_proposals) == :undefined do
      :ets.new(:arbor_memory_proposals, [:named_table, :public, :set])
    end

    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    # Initialize a graph for this agent
    graph = KnowledgeGraph.new(agent_id)
    :ets.insert(:arbor_memory_graphs, {agent_id, graph})

    on_exit(fn ->
      Proposal.delete_all(agent_id)
      :ets.delete(:arbor_memory_graphs, agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  defp make_action(tool, status, timestamp) do
    %{
      tool: tool,
      status: status,
      timestamp: timestamp
    }
  end

  defp make_history(actions) do
    base_time = DateTime.utc_now()

    actions
    |> Enum.with_index()
    |> Enum.map(fn {{tool, status}, idx} ->
      make_action(tool, status, DateTime.add(base_time, idx * 5, :second))
    end)
  end

  describe "analyze/2" do
    test "returns empty for short history" do
      history = [make_action("Read", :success, DateTime.utc_now())]
      assert ActionPatterns.analyze(history) == []
    end

    test "returns patterns sorted by confidence" do
      # Create history with repeated sequence
      history =
        make_history([
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success}
        ])

      patterns = ActionPatterns.analyze(history, min_occurrences: 3)

      assert length(patterns) > 0
      confidences = Enum.map(patterns, & &1.confidence)
      assert confidences == Enum.sort(confidences, :desc)
    end
  end

  describe "detect_repeated_sequences/4" do
    test "detects 2-tool sequences" do
      history =
        make_history([
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success}
        ])

      patterns = ActionPatterns.detect_repeated_sequences(history, 2, 2, 3)

      assert Enum.any?(patterns, fn p ->
               p.type == :repeated_sequence and
                 p.tools == ["Read", "Edit"] and
                 p.occurrences >= 3
             end)
    end

    test "detects 3-tool sequences" do
      history =
        make_history([
          {"Read", :success},
          {"Edit", :success},
          {"Write", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Write", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Write", :success}
        ])

      patterns = ActionPatterns.detect_repeated_sequences(history, 3, 3, 3)

      assert Enum.any?(patterns, fn p ->
               p.type == :repeated_sequence and
                 p.tools == ["Read", "Edit", "Write"]
             end)
    end

    test "respects min_occurrences" do
      history =
        make_history([
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success}
        ])

      # Only 2 occurrences, requiring 3
      patterns = ActionPatterns.detect_repeated_sequences(history, 2, 2, 3)

      assert patterns == []
    end
  end

  describe "detect_failure_then_success/1" do
    test "detects failure followed by different successful tool" do
      base_time = DateTime.utc_now()

      history = [
        make_action("Grep", :error, base_time),
        make_action("Read", :success, DateTime.add(base_time, 5, :second)),
        make_action("Grep", :error, DateTime.add(base_time, 60, :second)),
        make_action("Read", :success, DateTime.add(base_time, 65, :second))
      ]

      patterns = ActionPatterns.detect_failure_then_success(history)

      assert Enum.any?(patterns, fn p ->
               p.type == :failure_then_success and
                 p.tools == ["Grep", "Read"]
             end)
    end

    test "ignores failure followed by same tool success" do
      base_time = DateTime.utc_now()

      history = [
        make_action("Read", :error, base_time),
        make_action("Read", :success, DateTime.add(base_time, 5, :second))
      ]

      patterns = ActionPatterns.detect_failure_then_success(history)
      assert patterns == []
    end

    test "ignores actions too far apart" do
      base_time = DateTime.utc_now()

      history = [
        make_action("Grep", :error, base_time),
        # 2 minutes apart
        make_action("Read", :success, DateTime.add(base_time, 120, :second))
      ]

      patterns = ActionPatterns.detect_failure_then_success(history)
      assert patterns == []
    end
  end

  describe "detect_long_sequences/1" do
    test "detects rapid bursts of tool usage" do
      base_time = DateTime.utc_now()

      # 6 tools within 30 seconds
      history =
        for i <- 0..5 do
          make_action("Tool#{i}", :success, DateTime.add(base_time, i * 4, :second))
        end

      patterns = ActionPatterns.detect_long_sequences(history)

      assert Enum.any?(patterns, fn p ->
               p.type == :long_sequence and length(p.tools) >= 5
             end)
    end

    test "ignores slow sequences" do
      base_time = DateTime.utc_now()

      # 6 tools spread over 5 minutes
      history =
        for i <- 0..5 do
          make_action("Tool#{i}", :success, DateTime.add(base_time, i * 60, :second))
        end

      patterns = ActionPatterns.detect_long_sequences(history)
      assert patterns == []
    end
  end

  describe "synthesize_learnings/2" do
    test "generates readable learnings from patterns" do
      patterns = [
        %{
          type: :repeated_sequence,
          tools: ["Read", "Edit"],
          occurrences: 5,
          confidence: 0.8
        },
        %{
          type: :failure_then_success,
          tools: ["Grep", "Read"],
          occurrences: 3,
          confidence: 0.7
        }
      ]

      learnings = ActionPatterns.synthesize_learnings(patterns)

      assert length(learnings) == 2
      assert Enum.at(learnings, 0) =~ "Read → Edit"
      assert Enum.at(learnings, 1) =~ "Grep"
    end
  end

  describe "analyze_and_queue/3" do
    test "creates proposals for detected patterns", %{agent_id: agent_id} do
      history =
        make_history([
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success},
          {"Read", :success},
          {"Edit", :success}
        ])

      {:ok, proposals} = ActionPatterns.analyze_and_queue(agent_id, history, min_occurrences: 3)

      assert length(proposals) > 0
      assert Enum.all?(proposals, fn p -> p.type == :learning end)
      assert Enum.all?(proposals, fn p -> p.source == "action_patterns" end)
    end

    test "returns empty for no patterns", %{agent_id: agent_id} do
      history = make_history([{"Read", :success}, {"Write", :success}])

      {:ok, proposals} = ActionPatterns.analyze_and_queue(agent_id, history)

      assert proposals == []
    end
  end
end
