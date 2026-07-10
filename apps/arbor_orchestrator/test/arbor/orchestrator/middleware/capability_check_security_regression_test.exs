defmodule Arbor.Orchestrator.Middleware.CapabilityCheckSecurityRegressionTest do
  # async: false — mutates :arbor_orchestrator app env (:security_module +
  # :security_available_override), so it must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{CapabilityCheck, Token}

  # Stub "security" modules injected via the Config.security_module/0 seam.
  # Each mimics Arbor.Security.authorize/4 returning one decision shape.
  defmodule PendingSecurity do
    def authorize(_agent, _resource, _action, _opts), do: {:ok, :pending_approval, "proposal_1"}
  end

  defmodule GrantedSecurity do
    def authorize(_agent, _resource, _action, _opts), do: {:ok, :authorized}
  end

  defmodule GrantedPathSecurity do
    def authorize(_agent, _resource, _action, _opts), do: {:ok, :authorized, "/ws/ok.txt"}
  end

  defmodule DeniedSecurity do
    def authorize(_agent, _resource, _action, _opts), do: {:error, :no_capability}
  end

  defmodule LobbyOnlySecurity do
    def authorize(_agent, "arbor://orchestrator/execute/" <> _rest, _action, _opts),
      do: {:ok, :authorized}

    def authorize(_agent, _resource, _action, _opts), do: {:error, :no_capability}
  end

  setup do
    prev_mod = Application.get_env(:arbor_orchestrator, :security_module)
    prev_override = Application.get_env(:arbor_orchestrator, :security_available_override)
    # Force the authorize path to run (no real CapabilityStore in this unit test).
    Application.put_env(:arbor_orchestrator, :security_available_override, true)

    on_exit(fn ->
      restore(:security_module, prev_mod)
      restore(:security_available_override, prev_override)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore(key, val), do: Application.put_env(:arbor_orchestrator, key, val)

  defp token(attrs \\ %{}) do
    node = %Node{id: "n", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    graph = %Graph{nodes: %{"n" => node}, edges: [], attrs: %{}}
    {:ok, authority} = RunAuthorization.new(graph, agent_id: "agent_test", workdir: File.cwd!())

    %Token{
      node: node,
      context: %Context{values: %{}},
      graph: graph,
      assigns: %{
        authorization: true,
        agent_id: "agent_test",
        run_authorization: authority
      }
    }
  end

  describe "security regression: pending approval is not authorization" do
    test "a PENDING approval halts the node (does NOT execute before approval)" do
      Application.put_env(:arbor_orchestrator, :security_module, PendingSecurity)

      result = CapabilityCheck.before_node(token())

      # Pre-fix this recursed like {:ok, :authorized} and the node ran.
      assert result.halted,
             "pending-approval must NOT authorize node execution — the node must halt until approval is granted"

      assert result.outcome.status == :fail
    end

    test "control: a granted authorization proceeds (not halted)" do
      Application.put_env(:arbor_orchestrator, :security_module, GrantedSecurity)
      refute CapabilityCheck.before_node(token()).halted
    end

    test "control: a granted 3-tuple (resolved path) proceeds (not halted)" do
      Application.put_env(:arbor_orchestrator, :security_module, GrantedPathSecurity)
      refute CapabilityCheck.before_node(token()).halted
    end

    test "control: a denial halts" do
      Application.put_env(:arbor_orchestrator, :security_module, DeniedSecurity)
      assert CapabilityCheck.before_node(token()).halted
    end
  end

  describe "security regression: graph composition has an independent capability floor" do
    test "an orchestrator-lobby-only principal cannot compose a child pipeline" do
      Application.put_env(:arbor_orchestrator, :security_module, LobbyOnlySecurity)

      result =
        CapabilityCheck.before_node(token(%{"type" => "graph.compose", "source_key" => "child"}))

      assert result.halted
      assert result.outcome.status == :fail
      assert result.outcome.failure_reason =~ "arbor://action/pipeline/run"
    end

    test "malformed file-backed composition bindings fail closed" do
      Application.put_env(:arbor_orchestrator, :security_module, GrantedSecurity)

      for graph_file <- [nil, "", <<255>>, 123] do
        result =
          CapabilityCheck.before_node(
            token(%{"type" => "graph.invoke", "graph_file" => graph_file})
          )

        assert result.halted
        assert result.outcome.failure_reason =~ "invalid_file_path"
      end
    end
  end
end
