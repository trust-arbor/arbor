defmodule Arbor.Orchestrator.CodingPlan.SemanticPreflight do
  @moduledoc """
  Pure semantic preflight for compiled coding graphs.

  Inventory checks alone are not enough: this module fails closed on reviewed
  handler/action forms, forbidden authority overrides, reachability of mandatory
  gates and publication terminals, and structural dominance of validation and
  review on successful/publication paths.

  Dominators are computed with the classic iterative data-flow algorithm, which
  is correct for directed graphs that contain cycles.
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Handlers.Registry

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type policy :: %{String.t() => json_value()}
  @type error_entry :: %{String.t() => json_value()}
  @type validate_error ::
          {:semantic_preflight_failed, [error_entry()]}
          | {:invalid_semantic_policy, term()}
          | :invalid_graph

  @required_policy_keys ~w(
    allowed_handlers
    allowed_exec_targets
    allowed_actions
    optional_actions
    mandatory_gate_nodes
    publication_nodes
    validation_gate
    validation_result_gate
    post_validation_commit_routing
    committed_change_routing
    review_gate
    review_routing_gate
    validation_profile
  )

  @security_policy_keys ~w(
    attestation_source
    committed_candidate_join
    committed_material_gate
    post_validation_exact_head_check
    post_validation_routing
  )

  @forbidden_attr_keys MapSet.new(~w(
    agent_id
    authorization
    authorizer
    capabilities
    identity
    identity_private_key
    middleware
    principal_id
    private_key
    signer
    signing_key
    graph
    graph_hash
    graph_path
    graph_source
    pipeline
    pipeline_path
    template_path
    dot
    dot_source
    engine
    engine_module
    action_executor
    actions_executor
  ))

  # Bare agent_id is a reviewed template output (prep_review_agent copies
  # session.agent_id into context). Nested paths like session.agent_id are
  # rejected via segment checks against authority names below.
  @forbidden_output_keys MapSet.new(~w(
    authorization
    authorizer
    capabilities
    identity
    identity_private_key
    middleware
    principal_id
    private_key
    signer
    signing_key
    graph
    graph_hash
    graph_path
    graph_source
    pipeline
    pipeline_path
    template_path
    engine
    engine_module
    action_executor
    actions_executor
  ))

  # Static DOT params are bound via arg.* / param.* prefixes. After stripping that
  # prefix the remaining name is checked against authority/control aliases.
  @static_param_prefix_re ~r/^(?:param|arg)[^A-Za-z0-9]+(.+)$/i

  @doc """
  Validate a compiled coding graph against a reviewed semantic policy.

  Options:
    * `:review_profile` — `"binding"`, `"human_required"`, or `"none"`.
      Binding/human require council-review dominance over every reachable
      changed success/publication terminal. Legacy `"none"` skips that proof.
  """
  @spec validate(Graph.t(), policy(), keyword()) :: :ok | {:error, validate_error()}
  def validate(graph, policy, opts \\ [])

  def validate(%Graph{} = graph, policy, opts) when is_map(policy) and is_list(opts) do
    with {:ok, policy} <- normalize_policy(policy),
         {:ok, review_profile} <- normalize_review_profile(opts),
         :ok <- require_compiled(graph) do
      errors =
        []
        |> check_handlers_and_targets(graph, policy)
        |> check_actions(graph, policy)
        |> check_forbidden_authority(graph)
        |> check_profile_bindings(graph, policy, review_profile)
        |> check_reachability_and_dominance(graph, policy, review_profile)
        |> Enum.sort_by(&error_sort_key/1)

      if errors == [] do
        :ok
      else
        {:error, {:semantic_preflight_failed, errors}}
      end
    end
  end

  def validate(_graph, _policy, _opts), do: {:error, :invalid_graph}

  # --- policy normalization -------------------------------------------------

  defp normalize_policy(policy) when is_map(policy) do
    missing =
      @required_policy_keys
      |> Enum.reject(&Map.has_key?(policy, &1))
      |> Enum.sort()

    cond do
      missing != [] ->
        {:error, {:invalid_semantic_policy, {:missing_keys, missing}}}

      not Enum.all?(policy, fn {k, _v} -> is_binary(k) end) ->
        {:error, {:invalid_semantic_policy, :non_string_keys}}

      true ->
        with :ok <- require_string_list(policy, "allowed_handlers"),
             :ok <- require_string_list(policy, "allowed_exec_targets"),
             :ok <- require_string_list(policy, "allowed_actions"),
             :ok <- require_string_list(policy, "optional_actions"),
             :ok <- require_string_list(policy, "mandatory_gate_nodes"),
             :ok <- require_string_list(policy, "publication_nodes"),
             :ok <- require_nonempty_string(policy, "validation_gate"),
             :ok <- require_nonempty_string(policy, "validation_result_gate"),
             :ok <- require_nonempty_string(policy, "post_validation_commit_routing"),
             :ok <- require_nonempty_string(policy, "committed_change_routing"),
             :ok <- require_nonempty_string(policy, "review_gate"),
             :ok <- require_nonempty_string(policy, "review_routing_gate"),
             :ok <- require_nonempty_string(policy, "validation_profile"),
             :ok <- require_profile_policy(policy),
             :ok <- require_sorted_unique(policy, "allowed_handlers"),
             :ok <- require_sorted_unique(policy, "allowed_exec_targets"),
             :ok <- require_sorted_unique(policy, "allowed_actions"),
             :ok <- require_sorted_unique(policy, "optional_actions"),
             :ok <- require_sorted_unique(policy, "mandatory_gate_nodes"),
             :ok <- require_sorted_unique(policy, "publication_nodes"),
             :ok <- require_optional_subset(policy) do
          {:ok, policy}
        end
    end
  end

  defp normalize_policy(_policy), do: {:error, {:invalid_semantic_policy, :expected_map}}

  defp require_string_list(policy, key) do
    case Map.fetch!(policy, key) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          :ok
        else
          {:error, {:invalid_semantic_policy, {:invalid_string_list, key}}}
        end

      _other ->
        {:error, {:invalid_semantic_policy, {:invalid_string_list, key}}}
    end
  end

  defp require_nonempty_string(policy, key) do
    case Map.fetch!(policy, key) do
      value when is_binary(value) and value != "" -> :ok
      _other -> {:error, {:invalid_semantic_policy, {:invalid_string, key}}}
    end
  end

  defp require_sorted_unique(policy, key) do
    list = Map.fetch!(policy, key)

    cond do
      list != Enum.sort(list) ->
        {:error, {:invalid_semantic_policy, {:unsorted_list, key}}}

      length(list) != length(Enum.uniq(list)) ->
        {:error, {:invalid_semantic_policy, {:duplicate_list_entries, key}}}

      true ->
        :ok
    end
  end

  defp require_optional_subset(policy) do
    allowed = MapSet.new(policy["allowed_actions"])
    optional = policy["optional_actions"]

    missing = Enum.reject(optional, &MapSet.member?(allowed, &1))

    if missing == [] do
      :ok
    else
      {:error, {:invalid_semantic_policy, {:optional_actions_not_allowed, Enum.sort(missing)}}}
    end
  end

  defp require_profile_policy(%{"validation_profile" => "security_regression"} = policy) do
    Enum.reduce_while(@security_policy_keys, :ok, fn key, :ok ->
      case require_nonempty_string(policy, key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp require_profile_policy(_policy), do: :ok

  defp normalize_review_profile(opts) do
    if not Keyword.keyword?(opts) do
      {:error, {:invalid_semantic_policy, :invalid_options}}
    else
      case Keyword.get(opts, :review_profile, "binding") do
        profile when profile in ["binding", "human_required", "none"] ->
          {:ok, profile}

        other ->
          {:error, {:invalid_semantic_policy, {:invalid_review_profile, other}}}
      end
    end
  end

  defp require_compiled(%Graph{compiled: true}), do: :ok
  defp require_compiled(%Graph{}), do: {:error, :invalid_graph}

  # --- handler / target / action policy -------------------------------------

  defp check_handlers_and_targets(errors, graph, policy) do
    allowed_handlers = MapSet.new(policy["allowed_handlers"])
    allowed_targets = MapSet.new(policy["allowed_exec_targets"])

    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(errors, fn {node_id, node}, acc ->
      handler = Registry.node_type(node)

      acc =
        if MapSet.member?(allowed_handlers, handler) do
          acc
        else
          [
            error("forbidden_handler", node_id, %{"handler" => handler})
            | acc
          ]
        end

      if handler == "exec" do
        target = Map.get(node.attrs, "target") || "tool"

        if MapSet.member?(allowed_targets, target) do
          acc
        else
          [
            error("forbidden_exec_target", node_id, %{"target" => target})
            | acc
          ]
        end
      else
        acc
      end
    end)
  end

  defp check_actions(errors, graph, policy) do
    allowed = MapSet.new(policy["allowed_actions"])

    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(errors, fn {node_id, node}, acc ->
      if Registry.node_type(node) == "exec" do
        action = Map.get(node.attrs, "action")

        cond do
          not is_binary(action) or action == "" ->
            [error("missing_action", node_id, %{}) | acc]

          MapSet.member?(allowed, action) ->
            acc

          true ->
            [
              error("forbidden_action", node_id, %{"action" => action})
              | acc
            ]
        end
      else
        acc
      end
    end)
  end

  defp check_forbidden_authority(errors, graph) do
    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(errors, fn {node_id, node}, acc ->
      attr_hits =
        node.attrs
        |> Map.keys()
        |> Enum.filter(&forbidden_attr_key?/1)
        |> Enum.sort()

      acc =
        Enum.reduce(attr_hits, acc, fn key, inner ->
          [error("forbidden_authority_attribute", node_id, %{"attribute" => key}) | inner]
        end)

      output_hits =
        authority_output_keys(node.attrs)
        |> Enum.sort()

      Enum.reduce(output_hits, acc, fn key, inner ->
        [error("forbidden_authority_output", node_id, %{"output_key" => key}) | inner]
      end)
    end)
  end

  defp forbidden_attr_key?(key) when is_binary(key) do
    # Bare authority attrs and static action params (param.*/arg.*) both fail closed.
    key
    |> authority_name_candidates()
    |> Enum.any?(&forbidden_authority_name?/1)
  end

  defp forbidden_attr_key?(_key), do: false

  defp authority_output_keys(attrs) when is_map(attrs) do
    for {attr, value} <- attrs,
        attr in ["output_key", "output_prefix"],
        is_binary(value),
        value != "",
        forbidden_output_key?(value),
        do: value
  end

  defp forbidden_output_key?(key) when is_binary(key) do
    normalized = normalize_key(key)

    cond do
      MapSet.member?(@forbidden_output_keys, normalized) ->
        true

      output_authority_prefix?(normalized) ->
        true

      true ->
        # Nested paths (session.agent_id, Session/Principal-Id, …) fail closed
        # when any segment is an authority/control name. Bare agent_id stays
        # allowed for the reviewed prep_review_agent copy.
        case path_segments(key) do
          [] ->
            false

          [_single] ->
            false

          segments ->
            Enum.any?(segments, &forbidden_output_path_segment?/1)
        end
    end
  end

  defp forbidden_output_key?(_key), do: false

  defp authority_name_candidates(key) when is_binary(key) do
    stripped = strip_static_param_prefix(key)

    [key, stripped]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_static_param_prefix(key) when is_binary(key) do
    case Regex.run(@static_param_prefix_re, key) do
      [_, rest] when is_binary(rest) and rest != "" -> rest
      _other -> key
    end
  end

  # Path segments use structural separators only (., /). Underscores stay inside
  # names so agent_id remains one segment (not agent + id).
  defp path_segments(key) when is_binary(key) do
    key
    |> String.split(~r/[.\/]+/u, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp forbidden_authority_name?(name) when is_binary(name) do
    normalized = normalize_key(name)

    MapSet.member?(@forbidden_attr_keys, normalized) or
      String.starts_with?(normalized, "middleware_") or
      dotted_authority_prefix?(name)
  end

  defp forbidden_output_path_segment?(segment) when is_binary(segment) do
    normalized = normalize_key(segment)

    MapSet.member?(@forbidden_attr_keys, normalized) or
      MapSet.member?(@forbidden_output_keys, normalized) or
      output_authority_prefix?(normalized)
  end

  defp output_authority_prefix?(normalized) when is_binary(normalized) do
    String.starts_with?(normalized, "middleware") or
      String.starts_with?(normalized, "authorization") or
      String.starts_with?(normalized, "capabilities") or
      String.starts_with?(normalized, "signing") or
      String.starts_with?(normalized, "private_key")
  end

  defp dotted_authority_prefix?(key) when is_binary(key) do
    down = String.downcase(key)

    String.starts_with?(down, "middleware.") or
      String.starts_with?(down, "authorization.") or
      String.starts_with?(down, "capabilities.")
  end

  defp normalize_key(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  # --- profile-specific reviewed bindings ----------------------------------

  defp check_profile_bindings(errors, _graph, %{"validation_profile" => "default"}, _review),
    do: errors

  defp check_profile_bindings(
         errors,
         graph,
         %{"validation_profile" => "security_regression"},
         review_profile
       ) do
    errors
    |> reject_security_review_none(review_profile)
    |> check_security_node_bindings(graph)
    |> check_security_validator_parameters(graph)
    |> check_security_protected_writers(graph)
    |> check_security_topology(graph, review_profile)
  end

  defp check_profile_bindings(errors, _graph, _policy, _review_profile), do: errors

  defp reject_security_review_none(errors, "none") do
    [
      error("security_review_profile_forbidden", nil, %{
        "review_profile" => "none"
      })
      | errors
    ]
  end

  defp reject_security_review_none(errors, _review_profile), do: errors

  defp check_security_node_bindings(errors, graph) do
    expected = [
      {"hoist_workspace_id",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "workspace.workspace_id",
         "output_key" => "workspace_id"
       }},
      {"prep_expected_commit",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "commit_hash",
         "output_key" => "commit"
       }},
      {"load_committed_change",
       %{
         "type" => "exec",
         "target" => "action",
         "action" => "coding_workspace_committed_change",
         "context_keys" => "workspace_id,commit",
         "output_prefix" => "change"
       }},
      {"prep_review_diff",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "change.diff",
         "output_key" => "diff"
       }},
      {"prep_review_files",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "change.files",
         "output_key" => "files"
       }},
      {"prep_review_validation_profile",
       %{
         "type" => "transform",
         "transform" => "constant",
         "expression" => "security_regression",
         "output_key" => "validation_profile"
       }},
      {"review_change",
       %{
         "type" => "exec",
         "target" => "action",
         "action" => "council_review_change",
         "context_keys" =>
           "diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash,test_paths,validation_profile",
         "output_prefix" => "review"
       }},
      {"remember_validation_reviewed_commit",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "commit_hash",
         "output_key" => "prior_reviewed_commit"
       }},
      {"remember_review_reviewed_commit",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "commit_hash",
         "output_key" => "prior_reviewed_commit"
       }},
      {"hoist_review_attestation_id",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "review.review_attestation_id",
         "output_key" => "review_attestation_id"
       }},
      {"validate",
       %{
         "type" => "exec",
         "target" => "action",
         "action" => "coding_security_regression_validate",
         "context_keys" => "review_attestation_id",
         "output_prefix" => "validation"
       }},
      {"post_validation_expected_commit",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "commit_hash",
         "output_key" => "commit"
       }},
      {"post_validation_committed_change",
       %{
         "type" => "exec",
         "target" => "action",
         "action" => "coding_workspace_committed_change",
         "context_keys" => "workspace_id,commit",
         "output_prefix" => "post_validation_change"
       }},
      {"compare_security_rework_commit",
       %{
         "type" => "transform",
         "transform" => "not_equal",
         "source_key" => "commit_hash",
         "expression" => "prior_reviewed_commit",
         "output_key" => "fresh_rework_commit"
       }},
      {"check_security_rework_fresh",
       %{
         "type" => "gate",
         "predicate" => "expression",
         "expression" => "fresh_rework_commit"
       }}
    ]

    Enum.reduce(expected, errors, fn {node_id, attrs}, acc ->
      require_security_node_attrs(acc, graph, node_id, attrs)
    end)
  end

  defp require_security_node_attrs(errors, graph, node_id, expected) do
    case Map.fetch(graph.nodes, node_id) do
      :error ->
        [error("security_binding_missing_node", node_id, %{}) | errors]

      {:ok, node} ->
        Enum.reduce(expected, errors, fn {attribute, expected_value}, acc ->
          actual = Map.get(node.attrs, attribute)

          if actual == expected_value do
            acc
          else
            [
              error("security_binding_mismatch", node_id, %{
                "attribute" => attribute,
                "expected" => expected_value,
                "actual" => actual
              })
              | acc
            ]
          end
        end)
    end
  end

  defp check_security_validator_parameters(errors, graph) do
    case Map.fetch(graph.nodes, "validate") do
      :error ->
        errors

      {:ok, node} ->
        actual =
          node.attrs
          |> Enum.filter(fn {key, _value} ->
            is_binary(key) and
              (String.starts_with?(key, "param.") or String.starts_with?(key, "arg."))
          end)
          |> Map.new()

        expected = %{}

        if actual == expected do
          errors
        else
          [
            error("security_validator_parameter_violation", "validate", %{
              "expected" => expected,
              "actual" => actual
            })
            | errors
          ]
        end
    end
  end

  defp check_security_protected_writers(errors, graph) do
    expected = [
      {"output_key", "workspace_id", ["hoist_workspace_id"]},
      {"output_key", "test_paths", []},
      {"output_key", "validation_profile", ["prep_review_validation_profile"]},
      {"output_prefix", "review", ["review_change"]},
      {"output_key", "review.review_attestation_id", []},
      {"output_key", "review_attestation_id", ["hoist_review_attestation_id"]},
      {"output_key", "prior_reviewed_commit",
       ["remember_review_reviewed_commit", "remember_validation_reviewed_commit"]},
      {"output_key", "fresh_rework_commit", ["compare_security_rework_commit"]},
      {"output_key", "commit", ["post_validation_expected_commit", "prep_expected_commit"]},
      {"output_key", "commit_hash",
       ["adopt_head_commit", "hoist_change_commit", "hoist_commit_hash"]},
      {"output_key", "diff", ["prep_review_diff"]},
      {"output_key", "files", ["prep_review_files"]}
    ]

    Enum.reduce(expected, errors, fn {attribute, key, expected_nodes}, acc ->
      actual_nodes = writer_nodes(graph, attribute, key)
      expected_nodes = Enum.sort(expected_nodes)

      if actual_nodes == expected_nodes do
        acc
      else
        [
          error("security_protected_writer_violation", nil, %{
            "attribute" => attribute,
            "context_key" => key,
            "expected_nodes" => expected_nodes,
            "actual_nodes" => actual_nodes
          })
          | acc
        ]
      end
    end)
  end

  defp writer_nodes(graph, attribute, key) do
    graph.nodes
    |> Enum.flat_map(fn {node_id, node} ->
      if Map.get(node.attrs, attribute) == key, do: [node_id], else: []
    end)
    |> Enum.sort()
  end

  defp check_security_topology(errors, graph, review_profile) do
    validated_review_edges =
      case review_profile do
        "human_required" ->
          [
            {"route_human_review", "context.review.tier_decision=auto_proceed"},
            {"route_human_review", "context.review.tier_decision=human_review"},
            {"error_review_tier_invalid", nil}
          ]

        _other ->
          [
            {"route_publish", "context.review.tier_decision=auto_proceed"},
            {"route_human_review", "context.review.tier_decision=human_review"},
            {"error_review_tier_invalid", nil}
          ]
      end

    expected = [
      {"hoist_commit_hash", [{"route_security_after_commit", nil}]},
      {"adopt_head_commit", [{"route_security_after_commit", nil}]},
      {"route_security_after_commit",
       [
         {"route_after_commit", "context.total_rework_count=0"},
         {"compare_security_rework_commit", "context.total_rework_count>0"}
       ]},
      {"compare_security_rework_commit", [{"check_security_rework_fresh", nil}]},
      {"check_security_rework_fresh",
       [
         {"route_after_commit", "outcome=success"},
         {"error_security_rework_not_fresh", "outcome=fail"}
       ]},
      {"route_after_commit", [{"prep_expected_commit", "context.submit_review!=false"}]},
      {"prep_expected_commit", [{"load_committed_change", nil}]},
      {"load_committed_change",
       [
         {"error_committed_change_materialization", "outcome=fail"},
         {"hoist_change_commit", "outcome=success"}
       ]},
      {"prep_review_validation_profile", [{"review_change", nil}]},
      {"review_change",
       [
         {"error_council_review", "outcome=fail"},
         {"route_review", "outcome=success"}
       ]},
      {"route_review",
       [
         {"remember_review_reviewed_commit", "context.review.tier_decision=rework"},
         {"status_review_rejected", "context.review.tier_decision=stop"},
         {"hoist_review_attestation_id", "context.review.tier_decision=human_review"},
         {"hoist_review_attestation_id", "context.review.tier_decision=auto_proceed"},
         {"error_review_tier_invalid", nil}
       ]},
      {"remember_review_reviewed_commit", [{"check_review_category_budget", nil}]},
      {"hoist_review_attestation_id", [{"validate", nil}]},
      {"validate",
       [
         {"status_validation_failed", "outcome=fail"},
         {"check_validation_passed", "outcome=success"}
       ]},
      {"check_validation_passed",
       [
         {"remember_validation_reviewed_commit", "outcome=fail"},
         {"post_validation_expected_commit", "outcome=success"}
       ]},
      {"remember_validation_reviewed_commit", [{"check_validation_category_budget", nil}]},
      {"post_validation_expected_commit", [{"post_validation_committed_change", nil}]},
      {"post_validation_committed_change",
       [
         {"error_post_validation_committed_change", "outcome=fail"},
         {"route_validated_review", "outcome=success"}
       ]},
      {"route_validated_review", validated_review_edges}
    ]

    Enum.reduce(expected, errors, fn {node_id, outgoing}, acc ->
      require_exact_security_outgoing(acc, graph, node_id, outgoing)
    end)
  end

  defp require_exact_security_outgoing(errors, graph, node_id, expected) do
    actual =
      graph.edges
      |> Enum.flat_map(fn edge ->
        if edge.from == node_id do
          [{edge.to, Map.get(edge.attrs, "condition")}]
        else
          []
        end
      end)
      |> Enum.sort()

    expected = Enum.sort(expected)

    if actual == expected do
      errors
    else
      [
        error("security_topology_mismatch", node_id, %{
          "expected" => Enum.map(expected, &edge_binding_to_json/1),
          "actual" => Enum.map(actual, &edge_binding_to_json/1)
        })
        | errors
      ]
    end
  end

  defp edge_binding_to_json({target, condition}), do: [target, condition]

  # --- reachability + dominance ---------------------------------------------

  defp check_reachability_and_dominance(errors, graph, policy, review_profile) do
    case Graph.find_start_node(graph) do
      nil ->
        [error("missing_start", nil, %{}) | errors]

      start_node ->
        entry = start_node.id
        reachable = reachable_from(graph, entry)
        dominators = compute_dominators(graph, entry, reachable)

        errors
        |> check_mandatory_gates(policy, reachable)
        |> check_publication_presence(policy, reachable, review_profile)
        |> check_dominance(
          policy,
          dominators,
          reachable,
          review_profile
        )
        |> check_security_rework_dominance(graph, policy)
    end
  end

  defp check_mandatory_gates(errors, policy, reachable) do
    Enum.reduce(policy["mandatory_gate_nodes"], errors, fn node_id, acc ->
      if MapSet.member?(reachable, node_id) do
        acc
      else
        [error("unreachable_mandatory_gate", node_id, %{}) | acc]
      end
    end)
  end

  defp check_publication_presence(errors, policy, reachable, review_profile) do
    publication = policy["publication_nodes"]
    reachable_publication = Enum.filter(publication, &MapSet.member?(reachable, &1))

    # Legacy none and binding/human all need at least one changed success or
    # publication terminal reachable so the changed path is not a dead end.
    if review_profile in ["binding", "human_required", "none"] and reachable_publication == [] do
      [
        error("unreachable_publication", nil, %{
          "publication_nodes" => publication
        })
        | errors
      ]
    else
      errors
    end
  end

  defp check_dominance(errors, policy, dominators, reachable, review_profile) do
    if policy["validation_profile"] == "security_regression" do
      check_security_dominance(errors, policy, dominators, reachable)
    else
      check_default_dominance(errors, policy, dominators, reachable, review_profile)
    end
  end

  defp check_default_dominance(errors, policy, dominators, reachable, review_profile) do
    validation_gate = policy["validation_gate"]
    validation_result_gate = policy["validation_result_gate"]
    post_validation = policy["post_validation_commit_routing"]
    committed_routing = policy["committed_change_routing"]
    review_gate = policy["review_gate"]
    review_routing_gate = policy["review_routing_gate"]
    # Reviewed coding template commit node; always mandatory in policy inventories.
    commit_gate = "commit_change"

    publication_targets =
      policy["publication_nodes"]
      |> Enum.filter(&MapSet.member?(reachable, &1))
      |> Enum.sort()

    # validate dominates the validation-result gate; that gate dominates both
    # commit_change and post-validation commit routing. Keep validate ->
    # route_after_commit as a direct proof for the changed success path.
    errors =
      errors
      |> require_dominates(
        validation_gate,
        validation_result_gate,
        reachable,
        dominators,
        "validation"
      )
      |> require_dominates(
        validation_result_gate,
        commit_gate,
        reachable,
        dominators,
        "validation_result"
      )
      |> require_dominates(
        validation_result_gate,
        post_validation,
        reachable,
        dominators,
        "validation_result"
      )
      |> require_dominates(
        validation_gate,
        post_validation,
        reachable,
        dominators,
        "validation"
      )

    # Committed-change routing dominates every reachable publication terminal,
    # and the review gate when review is required.
    errors =
      Enum.reduce(publication_targets, errors, fn target, acc ->
        require_dominates(
          acc,
          committed_routing,
          target,
          reachable,
          dominators,
          "committed_change_routing"
        )
      end)

    if review_profile in ["binding", "human_required"] do
      errors
      |> require_dominates(
        committed_routing,
        review_gate,
        reachable,
        dominators,
        "committed_change_routing"
      )
      |> require_dominates(
        review_gate,
        review_routing_gate,
        reachable,
        dominators,
        "review"
      )
      |> then(fn acc ->
        Enum.reduce(publication_targets, acc, fn target, inner ->
          inner
          |> require_dominates(
            review_routing_gate,
            target,
            reachable,
            dominators,
            "review_routing"
          )
          |> require_dominates(review_gate, target, reachable, dominators, "review")
        end)
      end)
    else
      errors
    end
  end

  defp check_security_dominance(errors, policy, dominators, reachable) do
    committed_candidate_join = policy["committed_candidate_join"]
    committed_join = policy["committed_change_routing"]
    committed_material = policy["committed_material_gate"]
    review_gate = policy["review_gate"]
    review_routing = policy["review_routing_gate"]
    attestation_source = policy["attestation_source"]
    validator = policy["validation_gate"]
    validator_result = policy["validation_result_gate"]
    post_validation_check = policy["post_validation_exact_head_check"]
    post_validation_routing = policy["post_validation_routing"]

    chain = [
      {committed_candidate_join, committed_join, "committed_candidate_join"},
      {committed_join, committed_material, "committed_join"},
      {committed_material, review_gate, "committed_material"},
      {review_gate, review_routing, "review"},
      {review_routing, attestation_source, "review_routing"},
      {attestation_source, validator, "review_attestation"},
      {validator, validator_result, "validation"},
      {validator_result, post_validation_check, "validation_result"},
      {post_validation_check, post_validation_routing, "post_validation_exact_head"}
    ]

    errors =
      Enum.reduce(chain, errors, fn {dominator, node, kind}, acc ->
        require_dominates(acc, dominator, node, reachable, dominators, kind)
      end)

    publication_targets =
      policy["publication_nodes"]
      |> Enum.filter(&MapSet.member?(reachable, &1))
      |> Enum.sort()

    Enum.reduce(publication_targets, errors, fn target, acc ->
      acc
      |> require_dominates(
        post_validation_check,
        target,
        reachable,
        dominators,
        "post_validation_exact_head"
      )
      |> require_dominates(
        post_validation_routing,
        target,
        reachable,
        dominators,
        "post_validation_routing"
      )
      |> require_dominates(review_gate, target, reachable, dominators, "review")
      |> require_dominates(validator, target, reachable, dominators, "validation")
    end)
  end

  defp check_security_rework_dominance(
         errors,
         graph,
         %{"validation_profile" => "security_regression"} = policy
       ) do
    rework_graph = security_rework_graph(graph)

    entries = [
      {"remember_review_reviewed_commit", "review_rework"},
      {"remember_validation_reviewed_commit", "validation_rework"}
    ]

    chain = [
      {"compare_security_rework_commit", "check_security_rework_fresh", "fresh_commit_compare"},
      {"check_security_rework_fresh", policy["committed_change_routing"], "fresh_commit_gate"},
      {policy["committed_change_routing"], policy["committed_material_gate"],
       "fresh_committed_material"},
      {policy["committed_material_gate"], policy["review_gate"], "fresh_review"},
      {policy["review_gate"], policy["review_routing_gate"], "fresh_review_routing"},
      {policy["review_routing_gate"], policy["attestation_source"], "fresh_attestation"},
      {policy["attestation_source"], policy["validation_gate"], "fresh_validation"},
      {policy["validation_gate"], policy["validation_result_gate"], "fresh_validation_result"},
      {policy["validation_result_gate"], policy["post_validation_exact_head_check"],
       "fresh_post_validation_exact_head"},
      {policy["post_validation_exact_head_check"], policy["post_validation_routing"],
       "fresh_post_validation_routing"}
    ]

    publication_targets = policy["publication_nodes"] |> Enum.sort()

    Enum.reduce(entries, errors, fn {entry, rework_kind}, acc ->
      reachable = reachable_from(rework_graph, entry)
      dominators = compute_dominators(rework_graph, entry, reachable)

      acc =
        Enum.reduce(chain, acc, fn {dominator, node, kind}, inner ->
          require_dominates(
            inner,
            dominator,
            node,
            reachable,
            dominators,
            "#{rework_kind}.#{kind}"
          )
        end)

      publication_targets
      |> Enum.filter(&MapSet.member?(reachable, &1))
      |> Enum.reduce(acc, fn target, inner ->
        inner
        |> require_dominates(
          policy["attestation_source"],
          target,
          reachable,
          dominators,
          "#{rework_kind}.fresh_attestation_terminal"
        )
        |> require_dominates(
          policy["validation_gate"],
          target,
          reachable,
          dominators,
          "#{rework_kind}.fresh_validation_terminal"
        )
        |> require_dominates(
          policy["validation_result_gate"],
          target,
          reachable,
          dominators,
          "#{rework_kind}.fresh_validation_result_terminal"
        )
        |> require_dominates(
          policy["post_validation_exact_head_check"],
          target,
          reachable,
          dominators,
          "#{rework_kind}.fresh_post_validation_exact_head_terminal"
        )
        |> require_dominates(
          policy["post_validation_routing"],
          target,
          reachable,
          dominators,
          "#{rework_kind}.fresh_post_validation_routing_terminal"
        )
      end)
    end)
  end

  defp check_security_rework_dominance(errors, _graph, _policy), do: errors

  defp security_rework_graph(graph) do
    edges =
      Enum.reject(graph.edges, fn edge ->
        edge.from == "route_security_after_commit" and edge.to == "route_after_commit" and
          Map.get(edge.attrs, "condition") == "context.total_rework_count=0"
      end)

    %{graph | edges: edges, adjacency: %{}, reverse_adjacency: %{}}
  end

  defp require_dominates(errors, dominator, node, reachable, dominators, kind) do
    cond do
      not MapSet.member?(reachable, node) ->
        # Unreachable targets are reported by reachability checks when mandatory.
        errors

      not MapSet.member?(reachable, dominator) ->
        [
          error("unreachable_dominator", dominator, %{
            "kind" => kind,
            "target" => node
          })
          | errors
        ]

      dominates?(dominators, dominator, node) ->
        errors

      true ->
        [
          error("dominance_violation", node, %{
            "kind" => kind,
            "required_dominator" => dominator
          })
          | errors
        ]
    end
  end

  defp dominates?(dominators, dominator, node) do
    case Map.fetch(dominators, node) do
      {:ok, set} -> MapSet.member?(set, dominator)
      :error -> false
    end
  end

  # --- graph algorithms -----------------------------------------------------

  defp reachable_from(%Graph{} = graph, entry) do
    do_reachable(graph, [entry], MapSet.new())
  end

  defp do_reachable(_graph, [], visited), do: visited

  defp do_reachable(graph, [node_id | rest], visited) do
    if MapSet.member?(visited, node_id) or not Map.has_key?(graph.nodes, node_id) do
      do_reachable(graph, rest, visited)
    else
      next =
        graph
        |> Graph.outgoing_edges(node_id)
        |> Enum.map(& &1.to)

      do_reachable(graph, rest ++ next, MapSet.put(visited, node_id))
    end
  end

  # Iterative data-flow dominators. Correct in the presence of cycles: a node d
  # dominates n iff every path from entry to n goes through d.
  defp compute_dominators(%Graph{} = graph, entry, reachable) do
    preds =
      reachable
      |> Enum.reduce(%{}, fn node_id, acc ->
        Map.put(acc, node_id, reachable_predecessors(graph, node_id, reachable))
      end)

    init =
      Map.new(reachable, fn node_id ->
        if node_id == entry do
          {node_id, MapSet.new([entry])}
        else
          {node_id, reachable}
        end
      end)

    iterate_dominators(init, preds, entry, reachable)
  end

  defp reachable_predecessors(graph, node_id, reachable) do
    graph
    |> Graph.incoming_edges(node_id)
    |> Enum.map(& &1.from)
    |> Enum.filter(&MapSet.member?(reachable, &1))
  end

  defp iterate_dominators(dom, preds, entry, reachable) do
    {next, changed?} =
      reachable
      |> Enum.sort()
      |> Enum.reduce({dom, false}, fn node_id, {acc, changed?} ->
        if node_id == entry do
          {acc, changed?}
        else
          predecessors = Map.get(preds, node_id, [])

          intersection =
            case predecessors do
              [] ->
                MapSet.new()

              [first | rest] ->
                Enum.reduce(rest, Map.get(acc, first, MapSet.new()), fn pred, set ->
                  MapSet.intersection(set, Map.get(acc, pred, MapSet.new()))
                end)
            end

          new_set = MapSet.put(intersection, node_id)
          old_set = Map.fetch!(acc, node_id)

          if MapSet.equal?(old_set, new_set) do
            {acc, changed?}
          else
            {Map.put(acc, node_id, new_set), true}
          end
        end
      end)

    if changed?, do: iterate_dominators(next, preds, entry, reachable), else: next
  end

  # --- error helpers --------------------------------------------------------

  defp error(code, node_id, detail) when is_binary(code) and is_map(detail) do
    base = %{"code" => code, "detail" => detail}

    if is_binary(node_id) do
      Map.put(base, "node_id", node_id)
    else
      base
    end
  end

  defp error_sort_key(%{"code" => code} = err) do
    {code, Map.get(err, "node_id", ""), Jason.encode!(Map.get(err, "detail", %{}))}
  end
end
