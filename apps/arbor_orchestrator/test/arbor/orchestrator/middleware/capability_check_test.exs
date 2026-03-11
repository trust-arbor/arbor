defmodule Arbor.Orchestrator.Middleware.CapabilityCheckTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{CapabilityCheck, Token}

  defp make_token(attrs \\ %{}, assigns \\ %{}) do
    node = %Node{id: "cap_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"cap_node" => node}, edges: [], attrs: %{}}
    %Token{node: node, context: context, graph: graph, assigns: assigns}
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

    test "uses default agent_id when not in assigns" do
      # Verifies the default "agent_system" path doesn't crash
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
               "arbor://orchestrator/execute/file_read"
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
      assert CapabilityCheck.capability_resources(node) == ["arbor://orchestrator/execute/shell"]
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
  end
end
