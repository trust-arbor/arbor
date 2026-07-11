defmodule Arbor.Orchestrator.CodingPlan.SemanticPreflightTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, Compiler, Profiles, SemanticPreflight}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

  @moduletag :fast

  @action_modules [
    Arbor.Actions.Acp.StartSession,
    Arbor.Actions.Acp.SendMessage,
    Arbor.Actions.Acp.CloseSession,
    Arbor.Actions.Coding.Workspace.Acquire,
    Arbor.Actions.Coding.Workspace.Inspect,
    Arbor.Actions.Coding.Workspace.Release,
    Arbor.Actions.Coding.Workspace.CommittedChange,
    Arbor.Actions.Coding.SecurityRegression.Validate,
    Arbor.Actions.Mix.Compile,
    Arbor.Actions.Mix.Test,
    Arbor.Actions.Coding.ReviewedCommit,
    Arbor.Actions.Git.Commit,
    Arbor.Actions.Git.PR,
    Arbor.Actions.Coding.ReviewTree.Read,
    Arbor.Actions.Coding.ReviewTree.Search,
    Arbor.Actions.Council.ReviewChange,
    Arbor.Actions.Consensus.Decide
  ]

  setup_all do
    template_path =
      Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot")

    {:ok, catalog} = ActionCatalog.snapshot(modules: @action_modules)

    %{template_source: File.read!(template_path), action_catalog: catalog}
  end

  test "default binding compilation passes semantic preflight deterministically", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    assert {:ok, second} = compile(plan!(), ctx)
    assert compilation.graph_hash == second.graph_hash

    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    # Structural: skip-review edge removed so review dominates publication.
    refute has_edge?(
             parse!(compilation.dot_source),
             "route_after_commit",
             "route_publish",
             "context.submit_review=false"
           )
  end

  test "legacy review_profile=none keeps skip-review topology and passes without review dominance",
       ctx do
    plan = plan!(%{"review_profile" => "none"})
    assert {:ok, compilation} = compile(plan, ctx)
    graph = parse!(compilation.dot_source)

    assert has_edge?(
             graph,
             "route_after_commit",
             "route_publish",
             "context.submit_review=false"
           )

    assert compilation.initial_values["submit_review"] == "false"

    compiled = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    assert :ok =
             SemanticPreflight.validate(compiled, profile["semantic_policy"],
               review_profile: "none"
             )

    # Under binding rules the same topology fails review dominance.
    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(compiled, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "dominance_violation" and err["detail"]["kind"] == "review"
           end)
  end

  test "security profile proves exact bindings and rejects review_profile none", ctx do
    plan = security_plan!()
    assert {:ok, compilation} = compile(plan, ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(graph, profile["semantic_policy"], review_profile: "none")

    assert Enum.any?(errors, &(&1["code"] == "security_review_profile_forbidden"))
  end

  test "security profile rejects action, context, source, and writer mutations", ctx do
    assert {:ok, compilation} = compile(security_plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    mutations = [
      update_in(graph.nodes["validate"].attrs, &Map.put(&1, "action", "mix_test")),
      update_in(
        graph.nodes["validate"].attrs,
        &Map.put(&1, "context_keys", "review_attestation_id,workspace_id")
      ),
      update_in(
        graph.nodes["validate"].attrs,
        &Map.put(&1, "param.test_paths", ["test/forged_test.exs"])
      ),
      update_in(
        graph.nodes["hoist_review_attestation_id"].attrs,
        &Map.put(&1, "source_key", "forged.review_attestation_id")
      ),
      update_in(
        graph.nodes["prep_review_intent"].attrs,
        &Map.put(&1, "output_key", "review_attestation_id")
      ),
      update_in(
        graph.nodes["review_change"].attrs,
        &Map.put(
          &1,
          "context_keys",
          "diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash"
        )
      )
    ]

    for mutated <- mutations do
      assert {:error, {:semantic_preflight_failed, errors}} =
               SemanticPreflight.validate(mutated, profile["semantic_policy"],
                 review_profile: "binding"
               )

      assert Enum.any?(errors, fn err ->
               err["code"] in [
                 "forbidden_action",
                 "security_binding_mismatch",
                 "security_protected_writer_violation",
                 "security_validator_parameter_violation"
               ]
             end)
    end
  end

  test "security profile rejects every commit-review-validation dominator bypass", ctx do
    assert {:ok, compilation} = compile(security_plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    bypasses = [
      {"committed_candidate_join", "hoist_commit_hash", "route_after_commit"},
      {"committed_join", "route_security_after_commit", "load_committed_change"},
      {"committed_material", "route_after_commit", "review_change"},
      {"review", "load_committed_change", "route_review"},
      {"review_routing", "review_change", "hoist_review_attestation_id"},
      {"review_attestation", "route_review", "validate"},
      {"validation", "hoist_review_attestation_id", "check_validation_passed"},
      {"validation_result", "validate", "post_validation_committed_change"},
      {"post_validation_exact_head", "check_validation_passed", "route_validated_review"},
      {"review", "load_committed_change", "status_change_committed"},
      {"validation", "hoist_review_attestation_id", "status_change_committed"},
      {"post_validation_exact_head", "check_validation_passed", "status_change_committed"},
      {"post_validation_routing", "post_validation_committed_change", "status_change_committed"}
    ]

    for {kind, from, to} <- bypasses do
      bypassed = add_edge(graph, from, to, "context.bypass=true")

      assert {:error, {:semantic_preflight_failed, errors}} =
               SemanticPreflight.validate(bypassed, profile["semantic_policy"],
                 review_profile: "binding"
               )

      assert Enum.any?(errors, fn err ->
               err["code"] == "dominance_violation" and err["detail"]["kind"] == kind
             end),
             "expected #{kind} dominance failure for #{from} -> #{to}, got: #{inspect(errors)}"
    end
  end

  test "security profile proves both rework entries cross the fresh-commit comparison", ctx do
    assert {:ok, compilation} = compile(security_plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    for {entry, kind} <- [
          {"remember_validation_reviewed_commit", "validation_rework.fresh_commit_compare"},
          {"remember_review_reviewed_commit", "review_rework.fresh_commit_compare"}
        ] do
      bypassed = add_edge(graph, entry, "check_security_rework_fresh", "context.bypass=true")

      assert {:error, {:semantic_preflight_failed, errors}} =
               SemanticPreflight.validate(bypassed, profile["semantic_policy"],
                 review_profile: "binding"
               )

      assert Enum.any?(errors, fn err ->
               err["code"] == "dominance_violation" and err["detail"]["kind"] == kind
             end)
    end
  end

  test "security profile rejects rework-only validation and publication bypasses", ctx do
    assert {:ok, compilation} = compile(security_plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    bypasses = [
      {"build_validation_rework_prompt", "validate", "validation_rework.fresh_validation"},
      {"build_review_rework_prompt", "status_change_committed",
       "review_rework.fresh_post_validation_routing_terminal"}
    ]

    for {from, to, kind} <- bypasses do
      bypassed = add_edge(graph, from, to, "context.rework_bypass=true")

      assert {:error, {:semantic_preflight_failed, errors}} =
               SemanticPreflight.validate(bypassed, profile["semantic_policy"],
                 review_profile: "binding"
               )

      assert Enum.any?(errors, fn err ->
               err["code"] == "dominance_violation" and err["detail"]["kind"] == kind
             end),
             "expected #{kind} dominance failure for #{from} -> #{to}, got: #{inspect(errors)}"
    end
  end

  test "security human handoff remains dominated by review routing; unattended still needs validation",
       ctx do
    plan = security_plan!(%{"review_profile" => "human_required"})
    assert {:ok, compilation} = compile(plan, ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "human_required"
             )

    # Human handoff may be unattested, so review must still dominate it.
    bypassed =
      add_edge(
        graph,
        "load_committed_change",
        "status_human_review_required",
        "context.bypass=true"
      )

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(bypassed, profile["semantic_policy"],
               review_profile: "human_required"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "dominance_violation" and err["detail"]["kind"] == "review"
           end)
  end

  test "security regression: unknown publication terminal defaults to unattended dominance",
       ctx do
    assert {:ok, compilation} = compile(security_plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    policy =
      Map.update!(profile["semantic_policy"], "publication_nodes", fn nodes ->
        Enum.sort(["status_review_rejected" | nodes])
      end)

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(graph, policy, review_profile: "binding")

    assert Enum.any?(errors, fn error ->
             error["code"] == "dominance_violation" and
               error["node_id"] == "status_review_rejected" and
               error["detail"]["kind"] in ["review_attestation", "validation"]
           end)
  end

  test "security profile requires present attestation on validator entries and absent human route",
       ctx do
    assert {:ok, compilation} = compile(security_plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    present = ~s(context.review.review_attestation_id!="")
    absent = ~s(context.review.review_attestation_id="")

    assert edge_target(graph, "route_review", "context.review.tier_decision=human_review") ==
             "route_security_attested_human"

    assert edge_target(graph, "route_review", "context.review.tier_decision=auto_proceed") ==
             "route_security_attested_auto"

    assert edge_target(graph, "route_security_attested_human", present) ==
             "hoist_review_attestation_id"

    assert edge_target(graph, "route_security_attested_human", absent) ==
             "status_human_review_required"

    assert edge_target(graph, "route_security_attested_auto", present) ==
             "hoist_review_attestation_id"

    # Bypass the attestation presence gate: any human_review may hoist/validate.
    unguarded =
      add_edge(
        graph,
        "route_security_attested_human",
        "hoist_review_attestation_id",
        "context.bypass_attestation=true"
      )

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(unguarded, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, &(&1["code"] == "security_topology_mismatch"))
  end

  test "adversarial: validation bypass fails closed", ctx do
    # Keep the legitimate validate path reachable, but add a parallel changed
    # path that reaches commit routing without validation. Dominators must fail.
    bypassed =
      String.replace(
        ctx.template_source,
        ~s(hoist_head_commit -> prep_validation_path [condition="context.changed_from_base=true"]),
        ~s(hoist_head_commit -> prep_validation_path [condition="context.changed_from_base=true"]\n  hoist_head_commit -> prep_commit_path [condition="context.bypass_validation=true"])
      )

    assert {:error, {:semantic_preflight_failed, errors}} = compile(plan!(), ctx, bypassed)

    assert Enum.any?(errors, fn err ->
             err["code"] == "dominance_violation" and
               err["detail"]["kind"] == "validation" and
               err["detail"]["required_dominator"] == "validate"
           end)
  end

  test "adversarial: review bypass fails closed for binding plans", ctx do
    # Re-introduce a free path from post-commit routing to publication.
    bypassed =
      String.replace(
        ctx.template_source,
        ~s(route_after_commit -> prep_expected_commit [condition="context.submit_review!=false"]),
        ~s(route_after_commit -> route_publish [condition="context.force_publish=true"]\n  route_after_commit -> prep_expected_commit [condition="context.submit_review!=false"])
      )

    assert {:error, {:semantic_preflight_failed, errors}} = compile(plan!(), ctx, bypassed)

    assert Enum.any?(errors, fn err ->
             err["code"] == "dominance_violation" and err["detail"]["kind"] == "review"
           end)
  end

  test "adversarial: injected known but non-allowlisted action fails closed", ctx do
    # mix_test is registered in the live catalog, but default reviewed policy only
    # allowlists required actions + optional git_pr. Mutate a post-compile graph
    # so catalog schema checks cannot mask the policy rejection.
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)

    injected =
      update_in(graph.nodes["inspect_workspace"].attrs, fn attrs ->
        attrs
        |> Map.put("action", "mix_test")
        |> Map.put("context_keys", "path")
        |> Map.delete("param.all")
      end)

    assert {:ok, profile} = Profiles.fetch_executable("default")
    refute "mix_test" in profile["semantic_policy"]["allowed_actions"]

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(injected, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "forbidden_action" and err["node_id"] == "inspect_workspace" and
               err["detail"]["action"] == "mix_test"
           end)
  end

  test "adversarial: commit gate must be coding_reviewed_commit; denial bypass attrs rejected",
       ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    assert graph.nodes["commit_change"].attrs["action"] == "coding_reviewed_commit"
    refute Map.has_key?(graph.nodes["commit_change"].attrs, "project_interaction_control")
    assert graph.nodes["status_approval_denied"]
    assert graph.nodes["check_operator_rework_category_budget"]
    assert graph.nodes["check_operator_rework_total_budget"]

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    forged =
      update_in(graph.nodes["validate"].attrs, fn attrs ->
        Map.put(attrs, "project_interaction_control", "true")
      end)

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(forged, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "forbidden_denial_bypass_attribute" and
               err["node_id"] == "validate"
           end)

    wrong_action =
      update_in(graph.nodes["commit_change"].attrs, &Map.put(&1, "action", "git_commit"))

    assert {:error, {:semantic_preflight_failed, action_errors}} =
             SemanticPreflight.validate(wrong_action, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(action_errors, fn err ->
             err["code"] == "invalid_commit_approval_action" and
               err["node_id"] == "commit_change"
           end)

    bypass_edge =
      %Arbor.Orchestrator.Graph.Edge{
        from: "commit_change",
        to: "hoist_commit_hash",
        attrs: %{},
        condition: nil
      }

    bypass = %{
      graph
      | edges: graph.edges ++ [bypass_edge],
        # Force edge-list scan so the injected bypass is visible.
        adjacency: %{},
        reverse_adjacency: %{}
    }

    assert {:error, {:semantic_preflight_failed, bypass_errors}} =
             SemanticPreflight.validate(bypass, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(bypass_errors, fn err ->
             err["code"] == "commit_approval_bypass_edge"
           end)
  end

  test "security regression: canonical approval deny and rework graph passes public compiler",
       ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )
  end

  test "security regression: direct approval deny to terminal bypass fails closed", ctx do
    bypassed =
      inject_edge(
        ctx.template_source,
        "status_approval_denied -> close_worker",
        "status_approval_denied -> done [condition=\"context.bypass_cleanup=true\"]"
      )

    assert_semantic_error(
      compile(plan!(), ctx, bypassed),
      "all_path_violation",
      "approval_denied_cleanup"
    )
  end

  test "security regression: one good and one bad approval deny branch fails closed", ctx do
    bypassed =
      inject_edge(
        ctx.template_source,
        "status_approval_denied -> close_worker",
        "status_approval_denied -> prep_release_mode [condition=\"context.bypass_close=true\"]"
      )

    assert_semantic_error(
      compile(plan!(), ctx, bypassed),
      "all_path_violation",
      "approval_denied_cleanup"
    )
  end

  test "security regression: approval deny cycle escape fails closed", ctx do
    bypassed =
      inject_edge(
        ctx.template_source,
        "status_approval_denied -> close_worker",
        "status_approval_denied -> status_approval_denied [condition=\"context.cycle=true\"]"
      )

    assert_semantic_error(
      compile(plan!(), ctx, bypassed),
      "all_path_violation",
      "approval_denied_cleanup"
    )
  end

  test "security regression: operator rework cannot bypass category and total counters", ctx do
    bypassed =
      inject_edge(
        ctx.template_source,
        "hoist_approval_note_rework -> check_operator_rework_category_budget",
        "hoist_approval_note_rework -> inc_operator_total_rework_count [condition=\"context.bypass_operator_budget=true\"]"
      )

    assert_semantic_error(
      compile(plan!(), ctx, bypassed),
      "dominance_violation",
      "operator_rework_category_budget"
    )
  end

  test "security regression: operator rework requires a fresh commit approval gate", ctx do
    bypassed =
      inject_edge(
        ctx.template_source,
        "build_operator_rework_prompt -> reset_worker_turn_protocol_retry_count",
        "build_operator_rework_prompt -> hoist_commit_hash [condition=\"context.bypass_fresh_gate=true\"]"
      )

    assert_semantic_error(
      compile(plan!(), ctx, bypassed),
      "dominance_violation",
      "fresh_reviewed_commit_gate"
    )
  end

  test "security regression: operator rework cannot terminate at an unrelated status after counters",
       ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    bypassed =
      add_edge(
        graph,
        "inc_operator_total_rework_count",
        "status_no_changes",
        "context.bypass_fresh_gate=true"
      )

    assert_preflight_error(
      bypassed,
      profile,
      "all_path_violation",
      "operator_rework_resolution"
    )
  end

  test "security regression: fresh operator turn cannot bypass its causal status gate", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    bypassed = add_edge(graph, "implement", "status_no_changes", "context.hidden_abort=true")

    assert_preflight_error(
      bypassed,
      profile,
      "rework_status_bypass",
      "operator_rework_status_origin"
    )
  end

  test "security regression: operator rework rejects a post-budget dead end", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    dead_end = "operator_rework_dead_end"
    dead_end_graph = add_cloned_node(graph, "mark_operator_rework_kind", dead_end)

    dead_end_graph =
      add_edge(
        dead_end_graph,
        "inc_operator_total_rework_count",
        dead_end,
        "context.dead_end=true"
      )

    assert_preflight_path_violation(dead_end_graph, profile, "dead_end")
  end

  test "security regression: operator rework rejects a post-budget closed cycle", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    cycle = "operator_rework_closed_cycle"
    cycle_graph = add_cloned_node(graph, "mark_operator_rework_kind", cycle)
    cycle_graph = add_edge(cycle_graph, cycle, cycle, "context.keep_cycling=true")

    cycle_graph =
      add_edge(
        cycle_graph,
        "inc_operator_total_rework_count",
        cycle,
        "context.enter_cycle=true"
      )

    assert_preflight_path_violation(cycle_graph, profile, "cycle")
  end

  test "security regression: stale adjacency cannot hide an operator rework bypass edge", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    edge = edge("inc_operator_total_rework_count", "status_no_changes", "context.hidden=true")
    stale = %{graph | edges: [edge | graph.edges]}

    assert_preflight_error(
      stale,
      profile,
      "all_path_violation",
      "operator_rework_resolution"
    )
  end

  test "security regression: graph analysis rejects node exhaustion inputs", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    oversized_nodes =
      Enum.reduce(map_size(graph.nodes)..256, graph, fn index, acc ->
        add_cloned_node(acc, "mark_operator_rework_kind", "limit_node_#{index}")
      end)

    assert_graph_limit(oversized_nodes, profile, "nodes")
  end

  test "security regression: graph analysis rejects edge exhaustion inputs", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    duplicate = List.first(graph.edges)
    additions = List.duplicate(duplicate, 513 - length(graph.edges))
    oversized_edges = %{graph | edges: additions ++ graph.edges}

    assert_graph_limit(oversized_edges, profile, "edges")
  end

  test "security regression: serialized graph attributes are bounded", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    oversized_attrs =
      update_in(graph.attrs, &Map.put(&1, "oversized", String.duplicate("x", 131_073)))

    assert_graph_limit(oversized_attrs, profile, "attribute_container")
  end

  test "security regression: compiler rejects an oversized graph source before parsing", ctx do
    oversized_source = ctx.template_source <> "\n// " <> String.duplicate("x", 262_145)

    assert {:error, {:graph_source_too_large, actual, 262_144}} =
             compile(plan!(), ctx, oversized_source)

    assert actual > 262_144
  end

  test "security regression: malformed approval edge fails closed in public preflight", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    malformed =
      add_edge(
        graph,
        "status_approval_denied",
        "missing_cleanup_node",
        "context.malformed=true"
      )

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(malformed, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, &(&1["code"] == "malformed_graph_edge"))
  end

  test "adversarial: authority override attribute fails closed", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)

    overridden =
      update_in(graph.nodes["review_change"].attrs, &Map.put(&1, "agent_id", "agent_forged"))

    assert {:ok, profile} = Profiles.fetch_executable("default")

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(overridden, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "forbidden_authority_attribute" and
               err["node_id"] == "review_change" and
               err["detail"]["attribute"] == "agent_id"
           end)

    # Also rejected when present in the trusted template before compile finishes.
    template_override =
      String.replace(
        ctx.template_source,
        ~s(action="council_review_change",\n    context_keys="diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash",),
        ~s(action="council_review_change",\n    agent_id="agent_forged",\n    context_keys="diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash",),
        global: false
      )

    assert {:error, {:semantic_preflight_failed, errors2}} =
             compile(plan!(), ctx, template_override)

    assert Enum.any?(errors2, fn err ->
             err["code"] == "forbidden_authority_attribute"
           end)
  end

  test "adversarial: param.graph and separator/case authority aliases fail closed", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    forged =
      update_in(graph.nodes["commit_change"].attrs, &Map.put(&1, "param.graph", "evil.dot"))

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(forged, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "forbidden_authority_attribute" and
               err["node_id"] == "commit_change" and
               err["detail"]["attribute"] == "param.graph"
           end)

    aliases = [
      {"param.agent_id", "agent_forged"},
      {"arg.principal_id", "principal_forged"},
      {"Param.Authorization", "forged"},
      {"ARG.Capabilities", "forged"},
      {"param.pipeline_path", "/evil/pipeline.dot"},
      {"param-pipeline_path", "/evil/pipeline.dot"}
    ]

    for {attr, value} <- aliases do
      aliased =
        update_in(graph.nodes["inspect_workspace"].attrs, &Map.put(&1, attr, value))

      assert {:error, {:semantic_preflight_failed, alias_errors}} =
               SemanticPreflight.validate(aliased, profile["semantic_policy"],
                 review_profile: "binding"
               )

      assert Enum.any?(alias_errors, fn err ->
               err["code"] == "forbidden_authority_attribute" and
                 err["detail"]["attribute"] == attr
             end),
             "expected #{attr} to fail closed"
    end
  end

  test "adversarial: output_key session.agent_id overwrites authority and fails closed", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    overridden =
      update_in(
        graph.nodes["inspect_workspace"].attrs,
        &Map.put(&1, "output_key", "session.agent_id")
      )

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(overridden, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn err ->
             err["code"] == "forbidden_authority_output" and
               err["node_id"] == "inspect_workspace" and
               err["detail"]["output_key"] == "session.agent_id"
           end)
  end

  test "adversarial: bypass of check_validation_passed fails closed", ctx do
    # Keep validate reachable, but route success straight to commit prep so the
    # validation-result gate no longer dominates commit/publication routing.
    bypassed =
      String.replace(
        ctx.template_source,
        ~s(validate -> check_validation_passed [condition="outcome=success"]),
        ~s(validate -> check_validation_passed [condition="outcome=success"]\n  validate -> prep_commit_path [condition="context.bypass_validation_result=true"])
      )

    assert {:error, {:semantic_preflight_failed, errors}} = compile(plan!(), ctx, bypassed)

    assert Enum.any?(errors, fn err ->
             err["code"] == "dominance_violation" and
               err["detail"]["kind"] == "validation_result" and
               err["detail"]["required_dominator"] == "check_validation_passed"
           end)
  end

  test "adversarial: review_change edge that bypasses route_review fails closed", ctx do
    # review_change still dominates publications if it reaches them directly, but
    # route_review must dominate every publication terminal under binding review.
    bypassed =
      String.replace(
        ctx.template_source,
        ~s(review_change -> route_review [condition="outcome=success"]),
        ~s(review_change -> route_review [condition="outcome=success"]\n  review_change -> route_publish [condition="context.bypass_review_routing=true"])
      )

    assert {:error, {:semantic_preflight_failed, errors}} = compile(plan!(), ctx, bypassed)

    assert Enum.any?(errors, fn err ->
             err["code"] == "dominance_violation" and
               err["detail"]["kind"] == "review_routing" and
               err["detail"]["required_dominator"] == "route_review"
           end)
  end

  test "adversarial: forbidden handler and exec target fail closed", ctx do
    assert {:ok, compilation} = compile(plan!(), ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    forbidden_handler =
      update_in(graph.nodes["status_declined"].attrs, &Map.put(&1, "type", "compute"))

    # Recompile IR so handler_types/registry match the mutated attrs.
    {:ok, handler_graph} =
      IRCompiler.compile(%{forbidden_handler | compiled: false, handler_types: %{}})

    assert {:error, {:semantic_preflight_failed, handler_errors}} =
             SemanticPreflight.validate(handler_graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(handler_errors, fn err ->
             err["code"] == "forbidden_handler" and err["detail"]["handler"] == "compute"
           end)

    forbidden_target =
      update_in(graph.nodes["commit_change"].attrs, fn attrs ->
        attrs
        |> Map.put("target", "shell")
        |> Map.delete("action")
      end)

    {:ok, target_graph} =
      IRCompiler.compile(%{forbidden_target | compiled: false, handler_types: %{}})

    assert {:error, {:semantic_preflight_failed, target_errors}} =
             SemanticPreflight.validate(target_graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(target_errors, fn err ->
             err["code"] == "forbidden_exec_target" and err["node_id"] == "commit_change" and
               err["detail"]["target"] == "shell"
           end)
  end

  test "adversarial: malformed semantic policy fails closed" do
    assert {:ok, profile} = Profiles.fetch_executable("default")
    graph = minimal_compiled_graph()

    assert {:error, {:invalid_semantic_policy, {:missing_keys, keys}}} =
             SemanticPreflight.validate(graph, %{}, review_profile: "binding")

    assert "allowed_actions" in keys
    assert keys == Enum.sort(keys)

    bad = Map.put(profile["semantic_policy"], "allowed_actions", ["z", "a"])

    assert {:error, {:invalid_semantic_policy, {:unsorted_list, "allowed_actions"}}} =
             SemanticPreflight.validate(graph, bad, review_profile: "binding")

    bad_optional =
      profile["semantic_policy"]
      |> Map.put("optional_actions", ["not_allowed"])
      |> Map.put("allowed_actions", profile["semantic_policy"]["allowed_actions"])

    assert {:error, {:invalid_semantic_policy, {:optional_actions_not_allowed, ["not_allowed"]}}} =
             SemanticPreflight.validate(graph, bad_optional, review_profile: "binding")
  end

  test "dominators handle cycles without false positives", ctx do
    # The coding template has rework cycles back to implement. Default graph
    # still has validate dominate route_after_commit and review dominate
    # publication after the skip edge is removed.
    assert {:ok, compilation} = compile(plan!(), ctx)
    compiled = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("default")

    assert :ok =
             SemanticPreflight.validate(compiled, profile["semantic_policy"],
               review_profile: "binding"
             )

    # Adding a cycle that does not create a bypass must still pass.
    with_extra_cycle =
      compilation.dot_source
      |> parse!()
      |> add_edge("implement", "implement", "context.noop=true")

    {:ok, cycled} = IRCompiler.compile(with_extra_cycle)

    assert :ok =
             SemanticPreflight.validate(cycled, profile["semantic_policy"],
               review_profile: "binding"
             )
  end

  defp compile(plan, ctx, template_source \\ nil) do
    Compiler.compile(plan,
      template_source: template_source || ctx.template_source,
      action_catalog: ctx.action_catalog
    )
  end

  defp plan!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "task" => "Implement a focused reviewed change",
          "repo_root" => "/tmp/arbor-coding-plan",
          "worker" => %{"provider" => "grok"}
        },
        overrides
      )

    {:ok, plan} = Plan.new(attrs)
    plan
  end

  defp security_plan!(overrides \\ %{}) do
    plan!(
      Map.merge(
        %{
          "validation_profile" => "security_regression",
          "requested_paths" => ["apps/arbor_security/test/security_regression_test.exs"]
        },
        overrides
      )
    )
  end

  defp parse!(source) do
    {:ok, graph} = Parser.parse(source)
    graph
  end

  defp compiled_graph!(source) do
    graph = parse!(source)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
  end

  defp has_edge?(graph, from, to, condition) do
    Enum.any?(graph.edges, fn edge ->
      edge.from == from and edge.to == to and Map.get(edge.attrs, "condition") == condition
    end)
  end

  defp add_edge(graph, from, to, condition) do
    edge = edge(from, to, condition)

    %{graph | edges: [edge | graph.edges], adjacency: %{}, reverse_adjacency: %{}}
  end

  defp edge(from, to, condition) do
    %Arbor.Orchestrator.Graph.Edge{
      from: from,
      to: to,
      attrs: %{"condition" => condition}
    }
  end

  defp add_cloned_node(graph, source_id, node_id) do
    source = Map.fetch!(graph.nodes, source_id)
    node = %{source | id: node_id, label: node_id}
    %{graph | nodes: Map.put(graph.nodes, node_id, node)}
  end

  defp inject_edge(source, existing_edge, injected_edge) do
    replacement = existing_edge <> "\n  " <> injected_edge
    mutated = String.replace(source, existing_edge, replacement, global: false)
    refute mutated == source
    mutated
  end

  defp assert_semantic_error(result, code, kind) do
    assert {:error, {:semantic_preflight_failed, errors}} = result

    assert Enum.any?(errors, fn error ->
             error["code"] == code and error["detail"]["kind"] == kind
           end),
           "expected #{code}/#{kind}, got: #{inspect(errors)}"
  end

  defp assert_preflight_error(graph, profile, code, kind) do
    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn error ->
             error["code"] == code and error["detail"]["kind"] == kind
           end),
           "expected #{code}/#{kind}, got: #{inspect(errors)}"
  end

  defp assert_preflight_path_violation(graph, profile, violation_type) do
    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn error ->
             error["code"] == "all_path_violation" and
               error["detail"]["kind"] == "operator_rework_resolution" and
               error["detail"]["violation"]["type"] == violation_type
           end),
           "expected #{violation_type} path violation, got: #{inspect(errors)}"
  end

  defp assert_graph_limit(graph, profile, resource) do
    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "binding"
             )

    assert Enum.any?(errors, fn error ->
             error["code"] == "graph_limit_exceeded" and
               error["detail"]["resource"] == resource
           end),
           "expected #{resource} graph limit, got: #{inspect(errors)}"
  end

  defp edge_target(graph, from, condition) do
    graph.edges
    |> Enum.find(&(&1.from == from and &1.attrs["condition"] == condition))
    |> Map.fetch!(:to)
  end

  defp minimal_compiled_graph do
    source = """
    digraph Minimal {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """

    compiled_graph!(source)
  end
end
