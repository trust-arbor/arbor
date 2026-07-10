defmodule Arbor.Orchestrator.Middleware.CapabilityCheckTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{CapabilityCheck, Token}
  alias Arbor.Orchestrator.Stdlib.Aliases

  defp make_token(attrs \\ %{}, assigns \\ %{}) do
    node = %Node{id: "cap_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"cap_node" => node}, edges: [], attrs: %{}}
    {:ok, authority} = RunAuthorization.new(graph, agent_id: "agent_test", workdir: File.cwd!())

    default_assigns = %{
      authorization: true,
      agent_id: "agent_test",
      run_authorization: authority
    }

    %Token{
      node: node,
      context: context,
      graph: graph,
      assigns: Map.merge(default_assigns, assigns)
    }
  end

  defp make_compiled_node(overrides) do
    defaults = %{
      id: "compiled_node",
      attrs: %{"type" => "compute"},
      type: "compute",
      capabilities_required: [],
      taint_profile: nil,
      llm_model: nil,
      llm_provider: nil,
      timeout_ms: nil,
      handler_module: nil
    }

    struct(Node, Map.merge(defaults, overrides))
  end

  # --- before_node skip conditions ---

  describe "before_node/1 skip conditions" do
    test "passes through when skip_capability_check is set" do
      token = make_token(%{}, %{skip_capability_check: true})
      result = CapabilityCheck.before_node(token)
      refute result.halted
    end

    test "passes through when authorization is false" do
      token = make_token(%{}, %{authorization: false})
      result = CapabilityCheck.before_node(token)
      refute result.halted
    end

    test "skip_capability_check takes priority over authorization true" do
      token = make_token(%{}, %{skip_capability_check: true, authorization: true})
      result = CapabilityCheck.before_node(token)
      refute result.halted
    end

    test "gracefully handles missing Security module" do
      # In test env, Security may or may not be loaded
      token = make_token()
      result = CapabilityCheck.before_node(token)
      assert is_struct(result, Token)
    end

    test "uses the immutable authority principal" do
      token = make_token()
      result = CapabilityCheck.before_node(token)
      assert is_struct(result, Token)
    end
  end

  # --- capability_resources ---

  describe "capability_resources/1" do
    test "uses capabilities_required when populated" do
      node = make_compiled_node(%{capabilities_required: ["llm_query", "file_read"]})

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/llm_query",
               "arbor://fs/read"
             ]
    end

    test "preserves already-qualified URIs" do
      node =
        make_compiled_node(%{
          capabilities_required: ["arbor://custom/execute/foo", "bare_name"]
        })

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://custom/execute/foo",
               "arbor://orchestrator/execute/bare_name"
             ]
    end

    test "falls back to type-based URI for empty list" do
      node = make_compiled_node(%{capabilities_required: [], attrs: %{"type" => "shell"}})
      assert CapabilityCheck.capability_resources(node) == ["arbor://shell/exec"]
    end

    test "falls back to type-based URI for nil" do
      node = %Node{id: "test", attrs: %{"type" => "compute"}, capabilities_required: nil}

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/compute"
             ]
    end

    test "uses 'unknown' when type attr is missing" do
      node = %Node{id: "test", attrs: %{}, capabilities_required: []}

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/unknown"
             ]
    end

    test "handles single capability" do
      node = make_compiled_node(%{capabilities_required: ["single_cap"]})

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/single_cap"
             ]
    end

    test "handles many capabilities" do
      caps = Enum.map(1..10, &"cap_#{&1}")
      node = make_compiled_node(%{capabilities_required: caps})
      resources = CapabilityCheck.capability_resources(node)
      assert length(resources) == 10
      assert Enum.all?(resources, &String.starts_with?(&1, "arbor://orchestrator/execute/"))
    end

    test "does not double-prefix already qualified URIs" do
      node =
        make_compiled_node(%{
          capabilities_required: ["arbor://orchestrator/execute/already_prefixed"]
        })

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/already_prefixed"
             ]
    end

    test "raw file and command handlers use canonical host-effect resources" do
      read = %Node{id: "read", attrs: %{"type" => "read", "source" => "file"}}
      write = %Node{id: "write", attrs: %{"type" => "file.write"}}
      shell = %Node{id: "shell", attrs: %{"type" => "shell"}}
      tool = %Node{id: "tool", attrs: %{"type" => "tool"}}

      assert CapabilityCheck.capability_resources(read) == ["arbor://fs/read"]
      assert CapabilityCheck.capability_resources(write) == ["arbor://fs/write"]
      assert CapabilityCheck.capability_resources(shell) == ["arbor://shell/exec"]
      assert CapabilityCheck.capability_resources(tool) == ["arbor://shell/exec"]
    end

    test "context reads and accumulator writes remain traversal-only" do
      read = %Node{id: "read", attrs: %{"type" => "read", "source" => "context"}}

      write =
        %Node{id: "write", attrs: %{"type" => "write", "target" => "accumulator"}}

      assert CapabilityCheck.capability_resources(read) == [
               "arbor://orchestrator/execute/read"
             ]

      assert CapabilityCheck.capability_resources(write) == [
               "arbor://orchestrator/execute/write"
             ]
    end

    test "handles mixed qualified and bare capabilities" do
      node =
        make_compiled_node(%{
          capabilities_required: [
            "arbor://security/read/keys",
            "bare_cap",
            "arbor://memory/write/notes"
          ]
        })

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://security/read/keys",
               "arbor://orchestrator/execute/bare_cap",
               "arbor://memory/write/notes"
             ]
    end

    test "security regression: composition aliases and modes always require pipeline.run" do
      for type <- Aliases.aliases_for("compose") do
        node = %Node{id: type, attrs: %{"type" => type}}

        assert "arbor://action/pipeline/run" in CapabilityCheck.capability_resources(node),
               "missing composition capability for #{inspect(node.attrs)}"
      end
    end

    test "file-backed composition additionally requires fs/read" do
      for node <- [
            %Node{
              id: "graph_file",
              attrs: %{"type" => "graph.invoke", "graph_file" => "child.dot"}
            },
            %Node{
              id: "canonical_graph_file",
              attrs: %{"type" => "compose", "mode" => "invoke", "graph_file" => "child.dot"}
            },
            %Node{
              id: "pipeline_file",
              attrs: %{"type" => "pipeline.run", "source_file" => "child.dot"}
            },
            %Node{
              id: "canonical_pipeline_file",
              attrs: %{"type" => "compose", "mode" => "pipeline", "source_file" => "child.dot"}
            }
          ] do
        resources = CapabilityCheck.capability_resources(node)
        assert "arbor://action/pipeline/run" in resources
        assert "arbor://fs/read" in resources
      end

      context_backed = %Node{
        id: "context_graph",
        attrs: %{"type" => "graph.compose", "source_key" => "child_dot"}
      }

      assert CapabilityCheck.capability_resources(context_backed) == [
               "arbor://action/pipeline/run"
             ]
    end

    test "file-backed composition aliases require fs/read after alias injection" do
      for type <- Aliases.aliases_for("compose"),
          {_canonical, injected} <- [Aliases.resolve(type)],
          Enum.any?(["graph_file", "file", "source_file"], &Map.has_key?(injected, &1)) do
        node = %Node{id: type, attrs: %{"type" => type}}
        resources = CapabilityCheck.capability_resources(node)

        assert "arbor://action/pipeline/run" in resources
        assert "arbor://fs/read" in resources, "#{type} must authorize its injected graph file"
      end
    end
  end
end
