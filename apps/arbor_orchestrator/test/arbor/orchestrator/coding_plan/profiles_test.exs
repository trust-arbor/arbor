defmodule Arbor.Orchestrator.CodingPlan.ProfilesTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.Profiles
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @moduletag :fast

  @known_ids Plan.profile_ids()

  @executable_ids ~w[cross_app default security_regression]
  @unsupported_ids @known_ids -- @executable_ids

  describe "declarations" do
    test "declares every documented profile deterministically as JSON-clean data" do
      profiles = Profiles.all()

      assert Profiles.known_ids() == @known_ids
      assert Enum.map(profiles, & &1["id"]) == @known_ids
      assert {:ok, _encoded} = Jason.encode(profiles)
      assert Profiles.template_version() == "coding-change-v1"

      for profile <- profiles do
        assert Map.keys(profile) |> Enum.all?(&is_binary/1)
        assert profile["template_version"] == Profiles.template_version()
        assert profile["semantic_policy"]["validation_profile"] == profile["id"]
        assert is_boolean(profile["executable"])
        assert is_map(profile["validation_strategy"])
        assert is_map(profile["review_strategy"])
        assert profile["required_nodes"] == Enum.sort(Enum.uniq(profile["required_nodes"]))
        assert profile["required_actions"] == Enum.sort(Enum.uniq(profile["required_actions"]))

        assert profile["required_nested_actions"] ==
                 Enum.sort(["consensus_decide_review", "git_commit"])
      end
    end

    test "contract and registry profile IDs cannot drift independently" do
      assert Profiles.known_ids() == Plan.profile_ids()
    end

    test "executable profiles own complete action-unique validation declarations" do
      strategies =
        for profile_id <- @executable_ids do
          assert {:ok, profile} = Profiles.fetch_executable(profile_id)
          profile["validation_strategy"]
        end

      actions = Enum.map(strategies, & &1["action"])
      assert actions == Enum.uniq(actions)

      for strategy <- strategies do
        assert is_binary(strategy["action"])
        assert is_binary(strategy["result_adapter"])
        assert is_list(strategy["context_keys"]) and strategy["context_keys"] != []
        assert Enum.all?(strategy["context_keys"], &is_binary/1)
        assert is_map(strategy["static_parameters"])
        refute is_struct(strategy["static_parameters"])
        assert strategy["timeout_budget_param"] in ["timeout", "stage_timeout"]
      end
    end

    test "executable profiles pin repair prompt executable attrs as a subset" do
      expected_attrs = %{
        "type" => "transform",
        "transform" => "template",
        "source_key" => "task",
        "output_key" => "prompt"
      }

      for profile_id <- @executable_ids do
        assert {:ok, profile} = Profiles.fetch_executable(profile_id)
        convergence = profile["semantic_policy"]["review_convergence"]

        assert [
                 %{
                   "node_id" => "build_design_envelope_repair_prompt",
                   "attrs" => ^expected_attrs
                 }
               ] = convergence["node_attr_subsets"]

        refute Enum.any?(
                 convergence["node_attrs"],
                 &(&1["node_id"] == "build_design_envelope_repair_prompt")
               )
      end
    end

    test "design counter partition is explicit in review convergence policies" do
      assert {:ok, default} = Profiles.fetch_executable("default")
      assert {:ok, security} = Profiles.fetch_executable("security_regression")

      for profile <- [default, security] do
        writers = profile["semantic_policy"]["review_convergence"]["protected_writers"]

        assert writers["design_rework_count"] == [
                 "inc_design_rework_count",
                 "init_design_rework_count"
               ]

        refute "inc_design_rework_count" in writers["total_rework_count"]
      end
    end

    test "requires the frozen-ledger reducer and git_commit in compiled execution manifests" do
      assert {:ok, profile} = Profiles.fetch_executable("default")

      manifest = %{
        "actions" => [%{"name" => "consensus_decide_review"}, %{"name" => "git_commit"}]
      }

      assert :ok = Profiles.validate_execution_manifest(profile, manifest)

      assert {:error, {:missing_nested_actions, ["consensus_decide_review", "git_commit"]}} =
               Profiles.validate_execution_manifest(profile, %{"actions" => []})

      assert {:error, {:missing_nested_actions, ["git_commit"]}} =
               Profiles.validate_execution_manifest(profile, %{
                 "actions" => [%{"name" => "consensus_decide_review"}]
               })

      assert {:error, :invalid_manifest} = Profiles.validate_execution_manifest(profile, %{})
    end

    test "exposes only reviewed enforceable validation strategies" do
      assert {:ok, default} = Profiles.fetch_executable("default")

      assert default["validation_strategy"] == %{
               "action" => "mix_compile",
               "context_keys" => ["path", "workspace_id"],
               "result_adapter" => "mix_compile_v1",
               "static_parameters" => %{"warnings_as_errors" => true},
               "timeout_budget_param" => "timeout",
               "timeout_budget_source" => "budgets.wall_clock_ms",
               "timeout_max_ms" => 1_200_000
             }

      assert default["review_strategy"] == %{
               "action" => "council_review_change",
               "binding" => true
             }

      policy = default["semantic_policy"]
      assert is_map(policy)
      assert "git_pr" in policy["allowed_actions"]
      assert "git_pr" in policy["optional_actions"]
      assert "mix_compile" in policy["allowed_actions"]
      refute "mix_test" in policy["allowed_actions"]
      assert "validate" in policy["mandatory_gate_nodes"]
      assert "review_change" == policy["review_gate"]
      assert "check_validation_passed" == policy["validation_result_gate"]
      assert "capture_validation_workspace" == policy["validation_observation_gate"]
      assert "route_review" == policy["review_routing_gate"]
      assert policy["allowed_handlers"] == Enum.sort(policy["allowed_handlers"])

      assert {:ok, security} = Profiles.fetch_executable("security_regression")
      assert security["executable"]

      security_stage_ceiling = Arbor.Actions.security_regression_maximum_stage_timeout_ms()

      assert security["validation_strategy"] == %{
               "action" => "coding_security_regression_validate",
               "authority_parameter" => "review_attestation_id",
               "authority_source" => "review.review_attestation_id",
               "context_keys" => ["review_attestation_id"],
               "result_adapter" => "security_regression_v1",
               "static_parameters" => %{},
               "timeout_budget_param" => "stage_timeout",
               "timeout_budget_source" => "budgets.wall_clock_ms",
               "timeout_max_ms" => 600_000,
               "stage_timeout_budget_source" => "budgets.wall_clock_ms",
               "stage_timeout_max_ms" => security_stage_ceiling,
               "two_revision" => true
             }

      assert security_stage_ceiling == 1_200_000
      assert security_stage_ceiling == 2 * Arbor.Shell.spawn_capable_max_timeout_ms()

      assert security["semantic_policy"]["validation_profile"] == "security_regression"

      assert security["semantic_policy"]["attestation_source"] ==
               "hoist_review_attestation_id"

      assert security["semantic_policy"]["post_validation_exact_head_check"] ==
               "post_validation_committed_change"

      assert "mix_compile" in default["required_actions"]
      assert "coding_design_envelope_parse" in default["required_actions"]
      assert "coding_design_artifact_capture" in default["required_actions"]
      assert "coding_design_artifact_load" in default["required_actions"]
      assert "coding_design_checkpoint_open" in default["required_actions"]
      assert "coding_design_checkpoint_await" in default["required_actions"]
      assert "coding_workspace_inspect" in default["required_actions"]
      assert "coding_workspace_committed_change" in default["required_actions"]
      refute "mix_test" in default["required_actions"]
      assert "coding_security_regression_validate" in security["required_actions"]
      refute "mix_test" in security["required_actions"]
      refute "mix_compile" in security["required_actions"]

      for node <- ~w[
            await_design_checkpoint
            build_design_envelope_repair_prompt
            capture_design_artifact
            check_design_envelope_retry_budget
            check_design_workspace_unchanged
            hoist_design_artifact
            inc_design_envelope_retry_count
            init_design_attempt
            init_design_envelope_retry_count
            load_design_artifact
            open_design_checkpoint
            parse_design_response
            reset_design_envelope_retry_count
            route_design_checkpoint_outcome
            route_worker_phase
          ] do
        assert node in default["required_nodes"]
        assert node in security["required_nodes"]
      end

      for profile <- [default, security],
          node <- ~w[
            error_design_checkpoint_await_failed
            error_design_checkpoint_open_failed
            error_design_checkpoint_outcome_invalid
            error_design_checkpoint_timeout
            error_design_modified_workspace
            error_design_response_invalid
            error_design_worker_phase_invalid
          ] do
        assert node in profile["required_nodes"]

        assert [node, "status_pipeline_error_then_close", nil] in profile["semantic_policy"][
                 "review_convergence"
               ]["edges"]
      end

      placements = default["semantic_policy"]["action_placements"]

      assert Enum.count(
               placements,
               &(&1["node_id"] == "open_design_checkpoint" and
                   &1["action"] == "coding_design_checkpoint_open")
             ) == 1

      assert Enum.count(
               placements,
               &(&1["node_id"] == "await_design_checkpoint" and
                   &1["action"] == "coding_design_checkpoint_await")
             ) == 1

      assert Enum.count(
               placements,
               &(&1["node_id"] == "parse_design_response" and
                   &1["action"] == "coding_design_envelope_parse")
             ) == 1

      assert {:ok, cross_app} = Profiles.fetch_executable("cross_app")
      assert cross_app["executable"]

      assert {:ok, intensive_ceiling} = Arbor.Shell.spawn_capable_max_timeout_ms(:intensive)
      standard_ceiling = Arbor.Shell.spawn_capable_max_timeout_ms()
      test_stage_ceiling = Arbor.Actions.cross_app_maximum_test_stage_timeout_ms()
      whole_stage_ceiling = Arbor.Actions.cross_app_maximum_stage_timeout_ms()
      assert intensive_ceiling == 1_200_000
      assert test_stage_ceiling == 4_200_000
      assert whole_stage_ceiling == 3 * intensive_ceiling + test_stage_ceiling

      assert cross_app["validation_strategy"] == %{
               "action" => "coding_cross_app_validate",
               "authority_parameter" => "workspace_id",
               "authority_source" => "workspace_id",
               "context_keys" => ["workspace_id"],
               "result_adapter" => "cross_app_v1",
               "static_parameters" => %{},
               "timeout_budget_param" => "stage_timeout",
               "timeout_budget_source" => "budgets.wall_clock_ms",
               "timeout_max_ms" => intensive_ceiling,
               "test_stage_timeout_budget_source" => "budgets.wall_clock_ms",
               "test_stage_timeout_max_ms" => test_stage_ceiling,
               "stage_timeout_budget_source" => "budgets.wall_clock_ms",
               "stage_timeout_max_ms" => whole_stage_ceiling,
               "selects_downstream_dependents" => true,
               "runs_xref_graph_evidence" => true,
               "runs_test_environment_compile" => true,
               "claims_zero_cycles" => false
             }

      assert cross_app["semantic_policy"]["validation_profile"] == "cross_app"
      assert "coding_cross_app_validate" in cross_app["required_actions"]
      refute "mix_compile" in cross_app["required_actions"]
      refute "mix_test" in cross_app["required_actions"]
      assert "coding_cross_app_validate" in cross_app["semantic_policy"]["allowed_actions"]

      # Per-op intensive ceiling vs aggregate stage max are independent; both min with wall-clock.
      assert {:ok, 900_000} = Profiles.validation_timeout(cross_app, 900_000)
      assert {:ok, 120_000} = Profiles.validation_timeout(cross_app, 120_000)
      assert {:ok, ^intensive_ceiling} = Profiles.validation_timeout(cross_app, 1_500_000)
      assert {:ok, ^intensive_ceiling} = Profiles.validation_timeout(cross_app, 2_500_000)
      assert {:ok, 900_000} = Profiles.validation_test_stage_timeout(cross_app, 900_000)
      assert {:ok, 1_500_000} = Profiles.validation_test_stage_timeout(cross_app, 1_500_000)
      assert {:ok, 2_500_000} = Profiles.validation_test_stage_timeout(cross_app, 2_500_000)

      assert {:ok, ^test_stage_ceiling} =
               Profiles.validation_test_stage_timeout(cross_app, 4_300_000)

      assert {:ok, 120_000} = Profiles.validation_test_stage_timeout(cross_app, 120_000)

      assert {:ok, 900_000} = Profiles.validation_stage_timeout(cross_app, 900_000)
      assert {:ok, 1_500_000} = Profiles.validation_stage_timeout(cross_app, 1_500_000)
      assert {:ok, 5_000_000} = Profiles.validation_stage_timeout(cross_app, 5_000_000)

      assert {:ok, ^whole_stage_ceiling} =
               Profiles.validation_stage_timeout(cross_app, whole_stage_ceiling + 100_000)

      assert {:ok, 120_000} = Profiles.validation_stage_timeout(cross_app, 120_000)

      # Profiles without aggregate-stage keys return nil (not an error).
      assert {:ok, nil} = Profiles.validation_test_stage_timeout(default, 900_000)
      assert {:ok, nil} = Profiles.validation_test_stage_timeout(security, 900_000)
      assert {:ok, nil} = Profiles.validation_stage_timeout(default, 900_000)

      # security_regression binds a whole-stage ceiling of two sequential children.
      assert {:ok, 600_000} = Profiles.validation_timeout(security, 900_000)
      assert {:ok, 600_000} = Profiles.validation_timeout(security, 1_500_000)
      assert {:ok, 900_000} = Profiles.validation_stage_timeout(security, 900_000)
      assert {:ok, 1_200_000} = Profiles.validation_stage_timeout(security, 1_500_000)
      assert {:ok, 120_000} = Profiles.validation_stage_timeout(security, 120_000)

      # Partial/malformed aggregate declarations fail closed — never coerced to nil.
      missing_source =
        update_in(
          cross_app,
          ["validation_strategy"],
          &Map.delete(&1, "test_stage_timeout_budget_source")
        )

      assert {:error, :invalid_validation_test_stage_timeout_policy} =
               Profiles.validation_test_stage_timeout(missing_source, 900_000)

      missing_max =
        update_in(
          cross_app,
          ["validation_strategy"],
          &Map.delete(&1, "test_stage_timeout_max_ms")
        )

      assert {:error, :invalid_validation_test_stage_timeout_policy} =
               Profiles.validation_test_stage_timeout(missing_max, 900_000)

      bad_stage_source =
        put_in(
          cross_app,
          ["validation_strategy", "test_stage_timeout_budget_source"],
          "unreviewed.budget"
        )

      assert {:error, :invalid_validation_test_stage_timeout_policy} =
               Profiles.validation_test_stage_timeout(bad_stage_source, 900_000)

      missing_whole_source =
        update_in(
          cross_app,
          ["validation_strategy"],
          &Map.delete(&1, "stage_timeout_budget_source")
        )

      assert {:error, :invalid_validation_stage_timeout_policy} =
               Profiles.validation_stage_timeout(missing_whole_source, 900_000)

      missing_whole_max =
        update_in(
          cross_app,
          ["validation_strategy"],
          &Map.delete(&1, "stage_timeout_max_ms")
        )

      assert {:error, :invalid_validation_stage_timeout_policy} =
               Profiles.validation_stage_timeout(missing_whole_max, 900_000)

      bad_whole_source =
        put_in(
          cross_app,
          ["validation_strategy", "stage_timeout_budget_source"],
          "unreviewed.budget"
        )

      assert {:error, :invalid_validation_stage_timeout_policy} =
               Profiles.validation_stage_timeout(bad_whole_source, 900_000)

      bad_whole_max =
        put_in(cross_app, ["validation_strategy", "stage_timeout_max_ms"], "7_800_000")

      assert {:error, :invalid_validation_stage_timeout_policy} =
               Profiles.validation_stage_timeout(bad_whole_max, 900_000)

      # Per-op from intensive Shell; aggregate/whole stage from Actions facade.
      assert cross_app["validation_strategy"]["timeout_max_ms"] == intensive_ceiling

      assert cross_app["validation_strategy"]["test_stage_timeout_max_ms"] ==
               Profiles.cross_app_test_stage_timeout_max_ms()

      assert Profiles.cross_app_test_stage_timeout_max_ms() == test_stage_ceiling
      assert Profiles.cross_app_stage_timeout_max_ms() == whole_stage_ceiling

      assert cross_app["validation_strategy"]["stage_timeout_max_ms"] ==
               Profiles.cross_app_stage_timeout_max_ms()

      assert cross_app["validation_strategy"]["test_stage_timeout_max_ms"] >
               cross_app["validation_strategy"]["timeout_max_ms"]

      assert cross_app["validation_strategy"]["timeout_max_ms"] > standard_ceiling

      # Default compile and CrossApp use intensive containment; security keeps standard.
      assert default["validation_strategy"]["timeout_max_ms"] == intensive_ceiling
      assert security["validation_strategy"]["timeout_max_ms"] == standard_ceiling

      drifted_source =
        put_in(
          cross_app,
          ["validation_strategy", "timeout_budget_source"],
          "unreviewed.budget"
        )

      assert {:error, :invalid_validation_timeout_policy} =
               Profiles.validation_timeout(drifted_source, 900_000)

      for node <- ~w[
            capture_validation_workspace
            hoist_validation_candidate_tree_oid
            hoist_validation_observed_at
            inspect_workspace
            check_validation_passed
            check_validation_total_budget
            load_committed_change
            route_review
            check_review_total_budget
            route_release_mode
            route_success_workspace_retention
            release_workspace_only
          ] do
        assert node in default["required_nodes"]
        assert node in security["required_nodes"]
        assert node in cross_app["required_nodes"]
      end
    end

    test "declares unsupported profiles with precise missing enforcement reasons" do
      expected_reason_terms = %{
        "contract_change" => ["CONTRACT_RULES", "compatibility review"],
        "frontend_visual" => ["Playwright", "desktop/mobile visual evidence"],
        "docs_only" => [
          "documentation-validation action contract",
          "not an enforceable substitute"
        ],
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
