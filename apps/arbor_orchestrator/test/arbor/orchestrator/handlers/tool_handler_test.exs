defmodule Arbor.Orchestrator.Handlers.ToolHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ToolHandler

  @test_dir System.tmp_dir!() |> Path.join("arbor_tool_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "real shell execution" do
    test "runs a successful command and captures output" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "echo hello"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "hello"
    end

    test "fails on non-zero exit code" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "false"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "exited with code"
      assert outcome.context_updates["tool.output"] != nil
    end

    test "captures stderr in output" do
      node = %Node{
        id: "t1",
        attrs: %{
          "tool_command" => "ls /nonexistent_arbor_tool_handler_path"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.context_updates["tool.output"] =~ "nonexistent_arbor_tool_handler_path"
    end

    test "uses workdir from context" do
      File.write!(Path.join(@test_dir, "marker.txt"), "found")

      node = %Node{id: "t1", attrs: %{"tool_command" => "cat marker.txt"}}
      context = Context.new(%{"workdir" => @test_dir})
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "found"
    end

    test "uses workdir from opts as fallback" do
      File.write!(Path.join(@test_dir, "opts_marker.txt"), "from_opts")

      node = %Node{id: "t1", attrs: %{"tool_command" => "cat opts_marker.txt"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, workdir: @test_dir)

      assert outcome.status == :success
      assert String.trim(outcome.context_updates["tool.output"]) == "from_opts"
    end

    test "fails gracefully on missing executable" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "nonexistent_binary_xyz"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "direct-executable policy"
    end

    test "custom tool_command_runner overrides real execution" do
      node = %Node{id: "t1", attrs: %{"tool_command" => "anything"}}
      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      runner = fn "anything" -> "custom_output" end
      outcome = ToolHandler.execute(node, context, graph, tool_command_runner: runner)

      assert outcome.status == :success
      assert outcome.context_updates["tool.output"] == "custom_output"
    end
  end

  describe "end-to-end via Orchestrator.run" do
    test "tool node executes real command in pipeline" do
      dot = """
      digraph ToolE2E {
        start [shape=Mdiamond]
        run_cmd [shape=parallelogram, tool_command="echo pipeline_works"]
        done [shape=Msquare]
        start -> run_cmd -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert String.trim(result.context["tool.output"]) == "pipeline_works"
    end

    test "tool failure propagates in pipeline" do
      dot = """
      digraph ToolFail {
        start [shape=Mdiamond]
        fail_cmd [shape=parallelogram, tool_command="false"]
        done [shape=Msquare]
        start -> fail_cmd -> done
      }
      """

      assert {:ok, result} = Arbor.Orchestrator.run(dot)
      assert result.final_outcome.status == :fail
    end
  end

  describe "direct-executable policy (H3 regression)" do
    test "security regression (H3): dangerous command is rejected by the closed policy" do
      node = %Node{
        id: "rm_attempt",
        attrs: %{
          "tool_command" => "rm -rf /",
          "sandbox" => "basic"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :fail,
             "Dangerous command must be rejected by the sandbox — H3 regression. " <>
               "Got: #{inspect(outcome)}"

      assert outcome.failure_reason =~ "direct-executable policy",
             "Failure reason should mention direct policy — got #{inspect(outcome.failure_reason)}"
    end

    test "sandbox=none cannot widen policy but retains a canonical simple command" do
      node = %Node{
        id: "ok",
        attrs: %{
          "tool_command" => ~s(/bin/echo hello),
          "sandbox" => "none"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert outcome.status == :success
    end
  end

  describe "tool-hook fail-closed policy (H5 regression)" do
    test "security regression (H5): a graph string tool_hooks.pre command never executes" do
      # H5 (codex command-execution.orchestrator-tool-hooks-shell): pre-fix,
      # ToolHooks ran graph-authored hook strings via `/bin/sh -c` with NO
      # sandbox authorization — unlike the tool *command* path (H3). An
      # agent-authored graph could put `rm -rf /` (or any dangerous command)
      # in tool_hooks.pre/post and bypass the gate the command path enforces.
      #
      # Behavioral proof of non-execution: if the historical shell hook executes,
      # the existing sentinel directory is removed.
      sentinel = Path.join(@test_dir, "do_not_delete")
      File.mkdir_p!(sentinel)

      node = %Node{
        id: "hook_attack",
        attrs: %{
          "tool_command" => ~s(/bin/echo ran),
          "sandbox" => "basic",
          "tool_hooks.pre" => "rmdir #{sentinel}"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome = ToolHandler.execute(node, context, graph, [])

      assert File.dir?(sentinel),
             "dangerous tool_hooks.pre command executed — the sandbox gate did not fire (H5 regression). " <>
               "Got outcome: #{inspect(outcome)}"

      # An unavailable pre-hook reports :skip, so the tool itself is skipped too.
      assert outcome.status == :skipped,
             "a sandbox-denied pre-hook must skip the tool — got #{inspect(outcome)}"
    end

    test "a trusted function pre-hook is allowed and the tool proceeds" do
      node = %Node{
        id: "hook_ok",
        attrs: %{
          "tool_command" => ~s(/bin/echo ran),
          "sandbox" => "basic"
        }
      }

      context = Context.new()
      graph = %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

      outcome =
        ToolHandler.execute(node, context, graph, tool_hooks: %{pre: fn _payload -> :ok end})

      assert outcome.status == :success,
             "a benign pre-hook must not block the tool — got #{inspect(outcome)}"
    end
  end
end
