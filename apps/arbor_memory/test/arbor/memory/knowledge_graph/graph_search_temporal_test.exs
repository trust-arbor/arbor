defmodule Arbor.Memory.KnowledgeGraph.GraphSearchTemporalTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraph.GraphSearch

  @moduletag :fast

  # Helper to build a graph with nodes at specific dates
  defp build_graph_with_dated_nodes do
    graph = KnowledgeGraph.new("test_agent")

    {:ok, graph, id1} =
      KnowledgeGraph.add_node(graph, %{
        type: :observation,
        content: "Feb 15 observation",
        referenced_date: ~U[2026-02-15 12:00:00Z],
        skip_dedup: true
      })

    {:ok, graph, id2} =
      KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "Feb 16 fact",
        referenced_date: ~U[2026-02-16 14:00:00Z],
        skip_dedup: true
      })

    {:ok, graph, id3} =
      KnowledgeGraph.add_node(graph, %{
        type: :observation,
        content: "No referenced date",
        skip_dedup: true
      })

    # Future-dated node
    future = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)

    {:ok, graph, id4} =
      KnowledgeGraph.add_node(graph, %{
        type: :goal,
        content: "Future meeting",
        referenced_date: future,
        skip_dedup: true
      })

    {graph, %{feb15: id1, feb16: id2, no_ref: id3, future: id4}}
  end

  describe "nodes_for_period/2" do
    test "filters nodes by date range using referenced_date" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results = GraphSearch.nodes_for_period(graph, start: ~D[2026-02-15], end: ~D[2026-02-16])

      contents = Enum.map(results, & &1.content)
      assert "Feb 15 observation" in contents
      assert "Feb 16 fact" in contents
      refute "No referenced date" in contents
    end

    test "respects :date_field option for referenced_date only" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results =
        GraphSearch.nodes_for_period(graph,
          start: ~D[2026-02-15],
          end: ~D[2026-02-16],
          date_field: :referenced_date
        )

      # Only nodes with referenced_date in range
      contents = Enum.map(results, & &1.content)
      assert "Feb 15 observation" in contents
      assert "Feb 16 fact" in contents
    end

    test "respects :date_field :created_at — includes nodes without referenced_date" do
      {graph, _ids} = build_graph_with_dated_nodes()

      today = Date.utc_today()

      results =
        GraphSearch.nodes_for_period(graph,
          start: today,
          end: today,
          date_field: :created_at
        )

      # All nodes were created today
      assert results != []
    end

    test "respects :types filter" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results =
        GraphSearch.nodes_for_period(graph,
          start: ~D[2026-02-14],
          end: ~D[2026-02-17],
          types: [:fact]
        )

      assert length(results) == 1
      assert hd(results).content == "Feb 16 fact"
    end

    test "respects :limit" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results =
        GraphSearch.nodes_for_period(graph, start: ~D[2026-02-14], end: ~D[2026-02-17], limit: 1)

      assert length(results) == 1
    end

    test "returns empty list when no matches" do
      {graph, _ids} = build_graph_with_dated_nodes()
      results = GraphSearch.nodes_for_period(graph, start: ~D[2025-01-01], end: ~D[2025-01-31])
      assert results == []
    end

    test "works with empty graph" do
      graph = KnowledgeGraph.new("empty_agent")
      results = GraphSearch.nodes_for_period(graph, start: ~D[2026-01-01], end: ~D[2026-12-31])
      assert results == []
    end
  end

  describe "nodes_with_referenced_date/2" do
    test "returns only nodes with referenced_date set" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results = GraphSearch.nodes_with_referenced_date(graph)

      contents = Enum.map(results, & &1.content)
      assert "Feb 15 observation" in contents
      assert "Feb 16 fact" in contents
      assert "Future meeting" in contents
      refute "No referenced date" in contents
    end

    test "respects :types filter" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results = GraphSearch.nodes_with_referenced_date(graph, types: [:observation])

      assert length(results) == 1
      assert hd(results).content == "Feb 15 observation"
    end

    test "respects :limit" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results = GraphSearch.nodes_with_referenced_date(graph, limit: 2)
      assert length(results) == 2
    end
  end

  describe "upcoming_nodes/2" do
    test "returns only future-dated nodes" do
      {graph, _ids} = build_graph_with_dated_nodes()

      results = GraphSearch.upcoming_nodes(graph)

      assert length(results) == 1
      assert hd(results).content == "Future meeting"
    end

    test "respects :types filter" do
      {graph, _ids} = build_graph_with_dated_nodes()

      # Future node is type :goal
      results = GraphSearch.upcoming_nodes(graph, types: [:observation])
      assert results == []
    end

    test "returns empty for graph with no future dates" do
      graph = KnowledgeGraph.new("test_agent")

      {:ok, graph, _} =
        KnowledgeGraph.add_node(graph, %{
          type: :fact,
          content: "Past event",
          referenced_date: ~U[2025-01-01 00:00:00Z]
        })

      results = GraphSearch.upcoming_nodes(graph)
      assert results == []
    end
  end
end
