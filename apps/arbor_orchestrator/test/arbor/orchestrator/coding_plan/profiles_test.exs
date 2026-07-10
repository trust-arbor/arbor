defmodule Arbor.Orchestrator.CodingPlan.ProfilesTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.Profiles
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @moduletag :fast

  @known_ids ~w[
    contract_change
    cross_app
    database_migration
    default
    docs_only
    frontend_visual
    security_regression
  ]

  @executable_ids ~w[default]
  @unsupported_ids @known_ids -- @executable_ids

  describe "declarations" do
    test "declares every documented profile deterministically as JSON-clean data" do
      profiles = Profiles.all()

      assert Profiles.known_ids() == @known_ids
      assert Enum.map(profiles, & &1["id"]) == @known_ids
      assert {:ok, _encoded} = Jason.encode(profiles)

      for profile <- profiles do
        assert Map.keys(profile) |> Enum.all?(&is_binary/1)
        assert profile["template_version"] == "coding-change-v1"
        assert is_boolean(profile["executable"])
        assert is_map(profile["validation_strategy"])
        assert is_map(profile["review_strategy"])
        assert profile["required_nodes"] == Enum.sort(Enum.uniq(profile["required_nodes"]))
        assert profile["required_actions"] == Enum.sort(Enum.uniq(profile["required_actions"]))
      end
    end

    test "exposes only reviewed enforceable validation strategies" do
      assert {:ok, default} = Profiles.fetch_executable("default")
      assert default["validation_strategy"] == %{"action" => "mix_compile"}

      assert default["review_strategy"] == %{
               "action" => "council_review_change",
               "binding" => true
             }

      assert {:ok, security} = Profiles.fetch("security_regression")
      refute security["executable"]

      assert security["validation_strategy"] == %{
               "action" => "mix_test",
               "path_parameter" => "test_paths",
               "path_source" => "requested_paths",
               "requires_non_empty_paths" => true
             }

      assert "mix_compile" in default["required_actions"]
      assert "coding_workspace_inspect" in default["required_actions"]
      assert "coding_workspace_committed_change" in default["required_actions"]
      refute "mix_test" in default["required_actions"]
      assert "mix_test" in security["required_actions"]
      refute "mix_compile" in security["required_actions"]

      for node <- ~w[
            inspect_workspace
            check_validation_passed
            check_validation_total_budget
            load_committed_change
            route_review
            check_review_total_budget
          ] do
        assert node in default["required_nodes"]
        assert node in security["required_nodes"]
      end
    end

    test "declares unsupported profiles with precise missing enforcement reasons" do
      expected_reason_terms = %{
        "security_regression" => ["fails against the base/pre-fix code", "candidate code"],
        "contract_change" => ["CONTRACT_RULES", "compatibility review"],
        "frontend_visual" => ["Playwright", "desktop/mobile visual evidence"],
        "docs_only" => [
          "documentation-validation action contract",
          "not an enforceable substitute"
        ],
        "cross_app" => ["xref", "dependency surface"],
        "database_migration" => ["mandatory human gate", "unattended publication"]
      }

      for id <- @unsupported_ids do
        assert {:ok, profile} = Profiles.fetch(id)
        refute profile["executable"]

        reason = profile["unsupported_reason"]
        assert is_binary(reason) and reason != ""

        for term <- Map.fetch!(expected_reason_terms, id) do
          assert reason =~ term
        end

        assert {:error, {:profile_not_executable, ^id, ^reason}} =
                 Profiles.fetch_executable(id)
      end
    end

    test "unknown and unsupported IDs never fall back to default" do
      assert {:error, {:unknown_profile, "not_a_profile"}} = Profiles.fetch("not_a_profile")

      assert {:error, {:unknown_profile, "not_a_profile"}} =
               Profiles.fetch_executable("not_a_profile")

      assert {:ok, docs_profile} = Profiles.fetch("docs_only")
      assert docs_profile["id"] == "docs_only"
      refute docs_profile["executable"]
      refute docs_profile["validation_strategy"] == %{"action" => "mix_compile"}
    end
  end

  describe "validate_requirements/2" do
    for profile_id <- @executable_ids do
      test "detects every missing mandatory node for #{profile_id}" do
        profile_id = unquote(profile_id)
        assert {:ok, profile} = Profiles.fetch_executable(profile_id)
        inventory = inventory_for(profile)

        assert :ok = Profiles.validate_requirements(profile_id, inventory)
        assert :ok = Profiles.validate_requirements(inventory, profile_id)

        for node_id <- profile["required_nodes"] do
          missing_inventory = %{inventory | nodes: List.delete(inventory.nodes, node_id)}

          assert {:error,
                  {:missing_requirements,
                   %{"missing_nodes" => [^node_id], "missing_actions" => []}}} =
                   Profiles.validate_requirements(profile, missing_inventory)
        end
      end

      test "detects every missing mandatory action for #{profile_id}" do
        profile_id = unquote(profile_id)
        assert {:ok, profile} = Profiles.fetch_executable(profile_id)
        inventory = inventory_for(profile)

        for action <- profile["required_actions"] do
          missing_inventory = %{inventory | actions: List.delete(inventory.actions, action)}

          assert {:error,
                  {:missing_requirements,
                   %{"missing_nodes" => [], "missing_actions" => [^action]}}} =
                   Profiles.validate_requirements(profile_id, missing_inventory)
        end
      end
    end

    test "extracts node IDs and action names from a compiled Graph" do
      assert {:ok, profile} = Profiles.fetch_executable("default")

      required_nodes =
        Map.new(profile["required_nodes"], fn id ->
          {id, %Node{id: id, attrs: %{}}}
        end)

      action_nodes =
        profile["required_actions"]
        |> Enum.with_index()
        |> Map.new(fn {action, index} ->
          id = "required_action_#{index}"
          {id, %Node{id: id, attrs: %{"action" => action}}}
        end)

      graph = %Graph{compiled: true, nodes: Map.merge(required_nodes, action_nodes)}

      assert :ok = Profiles.validate_requirements("default", graph)
      assert :ok = Profiles.validate_requirements(graph, "default")

      {mix_node_id, _node} =
        Enum.find(graph.nodes, fn {_id, node} -> node.attrs["action"] == "mix_compile" end)

      graph_without_compile = %{graph | nodes: Map.delete(graph.nodes, mix_node_id)}

      assert {:error,
              {:missing_requirements,
               %{"missing_nodes" => [], "missing_actions" => ["mix_compile"]}}} =
               Profiles.validate_requirements("default", graph_without_compile)
    end

    test "reports all missing requirements in sorted lists" do
      assert {:error,
              {:missing_requirements,
               %{
                 "missing_nodes" => missing_nodes,
                 "missing_actions" => missing_actions
               }}} = Profiles.validate_requirements("default", %{nodes: [], actions: []})

      assert missing_nodes == Enum.sort(missing_nodes)
      assert missing_actions == Enum.sort(missing_actions)
    end
  end

  defp inventory_for(profile) do
    %{
      nodes: profile["required_nodes"],
      actions: profile["required_actions"]
    }
  end
end
