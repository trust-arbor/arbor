defmodule Arbor.Orchestrator.AgentShellBoundarySecurityRegressionTest do
  @moduledoc """
  Behavioral security regressions for agent-authored DOT shell/tool surfaces.

  These tests exercise real orchestrator boundaries and delayed filesystem side
  effects. They fail on pre-fix `b4e7c13c`: DOT `sandbox=none` and string
  ToolHooks invoke a system shell, while ToolHandler permits nested dispatch
  wrappers. Candidate behavior fails closed before those processes launch.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.{ShellHandler, ToolHandler}
  alias Arbor.Orchestrator.ToolHooks

  @side_effect_wait_ms 700

  test "security regression: authorized Engine tool requires exact shell command capability" do
    root =
      Path.join(
        System.tmp_dir!(),
        "tool_handler_exact_shell_#{System.unique_integer([:positive])}"
      )

    marker = Path.join(root, "must-not-exist")
    principal = "agent_tool_exact_#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    {:ok, canonical_root} = Arbor.Common.SafePath.resolve_real(root)
    Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(principal)
    Arbor.Orchestrator.TestCapabilities.grant_capability(principal, "arbor://shell/exec")

    dot = """
    digraph ExactToolShellAuthorization {
      start [shape=Mdiamond]
      run [type="exec", target="tool", tool_command="touch #{marker}"]
      done [shape=Msquare]
      start -> run -> done
    }
    """

    try do
      assert {:ok, result} =
               Arbor.Orchestrator.run(dot,
                 authorization: true,
                 execution_principal: principal,
                 workdir: canonical_root,
                 authorizer: fn
                   ^principal, "exec" -> :ok
                   _principal, _type -> {:error, :denied}
                 end
               )

      Process.sleep(200)
      refute File.exists?(marker)
      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason =~ "Tool shell authorization denied"
      assert result.final_outcome.failure_reason =~ principal
    after
      Arbor.Orchestrator.TestCapabilities.revoke_all(principal)
      File.rm_rf!(root)
    end
  end

  test "security regression: DOT sandbox none rejects standalone ampersand before authorization" do
    marker = marker_path("dot_ampersand")
    File.rm(marker)
    parent = self()

    authorizer = fn agent_id, command, _opts ->
      send(parent, {:shell_authorizer_called, agent_id, command})
      {:ok, :authorized}
    end

    dot = """
    digraph DotAmpersandClosed {
      start [shape=Mdiamond]
      attack [type="shell", command="sleep 0.2 & touch #{marker}", sandbox="none"]
      done [shape=Msquare]
      start -> attack -> done
    }
    """

    try do
      assert {:ok, result} = Arbor.Orchestrator.run(dot, shell_authorizer: authorizer)
      Process.sleep(@side_effect_wait_ms)
      refute File.exists?(marker), "DOT sandbox:none launched a background/list side effect"

      assert result.final_outcome.status == :fail
      refute_received {:shell_authorizer_called, _, _}
    after
      File.rm(marker)
    end
  end

  test "security regression: basic string ToolHook cannot launch standalone ampersand list" do
    marker = marker_path("tool_hook_ampersand")
    File.rm(marker)
    payload = %{tool_name: "lookup", tool_call_id: "hook-1", phase: "pre"}

    try do
      result =
        ToolHooks.run(
          :pre,
          "sleep 0.2 & touch #{marker}",
          payload,
          sandbox_level: :basic
        )

      Process.sleep(@side_effect_wait_ms)
      refute File.exists?(marker), "basic ToolHook launched a background/list side effect"

      assert result.status == :error
      assert result.decision == :skip
      assert result.reason =~ "string tool hooks are unavailable"
    after
      File.rm(marker)
    end
  end

  test "security regression: ToolHandler sandbox none rejects nested env/nice/sh wrapper" do
    marker = marker_path("tool_nested_wrapper")
    File.rm(marker)

    node = %Node{
      id: "wrapper_attack",
      attrs: %{
        "tool_command" => "env nice /bin/sh -c 'touch #{marker}'",
        "sandbox" => "none"
      }
    }

    graph = %Graph{id: "wrapper_graph", nodes: %{}, edges: [], attrs: %{}}

    try do
      outcome = ToolHandler.execute(node, Context.new(), graph, [])

      Process.sleep(@side_effect_wait_ms)
      refute File.exists?(marker), "ToolHandler nested wrapper executed a shell marker"

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "agent_executable_not_allowed"
    after
      File.rm(marker)
    end
  end

  test "security regression: authorized ShellHandler rejects sort compressor before authorization" do
    %{root: root, marker: marker, output: output, command: command} =
      sort_shell_dispatch_fixture("shell_handler")

    parent = self()

    authorizer = fn agent_id, received_command, _opts ->
      send(parent, {:sort_authorizer_called, agent_id, received_command})
      {:ok, :authorized}
    end

    node = %Node{
      id: "sort_attack",
      attrs: %{
        "command" => command,
        "sandbox" => "none",
        "timeout" => "100",
        "agent_id" => "agent_sort_attack"
      }
    }

    {:ok, authority} =
      RunAuthorization.new(%Graph{compiled: true},
        agent_id: "agent_sort_authority",
        workdir: elem(Arbor.Common.SafePath.resolve_real(root), 1)
      )

    try do
      outcome =
        ShellHandler.execute(node, Context.new(), %Graph{},
          shell_authorizer: authorizer,
          run_authorization: authority
        )

      Process.sleep(@side_effect_wait_ms + 800)
      refute File.exists?(marker), "authorized ShellHandler launched sort's shell compressor"
      refute File.exists?(output), "rejected ShellHandler sort created output"
      refute_received {:sort_authorizer_called, _, _}
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "agent_argv_not_allowed"
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: ToolHandler rejects sort compressor and delayed helper tree" do
    %{root: root, marker: marker, output: output, command: command} =
      sort_shell_dispatch_fixture("tool_handler")

    hook_marker = Path.join(root, "pre_hook_marker")

    node = %Node{
      id: "sort_tool_attack",
      attrs: %{
        "tool_command" => command,
        "sandbox" => "none",
        "tool_hooks.pre" => fn _payload ->
          File.write!(hook_marker, "ran")
          :ok
        end
      }
    }

    graph = %Graph{id: "sort_tool_graph", nodes: %{}, edges: [], attrs: %{}}

    try do
      outcome = ToolHandler.execute(node, Context.new(), graph, [])

      Process.sleep(@side_effect_wait_ms + 800)
      refute File.exists?(marker), "ToolHandler launched sort's delayed compressor child"
      refute File.exists?(output), "rejected ToolHandler sort created output"
      refute File.exists?(hook_marker), "ToolHandler ran a pre-hook before argv rejection"
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "agent_argv_not_allowed"
    after
      File.rm_rf!(root)
    end
  end

  test "trusted injected ToolHook runner remains explicit and available" do
    parent = self()
    payload = %{tool_name: "lookup", tool_call_id: "hook-2", phase: "pre"}

    runner = fn command, received_payload, _opts ->
      send(parent, {:trusted_hook_runner, command, received_payload})
      {:command, "trusted", 0}
    end

    result = ToolHooks.run(:pre, "operator-defined", payload, tool_hook_runner: runner)

    assert result.status == :ok
    assert result.output == "trusted"
    assert_received {:trusted_hook_runner, "operator-defined", ^payload}
  end

  defp marker_path(tag) do
    Path.join(
      System.tmp_dir!(),
      "orchestrator_agent_shell_#{tag}_#{System.unique_integer([:positive])}"
    )
  end

  defp sort_shell_dispatch_fixture(tag) do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator_sort_dispatch_#{tag}_#{System.unique_integer([:positive])}"
      )

    input = Path.join(root, "input")
    output = Path.join(root, "output")
    marker = Path.join(root, "marker")
    File.mkdir_p!(root)

    comments =
      for i <- 1..40_000, into: "" do
        "# #{i} #{String.duplicate("x", 48)}\n"
      end

    File.write!(input, comments <> "sleep 1\ntouch #{marker}\n")

    %{
      root: root,
      marker: marker,
      output: output,
      command: "sort -S 64K --compress-program=/bin/sh -o #{output} #{input}"
    }
  end
end
