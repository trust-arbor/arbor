defmodule Arbor.Orchestrator.Handlers.CoreHandlersTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  defp make_node(id, attrs) do
    %Node{id: id, attrs: attrs}
  end

  defp make_context(values \\ %{}) do
    %Context{values: values}
  end

  defp make_graph(nodes \\ %{}, edges \\ [], attrs \\ %{}) do
    %Graph{nodes: nodes, edges: edges, attrs: attrs}
  end

  # --- BranchHandler ---

  describe "BranchHandler" do
    alias Arbor.Orchestrator.Handlers.BranchHandler

    test "evaluates branch node successfully" do
      node = make_node("branch_1", %{"type" => "branch"})
      outcome = BranchHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :success
    end

    test "evaluates branch node via BehaviourHelpers wrapper" do
      alias Arbor.Orchestrator.Handlers.BehaviourHelpers

      node = make_node("branch_1", %{"type" => "branch"})
      outcome = BehaviourHelpers.execute(BranchHandler, node, make_context(), make_graph(), [])
      assert outcome.status == :success
    end

    test "idempotency is :idempotent" do
      assert BranchHandler.idempotency() == :idempotent
    end
  end

  # --- WaitHandler ---

  describe "WaitHandler" do
    alias Arbor.Orchestrator.Handlers.WaitHandler

    test "defaults to human source with auto-approve" do
      node = make_node("wait_1", %{"type" => "wait", "label" => "Continue?"})

      graph =
        make_graph(%{"wait_1" => node}, [
          %Graph.Edge{from: "wait_1", to: "next", attrs: %{"label" => "Yes"}}
        ])

      outcome = WaitHandler.execute(node, make_context(), graph, [])
      assert outcome.status == :success
    end

    test "timer source waits and returns success" do
      node = make_node("wait_timer", %{"type" => "wait", "source" => "timer", "duration" => "10"})
      outcome = WaitHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["wait.wait_timer.duration"] == 10
    end

    test "signal source returns placeholder success" do
      node =
        make_node("wait_sig", %{
          "type" => "wait",
          "source" => "signal",
          "signal_topic" => "test.complete"
        })

      outcome = WaitHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["wait.wait_sig.topic"] == "test.complete"
    end

    test "idempotency is :side_effecting" do
      assert WaitHandler.idempotency() == :side_effecting
    end
  end

  # --- ComputeHandler ---

  describe "ComputeHandler" do
    alias Arbor.Orchestrator.Handlers.ComputeHandler

    test "defaults to LLM purpose with simulation" do
      node =
        make_node("compute_1", %{
          "type" => "compute",
          "purpose" => "llm",
          "simulate" => "true"
        })

      graph = make_graph(%{}, [], %{"goal" => "test"})
      outcome = ComputeHandler.execute(node, make_context(), graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["last_response"] =~ "Simulated"
    end

    test "routing purpose delegates to RoutingHandler" do
      node =
        make_node("route_1", %{
          "type" => "compute",
          "purpose" => "routing",
          "candidates" => ~s([["anthropic","opus"]])
        })

      context =
        make_context(%{
          "avail_anthropic" => "true",
          "trust_anthropic" => "true",
          "quota_anthropic" => "true"
        })

      outcome = ComputeHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["selected_backend"] == "anthropic"
    end

    test "unknown purpose returns failure" do
      node =
        make_node("bad_compute", %{
          "type" => "compute",
          "purpose" => "nonexistent"
        })

      outcome = ComputeHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "Unknown compute purpose"
    end

    test "idempotency is :idempotent_with_key" do
      assert ComputeHandler.idempotency() == :idempotent_with_key
    end
  end

  # --- TransformHandler ---

  describe "TransformHandler" do
    alias Arbor.Orchestrator.Handlers.TransformHandler

    test "identity transform passes through" do
      context = make_context(%{"last_response" => "hello"})
      node = make_node("t1", %{"transform" => "identity"})
      outcome = TransformHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["transform.t1"] == "hello"
    end

    test "not_equal compares against an expression-named context key exactly" do
      context =
        make_context(%{
          "candidate_commit" => "commit-b",
          "reviewed_commit" => "commit-a",
          "numeric_string" => "42",
          "numeric_value" => 42
        })

      different =
        make_node("different", %{
          "transform" => "not_equal",
          "source_key" => "candidate_commit",
          "expression" => "reviewed_commit"
        })

      type_stable =
        make_node("type_stable", %{
          "transform" => "not_equal",
          "source_key" => "numeric_string",
          "expression" => "numeric_value"
        })

      assert %{status: :success, context_updates: %{"transform.different" => true}} =
               TransformHandler.execute(different, context, make_graph(), [])

      assert %{status: :success, context_updates: %{"transform.type_stable" => true}} =
               TransformHandler.execute(type_stable, context, make_graph(), [])

      same_context = make_context(%{"left" => %{"commit" => "a"}, "right" => %{"commit" => "a"}})

      same =
        make_node("same", %{
          "transform" => "not_equal",
          "source_key" => "left",
          "expression" => "right"
        })

      assert %{status: :success, context_updates: %{"transform.same" => false}} =
               TransformHandler.execute(same, same_context, make_graph(), [])
    end

    test "not_equal requires an expression context-key reference" do
      node = make_node("missing_compare_key", %{"transform" => "not_equal"})
      outcome = TransformHandler.execute(node, make_context(), make_graph(), [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "not_equal requires 'expression' context key"
    end

    test "json_extract extracts nested value" do
      json = Jason.encode!(%{"data" => %{"name" => "test"}})
      context = make_context(%{"last_response" => json})
      node = make_node("t2", %{"transform" => "json_extract", "expression" => "data.name"})
      outcome = TransformHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["transform.t2"] == "test"
    end

    test "regression: json_extract strips ```json fences from LLM output" do
      # LLMs routinely wrap JSON in markdown code fences even when the
      # system prompt explicitly asks for raw JSON. The 2026-06-05
      # code-review pipeline run hit this — Gemma 4 31B returned 709
      # chars of valid JSON wrapped in ```json...``` and json_extract
      # rejected it as "input is not valid JSON". The fence-stripping
      # in `decode_json_with_fences/1` makes the transform robust here
      # so every pipeline using json_extract benefits, not just one.
      fenced =
        "```json\n" <>
          Jason.encode!(%{"data" => %{"name" => "test"}}) <>
          "\n```"

      context = make_context(%{"last_response" => fenced})
      node = make_node("t_fence", %{"transform" => "json_extract", "expression" => "data.name"})
      outcome = TransformHandler.execute(node, context, make_graph(), [])

      assert outcome.status == :success
      assert outcome.context_updates["transform.t_fence"] == "test"
    end

    test "json_extract strips bare ``` fences (no language tag)" do
      fenced =
        "```\n" <>
          Jason.encode!(%{"x" => 42}) <>
          "\n```"

      context = make_context(%{"last_response" => fenced})
      node = make_node("t_bare_fence", %{"transform" => "json_extract", "expression" => "x"})
      outcome = TransformHandler.execute(node, context, make_graph(), [])

      assert outcome.status == :success
      assert outcome.context_updates["transform.t_bare_fence"] == 42
    end

    test "json_extract handles input with extra whitespace around fences" do
      fenced = "\n\n  ```json\n  " <> Jason.encode!(%{"y" => "ok"}) <> "  \n```\n\n"

      context = make_context(%{"last_response" => fenced})
      node = make_node("t_ws", %{"transform" => "json_extract", "expression" => "y"})
      outcome = TransformHandler.execute(node, context, make_graph(), [])

      assert outcome.status == :success
      assert outcome.context_updates["transform.t_ws"] == "ok"
    end

    test "template replaces {value}" do
      context = make_context(%{"last_response" => "world"})

      node =
        make_node("t3", %{
          "transform" => "template",
          "expression" => "Hello, {value}!"
        })

      outcome = TransformHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["transform.t3"] == "Hello, world!"
    end

    test "split splits string into list" do
      context = make_context(%{"last_response" => "a,b,c"})
      node = make_node("t4", %{"transform" => "split"})
      outcome = TransformHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["transform.t4"] == ["a", "b", "c"]
    end

    test "join joins list into string" do
      context = make_context(%{"last_response" => ["a", "b", "c"]})
      node = make_node("t5", %{"transform" => "join", "expression" => " | "})
      outcome = TransformHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["transform.t5"] == "a | b | c"
    end

    test "custom output_key" do
      context = make_context(%{"last_response" => "data"})

      node =
        make_node("t6", %{
          "transform" => "identity",
          "output_key" => "custom.key"
        })

      outcome = TransformHandler.execute(node, context, make_graph(), [])
      assert outcome.context_updates["custom.key"] == "data"
    end

    test "unknown transform returns error" do
      node = make_node("t_bad", %{"transform" => "nonexistent"})
      outcome = TransformHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unknown transform"
    end

    test "idempotency is :idempotent" do
      assert TransformHandler.idempotency() == :idempotent
    end
  end

  # --- ExecHandler ---

  describe "ExecHandler" do
    alias Arbor.Orchestrator.Handlers.ExecHandler

    test "defaults to tool target" do
      node =
        make_node("exec_1", %{
          "type" => "exec",
          "tool_command" => "echo hello"
        })

      outcome =
        ExecHandler.execute(node, make_context(), make_graph(),
          tool_command_runner: fn _cmd -> "hello\n" end
        )

      assert outcome.status == :success
    end

    test "shell target delegates to ShellHandler" do
      node =
        make_node("exec_shell", %{
          "type" => "exec",
          "target" => "shell",
          "command" => "echo test",
          "sandbox" => "none"
        })

      # This test exercises exec→shell DELEGATION, not the shell capability gate
      # (which correctly denies the default `system` principal — see the phase-0
      # shell auth gate). Inject an approving authorizer so delegation proceeds.
      graph = make_graph()

      {:ok, authority} =
        RunAuthorization.new(%{graph | compiled: true},
          agent_id: "agent_test",
          workdir: File.cwd!()
        )

      opts = [
        run_authorization: authority,
        shell_authorizer: fn _agent, _cmd, _opts -> {:ok, :authorized} end
      ]

      outcome = ExecHandler.execute(node, make_context(), graph, opts)
      assert outcome.status == :success
    end

    test "function target with handler" do
      node =
        make_node("exec_fn", %{
          "type" => "exec",
          "target" => "function"
        })

      outcome =
        ExecHandler.execute(node, make_context(), make_graph(),
          function_handler: fn _args -> {:ok, "result"} end
        )

      assert outcome.status == :success
      assert outcome.context_updates["last_response"] =~ "result"
    end

    test "function target without handler fails" do
      node =
        make_node("exec_fn_bad", %{
          "type" => "exec",
          "target" => "function"
        })

      outcome = ExecHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "function_handler"
    end

    test "idempotency is :side_effecting" do
      assert ExecHandler.idempotency() == :side_effecting
    end
  end

  # --- ReadHandler ---

  describe "ReadHandler" do
    alias Arbor.Orchestrator.Handlers.ReadHandler

    test "context source reads from context" do
      context = make_context(%{"my_data" => "hello world"})

      node =
        make_node("read_ctx", %{
          "type" => "read",
          "source" => "context",
          "source_key" => "my_data"
        })

      outcome = ReadHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["read.read_ctx"] == "hello world"
    end

    test "file source reads file" do
      # Create a temp file — use relative path within a workdir
      tmp_dir = System.tmp_dir!()
      filename = "arbor_read_test_#{System.unique_integer([:positive])}.txt"
      File.write!(Path.join(tmp_dir, filename), "file content")

      node =
        make_node("read_file", %{
          "type" => "read",
          "source" => "file",
          "path" => filename
        })

      outcome = ReadHandler.execute(node, make_context(), make_graph(), workdir: tmp_dir)
      assert outcome.status == :success
      assert outcome.context_updates["last_response"] == "file content"

      File.rm!(Path.join(tmp_dir, filename))
    end

    test "file source fails for missing file" do
      node =
        make_node("read_missing", %{
          "type" => "read",
          "source" => "file",
          "path" => "/nonexistent/file.txt"
        })

      outcome = ReadHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :fail
    end

    test "idempotency is :read_only" do
      assert ReadHandler.idempotency() == :read_only
    end
  end

  # --- WriteHandler ---

  describe "WriteHandler" do
    alias Arbor.Orchestrator.Handlers.WriteHandler

    test "file target writes file" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "arbor_write_test_#{System.unique_integer([:positive])}")

      tmp_file = Path.join(tmp_dir, "output.txt")

      context = make_context(%{"my_content" => "written data"})

      node =
        make_node("write_file", %{
          "type" => "write",
          "target" => "file",
          "content_key" => "my_content",
          "output" => tmp_file
        })

      outcome = WriteHandler.execute(node, context, make_graph(), workdir: System.tmp_dir!())
      assert outcome.status == :success

      # Clean up
      File.rm_rf!(tmp_dir)
    end

    test "accumulator target delegates" do
      context = make_context(%{"value" => "5"})

      node =
        make_node("write_acc", %{
          "type" => "write",
          "target" => "accumulator",
          "operation" => "sum",
          "input_key" => "value"
        })

      outcome = WriteHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
    end

    test "idempotency is :side_effecting" do
      assert WriteHandler.idempotency() == :side_effecting
    end
  end

  # --- ComposeHandler ---

  describe "ComposeHandler" do
    alias Arbor.Orchestrator.Handlers.ComposeHandler

    test "invoke mode delegates to SubgraphHandler" do
      # SubgraphHandler needs a graph source — test error path
      node =
        make_node("compose_1", %{
          "type" => "compose",
          "mode" => "invoke"
        })

      outcome = ComposeHandler.execute(node, make_context(), make_graph(), [])
      assert outcome.status == :fail
      # Should fail because no graph source
      assert outcome.failure_reason =~ "graph"
    end

    test "idempotency is :side_effecting" do
      assert ComposeHandler.idempotency() == :side_effecting
    end
  end

  # --- GateHandler ---

  describe "GateHandler" do
    alias Arbor.Orchestrator.Handlers.GateHandler

    test "budget_ok gate passes for normal budget" do
      context = make_context(%{"budget_status" => "normal"})

      node =
        make_node("gate_budget", %{
          "type" => "gate",
          "predicate" => "budget_ok"
        })

      outcome = GateHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["gate.gate_budget.passed"] == true
    end

    test "budget_ok gate fails for over budget" do
      context = make_context(%{"budget_status" => "over"})

      node =
        make_node("gate_budget_fail", %{
          "type" => "gate",
          "predicate" => "budget_ok"
        })

      outcome = GateHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :fail
    end

    test "expression gate passes for truthy value" do
      context = make_context(%{"is_valid" => "true"})

      node =
        make_node("gate_expr", %{
          "type" => "gate",
          "predicate" => "expression",
          "expression" => "is_valid"
        })

      outcome = GateHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
    end

    test "expression gate fails for nil value" do
      context = make_context(%{})

      node =
        make_node("gate_expr_fail", %{
          "type" => "gate",
          "predicate" => "expression",
          "expression" => "missing_key"
        })

      outcome = GateHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :fail
    end

    test "expression gate fails for empty string" do
      context = make_context(%{"empty" => ""})

      node =
        make_node("gate_empty", %{
          "type" => "gate",
          "predicate" => "expression",
          "expression" => "empty"
        })

      outcome = GateHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :fail
    end

    test "output_valid predicate delegates to OutputValidateHandler" do
      context = make_context(%{"last_response" => "hello"})

      node =
        make_node("gate_output", %{
          "type" => "gate",
          "predicate" => "output_valid",
          "source_key" => "last_response"
        })

      outcome = GateHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
    end

    test "idempotency is :read_only" do
      assert GateHandler.idempotency() == :read_only
    end
  end
end
