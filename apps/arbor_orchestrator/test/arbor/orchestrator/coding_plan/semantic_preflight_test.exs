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
      {"committed_candidate_join", "adopt_head_commit", "route_after_commit"},
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

  test "security human handoff remains dominated by review, validation, and exact-head check",
       ctx do
    plan = security_plan!(%{"review_profile" => "human_required"})
    assert {:ok, compilation} = compile(plan, ctx)
    graph = compiled_graph!(compilation.dot_source)
    assert {:ok, profile} = Profiles.fetch_executable("security_regression")

    assert :ok =
             SemanticPreflight.validate(graph, profile["semantic_policy"],
               review_profile: "human_required"
             )

    bypassed =
      add_edge(
        graph,
        "check_validation_passed",
        "status_human_review_required",
        "context.bypass=true"
      )

    assert {:error, {:semantic_preflight_failed, errors}} =
             SemanticPreflight.validate(bypassed, profile["semantic_policy"],
               review_profile: "human_required"
             )

    for kind <- ["post_validation_exact_head", "post_validation_routing"] do
      assert Enum.any?(errors, fn err ->
               err["code"] == "dominance_violation" and err["detail"]["kind"] == kind
             end)
    end
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
    edge = %Arbor.Orchestrator.Graph.Edge{
      from: from,
      to: to,
      attrs: %{"condition" => condition}
    }

    %{graph | edges: [edge | graph.edges], adjacency: %{}, reverse_adjacency: %{}}
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
