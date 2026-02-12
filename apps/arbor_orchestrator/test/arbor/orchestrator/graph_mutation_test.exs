defmodule Arbor.Orchestrator.GraphMutationTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Node, Edge}
  alias Arbor.Orchestrator.GraphMutation

  # --- Helpers ---

  defp build_test_graph do
    %Graph{
      id: "test_graph",
      nodes: %{
        "start" => %Node{id: "start", attrs: %{"shape" => "Mdiamond", "label" => "Start"}},
        "impl" => %Node{id: "impl", attrs: %{"shape" => "box", "label" => "Implement"}},
        "done" => %Node{id: "done", attrs: %{"shape" => "Msquare", "label" => "Done"}}
      },
      edges: [
        %Edge{from: "start", to: "impl", attrs: %{"label" => "begin"}},
        %Edge{from: "impl", to: "done", attrs: %{"label" => "finish"}}
      ],
      attrs: %{}
    }
  end

  @moduletag :graph_mutation

  # ==============================
  # parse/1
  # ==============================

  describe "parse/1" do
    test "parses valid JSON array of operations" do
      json = Jason.encode!([%{"op" => "add_node", "id" => "new_node"}])
      assert {:ok, [%{"op" => "add_node", "id" => "new_node"}]} = GraphMutation.parse(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, "JSON decode error: " <> _} = GraphMutation.parse("{not valid json")
    end

    test "returns error for non-array JSON" do
      json = Jason.encode!(%{"op" => "add_node", "id" => "x"})
      assert {:error, "mutations must be a JSON array"} = GraphMutation.parse(json)
    end

    test "returns error for operation missing required keys" do
      json = Jason.encode!([%{"op" => "add_node"}])
      assert {:error, "add_node requires \"id\""} = GraphMutation.parse(json)
    end

    test "returns error for operation missing op key" do
      json = Jason.encode!([%{"id" => "x"}])
      assert {:error, "operation missing \"op\" key"} = GraphMutation.parse(json)
    end

    test "returns error for unknown operation type" do
      json = Jason.encode!([%{"op" => "teleport", "id" => "x"}])
      assert {:error, "unknown operation: teleport"} = GraphMutation.parse(json)
    end

    test "validates all operations in the array" do
      json =
        Jason.encode!([
          %{"op" => "add_node", "id" => "ok_node"},
          %{"op" => "remove_node"}
        ])

      assert {:error, "remove_node requires \"id\""} = GraphMutation.parse(json)
    end

    test "parses modify_attrs requiring id and attrs" do
      json = Jason.encode!([%{"op" => "modify_attrs", "id" => "x", "attrs" => %{"a" => "b"}}])
      assert {:ok, _} = GraphMutation.parse(json)
    end

    test "rejects modify_attrs missing attrs" do
      json = Jason.encode!([%{"op" => "modify_attrs", "id" => "x"}])
      assert {:error, "modify_attrs requires \"id\" and \"attrs\""} = GraphMutation.parse(json)
    end

    test "parses add_edge requiring from and to" do
      json = Jason.encode!([%{"op" => "add_edge", "from" => "a", "to" => "b"}])
      assert {:ok, _} = GraphMutation.parse(json)
    end

    test "rejects add_edge missing to" do
      json = Jason.encode!([%{"op" => "add_edge", "from" => "a"}])
      assert {:error, "add_edge requires \"from\" and \"to\""} = GraphMutation.parse(json)
    end

    test "parses remove_edge requiring from and to" do
      json = Jason.encode!([%{"op" => "remove_edge", "from" => "a", "to" => "b"}])
      assert {:ok, _} = GraphMutation.parse(json)
    end

    test "rejects remove_edge missing from" do
      json = Jason.encode!([%{"op" => "remove_edge", "to" => "b"}])
      assert {:error, "remove_edge requires \"from\" and \"to\""} = GraphMutation.parse(json)
    end
  end

  # ==============================
  # validate/3
  # ==============================

  describe "validate/3" do
    test "accepts valid add_node operation" do
      graph = build_test_graph()
      ops = [%{"op" => "add_node", "id" => "new_step"}]
      assert :ok = GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects removing start node (shape=Mdiamond)" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_node", "id" => "start"}]

      assert {:error, "cannot remove start node \"start\""} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects removing exit node (shape=Msquare)" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_node", "id" => "done"}]

      assert {:error, "cannot remove exit node \"done\""} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects removing already-completed node" do
      graph = build_test_graph()
      completed = MapSet.new(["impl"])
      ops = [%{"op" => "remove_node", "id" => "impl"}]

      assert {:error, "cannot remove node \"impl\": already completed"} =
               GraphMutation.validate(ops, graph, completed)
    end

    test "rejects modifying already-completed node" do
      graph = build_test_graph()
      completed = MapSet.new(["impl"])
      ops = [%{"op" => "modify_attrs", "id" => "impl", "attrs" => %{"prompt" => "new"}}]

      assert {:error, "cannot modify node \"impl\": already completed"} =
               GraphMutation.validate(ops, graph, completed)
    end

    test "rejects adding node with existing ID" do
      graph = build_test_graph()
      ops = [%{"op" => "add_node", "id" => "impl"}]

      assert {:error, "cannot add node \"impl\": already exists"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects adding edge to nonexistent node" do
      graph = build_test_graph()
      ops = [%{"op" => "add_edge", "from" => "impl", "to" => "ghost"}]

      assert {:error, "cannot add edge: target node \"ghost\" not found"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects adding edge from nonexistent node" do
      graph = build_test_graph()
      ops = [%{"op" => "add_edge", "from" => "ghost", "to" => "impl"}]

      assert {:error, "cannot add edge: source node \"ghost\" not found"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects removing nonexistent edge" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_edge", "from" => "start", "to" => "done"}]

      assert {:error, "cannot remove edge from \"start\" to \"done\": not found"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects unknown operation type" do
      graph = build_test_graph()
      ops = [%{"op" => "warp"}]

      assert {:error, "unknown operation: warp"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects removing nonexistent node" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_node", "id" => "ghost"}]

      assert {:error, "cannot remove node \"ghost\": not found"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "rejects modifying nonexistent node" do
      graph = build_test_graph()
      ops = [%{"op" => "modify_attrs", "id" => "ghost", "attrs" => %{"x" => "y"}}]

      assert {:error, "cannot modify node \"ghost\": not found"} =
               GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "accepts adding edge between existing nodes" do
      graph = build_test_graph()
      ops = [%{"op" => "add_edge", "from" => "start", "to" => "done"}]
      assert :ok = GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "accepts removing existing edge" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_edge", "from" => "start", "to" => "impl"}]
      assert :ok = GraphMutation.validate(ops, graph, MapSet.new())
    end

    test "add_edge validates against projected node set (batch-aware)" do
      graph = build_test_graph()

      ops = [
        %{"op" => "add_node", "id" => "review"},
        %{"op" => "add_edge", "from" => "impl", "to" => "review"}
      ]

      assert :ok = GraphMutation.validate(ops, graph, MapSet.new())
    end
  end

  # ==============================
  # apply_mutations/2
  # ==============================

  describe "apply_mutations/2" do
    test "adds a new node to the graph" do
      graph = build_test_graph()

      ops = [
        %{
          "op" => "add_node",
          "id" => "review",
          "attrs" => %{"shape" => "box", "label" => "Review"}
        }
      ]

      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      assert Map.has_key?(new_graph.nodes, "review")
      assert new_graph.nodes["review"].attrs["label"] == "Review"
      assert new_graph.nodes["review"].attrs["shape"] == "box"
    end

    test "adds node with default attrs when none provided" do
      graph = build_test_graph()
      ops = [%{"op" => "add_node", "id" => "bare"}]
      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      assert Map.has_key?(new_graph.nodes, "bare")
    end

    test "removes a node and its edges" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_node", "id" => "impl"}]
      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      refute Map.has_key?(new_graph.nodes, "impl")
      assert Enum.all?(new_graph.edges, fn e -> e.from != "impl" and e.to != "impl" end)
      assert new_graph.edges == []
    end

    test "modifies node attributes (merges)" do
      graph = build_test_graph()

      ops = [
        %{"op" => "modify_attrs", "id" => "impl", "attrs" => %{"prompt" => "do something new"}}
      ]

      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      assert new_graph.nodes["impl"].attrs["prompt"] == "do something new"
      # Original shape should be preserved
      assert new_graph.nodes["impl"].attrs["shape"] == "box"
    end

    test "adds an edge" do
      graph = build_test_graph()

      ops = [
        %{
          "op" => "add_edge",
          "from" => "start",
          "to" => "done",
          "attrs" => %{"label" => "skip"}
        }
      ]

      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)

      skip_edges =
        Enum.filter(new_graph.edges, fn e -> e.from == "start" and e.to == "done" end)

      assert length(skip_edges) == 1
      assert hd(skip_edges).attrs["label"] == "skip"
    end

    test "adds edge with default attrs" do
      graph = build_test_graph()
      ops = [%{"op" => "add_edge", "from" => "start", "to" => "done"}]
      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      assert length(new_graph.edges) == 3
    end

    test "removes an edge" do
      graph = build_test_graph()
      ops = [%{"op" => "remove_edge", "from" => "start", "to" => "impl"}]
      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      refute Enum.any?(new_graph.edges, fn e -> e.from == "start" and e.to == "impl" end)
      assert length(new_graph.edges) == 1
    end

    test "increments mutation version" do
      graph = build_test_graph()
      ops = [%{"op" => "add_node", "id" => "v1"}]
      assert {:ok, g1} = GraphMutation.apply_mutations(ops, graph)
      assert g1.attrs["__mutation_version__"] == 1

      ops2 = [%{"op" => "add_node", "id" => "v2"}]
      assert {:ok, g2} = GraphMutation.apply_mutations(ops2, g1)
      assert g2.attrs["__mutation_version__"] == 2
    end

    test "applies multiple operations sequentially" do
      graph = build_test_graph()

      ops = [
        %{
          "op" => "add_node",
          "id" => "review",
          "attrs" => %{"shape" => "box", "label" => "Review"}
        },
        %{"op" => "add_edge", "from" => "impl", "to" => "review"},
        %{"op" => "add_edge", "from" => "review", "to" => "done"},
        %{"op" => "remove_edge", "from" => "impl", "to" => "done"}
      ]

      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)
      assert Map.has_key?(new_graph.nodes, "review")
      assert Enum.any?(new_graph.edges, fn e -> e.from == "impl" and e.to == "review" end)
      assert Enum.any?(new_graph.edges, fn e -> e.from == "review" and e.to == "done" end)
      refute Enum.any?(new_graph.edges, fn e -> e.from == "impl" and e.to == "done" end)
      assert new_graph.attrs["__mutation_version__"] == 1
    end

    test "returns error for modify on nonexistent node during apply" do
      graph = build_test_graph()
      ops = [%{"op" => "modify_attrs", "id" => "ghost", "attrs" => %{"x" => "y"}}]

      assert {:error, "cannot modify node \"ghost\": not found"} =
               GraphMutation.apply_mutations(ops, graph)
    end

    test "rebuilds adjacency indexes after mutation" do
      graph = build_test_graph()

      ops = [
        %{
          "op" => "add_node",
          "id" => "review",
          "attrs" => %{"shape" => "box"}
        },
        %{"op" => "add_edge", "from" => "impl", "to" => "review"},
        %{"op" => "add_edge", "from" => "review", "to" => "done"}
      ]

      assert {:ok, new_graph} = GraphMutation.apply_mutations(ops, graph)

      # adjacency should include the new edges
      assert Map.has_key?(new_graph.adjacency, "review")
      review_out = Map.get(new_graph.adjacency, "review", [])
      assert Enum.any?(review_out, fn e -> e.to == "done" end)

      # reverse_adjacency should include the new edge target
      assert Map.has_key?(new_graph.reverse_adjacency, "review")
      review_in = Map.get(new_graph.reverse_adjacency, "review", [])
      assert Enum.any?(review_in, fn e -> e.from == "impl" end)
    end
  end
end
