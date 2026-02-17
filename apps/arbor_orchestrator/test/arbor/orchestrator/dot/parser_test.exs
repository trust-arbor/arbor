defmodule Arbor.Orchestrator.Dot.ParserTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  # ── 0. parse_file/1 ──────────────────────────────────────────────────

  describe "parse_file/1" do
    test "reads and parses a DOT file from disk" do
      path = Path.join(System.tmp_dir!(), "test_parser_#{:rand.uniform(999_999)}.dot")

      try do
        File.write!(path, """
        digraph FileTest {
          start [shape=Mdiamond]
          done [shape=Msquare]
          start -> done
        }
        """)

        assert {:ok, graph} = Parser.parse_file(path)
        assert graph.id == "FileTest"
        assert map_size(graph.nodes) == 2
      after
        File.rm(path)
      end
    end

    test "returns error for missing file" do
      assert {:error, msg} = Parser.parse_file("/tmp/nonexistent_#{:rand.uniform(999_999)}.dot")
      assert msg =~ "Could not read"
    end
  end

  # ── 1. minimal pipeline ──────────────────────────────────────────────

  describe "minimal pipeline" do
    test "parses digraph with start/exit nodes and one edge" do
      dot = """
      digraph Minimal {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.id == "Minimal"
      assert map_size(graph.nodes) == 2
      assert length(graph.edges) == 1

      [edge] = graph.edges
      assert edge.from == "start"
      assert edge.to == "done"
    end

    test "Graph helpers find start and exit nodes" do
      dot = """
      digraph Helpers {
        begin [shape=Mdiamond]
        middle [shape=box]
        finish [shape=Msquare]
        begin -> middle -> finish
      }
      """

      assert {:ok, graph} = Parser.parse(dot)

      start = Graph.find_start_node(graph)
      assert %Node{id: "begin"} = start
      assert start.attrs["shape"] == "Mdiamond"

      exits = Graph.find_exit_nodes(graph)
      assert length(exits) == 1
      assert hd(exits).id == "finish"
      assert hd(exits).attrs["shape"] == "Msquare"
    end
  end

  # ── 2. node attributes ───────────────────────────────────────────────

  describe "node attributes" do
    test "parses label, shape, type, prompt, max_retries, goal_gate via attrs map" do
      dot = """
      digraph Attrs {
        task [
          label="Plan Phase",
          shape=box,
          type=llm,
          prompt="Do the thing",
          max_retries=3,
          goal_gate="quality > 0.8"
        ]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["label"] == "Plan Phase"
      assert node.attrs["shape"] == "box"
      assert node.attrs["type"] == "llm"
      assert node.attrs["prompt"] == "Do the thing"
      assert node.attrs["max_retries"] == 3
      assert node.attrs["goal_gate"] == "quality > 0.8"
    end

    test "node label is NOT auto-defaulted to id (arbor keeps raw attrs)" do
      dot = """
      digraph NoLabel {
        task [shape=box]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      # No label attr means nil, not the node id
      assert node.attrs["label"] == nil
    end

    test "unknown attributes go into attrs map" do
      dot = """
      digraph Unknown {
        task [custom_field="hello", zz_top=42]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["custom_field"] == "hello"
      assert node.attrs["zz_top"] == 42
    end

    test "explicit node attrs override defaults" do
      dot = """
      digraph Override {
        node [shape=box, color=red]
        task [shape=diamond, label="Task"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["shape"] == "diamond"
      assert node.attrs["color"] == "red"
      assert node.attrs["label"] == "Task"
    end

    test "node defaults accumulate across multiple declarations" do
      dot = """
      digraph Accum {
        node [shape=box]
        node [color=blue]
        task [label="Work"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["shape"] == "box"
      assert node.attrs["color"] == "blue"
      assert node.attrs["label"] == "Work"
    end
  end

  # ── 3. edge attributes ───────────────────────────────────────────────

  describe "edge attributes" do
    test "parses label, condition, weight via attrs map" do
      dot = """
      digraph EdgeAttrs {
        a -> b [label="next", condition="outcome=success", weight=10]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      [edge] = graph.edges

      assert edge.attrs["label"] == "next"
      assert edge.attrs["condition"] == "outcome=success"
      assert edge.attrs["weight"] == 10
    end

    test "unknown edge attrs go into attrs map" do
      dot = """
      digraph EdgeUnknown {
        a -> b [custom="xyz", priority=99]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      [edge] = graph.edges

      assert edge.attrs["custom"] == "xyz"
      assert edge.attrs["priority"] == 99
    end

    test "edge without attributes uses empty attrs or edge defaults" do
      dot = """
      digraph NoEdgeAttrs {
        a -> b
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      [edge] = graph.edges

      assert edge.attrs == %{}
    end

    test "explicit edge attrs override defaults" do
      dot = """
      digraph EdgeOverride {
        edge [weight=5, fidelity="compact"]
        a -> b [weight=20, label="fast"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      [edge] = graph.edges

      assert edge.attrs["weight"] == 20
      assert edge.attrs["fidelity"] == "compact"
      assert edge.attrs["label"] == "fast"
    end
  end

  # ── 4. chained edges ─────────────────────────────────────────────────

  describe "chained edges" do
    test "a -> b -> c -> d produces three edges" do
      dot = """
      digraph Chain {
        a -> b -> c -> d
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert length(graph.edges) == 3

      pairs = Enum.map(graph.edges, fn e -> {e.from, e.to} end)
      assert {"a", "b"} in pairs
      assert {"b", "c"} in pairs
      assert {"c", "d"} in pairs
    end

    test "chained edges share the same attribute block" do
      dot = """
      digraph ChainAttrs {
        a -> b -> c [label="flow", weight=5]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert length(graph.edges) == 2

      for edge <- graph.edges do
        assert edge.attrs["label"] == "flow"
        assert edge.attrs["weight"] == 5
      end
    end

    test "all nodes in chain are registered even without explicit declarations" do
      dot = """
      digraph Implicit {
        x -> y -> z
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert Map.has_key?(graph.nodes, "x")
      assert Map.has_key?(graph.nodes, "y")
      assert Map.has_key?(graph.nodes, "z")
    end
  end

  # ── 5. graph attributes ──────────────────────────────────────────────

  describe "graph attributes" do
    test "graph [goal=... label=...] sets graph attrs" do
      dot = """
      digraph GA {
        graph [goal="Build feature", label="SDLC Pipeline"]
        start [shape=Mdiamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.attrs["goal"] == "Build feature"
      assert graph.attrs["label"] == "SDLC Pipeline"
    end

    test "multiple graph attr blocks merge" do
      dot = """
      digraph Merge {
        graph [goal="Ship it"]
        graph [label="Pipeline", timeout="5m"]
        start [shape=Mdiamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.attrs["goal"] == "Ship it"
      assert graph.attrs["label"] == "Pipeline"
      assert graph.attrs["timeout"] == "5m"
    end
  end

  # ── 6. node defaults ─────────────────────────────────────────────────

  describe "node defaults" do
    test "node [shape=box] applies to subsequently declared nodes" do
      dot = """
      digraph ND {
        node [shape=box]
        task1 [label="A"]
        task2 [label="B"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.nodes["task1"].attrs["shape"] == "box"
      assert graph.nodes["task2"].attrs["shape"] == "box"
    end

    test "explicit node attrs override defaults" do
      dot = """
      digraph NDOverride {
        node [shape=box, llm_model="haiku"]
        task [shape=diamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["shape"] == "diamond"
      assert node.attrs["llm_model"] == "haiku"
    end

    test "node defaults accumulate" do
      dot = """
      digraph NDAccum {
        node [shape=box]
        node [color=red]
        task [label="Work"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["shape"] == "box"
      assert node.attrs["color"] == "red"
      assert node.attrs["label"] == "Work"
    end
  end

  # ── 7. edge defaults ─────────────────────────────────────────────────

  describe "edge defaults" do
    test "edge [weight=5] applies to subsequent edges" do
      dot = """
      digraph ED {
        edge [weight=5]
        a -> b
        c -> d
      }
      """

      assert {:ok, graph} = Parser.parse(dot)

      for edge <- graph.edges do
        assert edge.attrs["weight"] == 5
      end
    end

    test "explicit edge attrs override edge defaults" do
      dot = """
      digraph EDOverride {
        edge [weight=5, fidelity="compact"]
        a -> b [weight=100]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      [edge] = graph.edges

      assert edge.attrs["weight"] == 100
      assert edge.attrs["fidelity"] == "compact"
    end
  end

  # ── 8. subgraphs ─────────────────────────────────────────────────────

  describe "subgraphs" do
    test "subgraph with label derives class on child nodes" do
      dot = """
      digraph SG {
        subgraph cluster_build {
          graph [label="Build Phase"]
          plan [label="Plan"]
          implement [label="Impl"]
        }
      }
      """

      assert {:ok, graph} = Parser.parse(dot)

      assert graph.nodes["plan"].attrs["class"] == "build-phase"
      assert graph.nodes["implement"].attrs["class"] == "build-phase"
    end

    test "subgraph info is recorded in graph.subgraphs list" do
      dot = """
      digraph SG2 {
        subgraph cluster_test {
          graph [label="Testing"]
          verify [label="Verify"]
        }
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert length(graph.subgraphs) == 1

      [sg] = graph.subgraphs
      assert sg.id == "cluster_test"
      assert sg.label == "Testing"
      assert sg.derived_class == "testing"
    end

    test "subgraph inherits parent node defaults" do
      dot = """
      digraph SGDefaults {
        node [shape=box]

        subgraph cluster_inner {
          task [label="Inner"]
        }
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.nodes["task"].attrs["shape"] == "box"
    end

    test "subgraph edges are merged into main graph" do
      dot = """
      digraph SGEdges {
        start [shape=Mdiamond]

        subgraph cluster_work {
          plan [label="Plan"]
          implement [label="Impl"]
          plan -> implement
        }

        start -> plan
        implement -> done
        done [shape=Msquare]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)

      pairs = Enum.map(graph.edges, fn e -> {e.from, e.to} end)
      assert {"plan", "implement"} in pairs
      assert {"start", "plan"} in pairs
      assert {"implement", "done"} in pairs
    end

    test "node with explicit class is NOT overridden by subgraph derived class" do
      dot = """
      digraph SGClass {
        subgraph cluster_build {
          graph [label="Build"]
          task [class="my-custom-class"]
          other [label="Other"]
        }
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.nodes["task"].attrs["class"] == "my-custom-class"
      assert graph.nodes["other"].attrs["class"] == "build"
    end
  end

  # ── 9. comments ──────────────────────────────────────────────────────

  describe "comments" do
    test "single-line comments stripped" do
      dot = """
      digraph Comments {
        // This is a comment
        start [shape=Mdiamond]
        // Another comment
        done [shape=Msquare]
        start -> done
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert map_size(graph.nodes) == 2
      assert length(graph.edges) == 1
    end

    test "block comments stripped" do
      dot = """
      digraph Block {
        /* This is a
           multi-line comment */
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert map_size(graph.nodes) == 2
      assert length(graph.edges) == 1
    end

    test "inline comments after statements stripped" do
      dot = """
      digraph Inline {
        start [shape=Mdiamond] // start node
        done [shape=Msquare] // end node
        start -> done // main edge
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert map_size(graph.nodes) == 2
      assert length(graph.edges) == 1
    end
  end

  # ── 10. string escapes ───────────────────────────────────────────────

  describe "string escapes" do
    test "escaped double quotes inside strings" do
      dot = """
      digraph Esc {
        task [prompt="Say \\"hello\\""]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.nodes["task"].attrs["prompt"] == "Say \"hello\""
    end

    test "escaped newlines and tabs" do
      dot = """
      digraph EscNT {
        task [prompt="line1\\nline2\\ttabbed"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.nodes["task"].attrs["prompt"] == "line1\nline2\ttabbed"
    end

    test "empty quoted string" do
      dot = """
      digraph Empty {
        task [label=""]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.nodes["task"].attrs["label"] == ""
    end
  end

  # ── 11. graph-level key=value ────────────────────────────────────────

  describe "graph-level key=value" do
    test "bare key=value stored in graph attrs" do
      dot = """
      digraph Bare {
        goal="Build feature"
        start [shape=Mdiamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.attrs["goal"] == "Build feature"
    end

    test "multiple direct assignments" do
      dot = """
      digraph Multi {
        goal="Ship it"
        label="Pipeline"
        timeout="5m"
        start [shape=Mdiamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert graph.attrs["goal"] == "Ship it"
      assert graph.attrs["label"] == "Pipeline"
      assert graph.attrs["timeout"] == "5m"
    end
  end

  # ── 12. error cases ──────────────────────────────────────────────────

  describe "error cases" do
    test "non-digraph returns error with string message" do
      assert {:error, msg} = Parser.parse("graph G { a -> b }")
      assert is_binary(msg)
    end

    test "missing closing brace returns error" do
      assert {:error, msg} = Parser.parse("digraph G { a -> b")
      assert is_binary(msg)
    end

    test "empty input returns error" do
      assert {:error, msg} = Parser.parse("")
      assert is_binary(msg)
    end

    test "random text returns error" do
      assert {:error, msg} = Parser.parse("not a graph at all")
      assert is_binary(msg)
    end
  end

  # ── 13. qualified keys ───────────────────────────────────────────────

  describe "qualified keys" do
    test "dotted keys like thread.id parsed as single key in attrs" do
      dot = """
      digraph QK {
        manager [thread.id="abc123", manager.actions="observe,steer"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["manager"]

      assert node.attrs["thread.id"] == "abc123"
      assert node.attrs["manager.actions"] == "observe,steer"
    end

    test "dotted keys in edge attributes" do
      dot = """
      digraph QKEdge {
        a -> b [routing.strategy="round_robin", meta.source="test"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      [edge] = graph.edges

      assert edge.attrs["routing.strategy"] == "round_robin"
      assert edge.attrs["meta.source"] == "test"
    end
  end

  # ── 14. bare attributes ──────────────────────────────────────────────

  describe "bare attributes" do
    test "[nullable] in node attrs yields attrs[\"nullable\"] == \"true\"" do
      dot = """
      digraph BA {
        task [nullable, label="Work"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["nullable"] == "true"
      assert node.attrs["label"] == "Work"
    end
  end

  # ── 15. semicolons and separators ────────────────────────────────────

  describe "semicolons and separators" do
    test "semicolons between statements are optional" do
      dot = """
      digraph Semi {
        start [shape=Mdiamond];
        done [shape=Msquare];
        start -> done;
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert map_size(graph.nodes) == 2
      assert length(graph.edges) == 1
    end

    test "commas in attribute lists handled" do
      dot = """
      digraph Commas {
        task [label="Work", shape=box, color=red]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      node = graph.nodes["task"]

      assert node.attrs["label"] == "Work"
      assert node.attrs["shape"] == "box"
      assert node.attrs["color"] == "red"
    end
  end

  # ── 16. graph helpers ────────────────────────────────────────────────

  describe "graph helpers" do
    test "Graph.terminal?/2 detects Msquare nodes" do
      dot = """
      digraph Term {
        start [shape=Mdiamond]
        middle [shape=box]
        done [shape=Msquare]
        start -> middle -> done
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      done = graph.nodes["done"]
      middle = graph.nodes["middle"]

      assert Graph.terminal?(graph, done)
      refute Graph.terminal?(graph, middle)
    end

    test "Graph.goal/1 returns graph goal" do
      dot = """
      digraph Goal {
        graph [goal="Build the widget"]
        start [shape=Mdiamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert Graph.goal(graph) == "Build the widget"
    end

    test "Graph.label/1 returns graph label" do
      dot = """
      digraph Label {
        graph [label="My Pipeline"]
        start [shape=Mdiamond]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)
      assert Graph.label(graph) == "My Pipeline"
    end
  end

  # ── 17. integration ──────────────────────────────────────────────────

  describe "integration" do
    test "complex realistic pipeline with defaults, edges, conditions, retry edges" do
      dot = """
      digraph SDLC {
        graph [goal="Build feature", label="SDLC Pipeline"]

        // Node and edge defaults
        node [llm_model="haiku", max_retries=2]
        edge [timeout="5m"]

        // Terminal nodes
        start [shape=Mdiamond]
        done [shape=Msquare]
        failed [shape=Msquare, label="Failed"]

        /* Core pipeline stages */
        plan [
          label="Plan Phase",
          prompt="Analyze requirements and create plan",
          llm_model="sonnet",
          reasoning_effort="high"
        ]
        implement [label="Implement", prompt="Write the code"]
        compile [label="Compile", type=tool]
        run_tests [label="Test", type=tool]
        review [label="Review", prompt="Review changes"]

        // Happy path
        start -> plan -> implement -> compile -> run_tests -> review -> done [condition="outcome=success"]

        // Retry / failure edges
        compile -> implement [condition="outcome=fail", label="fix errors"]
        run_tests -> implement [condition="outcome=fail", label="fix tests"]
        review -> implement [condition="outcome=changes_requested", label="revisions"]
        review -> failed [condition="outcome=reject"]
      }
      """

      assert {:ok, graph} = Parser.parse(dot)

      # Graph metadata
      assert graph.id == "SDLC"
      assert Graph.goal(graph) == "Build feature"
      assert Graph.label(graph) == "SDLC Pipeline"

      # All nodes present
      assert map_size(graph.nodes) == 8

      for name <- ~w(start done failed plan implement compile run_tests review) do
        assert Map.has_key?(graph.nodes, name), "Missing node: #{name}"
      end

      # Start and exit nodes
      assert %Node{id: "start"} = Graph.find_start_node(graph)
      exits = Graph.find_exit_nodes(graph)
      exit_ids = Enum.map(exits, & &1.id) |> Enum.sort()
      assert exit_ids == ["done", "failed"]

      # Node defaults applied
      assert graph.nodes["implement"].attrs["llm_model"] == "haiku"
      assert graph.nodes["implement"].attrs["max_retries"] == 2

      # Explicit override
      assert graph.nodes["plan"].attrs["llm_model"] == "sonnet"
      assert graph.nodes["plan"].attrs["reasoning_effort"] == "high"

      # Edge count: 6 from chain + 4 individual = 10
      assert length(graph.edges) == 10

      # Edge defaults applied (timeout)
      for edge <- graph.edges do
        assert edge.attrs["timeout"] == "5m"
      end

      # Specific conditional edges exist
      retry_edges =
        Enum.filter(graph.edges, fn e ->
          e.from == "compile" and e.to == "implement"
        end)

      assert length(retry_edges) == 1
      [retry] = retry_edges
      assert retry.attrs["condition"] == "outcome=fail"
      assert retry.attrs["label"] == "fix errors"

      # Reject edge
      reject_edges =
        Enum.filter(graph.edges, fn e ->
          e.from == "review" and e.to == "failed"
        end)

      assert length(reject_edges) == 1
      [reject] = reject_edges
      assert reject.attrs["condition"] == "outcome=reject"
    end
  end
end
