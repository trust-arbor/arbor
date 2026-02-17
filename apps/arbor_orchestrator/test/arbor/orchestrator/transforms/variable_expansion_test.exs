defmodule Arbor.Orchestrator.Transforms.VariableExpansionTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Transforms.VariableExpansion

  defp make_graph(attrs, nodes) do
    nodes_map =
      Map.new(nodes, fn {id, node_attrs} ->
        {id, Node.from_attrs(id, node_attrs)}
      end)

    %Graph{id: "test_graph", attrs: attrs, nodes: nodes_map}
  end

  describe "apply/1" do
    test "expands $goal in node prompts" do
      graph =
        make_graph(
          %{"goal" => "Build a REST API"},
          [{"gen", %{"prompt" => "Your goal: $goal"}}]
        )

      result = VariableExpansion.apply(graph)
      node = result.nodes["gen"]

      assert node.prompt == "Your goal: Build a REST API"
      assert node.attrs["prompt"] == "Your goal: Build a REST API"
    end

    test "expands $label in node prompts" do
      graph =
        make_graph(
          %{"label" => "Security Pipeline"},
          [{"gen", %{"prompt" => "Running $label"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].prompt == "Running Security Pipeline"
    end

    test "expands $id to graph id" do
      graph =
        make_graph(
          %{},
          [{"gen", %{"prompt" => "Pipeline $id"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].prompt == "Pipeline test_graph"
    end

    test "expands multiple variables in one prompt" do
      graph =
        make_graph(
          %{"goal" => "Fix bugs", "label" => "Debug"},
          [{"gen", %{"prompt" => "$label: $goal"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].prompt == "Debug: Fix bugs"
    end

    test "expands custom graph attrs as variables" do
      graph =
        make_graph(
          %{"author" => "Alice", "version" => "2.0"},
          [{"gen", %{"prompt" => "By $author v$version"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].prompt == "By Alice v2.0"
    end

    test "leaves unresolved variables as-is" do
      graph =
        make_graph(
          %{},
          [{"gen", %{"prompt" => "Missing $undefined_var"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].prompt == "Missing $undefined_var"
    end

    test "does not expand variables in non-expandable fields" do
      graph =
        make_graph(
          %{"goal" => "test"},
          [{"gen", %{"type" => "$goal", "prompt" => "$goal"}}]
        )

      result = VariableExpansion.apply(graph)
      # type is not in @expandable_fields, so it stays as-is
      assert result.nodes["gen"].attrs["type"] == "$goal"
      # prompt IS expandable
      assert result.nodes["gen"].prompt == "test"
    end

    test "expands variables in node labels" do
      graph =
        make_graph(
          %{"goal" => "Deploy"},
          [{"gen", %{"label" => "Step: $goal"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].label == "Step: Deploy"
    end

    test "handles nodes without prompts gracefully" do
      graph =
        make_graph(
          %{"goal" => "test"},
          [{"start", %{"shape" => "Mdiamond"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["start"].prompt == nil
    end

    test "handles empty goal and label" do
      graph =
        make_graph(
          %{},
          [{"gen", %{"prompt" => "Goal: $goal, Label: $label"}}]
        )

      result = VariableExpansion.apply(graph)
      assert result.nodes["gen"].prompt == "Goal: , Label: "
    end
  end
end
