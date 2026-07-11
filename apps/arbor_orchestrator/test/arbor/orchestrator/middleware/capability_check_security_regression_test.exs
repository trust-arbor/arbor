defmodule Arbor.Orchestrator.Middleware.CapabilityCheckSecurityRegressionTest do
  # async: false — mutates :arbor_orchestrator app env (:security_module +
  # :security_available_override), so it must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.SigningAuthority
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

  defmodule RecordingSecurity do
    def authorize(_agent, resource, _action, opts) do
      send(self(), {:authorize, resource, opts})
      {:ok, :authorized}
    end
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

  defp token(attrs \\ %{}, opts \\ []) do
    node = %Node{id: "n", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    raw = %Graph{nodes: %{"n" => node}, edges: [], attrs: %{}}
    {:ok, graph} = Arbor.Orchestrator.compile(raw)
    node = Map.fetch!(graph.nodes, "n")

    {:ok, authority} =
      RunAuthorization.new(graph,
        agent_id: "agent_test",
        workdir: Keyword.get(opts, :workdir, File.cwd!())
      )

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

  defp composition_workspace do
    lexical_root =
      Path.join(
        System.tmp_dir!(),
        "capability_check_composition_#{System.unique_integer([:positive])}"
      )

    workdir = Path.join(lexical_root, "workdir")
    outside = Path.join(lexical_root, "outside")
    File.mkdir_p!(workdir)
    File.mkdir_p!(outside)

    {:ok, canonical_workdir} = SafePath.resolve_real(workdir)
    {:ok, canonical_outside} = SafePath.resolve_real(outside)

    on_exit(fn -> File.rm_rf(lexical_root) end)

    {canonical_workdir, canonical_outside}
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

      # Invalid UTF-8 cannot produce a compiled graph hash, so RunAuthorization
      # itself fails closed before CapabilityCheck runs.
      invalid_utf8_node = %Node{
        id: "n",
        attrs: %{"type" => "graph.invoke", "graph_file" => <<255>>}
      }

      raw = %Graph{nodes: %{"n" => invalid_utf8_node}, edges: [], attrs: %{}}
      {:ok, compiled} = Arbor.Orchestrator.compile(raw)

      assert {:error, :compiled_graph_hash_failed} =
               RunAuthorization.new(compiled, agent_id: "agent_test", workdir: File.cwd!())

      # Other malformed values still compile and reach CapabilityCheck under
      # valid run authority, then fail closed at path validation.
      for graph_file <- [nil, "", <<"child", 0, ".dot">>, 123] do
        result =
          CapabilityCheck.before_node(
            token(%{"type" => "graph.invoke", "graph_file" => graph_file})
          )

        assert result.halted
        assert result.outcome.failure_reason =~ "invalid_file_path"
      end
    end

    test "symlinked composition files outside the workdir halt before fs/read authorization" do
      Application.put_env(:arbor_orchestrator, :security_module, RecordingSecurity)
      {workdir, outside} = composition_workspace()
      outside_dot = Path.join(outside, "outside.dot")
      File.write!(outside_dot, "digraph outside {}")

      for {type, file_key} <- [{"graph.invoke", "graph_file"}, {"pipeline.run", "source_file"}] do
        symlink = Path.join(workdir, "#{type}.dot")
        File.ln_s!(outside_dot, symlink)

        result =
          CapabilityCheck.before_node(
            token(%{"type" => type, file_key => Path.basename(symlink)}, workdir: workdir)
          )

        assert result.halted
        assert result.outcome.failure_reason =~ "invalid_file_path"
        assert_received {:authorize, "arbor://action/pipeline/run", _opts}
        refute_received {:authorize, "arbor://fs/read", _opts}
      end
    end

    test "in-workdir composition symlinks authorize the real target path" do
      Application.put_env(:arbor_orchestrator, :security_module, RecordingSecurity)
      {workdir, _outside} = composition_workspace()
      real_target = Path.join(workdir, "child.dot")
      symlink = Path.join(workdir, "child-link.dot")
      File.write!(real_target, "digraph child {}")
      File.ln_s!(real_target, symlink)

      result =
        CapabilityCheck.before_node(
          token(%{"type" => "graph.invoke", "graph_file" => Path.basename(symlink)},
            workdir: workdir
          )
        )

      assert not result.halted
      assert_received {:authorize, "arbor://action/pipeline/run", _opts}
      assert_received {:authorize, "arbor://fs/read", opts}
      assert Keyword.fetch!(opts, :file_path) == real_target
      refute Keyword.fetch!(opts, :file_path) == symlink
    end
  end

  describe "security regression: SigningAuthority path ignores Config.security_module" do
    test "forged authority fails closed without consulting the injected security double" do
      # Inject a double that would authorize everything if consulted.
      Application.put_env(:arbor_orchestrator, :security_module, RecordingSecurity)

      {:ok, forged} =
        SigningAuthority.new(
          token: :crypto.strong_rand_bytes(32),
          principal_id: "agent_test",
          purpose: :session
        )

      t =
        token()
        |> Map.update!(:assigns, fn assigns ->
          assigns
          |> Map.put(:signing_authority, forged)
          |> Map.delete(:signer)
        end)

      result = CapabilityCheck.before_node(t)

      # Must fail closed via Arbor.Security.sign_with_authority (forged token),
      # never reach the RecordingSecurity double.
      assert result.halted
      assert result.outcome.status == :fail

      assert result.outcome.failure_reason =~ "authority_signing_failed" or
               result.outcome.failure_reason =~ "Capability check failed"

      refute_received {:authorize, _, _}
    end
  end
end
