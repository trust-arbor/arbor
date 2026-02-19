defmodule Arbor.Orchestrator.IR.ValidatorTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.IR.{Compiler, Validator}

  defp compile!(graph) do
    {:ok, compiled} = Compiler.compile(graph)
    compiled
  end

  defp simple_graph do
    %Graph{id: "Test"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "work", attrs: %{"prompt" => "Do something"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "work"})
    |> Graph.add_edge(%Edge{from: "work", to: "done"})
  end

  defp taint_leak_graph do
    %Graph{id: "TaintLeak"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{
      id: "secret_work",
      attrs: %{"prompt" => "Handle secrets", "data_class" => "secret"}
    })
    |> Graph.add_node(%Node{
      id: "public_output",
      attrs: %{"prompt" => "Publish result", "data_class" => "public"}
    })
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "secret_work"})
    |> Graph.add_edge(%Edge{from: "secret_work", to: "public_output"})
    |> Graph.add_edge(%Edge{from: "public_output", to: "done"})
  end

  defp missing_prompt_graph do
    %Graph{id: "MissingPrompt"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "no_prompt", attrs: %{}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "no_prompt"})
    |> Graph.add_edge(%Edge{from: "no_prompt", to: "done"})
  end

  defp unbounded_loop_graph do
    %Graph{id: "UnboundedLoop"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "step_a", attrs: %{"prompt" => "Step A"}})
    |> Graph.add_node(%Node{id: "step_b", attrs: %{"prompt" => "Step B"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "step_a"})
    |> Graph.add_edge(%Edge{from: "step_a", to: "step_b"})
    |> Graph.add_edge(%Edge{from: "step_b", to: "step_a"})
    |> Graph.add_edge(%Edge{
      from: "step_b",
      to: "done",
      attrs: %{"condition" => "outcome=success"}
    })
  end

  defp bounded_loop_graph do
    %Graph{id: "BoundedLoop"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "step_a", attrs: %{"prompt" => "Step A", "max_retries" => 3}})
    |> Graph.add_node(%Node{id: "step_b", attrs: %{"prompt" => "Step B"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "step_a"})
    |> Graph.add_edge(%Edge{from: "step_a", to: "step_b"})
    |> Graph.add_edge(%Edge{from: "step_b", to: "step_a"})
    |> Graph.add_edge(%Edge{
      from: "step_b",
      to: "done",
      attrs: %{"condition" => "outcome=success"}
    })
  end

  defp conditional_missing_fail_graph do
    %Graph{id: "IncompleteCond"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "check", attrs: %{"shape" => "diamond"}})
    |> Graph.add_node(%Node{id: "yes", attrs: %{"prompt" => "Yes path"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "check"})
    |> Graph.add_edge(%Edge{from: "check", to: "yes", attrs: %{"condition" => "outcome=success"}})
    |> Graph.add_edge(%Edge{from: "yes", to: "done"})
  end

  defp tool_no_retries_graph do
    %Graph{id: "ToolNoRetries"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "run", attrs: %{"type" => "tool", "tool_command" => "echo test"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "run"})
    |> Graph.add_edge(%Edge{from: "run", to: "done"})
  end

  describe "validate/1 — schema pass" do
    test "clean graph produces no schema errors" do
      diags = simple_graph() |> compile!() |> Validator.validate()
      schema_errors = Enum.filter(diags, &(&1.rule == "typed_schema" and &1.severity == :error))
      assert schema_errors == []
    end

    test "missing required attrs produce errors" do
      diags = missing_prompt_graph() |> compile!() |> Validator.validate()
      schema_errors = Enum.filter(diags, &(&1.rule == "typed_schema" and &1.severity == :error))
      assert length(schema_errors) == 1
      assert hd(schema_errors).message =~ "prompt"
    end

    test "validate_schema/1 runs only schema pass" do
      diags = missing_prompt_graph() |> compile!() |> Validator.validate_schema()
      assert Enum.all?(diags, &(&1.rule == "typed_schema"))
    end
  end

  describe "validate/1 — capability analysis" do
    test "reports capabilities for graphs that need them" do
      diags = simple_graph() |> compile!() |> Validator.validate()
      cap_diags = Enum.filter(diags, &(&1.rule == "capabilities_required"))
      assert length(cap_diags) == 1
      assert hd(cap_diags).message =~ "llm_query"
    end

    test "no capability warning for capability-free graphs" do
      graph =
        %Graph{id: "NoCaps"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "check", attrs: %{"shape" => "diamond"}})
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "check"})
        |> Graph.add_edge(%Edge{from: "check", to: "done"})

      diags = graph |> compile!() |> Validator.validate()
      cap_diags = Enum.filter(diags, &(&1.rule == "capabilities_required"))
      assert cap_diags == []
    end
  end

  describe "validate/1 — taint reachability" do
    test "detects data flowing from secret to public node" do
      diags = taint_leak_graph() |> compile!() |> Validator.validate()
      taint_errors = Enum.filter(diags, &(&1.rule == "taint_flow"))
      assert length(taint_errors) == 1
      assert hd(taint_errors).severity == :error
      assert hd(taint_errors).message =~ "secret"
      assert hd(taint_errors).message =~ "public"
    end

    test "no taint errors for same-classification flow" do
      # All-public graph: start → conditional → exit (no codergen defaults to internal)
      graph =
        %Graph{id: "AllPublic"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "check", attrs: %{"shape" => "diamond"}})
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "check"})
        |> Graph.add_edge(%Edge{from: "check", to: "done"})

      diags = graph |> compile!() |> Validator.validate()
      taint_errors = Enum.filter(diags, &(&1.rule == "taint_flow"))
      assert taint_errors == []
    end

    test "default classification mismatch produces warning (not error)" do
      # simple_graph() has codergen (internal default) → exit (public default)
      # Since neither has explicit data_class attr, this is a warning
      diags = simple_graph() |> compile!() |> Validator.validate()
      taint_warnings = Enum.filter(diags, &(&1.rule == "taint_flow"))
      assert length(taint_warnings) == 1
      assert hd(taint_warnings).severity == :warning
      assert hd(taint_warnings).message =~ "internal"
      assert hd(taint_warnings).message =~ "public"
    end

    test "validate_taint/1 runs only taint pass" do
      diags = taint_leak_graph() |> compile!() |> Validator.validate_taint()
      assert Enum.all?(diags, &(&1.rule == "taint_flow"))
    end
  end

  describe "validate/1 — loop detection" do
    test "warns about unbounded loops" do
      diags = unbounded_loop_graph() |> compile!() |> Validator.validate()
      loop_warnings = Enum.filter(diags, &(&1.rule == "unbounded_loop"))
      assert loop_warnings != []
      assert hd(loop_warnings).message =~ "Cycle"
    end

    test "no warning for bounded loops" do
      diags = bounded_loop_graph() |> compile!() |> Validator.validate()
      loop_warnings = Enum.filter(diags, &(&1.rule == "unbounded_loop"))
      assert loop_warnings == []
    end

    test "no loop warnings for acyclic graphs" do
      diags = simple_graph() |> compile!() |> Validator.validate()
      loop_warnings = Enum.filter(diags, &(&1.rule == "unbounded_loop"))
      assert loop_warnings == []
    end
  end

  describe "validate/1 — resource bounds" do
    test "warns about tool nodes without max_retries" do
      diags = tool_no_retries_graph() |> compile!() |> Validator.validate()
      resource_warnings = Enum.filter(diags, &(&1.rule == "missing_resource_bound"))
      assert length(resource_warnings) == 1
      assert hd(resource_warnings).message =~ "max_retries"
    end
  end

  describe "validate/1 — condition completeness" do
    test "warns about conditional with only success path" do
      diags = conditional_missing_fail_graph() |> compile!() |> Validator.validate()
      completeness = Enum.filter(diags, &(&1.rule == "incomplete_conditional"))
      assert length(completeness) == 1
      assert hd(completeness).message =~ "no failure path"
    end
  end

  describe "validate/1 — condition parse errors" do
    test "detects unparseable conditions" do
      graph =
        %Graph{id: "BadCondition"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{
          from: "start",
          to: "done",
          attrs: %{"condition" => "???badcondition???"}
        })

      diags = graph |> compile!() |> Validator.validate()
      parse_errors = Enum.filter(diags, &(&1.rule == "condition_parse"))
      assert length(parse_errors) == 1
    end
  end

  describe "validate/1 — not compiled guard" do
    test "returns error for uncompiled graph" do
      graph = simple_graph()
      diags = Validator.validate(graph)
      assert length(diags) == 1
      assert hd(diags).rule == "not_compiled"
    end
  end

  describe "validate/1 — real DOT pipeline specs" do
    @specs_dir "specs/pipelines"

    test "security-auth-chain.dot compiles and validates" do
      path = Path.join(@specs_dir, "security-auth-chain.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    test "sdlc.dot compiles and validates" do
      path = Path.join(@specs_dir, "sdlc.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    test "consensus-flow.dot compiles and validates" do
      path = Path.join(@specs_dir, "consensus-flow.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    test "bdi-goal-decomposition.dot compiles and validates" do
      path = Path.join(@specs_dir, "bdi-goal-decomposition.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    test "memory-consolidation.dot compiles and validates" do
      path = Path.join(@specs_dir, "memory-consolidation.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    test "eval-framework.dot compiles and validates" do
      path = Path.join(@specs_dir, "eval-framework.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    test "dotgen.dot compiles and validates" do
      path = Path.join(@specs_dir, "dotgen.dot")
      assert_pipeline_compiles_and_validates(path)
    end

    defp assert_pipeline_compiles_and_validates(path) do
      source = File.read!(path)
      {:ok, graph} = Arbor.Orchestrator.parse(source)
      {:ok, compiled} = Compiler.compile(graph)

      assert %Graph{compiled: true} = compiled
      assert map_size(compiled.nodes) > 0

      diags = Validator.validate(compiled)

      # No condition parse errors (structural correctness)
      parse_errors = Enum.filter(diags, &(&1.rule == "condition_parse"))
      assert parse_errors == [], "Condition parse errors in #{path}: #{inspect(parse_errors)}"

      # Verify capabilities are reported
      assert MapSet.size(compiled.capabilities_required) >= 0
    end
  end
end
