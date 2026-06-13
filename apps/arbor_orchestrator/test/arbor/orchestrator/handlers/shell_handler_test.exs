defmodule Arbor.Orchestrator.Handlers.ShellHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ShellHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp make_node(id, attrs) do
    # Tests run without Arbor.Shell — use sandbox="none" to allow direct execution.
    # In production, sandbox defaults to "basic" and requires Arbor.Shell.
    %Node{id: id, attrs: Map.merge(%{"type" => "shell", "sandbox" => "none"}, attrs)}
  end

  # These mechanics tests exercise the execution path, not authorization.
  # Since the phase-0 capability gate (2026-06-10) now authorizes every
  # shell node — and Arbor.Shell IS loadable in the umbrella test build —
  # inject an allowing authorizer so the gate is a no-op here. The gate
  # itself is covered by the "security regression" describe block below.
  defp run(node, context, opts \\ []) do
    opts = Keyword.put_new(opts, :shell_authorizer, &allow/3)
    ShellHandler.execute(node, context, @graph, opts)
  end

  defp allow(_agent_id, _command, _opts), do: {:ok, :authorized}
  defp deny(_agent_id, _command, _opts), do: {:error, :unauthorized}

  defp sentinel_path(tag) do
    Path.join(System.tmp_dir!(), "arbor_shell_gate_#{tag}_#{System.unique_integer([:positive])}")
  end

  describe "execute/4" do
    test "runs a simple command" do
      node = make_node("echo_test", %{"command" => "echo hello"})
      context = Context.new()

      assert %Outcome{status: :success} = run(node, context)
    end

    test "captures command output in context" do
      node = make_node("echo_test", %{"command" => "echo hello_world"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      assert String.contains?(outcome.context_updates["shell.echo_test.output"], "hello_world")
      assert outcome.context_updates["shell.echo_test.exit_code"] == 0
    end

    test "fails on non-zero exit code by default" do
      node = make_node("fail_test", %{"command" => "sh -c 'exit 1'"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :fail
      assert outcome.context_updates["shell.fail_test.exit_code"] == 1
    end

    test "on_error=warn returns success with warning" do
      node = make_node("warn_test", %{"command" => "sh -c 'exit 1'", "on_error" => "warn"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      assert String.contains?(outcome.notes, "code 1")
    end

    test "on_error=continue returns success" do
      node =
        make_node("continue_test", %{"command" => "sh -c 'exit 42'", "on_error" => "continue"})

      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      assert outcome.context_updates["shell.continue_test.exit_code"] == 42
    end

    test "missing command fails" do
      node = make_node("no_cmd", %{})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires 'command'")
    end

    test "respects cwd from node attribute" do
      node = make_node("cwd_test", %{"command" => "pwd", "cwd" => "/tmp"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      # /tmp may resolve to /private/tmp on macOS
      assert String.contains?(outcome.context_updates["shell.cwd_test.output"], "tmp")
    end

    test "respects cwd from context workdir" do
      node = make_node("cwd_ctx", %{"command" => "pwd"})
      context = Context.new(%{"workdir" => "/tmp"})

      outcome = run(node, context)
      assert outcome.status == :success
      assert String.contains?(outcome.context_updates["shell.cwd_ctx.output"], "tmp")
    end

    test "timeout produces error" do
      node = make_node("timeout_test", %{"command" => "sleep 10", "timeout" => "100"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "timeout")
    end

    test "output with multiple lines captured" do
      # Use a single command that produces multi-line output
      node = make_node("multi", %{"command" => "ls /tmp"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      output = outcome.context_updates["shell.multi.output"]
      assert String.length(output) > 0
    end

    test "regression: shell node does not clobber last_response (bug A)" do
      # Setup: pipeline shape `LLM → shell → use last_response`.
      # Previously, the shell node wrote `"last_response" => output`
      # in its context_updates, overwriting whatever the prior compute/
      # LLM node had produced. Production pipelines relying on the
      # `last_response` convention (LLM output) silently lost data
      # whenever a shell node ran downstream of a compute node.
      #
      # Fix: ShellHandler.execute/4 emits only `shell.<id>.exit_code`
      # and `shell.<id>.output`; `last_response` is reserved for
      # LLM/compute outputs (see handler_schema.ex compute ports).
      #
      # Surfaced 2026-06-05 by the upstream-deps-summary pipeline
      # losing the categorizer's LLM output to a downstream `mkdir &&
      # printf` shell node.
      node = make_node("just_a_shell", %{"command" => "echo from_shell"})
      context = Context.new()

      outcome = run(node, context)

      refute Map.has_key?(outcome.context_updates, "last_response"),
             "ShellHandler must not write last_response — that key is " <>
               "owned by LLM/compute nodes. Bug A: shell output " <>
               "clobbered LLM responses in pipelines of the shape " <>
               "LLM → shell → use last_response."
    end

    test "regression: captures full stdout from compound commands (bug B)" do
      # Setup: a compound command like `mkdir -p X && printf '%s' Y`
      # races on the port: the spawn port sends `:exit_status` and
      # trailing `{:data, _}` in an unspecified order, and for compound
      # commands with multiple forks, exit can win — handing the
      # caller an empty string even though the command produced
      # output. Bare-printf commands win the race; compound commands
      # often lose it.
      #
      # Fix: after receiving `:exit_status`, drain any remaining
      # `{:data, _}` messages with a 0-timeout receive before
      # returning.
      #
      # Surfaced 2026-06-05 by the upstream-deps-summary pipeline's
      # `build_output_path` step (mkdir-then-printf) returning empty
      # output, breaking the file_write target path.
      cmd =
        ~s|mkdir -p /tmp/arbor_shell_regression && printf '%s' "/tmp/arbor_shell_regression/x.md"|

      node = make_node("compound", %{"command" => cmd})
      context = Context.new()

      # Loop to catch raciness — if the bug is back this often fails
      # on the first or second iteration.
      for i <- 1..10 do
        outcome = run(node, context)
        output = outcome.context_updates["shell.compound.output"]

        assert outcome.status == :success, "iteration #{i}: status was #{inspect(outcome.status)}"

        assert output == "/tmp/arbor_shell_regression/x.md",
               "iteration #{i}: expected full path but got #{inspect(output)} " <>
                 "(exit_code=#{outcome.context_updates["shell.compound.exit_code"]}). " <>
                 "Bug B: collect_output/3 returned on :exit_status without " <>
                 "draining trailing :data messages."
      end
    end
  end

  describe "security regression: shell node capability gate (2026-06-10)" do
    # Before the phase-0 fix, ShellHandler.execute/4 ran `command` with NO
    # authorization. Any agent that could author or influence a DOT graph
    # got arbitrary shell — including the sandbox="none" real-/bin/sh path.
    # This is the orphan-path twin of ExecHandler's authorized
    # target="action" branch.
    #
    # Each test injects a DENYING authorizer and asserts the node fails
    # closed WITHOUT running the command (a sentinel file is never created).
    # On `git checkout HEAD~1` the command runs and the file appears, so
    # these fail on revert — proving the gate. See
    # .arbor/roadmap/1-brainstorming/safe-shell-execution.md (Phase 0).

    test "denies an unauthorized principal and does not execute the command" do
      sentinel = sentinel_path("denied")
      File.rm(sentinel)
      # Principal resolved from the session context.
      context = Context.new(%{"session.agent_id" => "agent_untrusted"})
      node = make_node("denied", %{"command" => "touch #{sentinel}"})

      outcome = ShellHandler.execute(node, context, @graph, shell_authorizer: &deny/3)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "authorization denied"

      assert outcome.failure_reason =~ "agent_untrusted",
             "principal must be resolved from session.agent_id"

      refute File.exists?(sentinel),
             "command executed despite denial — the capability gate did not " <>
               "fire (regression: shell node ran unauthorized, the 2026-06-10 bug)"
    end

    test "sandbox=none does NOT bypass the gate (the /bin/sh -c path)" do
      # The sharpest edge: sandbox="none" runs a real `/bin/sh -c`, which
      # previously skipped Arbor.Shell entirely. It must still authorize.
      sentinel = sentinel_path("none")
      File.rm(sentinel)
      # make_node already sets sandbox="none".
      node = make_node("denied_none", %{"command" => "touch #{sentinel} && echo done"})

      outcome = ShellHandler.execute(node, Context.new(), @graph, shell_authorizer: &deny/3)

      assert outcome.status == :fail

      refute File.exists?(sentinel),
             "sandbox=none bypassed the capability gate — /bin/sh -c ran unauthorized"
    end

    test "pending approval fails closed (escalation, not execution)" do
      sentinel = sentinel_path("pending")
      File.rm(sentinel)
      pending = fn _agent_id, _command, _opts -> {:ok, :pending_approval, "prop_123"} end
      node = make_node("pending", %{"command" => "touch #{sentinel}"})

      outcome = ShellHandler.execute(node, Context.new(), @graph, shell_authorizer: pending)

      assert outcome.status == :fail

      refute File.exists?(sentinel),
             "a command awaiting approval must not run until approved"
    end

    test "an authorized principal runs the command" do
      node = make_node("allowed", %{"command" => "echo authorized"})

      outcome = ShellHandler.execute(node, Context.new(), @graph, shell_authorizer: &allow/3)

      assert outcome.status == :success
      assert outcome.context_updates["shell.allowed.output"] =~ "authorized"
    end
  end

  describe "idempotency/0" do
    test "returns :side_effecting" do
      assert ShellHandler.idempotency() == :side_effecting
    end
  end

  describe "registry" do
    test "shell type resolves to ExecHandler (Phase 4 delegation)" do
      node = make_node("reg_test", %{})

      assert Arbor.Orchestrator.Handlers.Registry.resolve(node) ==
               Arbor.Orchestrator.Handlers.ExecHandler
    end

    test "shell type injects target attribute via resolve_with_attrs" do
      node = make_node("reg_test", %{})
      {handler, resolved_node} = Arbor.Orchestrator.Handlers.Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ExecHandler
      assert resolved_node.attrs["target"] == "shell"
    end
  end
end
