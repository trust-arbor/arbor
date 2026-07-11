defmodule Arbor.Orchestrator.CodingPlan.Compiler do
  @moduledoc """
  Deterministically compiles a versioned coding plan from a reviewed DOT template.

  The plan selects only reviewed policy choices. It cannot contribute nodes,
  edges, action names, capabilities, principals, or other execution authority.
  """

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Contracts.Security.Classification

  alias Arbor.Orchestrator.CodingPlan.{
    ActionCatalog,
    Compilation,
    ExecutionManifest,
    Profiles,
    SemanticPreflight
  }

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler
  alias Arbor.Orchestrator.IR.HandlerSchema
  alias Arbor.Orchestrator.IR.Validator, as: IRValidator
  alias Arbor.Orchestrator.Validation.Validator, as: StructuralValidator
  alias Arbor.Orchestrator.Viz.DotSerializer

  @compiler_version "coding-plan-1"
  @template_version "coding-change-v1"
  @security_dormant_nodes ~w[
    check_security_rework_fresh
    compare_security_rework_commit
    error_post_validation_committed_change
    error_security_rework_not_fresh
    hoist_review_attestation_id
    post_validation_committed_change
    post_validation_expected_commit
    prep_review_validation_profile
    remember_review_reviewed_commit
    remember_validation_reviewed_commit
    route_security_after_commit
    route_security_attested_auto
    route_security_attested_human
    route_validated_review
  ]
  @security_dormant_roots ~w[
    route_security_after_commit
    prep_review_validation_profile
    remember_validation_reviewed_commit
    remember_review_reviewed_commit
    hoist_review_attestation_id
    post_validation_expected_commit
    route_security_attested_human
    route_security_attested_auto
  ]
  @security_dormant_seed_condition "0=1"
  @allowed_options [:template_path, :template_source, :action_catalog]
  @static_schema_types ~w(string boolean integer number array object)
  @numeric_schema_constraints ~w(minimum maximum exclusiveMinimum exclusiveMaximum)
  @string_schema_constraints ~w(minLength maxLength)
  @catalog_action_keys Enum.sort(~w(
                         beam_sha256
                         description
                         effect_class
                         egress_declared
                         egress_destination_resolver
                         egress_tier_resolver
                         module
                         name
                         parameters_schema
                         resource_uri
                       ))
  @effect_classes Classification.effect_classes()
                  |> Enum.map(&Atom.to_string/1)
                  |> Enum.sort()

  @graph_metadata_keys %{
    compiler_version: "coding_plan_compiler_version",
    template_version: "coding_plan_template_version",
    plan_version: "coding_plan_version",
    plan_fingerprint: "coding_plan_fingerprint",
    task_class: "coding_plan_task_class",
    validation_profile: "coding_plan_validation_profile",
    review_profile: "coding_plan_review_profile",
    action_catalog_digest: "coding_plan_action_catalog_digest"
  }

  @type compile_error :: term()

  @doc "Compile a normalized coding plan into immutable DOT and execution inputs."
  @spec compile(Plan.t(), keyword()) ::
          {:ok, Compilation.t()} | {:error, compile_error()}
  def compile(plan, opts \\ [])

  def compile(%Plan{} = plan, opts) do
    with {:ok, plan} <- normalize_plan(plan),
         {:ok, opts} <- normalize_options(opts),
         {:ok, profile} <- Profiles.fetch_executable(plan.validation_profile),
         :ok <- validate_supported_features(plan),
         {:ok, action_catalog} <- resolve_action_catalog(opts),
         {:ok, template_source} <- resolve_template_source(opts),
         :ok <- SemanticPreflight.validate_source(template_source),
         plan_map = Plan.to_map(plan),
         {:ok, plan_fingerprint} <- fingerprint(plan_map, :plan),
         {:ok, template_graph} <- parse_dot(template_source, :template_parse_failed),
         {:ok, generated_graph} <-
           apply_reviewed_mutations(template_graph, plan, plan_fingerprint, action_catalog),
         dot_source = DotSerializer.serialize(generated_graph),
         :ok <- SemanticPreflight.validate_source(dot_source),
         {:ok, final_graph} <- parse_dot(dot_source, :generated_dot_parse_failed),
         :ok <- verify_canonical_roundtrip(final_graph, dot_source),
         :ok <- validate_known_handler_types(final_graph),
         :ok <- validate_action_nodes(final_graph, action_catalog),
         :ok <- Profiles.validate_requirements(profile, final_graph),
         :ok <- validate_structural_graph(final_graph),
         {:ok, compiled_graph} <- compile_ir(final_graph),
         :ok <- validate_typed_graph(compiled_graph),
         :ok <- Profiles.validate_requirements(profile, compiled_graph),
         :ok <-
           SemanticPreflight.validate(compiled_graph, profile["semantic_policy"],
             review_profile: plan.review_profile
           ),
         graph_hash = sha256(dot_source),
         {:ok, {execution_manifest, execution_manifest_digest}} <-
           ExecutionManifest.build(compiled_graph, action_catalog, graph_hash) do
      initial_values = build_initial_values(plan, plan_fingerprint, action_catalog["digest"])

      manifest =
        build_manifest(
          plan,
          final_graph,
          graph_hash,
          plan_fingerprint,
          action_catalog["digest"],
          execution_manifest,
          execution_manifest_digest
        )

      {:ok,
       %Compilation{
         plan_map: plan_map,
         dot_source: dot_source,
         graph_hash: graph_hash,
         compiler_version: @compiler_version,
         template_version: @template_version,
         plan_fingerprint: plan_fingerprint,
         action_catalog_digest: action_catalog["digest"],
         execution_manifest: execution_manifest,
         execution_manifest_digest: execution_manifest_digest,
         initial_values: initial_values,
         manifest: manifest
       }}
    end
  end

  def compile(_plan, _opts), do: {:error, :invalid_plan}

  defp normalize_plan(%Plan{} = plan) do
    case plan |> Plan.to_map() |> Plan.new() do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_plan, reason}}
    end
  rescue
    error -> {:error, {:invalid_plan, Exception.message(error)}}
  end

  defp normalize_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      unknown = keys |> Enum.uniq() |> Enum.reject(&(&1 in @allowed_options)) |> Enum.sort()

      duplicates =
        keys
        |> Enum.frequencies()
        |> Enum.filter(fn {_key, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      cond do
        unknown != [] ->
          {:error, {:unknown_options, unknown}}

        duplicates != [] ->
          {:error, {:duplicate_options, duplicates}}

        Keyword.has_key?(opts, :template_path) and
            Keyword.has_key?(opts, :template_source) ->
          {:error, :ambiguous_template_source}

        true ->
          validate_option_values(Map.new(opts))
      end
    else
      {:error, :invalid_options}
    end
  end

  defp normalize_options(_opts), do: {:error, :invalid_options}

  defp validate_option_values(opts) do
    with :ok <- validate_optional_nonempty_string(opts, :template_path),
         :ok <- validate_optional_nonempty_string(opts, :template_source),
         :ok <- validate_optional_catalog(opts) do
      {:ok, opts}
    end
  end

  defp validate_optional_nonempty_string(opts, key) do
    case Map.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value}
      when is_binary(value) and byte_size(value) > 0 ->
        if String.valid?(value) and String.trim(value) != "" and
             not String.contains?(value, <<0>>) do
          :ok
        else
          {:error, {:invalid_option, key}}
        end

      {:ok, _value} ->
        {:error, {:invalid_option, key}}
    end
  end

  defp validate_optional_catalog(opts) do
    case Map.fetch(opts, :action_catalog) do
      :error -> :ok
      {:ok, catalog} -> validate_action_catalog(catalog)
    end
  end

  defp resolve_action_catalog(%{action_catalog: catalog}), do: {:ok, catalog}

  defp resolve_action_catalog(_opts) do
    case ActionCatalog.snapshot() do
      {:ok, catalog} ->
        case validate_action_catalog(catalog) do
          :ok -> {:ok, catalog}
          {:error, reason} -> {:error, {:action_catalog_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:action_catalog_failed, reason}}
    end
  end

  defp validate_action_catalog(%{"actions" => actions, "digest" => digest} = catalog)
       when map_size(catalog) == 2 and is_list(actions) and is_binary(digest) do
    with :ok <- validate_digest(digest),
         :ok <- validate_catalog_actions(actions),
         {:ok, expected_digest} <- fingerprint(actions, :action_catalog),
         true <- expected_digest == digest do
      :ok
    else
      false -> {:error, {:invalid_action_catalog, :digest_mismatch}}
      {:error, {:invalid_action_catalog, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_action_catalog, reason}}
    end
  end

  defp validate_action_catalog(_catalog),
    do: {:error, {:invalid_action_catalog, :expected_normalized_snapshot}}

  defp validate_digest(digest) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, digest) do
      :ok
    else
      {:error, {:invalid_action_catalog, :invalid_digest}}
    end
  end

  defp validate_catalog_actions(actions) do
    with :ok <- validate_catalog_action_entries(actions),
         names = Enum.map(actions, & &1["name"]),
         true <- names == Enum.sort(names),
         true <- length(names) == length(Enum.uniq(names)) do
      :ok
    else
      false -> {:error, {:invalid_action_catalog, :actions_not_sorted_or_unique}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_catalog_action_entries(actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {action, index}, :ok ->
      case validate_catalog_action(action) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_action_catalog, {index, reason}}}}
      end
    end)
  end

  defp validate_catalog_action(action) when is_map(action) do
    valid? =
      Map.keys(action) |> Enum.sort() == @catalog_action_keys and
        is_binary(action["name"]) and String.trim(action["name"]) != "" and
        is_binary(action["description"]) and is_map(action["parameters_schema"]) and
        is_binary(action["module"]) and String.trim(action["module"]) != "" and
        is_binary(action["beam_sha256"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, action["beam_sha256"]) and
        is_binary(action["resource_uri"]) and String.trim(action["resource_uri"]) != "" and
        action["effect_class"] in @effect_classes and
        is_boolean(action["egress_declared"]) and
        is_boolean(action["egress_tier_resolver"]) and
        is_boolean(action["egress_destination_resolver"]) and json_clean?(action)

    if valid?, do: :ok, else: {:error, :malformed_action}
  end

  defp validate_catalog_action(_action), do: {:error, :malformed_action}

  defp resolve_template_source(%{template_source: source}), do: {:ok, source}

  defp resolve_template_source(%{template_path: path}), do: read_template(path)

  defp resolve_template_source(_opts) do
    :arbor_orchestrator
    |> Application.app_dir("priv/pipelines/coding-change-v1.dot")
    |> read_template()
  end

  defp read_template(path) do
    case File.read(path) do
      {:ok, source} ->
        if source != "" and String.valid?(source) do
          {:ok, source}
        else
          {:error, {:template_read_failed, :invalid_source}}
        end

      {:error, reason} ->
        {:error, {:template_read_failed, reason}}
    end
  end

  defp validate_supported_features(%Plan{} = plan) do
    cond do
      plan.validation_profile == "security_regression" and plan.review_profile == "none" ->
        {:error, {:security_regression_review_profile_not_allowed, "none"}}

      plan.task_class != "default" and plan.task_class != plan.validation_profile ->
        {:error, {:unsupported_v1_profile_mismatch, plan.task_class, plan.validation_profile}}

      plan.overlays != [] ->
        {:error, {:unsupported_v1_feature, "overlays"}}

      plan.rework["stop_conditions"] != [] ->
        {:error, {:unsupported_v1_feature, "rework.stop_conditions"}}

      not is_nil(plan.budgets["model_cost_usd"]) ->
        {:error, {:unsupported_v1_feature, "budgets.model_cost_usd"}}

      plan.budgets["parallelism"] != 1 ->
        {:error, {:unsupported_v1_feature, "budgets.parallelism"}}

      true ->
        :ok
    end
  end

  defp parse_dot(source, tag) do
    case Parser.parse(source) do
      {:ok, graph} -> {:ok, graph}
      {:ok, _graph, errors} -> {:error, {tag, errors}}
      {:error, reason} -> {:error, {tag, reason}}
    end
  end

  defp apply_reviewed_mutations(graph, plan, plan_fingerprint, action_catalog) do
    with {:ok, graph} <- rewrite_classification(graph, plan.task_class),
         {:ok, graph} <- rewrite_worker_open(graph, plan.worker),
         {:ok, graph} <- rewrite_prompt_budgets(graph),
         {:ok, graph} <- rewrite_profile_flow(graph, plan),
         {:ok, graph} <- rewrite_rework_budget(graph, plan.rework["max_cycles"]),
         {:ok, graph} <-
           rewrite_review_route(graph, plan.review_profile, plan.validation_profile),
         :ok <- require_action_node(graph, "review_change", "council_review_change") do
      {:ok, put_graph_metadata(graph, plan, plan_fingerprint, action_catalog["digest"])}
    end
  end

  defp rewrite_classification(graph, task_class) do
    update_node(graph, "classify_profile", fn attrs ->
      with :ok <- require_attrs(attrs, %{"type" => "transform", "transform" => "constant"}) do
        {:ok, Map.put(attrs, "expression", task_class)}
      end
    end)
  end

  defp rewrite_worker_open(graph, worker) do
    update_node(graph, "open_worker", fn attrs ->
      with :ok <- require_action_attrs(attrs, "acp_start_session") do
        context_keys =
          if is_nil(worker["model"]), do: "provider,cwd", else: "provider,cwd,model"

        {:ok,
         attrs
         |> Map.put("context_keys", context_keys)
         |> Map.put("param.permission_mode", worker["permission_mode"])}
      end
    end)
  end

  defp rewrite_prompt_budgets(graph) do
    with {:ok, graph} <- rewrite_prompt_budget_node(graph, "implement") do
      rewrite_prompt_budget_node(graph, "repair_worker_protocol")
    end
  end

  defp rewrite_prompt_budget_node(graph, node_id) do
    update_node(graph, node_id, fn attrs ->
      with :ok <- require_action_attrs(attrs, "acp_send_message") do
        {:ok,
         Map.put(
           attrs,
           "context_keys",
           "worker_session_id,prompt,timeout,inactivity_timeout_ms"
         )}
      end
    end)
  end

  defp rewrite_profile_flow(graph, %Plan{validation_profile: "default"}) do
    with {:ok, graph} <- rewrite_default_validation(graph) do
      drop_security_dormant_nodes(graph)
    end
  end

  defp rewrite_profile_flow(graph, %Plan{validation_profile: "cross_app"}) do
    with {:ok, graph} <- rewrite_cross_app_validation(graph) do
      drop_security_dormant_nodes(graph)
    end
  end

  defp rewrite_profile_flow(
         graph,
         %Plan{validation_profile: "security_regression"} = plan
       ) do
    with :ok <- validate_security_test_paths(plan.requested_paths),
         {:ok, graph} <- remove_security_dormant_seed_edges(graph),
         {:ok, graph} <- rewrite_security_validator(graph),
         {:ok, graph} <- rewrite_security_review(graph),
         {:ok, graph} <- rewrite_security_rework_prompt(graph),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "hoist_head_commit",
             "prep_validation_path",
             "context.changed_from_base=true",
             "prep_commit_path",
             "context.changed_from_base=true"
           ),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "check_validation_passed",
             "prep_commit_path",
             "outcome=success",
             "post_validation_expected_commit",
             "outcome=success"
           ),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "check_validation_passed",
             "check_validation_category_budget",
             "outcome=fail",
             "remember_validation_reviewed_commit",
             "outcome=fail"
           ),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "route_review",
             "check_review_category_budget",
             "context.review.tier_decision=rework",
             "remember_review_reviewed_commit",
             "context.review.tier_decision=rework"
           ),
         {:ok, graph} <-
           rewrite_unconditional_edge(
             graph,
             "prep_review_base",
             "review_change",
             "prep_review_validation_profile"
           ),
         {:ok, graph} <-
           rewrite_unconditional_edge(
             graph,
             "hoist_commit_hash",
             "route_after_commit",
             "route_security_after_commit"
           ) do
      # adopt_head_commit was removed: clean self-commit adoption is performed
      # inside coding_reviewed_commit so rework cannot bypass a fresh gate.
      remove_replaced_status_node(graph, "prep_validation_path", "validate")
    end
  end

  defp rewrite_default_validation(graph) do
    update_node(graph, "validate", fn attrs ->
      with :ok <- require_action_attrs(attrs, "mix_compile") do
        {:ok,
         attrs
         |> Map.put("context_keys", "path")
         |> Map.put("param.warnings_as_errors", true)}
      end
    end)
  end

  defp rewrite_cross_app_validation(graph) do
    update_node(graph, "validate", fn attrs ->
      with :ok <- require_action_attrs(attrs, "mix_compile") do
        {:ok,
         attrs
         |> Map.put("action", "coding_cross_app_validate")
         |> Map.put("context_keys", "workspace_id")
         |> Map.delete("param.warnings_as_errors")}
      end
    end)
  end

  defp rewrite_security_validator(graph) do
    update_node(graph, "validate", fn attrs ->
      with :ok <- require_action_attrs(attrs, "mix_compile") do
        {:ok,
         attrs
         |> Map.put("action", "coding_security_regression_validate")
         |> Map.put("context_keys", "review_attestation_id")
         |> Map.delete("param.warnings_as_errors")}
      end
    end)
  end

  defp rewrite_security_review(graph) do
    update_node(graph, "review_change", fn attrs ->
      with :ok <- require_action_attrs(attrs, "council_review_change") do
        {:ok,
         Map.put(
           attrs,
           "context_keys",
           "diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash,test_paths,validation_profile"
         )}
      end
    end)
  end

  defp rewrite_security_rework_prompt(graph) do
    update_node(graph, "build_validation_rework_prompt", fn attrs ->
      with :ok <-
             require_attrs(attrs, %{
               "type" => "transform",
               "transform" => "template",
               "source_key" => "task",
               "output_key" => "prompt"
             }) do
        {:ok,
         Map.put(
           attrs,
           "expression",
           "Security regression validation failed after your previous commit. Task: {value}. " <>
             "Validation reason: {ctx.validation.reason}. Fix the issue in the same worktree " <>
             "and leave a fresh commit or uncommitted change. Respond with ONLY one JSON object " <>
             "and no prose or markdown: {\"status\":\"implemented\"} or " <>
             "{\"status\":\"declined\"}, plus optional {\"summary\":\"...\"}."
         )}
      end
    end)
  end

  defp validate_security_test_paths([]),
    do: {:error, {:invalid_security_regression_paths, :empty}}

  defp validate_security_test_paths(paths) do
    case Enum.reject(paths, &String.ends_with?(&1, "_test.exs")) do
      [] -> :ok
      invalid -> {:error, {:invalid_security_regression_paths, invalid}}
    end
  end

  defp rewrite_rework_budget(graph, max_cycles) do
    rewrites = [
      {"check_validation_total_budget", "status_validation_failed",
       "context.total_rework_count>=2", "context.total_rework_count>=#{max_cycles}"},
      {"check_validation_total_budget", "inc_validation_rework_count",
       "context.total_rework_count<2", "context.total_rework_count<#{max_cycles}"},
      {"check_review_total_budget", "legacy_status_review_requires_rework",
       "context.total_rework_count>=2", "context.total_rework_count>=#{max_cycles}"},
      {"check_review_total_budget", "inc_review_rework_count", "context.total_rework_count<2",
       "context.total_rework_count<#{max_cycles}"},
      {"check_operator_rework_total_budget", "legacy_status_operator_approval_rework",
       "context.total_rework_count>=2", "context.total_rework_count>=#{max_cycles}"},
      {"check_operator_rework_total_budget", "inc_operator_rework_count",
       "context.total_rework_count<2", "context.total_rework_count<#{max_cycles}"}
    ]

    Enum.reduce_while(rewrites, {:ok, graph}, fn {from, to, old, new}, {:ok, graph} ->
      case rewrite_edge(graph, from, to, old, to, new) do
        {:ok, graph} -> {:cont, {:ok, graph}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite_review_route(graph, "none", "default") do
    # Legacy submit_review=false keeps the structural skip-review edge so
    # no-review publication remains possible. Binding/human remove that edge.
    rewrite_edge(
      graph,
      "route_review",
      "route_publish",
      "context.review.tier_decision=auto_proceed",
      "route_publish",
      "context.review.tier_decision=auto_proceed"
    )
  end

  defp rewrite_review_route(graph, "binding", "default") do
    with {:ok, graph} <- remove_submit_review_false_edge(graph) do
      rewrite_edge(
        graph,
        "route_review",
        "route_publish",
        "context.review.tier_decision=auto_proceed",
        "route_publish",
        "context.review.tier_decision=auto_proceed"
      )
    end
  end

  defp rewrite_review_route(graph, "human_required", "default") do
    with {:ok, graph} <- remove_submit_review_false_edge(graph),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "route_review",
             "route_publish",
             "context.review.tier_decision=auto_proceed",
             "route_human_review",
             "context.review.tier_decision=auto_proceed"
           ),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "open_draft_pr",
             "status_pr_created",
             "outcome=success",
             "status_human_review_required",
             "outcome=success"
           ),
         {:ok, graph} <- remove_replaced_status_node(graph, "status_pr_created", "close_worker") do
      # Auto-proceed no longer reaches route_publish, and the skip-review edge
      # is gone, so the unattended publication terminals are dead. Drop them so
      # structural reachability stays sound while review remains mandatory.
      remove_unattended_publication_nodes(graph)
    end
  end

  # cross_app keeps default review-route semantics (does not weaken review).
  defp rewrite_review_route(graph, "none", "cross_app"),
    do: rewrite_review_route(graph, "none", "default")

  defp rewrite_review_route(graph, "binding", "cross_app"),
    do: rewrite_review_route(graph, "binding", "default")

  defp rewrite_review_route(graph, "human_required", "cross_app"),
    do: rewrite_review_route(graph, "human_required", "default")

  defp rewrite_review_route(_graph, "none", "security_regression"),
    do: {:error, {:security_regression_review_profile_not_allowed, "none"}}

  defp rewrite_review_route(graph, "binding", "security_regression") do
    with {:ok, graph} <- remove_submit_review_false_edge(graph),
         {:ok, graph} <- route_security_eligible_review_to_attestation(graph) do
      {:ok, graph}
    end
  end

  defp rewrite_review_route(graph, "human_required", "security_regression") do
    with {:ok, graph} <- remove_submit_review_false_edge(graph),
         {:ok, graph} <- route_security_eligible_review_to_attestation(graph),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "route_validated_review",
             "route_publish",
             "context.review.tier_decision=auto_proceed",
             "route_human_review",
             "context.review.tier_decision=auto_proceed"
           ),
         {:ok, graph} <-
           rewrite_edge(
             graph,
             "open_draft_pr",
             "status_pr_created",
             "outcome=success",
             "status_human_review_required",
             "outcome=success"
           ),
         {:ok, graph} <- remove_replaced_status_node(graph, "status_pr_created", "close_worker") do
      remove_unattended_publication_nodes(graph)
    end
  end

  # Security regression may only claim a review attestation after Council issues
  # one. Tier routing stays on simple single-clause edges; attestation presence
  # is decided by the dormant branch nodes route_security_attested_{human,auto}.
  # Unattested human_review terminates at status_human_review_required (not
  # route_human_review, which can open a draft PR). Unattested auto_proceed
  # fails closed via error_review_tier_invalid.
  defp route_security_eligible_review_to_attestation(graph) do
    with {:ok, graph} <-
           rewrite_edge(
             graph,
             "route_review",
             "route_human_review",
             "context.review.tier_decision=human_review",
             "route_security_attested_human",
             "context.review.tier_decision=human_review"
           ) do
      rewrite_edge(
        graph,
        "route_review",
        "route_publish",
        "context.review.tier_decision=auto_proceed",
        "route_security_attested_auto",
        "context.review.tier_decision=auto_proceed"
      )
    end
  end

  defp drop_security_dormant_nodes(%Graph{} = graph) do
    missing = Enum.reject(@security_dormant_nodes, &Map.has_key?(graph.nodes, &1))

    if missing == [] do
      drop_ids = MapSet.new(@security_dormant_nodes)

      nodes = Map.drop(graph.nodes, @security_dormant_nodes)

      edges =
        Enum.reject(graph.edges, fn edge ->
          MapSet.member?(drop_ids, edge.from) or MapSet.member?(drop_ids, edge.to)
        end)

      {:ok, %{graph | nodes: nodes, edges: edges, adjacency: %{}, reverse_adjacency: %{}}}
    else
      {:error, {:missing_template_nodes, Enum.sort(missing)}}
    end
  end

  defp remove_security_dormant_seed_edges(%Graph{} = graph) do
    counts =
      Map.new(@security_dormant_roots, fn root ->
        count =
          Enum.count(graph.edges, fn edge ->
            edge.from == "start" and edge.to == root and
              Map.get(edge.attrs, "condition") == @security_dormant_seed_condition
          end)

        {root, count}
      end)

    unexpected = Enum.reject(counts, fn {_root, count} -> count == 1 end)

    if unexpected == [] do
      roots = MapSet.new(@security_dormant_roots)

      edges =
        Enum.reject(graph.edges, fn edge ->
          edge.from == "start" and MapSet.member?(roots, edge.to) and
            Map.get(edge.attrs, "condition") == @security_dormant_seed_condition
        end)

      {:ok, %{graph | edges: edges, adjacency: %{}, reverse_adjacency: %{}}}
    else
      {:error, {:unexpected_security_dormant_seed_edges, Enum.sort(unexpected)}}
    end
  end

  # For binding/human plans submit_review is always true, so the template's
  # submit_review=false bypass is infeasible. Removing it makes review
  # dominance structural rather than a runtime context assumption.
  defp remove_submit_review_false_edge(%Graph{} = graph) do
    matches =
      Enum.count(graph.edges, fn edge ->
        edge.from == "route_after_commit" and edge.to == "route_publish" and
          Map.get(edge.attrs, "condition") == "context.submit_review=false"
      end)

    if matches == 1 do
      edges =
        Enum.reject(graph.edges, fn edge ->
          edge.from == "route_after_commit" and edge.to == "route_publish" and
            Map.get(edge.attrs, "condition") == "context.submit_review=false"
        end)

      {:ok, %{graph | edges: edges, adjacency: %{}, reverse_adjacency: %{}}}
    else
      {:error,
       {:unexpected_template_edge, "route_after_commit", "route_publish",
        "context.submit_review=false", matches}}
    end
  end

  defp remove_unattended_publication_nodes(%Graph{} = graph) do
    # route_publish must already be unreachable (no external predecessors). Its
    # only dependents (status_change_committed, optional PR prep edge) drop with it.
    route_incoming =
      Enum.filter(graph.edges, fn edge ->
        edge.to == "route_publish" and edge.from != "route_publish"
      end)

    cond do
      not Map.has_key?(graph.nodes, "route_publish") ->
        {:error, {:missing_template_node, "route_publish"}}

      not Map.has_key?(graph.nodes, "status_change_committed") ->
        {:error, {:missing_template_node, "status_change_committed"}}

      route_incoming != [] ->
        {:error,
         {:unexpected_template_node, "route_publish",
          {:remaining_incoming_edges, length(route_incoming)}}}

      true ->
        drop_ids = MapSet.new(["route_publish", "status_change_committed"])

        nodes =
          Enum.reduce(drop_ids, graph.nodes, fn id, acc ->
            Map.delete(acc, id)
          end)

        edges =
          Enum.reject(graph.edges, fn edge ->
            MapSet.member?(drop_ids, edge.from) or MapSet.member?(drop_ids, edge.to)
          end)

        {:ok, %{graph | nodes: nodes, edges: edges, adjacency: %{}, reverse_adjacency: %{}}}
    end
  end

  defp remove_replaced_status_node(%Graph{} = graph, node_id, expected_successor) do
    incoming = Enum.filter(graph.edges, &(&1.to == node_id))
    outgoing = Enum.filter(graph.edges, &(&1.from == node_id))

    expected_outgoing? =
      match?([%{to: ^expected_successor, attrs: attrs}] when map_size(attrs) == 0, outgoing)

    cond do
      not Map.has_key?(graph.nodes, node_id) ->
        {:error, {:missing_template_node, node_id}}

      incoming != [] ->
        {:error,
         {:unexpected_template_node, node_id, {:remaining_incoming_edges, length(incoming)}}}

      not expected_outgoing? ->
        {:error,
         {:unexpected_template_node, node_id, {:unexpected_outgoing_edges, length(outgoing)}}}

      true ->
        {:ok,
         %{
           graph
           | nodes: Map.delete(graph.nodes, node_id),
             edges: Enum.reject(graph.edges, &(&1.from == node_id)),
             adjacency: %{},
             reverse_adjacency: %{}
         }}
    end
  end

  defp update_node(%Graph{} = graph, node_id, update_fun) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, node} ->
        case update_fun.(node.attrs) do
          {:ok, attrs} ->
            {:ok, %{graph | nodes: Map.put(graph.nodes, node_id, %{node | attrs: attrs})}}

          {:error, reason} ->
            {:error, {:unexpected_template_node, node_id, reason}}
        end

      :error ->
        {:error, {:missing_template_node, node_id}}
    end
  end

  defp require_action_node(%Graph{} = graph, node_id, action) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, node} ->
        case require_action_attrs(node.attrs, action) do
          :ok -> :ok
          {:error, reason} -> {:error, {:unexpected_template_node, node_id, reason}}
        end

      :error ->
        {:error, {:missing_template_node, node_id}}
    end
  end

  defp require_action_attrs(attrs, action) do
    require_attrs(attrs, %{"type" => "exec", "target" => "action", "action" => action})
  end

  defp require_attrs(attrs, expected) do
    case Enum.find(expected, fn {key, value} -> Map.get(attrs, key) != value end) do
      nil -> :ok
      {key, value} -> {:error, {:expected_attribute, key, value, Map.get(attrs, key)}}
    end
  end

  defp rewrite_edge(%Graph{} = graph, from, to, condition, new_to, new_condition) do
    matches =
      Enum.count(graph.edges, fn edge ->
        edge.from == from and edge.to == to and Map.get(edge.attrs, "condition") == condition
      end)

    if matches == 1 do
      edges =
        Enum.map(graph.edges, fn edge ->
          if edge.from == from and edge.to == to and Map.get(edge.attrs, "condition") == condition do
            attrs =
              if is_nil(new_condition),
                do: Map.delete(edge.attrs, "condition"),
                else: Map.put(edge.attrs, "condition", new_condition)

            %{edge | to: new_to, attrs: attrs}
          else
            edge
          end
        end)

      {:ok, %{graph | edges: edges, adjacency: %{}, reverse_adjacency: %{}}}
    else
      {:error, {:unexpected_template_edge, from, to, condition, matches}}
    end
  end

  defp rewrite_unconditional_edge(graph, from, to, new_to) do
    rewrite_edge(graph, from, to, nil, new_to, nil)
  end

  defp put_graph_metadata(graph, plan, plan_fingerprint, catalog_digest) do
    metadata = %{
      @graph_metadata_keys.compiler_version => @compiler_version,
      @graph_metadata_keys.template_version => @template_version,
      @graph_metadata_keys.plan_version => Integer.to_string(plan.version),
      @graph_metadata_keys.plan_fingerprint => plan_fingerprint,
      @graph_metadata_keys.task_class => plan.task_class,
      @graph_metadata_keys.validation_profile => plan.validation_profile,
      @graph_metadata_keys.review_profile => plan.review_profile,
      @graph_metadata_keys.action_catalog_digest => catalog_digest
    }

    %{graph | attrs: Map.merge(graph.attrs, metadata)}
  end

  defp verify_canonical_roundtrip(graph, source) do
    if DotSerializer.serialize(graph) == source do
      :ok
    else
      {:error, :generated_dot_not_canonical}
    end
  end

  defp validate_known_handler_types(%Graph{} = graph) do
    known = MapSet.new(HandlerSchema.known_types())

    unknown =
      graph.nodes
      |> Enum.flat_map(fn {node_id, node} ->
        handler_type = Registry.node_type(node)
        if MapSet.member?(known, handler_type), do: [], else: [[node_id, handler_type]]
      end)
      |> Enum.sort()

    if unknown == [], do: :ok, else: {:error, {:unknown_handler_types, unknown}}
  end

  defp validate_action_nodes(%Graph{} = graph, action_catalog) do
    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {node_id, node}, :ok ->
      if Registry.node_type(node) == "exec" and Map.get(node.attrs, "target") == "action" do
        case validate_action_node(node_id, node.attrs, action_catalog) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_action_node(node_id, attrs, action_catalog) do
    action = Map.get(attrs, "action")

    if not is_binary(action) or action == "" do
      {:error, {:invalid_action_node, node_id, :missing_action}}
    else
      case ActionCatalog.fetch(action_catalog, action) do
        {:ok, spec} -> validate_action_parameters(node_id, action, attrs, spec)
        :error -> {:error, {:unknown_action, node_id, action}}
      end
    end
  end

  defp validate_action_parameters(node_id, action, attrs, spec) do
    with {:ok, properties, required} <- normalize_parameter_schema(node_id, action, spec),
         {:ok, context_names} <- parse_context_keys(node_id, attrs),
         {:ok, static_params} <- parse_static_params(node_id, attrs),
         :ok <- reject_duplicate_parameter_sources(node_id, context_names, static_params),
         supplied = Enum.uniq(context_names ++ Map.keys(static_params)),
         :ok <- reject_unknown_parameters(node_id, action, supplied, properties),
         :ok <- reject_missing_parameters(node_id, action, supplied, required) do
      validate_static_parameter_types(node_id, action, static_params, properties)
    end
  end

  defp normalize_parameter_schema(node_id, action, %{"parameters_schema" => schema})
       when is_map(schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    root_type = Map.get(schema, "type", "object")

    cond do
      root_type != "object" ->
        {:error, {:invalid_action_schema, node_id, action, :expected_object}}

      not is_map(properties) or
          not Enum.all?(properties, fn {key, value} ->
            is_binary(key) and is_map(value)
          end) ->
        {:error, {:invalid_action_schema, node_id, action, :invalid_properties}}

      not is_list(required) or not Enum.all?(required, &is_binary/1) ->
        {:error, {:invalid_action_schema, node_id, action, :invalid_required}}

      length(required) != length(Enum.uniq(required)) ->
        {:error, {:invalid_action_schema, node_id, action, :duplicate_required}}

      Enum.any?(required, &(not Map.has_key?(properties, &1))) ->
        {:error, {:invalid_action_schema, node_id, action, :required_property_missing}}

      true ->
        {:ok, properties, required}
    end
  end

  defp normalize_parameter_schema(node_id, action, _spec),
    do: {:error, {:invalid_action_schema, node_id, action, :missing_parameters_schema}}

  defp parse_context_keys(node_id, attrs) do
    case Map.get(attrs, "context_keys") do
      nil ->
        {:ok, []}

      value when is_binary(value) ->
        names = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

        cond do
          Enum.any?(names, &(&1 == "")) ->
            {:error, {:invalid_action_node, node_id, :empty_context_key}}

          length(names) != length(Enum.uniq(names)) ->
            {:error, {:invalid_action_node, node_id, :duplicate_context_keys}}

          true ->
            {:ok, names}
        end

      _value ->
        {:error, {:invalid_action_node, node_id, :invalid_context_keys}}
    end
  end

  defp parse_static_params(node_id, attrs) do
    attrs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, params} ->
      case static_parameter_name(key) do
        nil ->
          {:cont, {:ok, params}}

        "" ->
          {:halt, {:error, {:invalid_action_node, node_id, :empty_static_parameter}}}

        name ->
          if Map.has_key?(params, name) do
            {:halt,
             {:error, {:invalid_action_node, node_id, {:duplicate_static_parameter, name}}}}
          else
            {:cont, {:ok, Map.put(params, name, value)}}
          end
      end
    end)
  end

  defp static_parameter_name("param." <> name), do: name
  defp static_parameter_name("arg." <> name), do: name
  defp static_parameter_name(_key), do: nil

  defp reject_duplicate_parameter_sources(node_id, context_names, static_params) do
    duplicates = context_names |> Enum.filter(&Map.has_key?(static_params, &1)) |> Enum.sort()

    if duplicates == [] do
      :ok
    else
      {:error, {:invalid_action_node, node_id, {:duplicate_parameter_sources, duplicates}}}
    end
  end

  defp reject_unknown_parameters(node_id, action, supplied, properties) do
    unknown = supplied |> Enum.reject(&Map.has_key?(properties, &1)) |> Enum.sort()

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_action_parameters, node_id, action, unknown}}
    end
  end

  defp reject_missing_parameters(node_id, action, supplied, required) do
    supplied = MapSet.new(supplied)
    missing = required |> Enum.reject(&MapSet.member?(supplied, &1)) |> Enum.sort()

    if missing == [] do
      :ok
    else
      {:error, {:missing_action_parameters, node_id, action, missing}}
    end
  end

  defp validate_static_parameter_types(node_id, action, static_params, properties) do
    static_params
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {name, value}, :ok ->
      schema = Map.fetch!(properties, name)

      case normalize_static_parameter_schema(node_id, action, name, schema) do
        {:ok, normalized_schema} ->
          if static_parameter_valid?(value, normalized_schema) do
            {:cont, :ok}
          else
            expected = static_type_descriptor(normalized_schema.types)

            {:halt,
             {:error, {:invalid_static_action_parameter, node_id, action, name, expected, value}}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize_static_parameter_schema(node_id, action, name, schema) do
    with {:ok, types} <- normalize_static_schema_types(schema),
         {:ok, enum} <- normalize_static_enum(schema),
         {:ok, numeric_constraints} <- normalize_numeric_constraints(schema),
         {:ok, string_constraints} <- normalize_string_constraints(schema) do
      {:ok,
       %{
         types: types,
         enum: enum,
         numeric_constraints: numeric_constraints,
         string_constraints: string_constraints
       }}
    else
      {:error, reason} ->
        {:error,
         {:invalid_action_schema, node_id, action, {:invalid_parameter_schema, name, reason}}}
    end
  end

  defp normalize_static_schema_types(schema) do
    case Map.fetch(schema, "type") do
      :error ->
        {:ok, nil}

      {:ok, type} when type in @static_schema_types ->
        {:ok, [type]}

      {:ok, types} when is_list(types) ->
        cond do
          types == [] ->
            {:error, :empty_type_union}

          not Enum.all?(types, &is_binary/1) ->
            {:error, :invalid_type_union}

          length(types) != length(Enum.uniq(types)) ->
            {:error, :duplicate_type_union}

          true ->
            unsupported = Enum.reject(types, &(&1 in @static_schema_types))

            if unsupported == [] do
              {:ok, types}
            else
              {:error, {:unsupported_types, Enum.sort(unsupported)}}
            end
        end

      {:ok, type} when is_binary(type) ->
        {:error, {:unsupported_type, type}}

      {:ok, _type} ->
        {:error, :invalid_type}
    end
  end

  defp normalize_static_enum(schema) do
    case Map.fetch(schema, "enum") do
      :error ->
        {:ok, nil}

      {:ok, values} when is_list(values) and values != [] ->
        if length(values) == length(Enum.uniq(values)) do
          {:ok, values}
        else
          {:error, :duplicate_enum_values}
        end

      {:ok, _values} ->
        {:error, :invalid_enum}
    end
  end

  defp normalize_numeric_constraints(schema) do
    normalize_constraints(schema, @numeric_schema_constraints, fn value -> is_number(value) end)
  end

  defp normalize_string_constraints(schema) do
    normalize_constraints(schema, @string_schema_constraints, fn value ->
      is_integer(value) and value >= 0
    end)
  end

  defp normalize_constraints(schema, keys, valid?) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, constraints} ->
      case Map.fetch(schema, key) do
        :error ->
          {:cont, {:ok, constraints}}

        {:ok, value} ->
          if valid?.(value) do
            {:cont, {:ok, Map.put(constraints, key, value)}}
          else
            {:halt, {:error, {:invalid_constraint, key}}}
          end
      end
    end)
  end

  defp static_type_descriptor(nil), do: nil
  defp static_type_descriptor([type]), do: type
  defp static_type_descriptor(types), do: types

  defp static_parameter_valid?(value, %{types: nil} = schema) do
    type = infer_static_type(value)
    static_candidate_valid?(type, value, schema)
  end

  defp static_parameter_valid?(value, %{types: types} = schema) do
    Enum.any?(types, fn type ->
      case coerce_static_value(value, type) do
        {:ok, coerced} -> static_candidate_valid?(type, coerced, schema)
        :error -> false
      end
    end)
  end

  defp infer_static_type(value) when is_binary(value), do: "string"
  defp infer_static_type(value) when is_boolean(value), do: "boolean"
  defp infer_static_type(value) when is_integer(value), do: "integer"
  defp infer_static_type(value) when is_float(value), do: "number"
  defp infer_static_type(value) when is_list(value), do: "array"
  defp infer_static_type(value) when is_map(value) and not is_struct(value), do: "object"
  defp infer_static_type(_value), do: nil

  defp coerce_static_value(value, "string") when is_binary(value), do: {:ok, value}
  defp coerce_static_value(value, "boolean") when is_boolean(value), do: {:ok, value}
  defp coerce_static_value("true", "boolean"), do: {:ok, true}
  defp coerce_static_value("false", "boolean"), do: {:ok, false}
  defp coerce_static_value(value, "integer") when is_integer(value), do: {:ok, value}

  defp coerce_static_value(value, "integer") when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp coerce_static_value(value, "number") when is_number(value), do: {:ok, value}

  defp coerce_static_value(value, "number") when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        {:ok, integer}

      _other ->
        case Float.parse(value) do
          {number, ""} -> {:ok, number}
          _other -> :error
        end
    end
  end

  defp coerce_static_value(value, "array") when is_list(value), do: {:ok, value}

  defp coerce_static_value(value, "object") when is_map(value) and not is_struct(value),
    do: {:ok, value}

  defp coerce_static_value(_value, _type), do: :error

  defp static_candidate_valid?(type, value, schema) do
    enum_valid?(value, schema.enum) and
      numeric_constraints_valid?(type, value, schema.numeric_constraints) and
      string_constraints_valid?(type, value, schema.string_constraints)
  end

  defp enum_valid?(_value, nil), do: true
  defp enum_valid?(value, enum), do: Enum.any?(enum, &(&1 == value))

  defp numeric_constraints_valid?(type, value, constraints)
       when type in ["integer", "number"] do
    Enum.all?(constraints, fn
      {"minimum", minimum} -> value >= minimum
      {"maximum", maximum} -> value <= maximum
      {"exclusiveMinimum", minimum} -> value > minimum
      {"exclusiveMaximum", maximum} -> value < maximum
    end)
  end

  defp numeric_constraints_valid?(_type, _value, _constraints), do: true

  defp string_constraints_valid?("string", value, constraints) do
    if String.valid?(value) do
      length = String.length(value)

      Enum.all?(constraints, fn
        {"minLength", minimum} -> length >= minimum
        {"maxLength", maximum} -> length <= maximum
      end)
    else
      false
    end
  end

  defp string_constraints_valid?(_type, _value, _constraints), do: true

  defp validate_structural_graph(graph) do
    graph
    |> StructuralValidator.validate()
    |> reject_error_diagnostics(:structural_validation_failed)
  end

  defp compile_ir(graph) do
    case IRCompiler.compile(graph) do
      {:ok, compiled_graph} -> {:ok, compiled_graph}
      {:error, reason} -> {:error, {:ir_compile_failed, reason}}
    end
  end

  defp validate_typed_graph(graph) do
    graph
    |> IRValidator.validate()
    |> reject_error_diagnostics(:typed_validation_failed)
  end

  defp reject_error_diagnostics(diagnostics, tag) do
    errors =
      diagnostics
      |> Enum.filter(&(&1.severity == :error))
      |> Enum.map(&diagnostic_to_map/1)
      |> Enum.sort_by(&{&1["rule"], &1["node_id"] || "", &1["message"]})

    if errors == [], do: :ok, else: {:error, {tag, errors}}
  end

  defp diagnostic_to_map(diagnostic) do
    %{
      "rule" => diagnostic.rule,
      "severity" => Atom.to_string(diagnostic.severity),
      "message" => diagnostic.message,
      "node_id" => diagnostic.node_id,
      "edge" => diagnostic_edge(diagnostic.edge),
      "fix" => diagnostic.fix
    }
  end

  defp diagnostic_edge(nil), do: nil
  defp diagnostic_edge({from, to}), do: [from, to]

  defp build_initial_values(plan, plan_fingerprint, catalog_digest) do
    submit_review = plan.review_profile != "none"

    %{
      "task" => plan.task,
      "repo_path" => plan.repo_root,
      "base_ref" => plan.base_ref,
      "acp_agent" => plan.worker["provider"],
      "open_pr" => bool_string(plan.output["draft_pr"]),
      "submit_review" => bool_string(submit_review),
      "timeout" => plan.budgets["wall_clock_ms"],
      "inactivity_timeout_ms" => plan.budgets["inactivity_timeout_ms"],
      @graph_metadata_keys.compiler_version => @compiler_version,
      @graph_metadata_keys.template_version => @template_version,
      @graph_metadata_keys.plan_version => plan.version,
      @graph_metadata_keys.plan_fingerprint => plan_fingerprint,
      @graph_metadata_keys.task_class => plan.task_class,
      @graph_metadata_keys.validation_profile => plan.validation_profile,
      @graph_metadata_keys.review_profile => plan.review_profile,
      @graph_metadata_keys.action_catalog_digest => catalog_digest
    }
    |> maybe_put("branch_name", plan.workspace_policy["branch_name"])
    |> maybe_put("worktree_base_dir", plan.workspace_policy["worktree_base_dir"])
    |> maybe_put("model", plan.worker["model"])
    |> maybe_put_test_paths(plan)
  end

  defp maybe_put_test_paths(values, %Plan{validation_profile: "security_regression"} = plan),
    do: Map.put(values, "test_paths", plan.requested_paths)

  defp maybe_put_test_paths(values, _plan), do: values

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  defp build_manifest(
         plan,
         graph,
         graph_hash,
         plan_fingerprint,
         catalog_digest,
         execution_manifest,
         execution_manifest_digest
       ) do
    %{
      "compiler_version" => @compiler_version,
      "template_version" => @template_version,
      "graph_hash" => graph_hash,
      "plan_fingerprint" => plan_fingerprint,
      "plan_version" => plan.version,
      "task_class" => plan.task_class,
      "validation_profile" => plan.validation_profile,
      "review_profile" => plan.review_profile,
      "overlays" => plan.overlays,
      "action_catalog_digest" => catalog_digest,
      "execution_manifest" => execution_manifest,
      "execution_manifest_digest" => execution_manifest_digest,
      "action_names" => generated_action_names(graph),
      "handler_types" => generated_handler_types(graph)
    }
  end

  defp generated_action_names(%Graph{} = graph) do
    graph.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      case Registry.node_type(node) do
        "exec" ->
          if Map.get(node.attrs, "target") == "action" do
            [Map.fetch!(node.attrs, "action")]
          else
            []
          end

        "compute" ->
          if Map.get(node.attrs, "use_tools") in [true, "true"] do
            node.attrs
            |> Map.get("tools", "")
            |> String.split(",", trim: true)
            |> Enum.map(&String.trim/1)
          else
            []
          end

        _other ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp generated_handler_types(%Graph{} = graph) do
    graph.nodes
    |> Map.values()
    |> Enum.map(&Registry.node_type/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fingerprint(term, _label) do
    case canonical_json(term) do
      {:ok, encoded} -> {:ok, sha256(encoded)}
      {:error, reason} -> {:error, {:canonical_json_failed, reason}}
    end
  end

  defp canonical_json(term) do
    term
    |> canonicalize()
    |> Jason.encode()
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp json_clean?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} -> is_binary(key) and json_clean?(item) end)
  end

  defp json_clean?(_value), do: false
end
