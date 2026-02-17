defmodule Arbor.Orchestrator.Viz.DotSerializerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Viz.DotSerializer

  defp make_graph(opts) do
    id = Keyword.get(opts, :id, "TestPipeline")
    nodes = Keyword.get(opts, :nodes, %{})
    edges = Keyword.get(opts, :edges, [])
    attrs = Keyword.get(opts, :attrs, %{})

    %Graph{
      id: id,
      nodes: nodes,
      edges: edges,
      attrs: attrs,
      subgraphs: Keyword.get(opts, :subgraphs, []),
      node_defaults: Keyword.get(opts, :node_defaults, %{}),
      edge_defaults: Keyword.get(opts, :edge_defaults, %{})
    }
  end

  defp make_node(id, attrs \\ %{}) do
    %Node{id: id, attrs: attrs}
  end

  defp make_edge(from, to, attrs \\ %{}) do
    %Edge{from: from, to: to, attrs: attrs}
  end

  describe "serialize/2" do
    test "produces valid DOT for an empty graph" do
      graph = make_graph(id: "Empty")
      result = DotSerializer.serialize(graph)

      assert result =~ "digraph Empty {"
      assert result =~ "}"
    end

    test "serializes nodes with attributes" do
      graph =
        make_graph(
          nodes: %{
            "start" => make_node("start", %{"shape" => "ellipse", "label" => "Start"}),
            "end" => make_node("end", %{"shape" => "doublecircle"})
          }
        )

      result = DotSerializer.serialize(graph)

      assert result =~ ~s(  end [label="Start", shape=ellipse];) ||
               result =~ ~s(  end [shape=doublecircle];)

      assert result =~ ~s(  start [)
    end

    test "serializes edges" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a"),
            "b" => make_node("b")
          },
          edges: [make_edge("a", "b")]
        )

      result = DotSerializer.serialize(graph)
      assert result =~ "  a -> b;"
    end

    test "serializes edges with attributes" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a"),
            "b" => make_node("b")
          },
          edges: [make_edge("a", "b", %{"label" => "next", "condition" => "success"})]
        )

      result = DotSerializer.serialize(graph)
      assert result =~ "a -> b ["
      assert result =~ "condition=success"
      assert result =~ "label=next"
    end

    test "serializes graph attributes" do
      graph = make_graph(attrs: %{"goal" => "test the serializer", "label" => "My Pipeline"})

      result = DotSerializer.serialize(graph)
      assert result =~ "graph ["
      assert result =~ ~s(goal="test the serializer")
      assert result =~ ~s(label="My Pipeline")
    end

    test "serializes node defaults" do
      graph = make_graph(node_defaults: %{"shape" => "box", "style" => "filled"})

      result = DotSerializer.serialize(graph)
      assert result =~ "  node [shape=box, style=filled];"
    end

    test "serializes edge defaults" do
      graph = make_graph(edge_defaults: %{"color" => "gray"})

      result = DotSerializer.serialize(graph)
      assert result =~ "  edge [color=gray];"
    end

    test "strips internal attributes by default" do
      graph =
        make_graph(
          nodes: %{
            "a" =>
              make_node("a", %{
                "label" => "A",
                "content_hash" => "abc123",
                "auto_status" => "done"
              })
          }
        )

      result = DotSerializer.serialize(graph)
      assert result =~ "label=A"
      refute result =~ "content_hash"
      refute result =~ "auto_status"
    end

    test "preserves internal attributes when strip_internal: false" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a", %{"label" => "A", "content_hash" => "abc123"})
          }
        )

      result = DotSerializer.serialize(graph, strip_internal: false)
      assert result =~ "content_hash=abc123"
    end

    test "strips derived attributes (id, from, to)" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a", %{"id" => "a", "label" => "A"}),
            "b" => make_node("b")
          },
          edges: [make_edge("a", "b", %{"from" => "a", "to" => "b", "label" => "next"})]
        )

      result = DotSerializer.serialize(graph)
      # Node attrs should not include redundant id
      refute result =~ ~r/a \[.*id=/
      # Edge attrs should not include redundant from/to
      assert result =~ "label=next"
    end

    test "quotes values with special characters" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a", %{"prompt" => "Generate a summary\nwith details"})
          }
        )

      result = DotSerializer.serialize(graph)
      assert result =~ ~s(prompt="Generate a summary\\nwith details")
    end

    test "quotes IDs with special characters" do
      graph =
        make_graph(
          nodes: %{
            "my node" => make_node("my node", %{"label" => "Test"})
          }
        )

      result = DotSerializer.serialize(graph)
      assert result =~ ~s("my node")
    end

    test "does not quote simple IDs" do
      graph =
        make_graph(
          nodes: %{
            "start" => make_node("start")
          }
        )

      result = DotSerializer.serialize(graph)
      assert result =~ "  start;"
      refute result =~ ~s("start")
    end

    test "serializes subgraphs" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a"),
            "b" => make_node("b"),
            "c" => make_node("c")
          },
          subgraphs: [
            %{id: "cluster_0", attrs: %{"label" => "Group 1"}, nodes: ["a", "b"]}
          ]
        )

      result = DotSerializer.serialize(graph)
      assert result =~ "subgraph cluster_0 {"
      assert result =~ ~s(graph [label="Group 1"])
      assert result =~ "    a;"
      assert result =~ "    b;"
    end

    test "nodes are sorted by ID for deterministic output" do
      graph =
        make_graph(
          nodes: %{
            "z_node" => make_node("z_node"),
            "a_node" => make_node("a_node"),
            "m_node" => make_node("m_node")
          }
        )

      result = DotSerializer.serialize(graph)
      a_pos = :binary.match(result, "a_node") |> elem(0)
      m_pos = :binary.match(result, "m_node") |> elem(0)
      z_pos = :binary.match(result, "z_node") |> elem(0)

      assert a_pos < m_pos
      assert m_pos < z_pos
    end

    test "handles boolean and numeric attribute values" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a", %{"fan_out" => true, "max_retries" => 3, "weight" => 1.5})
          }
        )

      result = DotSerializer.serialize(graph)
      assert result =~ "fan_out=true"
      assert result =~ "max_retries=3"
      assert result =~ "weight=1.5"
    end

    test "custom indent option" do
      graph =
        make_graph(nodes: %{"a" => make_node("a")})

      result = DotSerializer.serialize(graph, indent: "    ")
      assert result =~ "    a;"
    end

    test "uses default graph ID when nil" do
      graph = make_graph(id: nil)
      result = DotSerializer.serialize(graph)
      assert result =~ "digraph Pipeline {"
    end

    test "escapes double quotes in values" do
      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a", %{"prompt" => ~s(Say "hello" to the world)})
          }
        )

      result = DotSerializer.serialize(graph)
      assert result =~ ~s(prompt="Say \\"hello\\" to the world")
    end

    test "edges maintain order (reversed from internal prepend order)" do
      edges = [
        make_edge("a", "b"),
        make_edge("b", "c"),
        make_edge("c", "d")
      ]

      graph =
        make_graph(
          nodes: %{
            "a" => make_node("a"),
            "b" => make_node("b"),
            "c" => make_node("c"),
            "d" => make_node("d")
          },
          edges: edges
        )

      result = DotSerializer.serialize(graph)
      # Since edges are reversed internally (prepended), the output
      # should reverse them back to original order
      ab_pos = :binary.match(result, "a -> b") |> elem(0)
      bc_pos = :binary.match(result, "b -> c") |> elem(0)
      cd_pos = :binary.match(result, "c -> d") |> elem(0)

      # Reversed from stored order: c->d first, then b->c, then a->b
      assert cd_pos < bc_pos
      assert bc_pos < ab_pos
    end
  end
end
