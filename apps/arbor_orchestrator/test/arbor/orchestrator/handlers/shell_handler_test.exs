defmodule Arbor.Orchestrator.Handlers.ShellHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ShellHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}, compiled: true}

  defp make_node(id, attrs) do
    # sandbox="none" remains a compatibility input but cannot widen the closed
    # agent direct-executable policy.
    %Node{id: id, attrs: Map.merge(%{"type" => "shell", "sandbox" => "none"}, attrs)}
  end

  # These mechanics tests exercise the execution path, not authorization.
  # Since the phase-0 capability gate (2026-06-10) now authorizes every
  # shell node — and Arbor.Shell IS loadable in the umbrella test build —
  # inject an allowing authorizer so the gate is a no-op here. The gate
  # itself is covered by the "security regression" describe block below.
  defp run(node, context, opts \\ []) do
    {authority_workdir, opts} = Keyword.pop(opts, :authority_workdir, File.cwd!())
    {authority_principal, opts} = Keyword.pop(opts, :authority_principal, "agent_shell_handler")

    {:ok, authority} =
      RunAuthorization.new(@graph, agent_id: authority_principal, workdir: authority_workdir)

    opts =
      opts
      |> Keyword.put_new(:shell_authorizer, &allow/3)
      |> Keyword.put(:run_authorization, authority)

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

    test "security regression: standalone handler uses prepared execution without registry" do
      registry_pid = Process.whereis(Arbor.Shell.ExecutionRegistry)

      if registry_pid do
        GenServer.stop(registry_pid)

        on_exit(fn ->
          unless Process.whereis(Arbor.Shell.ExecutionRegistry) do
            {:ok, _pid} = Arbor.Shell.ExecutionRegistry.start_link([])
          end
        end)
      end

      refute Process.whereis(Arbor.Shell.ExecutionRegistry)
      node = make_node("standalone_prepared", %{"command" => "echo standalone-owned"})

      assert %Outcome{status: :success, context_updates: updates} =
               run(node, Context.new())

      assert updates["shell.standalone_prepared.output"] =~ "standalone-owned"
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
      node = make_node("fail_test", %{"command" => "false"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :fail
      assert outcome.context_updates["shell.fail_test.exit_code"] == 1
    end

    test "on_error=warn returns success with warning" do
      node = make_node("warn_test", %{"command" => "false", "on_error" => "warn"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      assert String.contains?(outcome.notes, "code 1")
    end

    test "on_error=continue returns success" do
      node =
        make_node("continue_test", %{"command" => "false", "on_error" => "continue"})

      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      assert outcome.context_updates["shell.continue_test.exit_code"] == 1
    end

    test "missing command fails" do
      node = make_node("no_cmd", %{})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires 'command'")
    end

    test "graph cwd cannot override immutable run workdir" do
      node = make_node("cwd_test", %{"command" => "pwd", "cwd" => "/tmp"})
      context = Context.new()

      outcome = run(node, context)
      assert outcome.status == :success
      assert String.trim(outcome.context_updates["shell.cwd_test.output"]) == File.cwd!()
    end

    test "context workdir cannot override immutable run workdir" do
      node = make_node("cwd_ctx", %{"command" => "pwd"})
      context = Context.new(%{"workdir" => "/tmp"})

      outcome = run(node, context)
      assert outcome.status == :success
      assert String.trim(outcome.context_updates["shell.cwd_ctx.output"]) == File.cwd!()
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

    test "security regression: standalone ampersand list fails closed under sandbox none" do
      marker = sentinel_path("standalone_ampersand")
      File.rm(marker)
      node = make_node("compound", %{"command" => "sleep 0.2 & touch #{marker}"})

      try do
        outcome = run(node, Context.new())
        assert outcome.status == :fail
        assert outcome.failure_reason =~ "compound_shell_unavailable"

        Process.sleep(700)
        refute File.exists?(marker)
      after
        File.rm(marker)
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
      context = Context.new(%{"session.agent_id" => "agent_untrusted"})
      node = make_node("denied", %{"command" => "touch #{sentinel}"})

      outcome =
        run(node, context,
          shell_authorizer: &deny/3,
          authority_principal: "agent_immutable_authority"
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "authorization denied"

      assert outcome.failure_reason =~ "agent_immutable_authority"
      refute outcome.failure_reason =~ "agent_untrusted"

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

      outcome = run(node, Context.new(), shell_authorizer: &deny/3)

      assert outcome.status == :fail

      refute File.exists?(sentinel),
             "sandbox=none bypassed the capability gate — /bin/sh -c ran unauthorized"
    end

    test "pending approval fails closed (escalation, not execution)" do
      sentinel = sentinel_path("pending")
      File.rm(sentinel)
      pending = fn _agent_id, _command, _opts -> {:ok, :pending_approval, "prop_123"} end
      node = make_node("pending", %{"command" => "touch #{sentinel}"})

      outcome = run(node, Context.new(), shell_authorizer: pending)

      assert outcome.status == :fail

      refute File.exists?(sentinel),
             "a command awaiting approval must not run until approved"
    end

    test "security regression: immutable system principal cannot escalate into shell" do
      sentinel = sentinel_path("system_principal")
      node = make_node("system_principal", %{"command" => "touch #{sentinel}"})

      outcome =
        run(node, Context.new(),
          shell_authorizer: &allow/3,
          authority_principal: "system"
        )

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "system_principal_shell_forbidden"
      refute File.exists?(sentinel)
    end

    test "an authorized principal runs the command" do
      node = make_node("allowed", %{"command" => "echo authorized"})

      outcome = run(node, Context.new(), shell_authorizer: &allow/3)

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
