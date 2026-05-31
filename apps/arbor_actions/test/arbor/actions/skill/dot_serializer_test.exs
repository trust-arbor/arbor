defmodule Arbor.Actions.Skill.DotSerializerTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Skill.DotSerializer

  @reference_spec %{
    "name" => "docker_reference",
    "category" => "reference",
    "nodes" => [
      %{"id" => "start", "type" => "start", "label" => "start"},
      %{
        "id" => "reference",
        "type" => "llm",
        "label" => "Docker Reference",
        "prompt" => "Load Docker best practices, security, compose, and CI/CD guidance."
      },
      %{"id" => "done", "type" => "exit", "label" => "done"}
    ],
    "connections" => [
      %{"from" => "start", "to" => "reference"},
      %{"from" => "reference", "to" => "done"}
    ]
  }

  describe "new/1 + to_dot/1 — happy path" do
    test "renders a valid reference graph with category, nodes, and edges" do
      assert {:ok, dot} = DotSerializer.compile(@reference_spec)

      assert dot =~ "digraph docker_reference {"
      assert dot =~ "  // Category: reference"
      assert dot =~ ~s(  reference [label="Docker Reference" type="llm" prompt="Load Docker)
      assert dot =~ "  start -> reference"
      assert dot =~ "  reference -> done"
      assert String.ends_with?(dot, "}\n")

      # exactly 3 node lines and 2 edge lines
      assert length(Regex.scan(~r/^\s+\w+ \[/m, dot)) == 3
      assert length(Regex.scan(~r/->/, dot)) == 2
    end

    test "is deterministic — same spec produces byte-identical output" do
      {:ok, a} = DotSerializer.compile(@reference_spec)
      {:ok, b} = DotSerializer.compile(@reference_spec)
      assert a == b
    end

    test "renders conditional edges" do
      spec = %{
        "name" => "router",
        "category" => "decision_tree",
        "nodes" => [
          %{"id" => "start", "type" => "start"},
          %{"id" => "check", "type" => "conditional", "label" => "Check"},
          %{"id" => "a", "type" => "llm"},
          %{"id" => "done", "type" => "exit"}
        ],
        "connections" => [
          %{"from" => "start", "to" => "check"},
          %{"from" => "check", "to" => "a", "condition" => "context.k=v", "label" => "yes"},
          %{"from" => "a", "to" => "done"}
        ]
      }

      assert {:ok, dot} = DotSerializer.compile(spec)
      assert dot =~ ~s(  check -> a [condition="context.k=v" label="yes"])
      assert dot =~ "  a -> done\n"
    end

    test "emits extra attributes sorted, excludes reserved keys, defaults label to id" do
      spec = %{
        "name" => "p",
        "nodes" => [
          %{
            "id" => "n1",
            "type" => "llm",
            "attributes" => %{
              "simulate" => false,
              "max_iterations" => 3,
              # reserved keys here must NOT leak into the attribute bag
              "type" => "SHOULD_BE_IGNORED",
              "id" => "SHOULD_BE_IGNORED"
            }
          }
        ],
        "connections" => []
      }

      assert {:ok, dot} = DotSerializer.compile(spec)
      # label defaults to the id when absent
      assert dot =~ ~s(n1 [label="n1" type="llm")
      # sorted: max_iterations before simulate; booleans/numbers stringified
      assert dot =~ ~s(max_iterations="3" simulate="false"])
      refute dot =~ "SHOULD_BE_IGNORED"
      # category defaults to "pipeline" when omitted
      assert dot =~ "// Category: pipeline"
    end
  end

  describe "description handling" do
    test "emits // Description right after // Category when present (single-lined)" do
      spec = %{
        "name" => "p",
        "category" => "reference",
        "description" => "A short\n  multi-line   summary.",
        "nodes" => [%{"id" => "n", "type" => "llm"}],
        "connections" => []
      }

      assert {:ok, dot} = DotSerializer.compile(spec)
      assert dot =~ "  // Category: reference\n  // Description: A short multi-line summary.\n"
    end

    test "omits the Description line when absent" do
      {:ok, dot} = DotSerializer.compile(@reference_spec)
      refute dot =~ "// Description:"
    end
  end

  describe "escaping & sanitization" do
    test "escapes quotes and collapses newlines in prompts" do
      spec = %{
        "name" => "p",
        "nodes" => [
          %{
            "id" => "n",
            "type" => "llm",
            "prompt" => "Say \"hi\"\nthen   stop."
          }
        ],
        "connections" => []
      }

      assert {:ok, dot} = DotSerializer.compile(spec)
      assert dot =~ ~s(prompt="Say \\"hi\\" then stop.")
      # no raw newline survived inside the quoted attribute
      refute dot =~ ~r/prompt="[^"]*\n/
    end

    test "sanitizes node ids and keeps edges referring to them consistent" do
      spec = %{
        "name" => "my pipeline!",
        "nodes" => [
          %{"id" => "start node", "type" => "start"},
          %{"id" => "2nd-step", "type" => "llm"}
        ],
        "connections" => [
          %{"from" => "start node", "to" => "2nd-step"}
        ]
      }

      assert {:ok, dot} = DotSerializer.compile(spec)
      assert dot =~ "digraph my_pipeline {"
      assert dot =~ "  start_node ["
      # leading-digit ids get an "n_" prefix to stay valid
      assert dot =~ "  n_2nd_step ["
      assert dot =~ "  start_node -> n_2nd_step"
    end
  end

  describe "validation errors (syntactic gate)" do
    test "rejects empty / non-list nodes" do
      assert {:error, :no_nodes} = DotSerializer.new(%{"name" => "p", "nodes" => []})
      assert {:error, :nodes_not_a_list} = DotSerializer.new(%{"name" => "p", "nodes" => "x"})
    end

    test "rejects a node missing id or type" do
      assert {:error, {:node_missing_id, _}} =
               DotSerializer.new(%{"nodes" => [%{"type" => "llm"}]})

      assert {:error, {:node_missing_type, "n"}} =
               DotSerializer.new(%{"nodes" => [%{"id" => "n"}]})
    end

    test "rejects duplicate node ids (after sanitization)" do
      spec = %{
        "nodes" => [
          %{"id" => "a b", "type" => "llm"},
          %{"id" => "a-b", "type" => "llm"}
        ],
        "connections" => []
      }

      assert {:error, {:duplicate_node_ids, ["a_b"]}} = DotSerializer.new(spec)
    end

    test "rejects an edge pointing at an unknown node" do
      spec = %{
        "nodes" => [%{"id" => "start", "type" => "start"}],
        "connections" => [%{"from" => "start", "to" => "ghost"}]
      }

      assert {:error, {:edge_unknown_node, "ghost"}} = DotSerializer.new(spec)
    end

    test "rejects a non-map spec" do
      assert {:error, :spec_not_a_map} = DotSerializer.new("not a map")
    end
  end

  test "accepts atom-keyed specs too (Elixir callers, not just JSON)" do
    spec = %{
      name: "p",
      category: "pipeline",
      nodes: [%{id: "start", type: "start"}, %{id: "done", type: "exit"}],
      connections: [%{from: "start", to: "done"}]
    }

    assert {:ok, dot} = DotSerializer.compile(spec)
    assert dot =~ "  start -> done"
  end
end
