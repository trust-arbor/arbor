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

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ToolHandler
  alias Arbor.Orchestrator.ToolHooks

  @side_effect_wait_ms 700

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
end
