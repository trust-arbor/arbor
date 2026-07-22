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

  @max_source_bytes 262_144
  @max_graph_nodes 256
  @max_graph_edges 512
  @max_node_id_bytes 512
  @max_attribute_container_bytes 131_072
  @max_serialized_attributes_bytes 1_048_576

  @required_policy_keys ~w(
    allowed_handlers
    allowed_exec_targets
    allowed_actions
    optional_actions
    action_placements
    mandatory_gate_nodes
    publication_nodes
    validation_gate
    validation_result_gate
    post_validation_commit_routing
    committed_change_routing
    review_gate
    review_routing_gate
    validation_profile
    worker_recovery
    review_convergence
  )

  @placement_entry_keys MapSet.new(~w(
    node_id
    action
    required_dominators
    review_required_dominators
    required_dominator_sets
  ))

  @security_policy_keys ~w(
    attestation_source
    committed_candidate_join
    committed_material_gate
    post_validation_exact_head_check
    post_validation_routing
  )

  # Only this explicit human handoff may skip attestation. Every current or
  # future publication terminal defaults to the stricter unattended checks.
  @human_handoff_publication_node "status_human_review_required"

  @attestation_present ~s(context.review.review_attestation_id!="")
  @attestation_absent ~s(context.review.review_attestation_id="")

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
    * `:worker_use_pool` and `:worker_resume_session_id` — when both are
      supplied by the reviewed plan boundary, bind `open_worker`'s static ACP
      continuity parameters to that exact normalized plan.
    * `:rework_max_cycles` — required integer from `0` through `2`, bound to the
      normalized plan. Every shared-total rework gate must use this threshold.
    * `:validation_timeout_ms` — required positive integer derived from the
      normalized plan and reviewed profile per-operation ceiling. Validation
      nodes must bind this exact value.
    * `:validation_test_stage_timeout_ms` — optional positive integer for
      profiles with a reviewed aggregate test-stage ceiling (cross_app). When
      present, `param.test_stage_timeout` must match exactly.
  """
  @spec validate(Graph.t(), policy(), keyword()) :: :ok | {:error, validate_error()}
  def validate(graph, policy, opts \\ [])

  def validate(%Graph{} = graph, policy, opts) when is_map(policy) and is_list(opts) do
    with {:ok, graph} <- prepare_graph(graph),
         {:ok, policy} <- normalize_policy(policy),
         {:ok, review_profile} <- normalize_review_profile(opts),
         {:ok, worker_continuity} <- normalize_worker_continuity(opts),
         {:ok, rework_max_cycles} <- normalize_rework_max_cycles(opts),
         {:ok, validation_timeout_ms} <- normalize_validation_timeout_ms(opts),
         {:ok, validation_test_stage_timeout_ms} <-
           normalize_validation_test_stage_timeout_ms(opts),
         :ok <- require_compiled(graph) do
      errors =
        []
        |> check_handlers_and_targets(graph, policy)
        |> check_actions(graph, policy)
        |> check_action_placement_bindings(graph, policy)
        |> check_commit_approval_gate(graph)
        |> check_operator_approval_routing(graph)
        |> check_forbidden_authority(graph)
        |> check_forbidden_denial_bypass_attrs(graph)
        |> check_worker_continuity_bindings(graph, worker_continuity)
        |> check_worker_recovery_bindings(graph, policy, worker_continuity)
        |> check_review_convergence_bindings(graph, policy, rework_max_cycles)
        |> check_workspace_cleanup_topology(graph)
        |> check_profile_bindings(
          graph,
          policy,
          review_profile,
          validation_timeout_ms,
          validation_test_stage_timeout_ms
        )
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

  @doc "Reject a coding graph source before parsing when it exceeds the reviewed ceiling."
  @spec validate_source(binary()) ::
          :ok | {:error, {:graph_source_too_large, non_neg_integer(), pos_integer()}}
  def validate_source(source) when is_binary(source) do
    size = byte_size(source)

    if size <= @max_source_bytes do
      :ok
    else
      {:error, {:graph_source_too_large, size, @max_source_bytes}}
    end
  end

  def validate_source(_source), do: {:error, :invalid_graph_source}

  # --- graph boundary ------------------------------------------------------

  defp prepare_graph(%Graph{nodes: nodes, edges: edges} = graph)
       when is_map(nodes) and is_list(edges) do
    count_errors =
      []
      |> check_count_limit("nodes", map_size(nodes), @max_graph_nodes)
      |> check_count_limit("edges", length(edges), @max_graph_edges)

    if count_errors == [] do
      errors =
        []
        |> check_node_boundary(nodes)
        |> check_edge_boundary(edges, nodes)
        |> check_attribute_boundaries(graph)

      if errors == [] do
        {adjacency, reverse_adjacency} = canonical_adjacency(edges)
        {:ok, %{graph | adjacency: adjacency, reverse_adjacency: reverse_adjacency}}
      else
        {:error, {:semantic_preflight_failed, Enum.sort_by(errors, &error_sort_key/1)}}
      end
    else
      {:error, {:semantic_preflight_failed, Enum.sort_by(count_errors, &error_sort_key/1)}}
    end
  end

  defp prepare_graph(%Graph{}) do
    {:error, {:semantic_preflight_failed, [error("malformed_graph", nil, %{})]}}
  end

  defp check_count_limit(errors, resource, count, maximum) do
    if count <= maximum do
      errors
    else
      [
        error("graph_limit_exceeded", nil, %{
          "resource" => resource,
          "count" => count,
          "maximum" => maximum
        })
        | errors
      ]
    end
  end

  defp check_node_boundary(errors, nodes) do
    nodes
    |> Enum.sort_by(fn {id, _node} -> inspect(id) end)
    |> Enum.reduce(errors, fn
      {node_id, %Graph.Node{id: node_id, attrs: attrs}}, acc
      when is_binary(node_id) and is_map(attrs) and byte_size(node_id) <= @max_node_id_bytes ->
        acc

      {node_id, _node}, acc ->
        [error("malformed_graph_node", valid_node_id(node_id), %{}) | acc]
    end)
  end

  defp check_edge_boundary(errors, edges, nodes) do
    edges
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {%Graph.Edge{from: from, to: to, attrs: attrs}, _index}, acc
      when is_binary(from) and is_binary(to) and is_map(attrs) and
             byte_size(from) <= @max_node_id_bytes and byte_size(to) <= @max_node_id_bytes ->
        if Map.has_key?(nodes, from) and Map.has_key?(nodes, to) do
          acc
        else
          [error("malformed_graph_edge", from, %{"to" => to}) | acc]
        end

      {_edge, index}, acc ->
        [error("malformed_graph_edge", nil, %{"edge_index" => index}) | acc]
    end)
  end

  defp check_attribute_boundaries(errors, graph) do
    containers =
      [
        {"graph", nil, graph.attrs},
        {"node_defaults", nil, graph.node_defaults},
        {"edge_defaults", nil, graph.edge_defaults},
        {"subgraphs", nil, graph.subgraphs}
      ] ++
        Enum.map(graph.nodes, fn {node_id, node} -> {"node", node_id, node.attrs} end) ++
        Enum.with_index(graph.edges, fn edge, index -> {"edge", index, edge.attrs} end)

    {errors, total} =
      Enum.reduce(containers, {errors, 0}, fn {kind, owner, attrs}, {acc, total} ->
        case serialized_size(attrs) do
          {:ok, size} when size <= @max_attribute_container_bytes ->
            {acc, total + size}

          {:ok, size} ->
            detail = %{
              "resource" => "attribute_container",
              "kind" => kind,
              "bytes" => size,
              "maximum" => @max_attribute_container_bytes
            }

            {[error("graph_limit_exceeded", attribute_owner(owner), detail) | acc], total + size}

          :error ->
            {[
               error("malformed_graph_attributes", attribute_owner(owner), %{"kind" => kind})
               | acc
             ], total}
        end
      end)

    if total <= @max_serialized_attributes_bytes do
      errors
    else
      [
        error("graph_limit_exceeded", nil, %{
          "resource" => "serialized_attributes",
          "bytes" => total,
          "maximum" => @max_serialized_attributes_bytes
        })
        | errors
      ]
    end
  end

  defp serialized_size(term) do
    {:ok, :erlang.external_size(term)}
  rescue
    _error -> :error
  end

  defp canonical_adjacency(edges) do
    Enum.reduce(edges, {%{}, %{}}, fn edge, {adjacency, reverse_adjacency} ->
      {
        Map.update(adjacency, edge.from, [edge], &[edge | &1]),
        Map.update(reverse_adjacency, edge.to, [edge], &[edge | &1])
      }
    end)
  end

  defp valid_node_id(node_id) when is_binary(node_id), do: node_id
  defp valid_node_id(_node_id), do: nil
  defp attribute_owner(owner) when is_binary(owner), do: owner
  defp attribute_owner(_owner), do: nil

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
             :ok <- require_worker_recovery_policy(policy),
             :ok <- require_review_convergence_policy(policy),
             :ok <- require_action_placements(policy),
             :ok <- require_profile_policy(policy),
             :ok <- require_sorted_unique(policy, "allowed_handlers"),
             :ok <- require_sorted_unique(policy, "allowed_exec_targets"),
             :ok <- require_sorted_unique(policy, "allowed_actions"),
             :ok <- require_sorted_unique(policy, "optional_actions"),
             :ok <- require_sorted_unique(policy, "mandatory_gate_nodes"),
             :ok <- require_sorted_unique(policy, "publication_nodes"),
             :ok <- require_optional_subset(policy),
             :ok <- require_placement_actions_allowed(policy) do
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

  defp require_action_placements(policy) do
    case Map.fetch!(policy, "action_placements") do
      placements when is_list(placements) ->
        with :ok <- validate_placement_entries(placements),
             :ok <- require_placements_sorted_unique(placements) do
          :ok
        end

      _other ->
        {:error, {:invalid_semantic_policy, {:invalid_action_placements, "action_placements"}}}
    end
  end

  defp validate_placement_entries(placements) do
    Enum.reduce_while(placements, :ok, fn entry, :ok ->
      case validate_placement_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_placement_entry(entry) when is_map(entry) do
    keys = Map.keys(entry)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, {:invalid_semantic_policy, {:invalid_action_placement_entry, :non_string_keys}}}

      MapSet.new(keys) != @placement_entry_keys ->
        {:error,
         {:invalid_semantic_policy,
          {:invalid_action_placement_entry, :unexpected_or_missing_keys}}}

      true ->
        with :ok <- require_placement_nonempty_string(entry, "node_id"),
             :ok <- require_placement_nonempty_string(entry, "action"),
             :ok <- require_placement_string_list(entry, "required_dominators"),
             :ok <- require_placement_string_list(entry, "review_required_dominators"),
             :ok <- require_placement_dominator_sets(entry) do
          :ok
        end
    end
  end

  defp validate_placement_entry(_entry) do
    {:error, {:invalid_semantic_policy, {:invalid_action_placement_entry, :expected_map}}}
  end

  defp require_placement_nonempty_string(entry, key) do
    case Map.fetch!(entry, key) do
      value when is_binary(value) and value != "" ->
        :ok

      _other ->
        {:error, {:invalid_semantic_policy, {:invalid_action_placement_field, key}}}
    end
  end

  defp require_placement_string_list(entry, key) do
    case Map.fetch!(entry, key) do
      list when is_list(list) ->
        cond do
          not Enum.all?(list, &(is_binary(&1) and &1 != "")) ->
            {:error, {:invalid_semantic_policy, {:invalid_action_placement_field, key}}}

          list != Enum.sort(list) ->
            {:error, {:invalid_semantic_policy, {:unsorted_action_placement_field, key}}}

          length(list) != length(Enum.uniq(list)) ->
            {:error, {:invalid_semantic_policy, {:duplicate_action_placement_field, key}}}

          true ->
            :ok
        end

      _other ->
        {:error, {:invalid_semantic_policy, {:invalid_action_placement_field, key}}}
    end
  end

  defp require_placement_dominator_sets(entry) do
    case Map.fetch!(entry, "required_dominator_sets") do
      sets when is_list(sets) ->
        Enum.reduce_while(sets, :ok, fn set, :ok ->
          case validate_dominator_set(set) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          :ok -> require_dominator_sets_sorted(sets)
          error -> error
        end

      _other ->
        {:error,
         {:invalid_semantic_policy, {:invalid_action_placement_field, "required_dominator_sets"}}}
    end
  end

  defp validate_dominator_set(set) when is_list(set) and set != [] do
    cond do
      not Enum.all?(set, &(is_binary(&1) and &1 != "")) ->
        {:error,
         {:invalid_semantic_policy, {:invalid_action_placement_field, "required_dominator_sets"}}}

      set != Enum.sort(set) ->
        {:error,
         {:invalid_semantic_policy, {:unsorted_action_placement_field, "required_dominator_sets"}}}

      length(set) != length(Enum.uniq(set)) ->
        {:error,
         {:invalid_semantic_policy,
          {:duplicate_action_placement_field, "required_dominator_sets"}}}

      true ->
        :ok
    end
  end

  defp validate_dominator_set(_set) do
    {:error,
     {:invalid_semantic_policy, {:invalid_action_placement_field, "required_dominator_sets"}}}
  end

  defp require_dominator_sets_sorted(sets) do
    sorted = Enum.sort_by(sets, &Enum.join(&1, "\0"))

    if sets == sorted do
      :ok
    else
      {:error,
       {:invalid_semantic_policy, {:unsorted_action_placement_field, "required_dominator_sets"}}}
    end
  end

  defp require_placements_sorted_unique(placements) do
    node_ids = Enum.map(placements, & &1["node_id"])

    cond do
      node_ids != Enum.sort(node_ids) ->
        {:error, {:invalid_semantic_policy, {:unsorted_list, "action_placements"}}}

      length(node_ids) != length(Enum.uniq(node_ids)) ->
        {:error, {:invalid_semantic_policy, {:duplicate_list_entries, "action_placements"}}}

      true ->
        :ok
    end
  end

  defp require_placement_actions_allowed(policy) do
    allowed = MapSet.new(policy["allowed_actions"])

    unknown =
      policy["action_placements"]
      |> Enum.map(& &1["action"])
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if unknown == [] do
      :ok
    else
      {:error, {:invalid_semantic_policy, {:placement_actions_not_allowed, unknown}}}
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

  defp require_worker_recovery_policy(policy) do
    case Map.fetch(policy, "worker_recovery") do
      {:ok,
       %{
         "node_attrs" => node_attrs,
         "protected_writers" => protected_writers,
         "edges" => edges
       }}
      when is_list(node_attrs) and is_map(protected_writers) and is_list(edges) ->
        with :ok <- require_worker_recovery_node_attrs(node_attrs),
             :ok <- require_worker_recovery_writers(protected_writers),
             :ok <- require_worker_recovery_edges(edges) do
          :ok
        end

      _other ->
        {:error, {:invalid_semantic_policy, :invalid_worker_recovery_policy}}
    end
  end

  defp require_review_convergence_policy(policy) do
    case Map.fetch(policy, "review_convergence") do
      {:ok,
       %{
         "node_attrs" => node_attrs,
         "protected_writers" => protected_writers,
         "edges" => edges
       }}
      when is_list(node_attrs) and is_map(protected_writers) and is_list(edges) ->
        with :ok <- require_worker_recovery_node_attrs(node_attrs),
             :ok <- require_worker_recovery_writers(protected_writers),
             :ok <- require_worker_recovery_edges(edges) do
          :ok
        end

      _other ->
        {:error, {:invalid_semantic_policy, :invalid_review_convergence_policy}}
    end
  end

  defp require_worker_recovery_node_attrs(entries) do
    valid? =
      Enum.all?(entries, fn
        %{"node_id" => node_id, "attrs" => attrs}
        when is_binary(node_id) and node_id != "" and is_map(attrs) ->
          Enum.all?(attrs, fn {key, _value} -> is_binary(key) end)

        _other ->
          false
      end)

    node_ids = Enum.map(entries, & &1["node_id"])

    if valid? and node_ids == Enum.sort(node_ids) and
         length(node_ids) == length(Enum.uniq(node_ids)) do
      :ok
    else
      {:error, {:invalid_semantic_policy, :invalid_worker_recovery_node_attrs}}
    end
  end

  defp require_worker_recovery_writers(writers) do
    keys = Map.keys(writers)

    if Enum.all?(keys, &is_binary/1) and keys == Enum.sort(keys) and
         Enum.all?(writers, fn {_key, nodes} ->
           is_list(nodes) and nodes == Enum.sort(nodes) and
             length(nodes) == length(Enum.uniq(nodes)) and
             Enum.all?(nodes, &(is_binary(&1) and &1 != ""))
         end) do
      :ok
    else
      {:error, {:invalid_semantic_policy, :invalid_worker_recovery_writers}}
    end
  end

  defp require_worker_recovery_edges(edges) do
    valid? =
      Enum.all?(edges, fn
        [from, to, condition]
        when is_binary(from) and from != "" and is_binary(to) and to != "" and
               (is_binary(condition) or is_nil(condition)) ->
          true

        _other ->
          false
      end)

    if valid? and edges == Enum.sort(edges) and length(edges) == length(Enum.uniq(edges)) do
      :ok
    else
      {:error, {:invalid_semantic_policy, :invalid_worker_recovery_edges}}
    end
  end

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

  defp normalize_worker_continuity(opts) do
    case {
      Keyword.fetch(opts, :worker_use_pool),
      Keyword.fetch(opts, :worker_resume_session_id)
    } do
      {:error, :error} ->
        {:ok, :unbound}

      {{:ok, use_pool}, {:ok, resume_session_id}}
      when is_boolean(use_pool) and
             (is_nil(resume_session_id) or is_binary(resume_session_id)) ->
        if is_nil(resume_session_id) or
             (String.valid?(resume_session_id) and String.trim(resume_session_id) != "") do
          {:ok,
           %{
             use_pool: use_pool,
             resume_session_id: resume_session_id,
             permission_mode: Keyword.get(opts, :worker_permission_mode),
             model:
               case Keyword.get(opts, :worker_model, :unknown) do
                 nil -> nil
                 :unknown -> :unknown
                 value when is_binary(value) -> value
                 _other -> :invalid
               end
           }}
        else
          {:error, {:invalid_semantic_policy, :invalid_worker_continuity}}
        end

      _other ->
        {:error, {:invalid_semantic_policy, :invalid_worker_continuity}}
    end
  end

  defp normalize_rework_max_cycles(opts) do
    case Keyword.fetch(opts, :rework_max_cycles) do
      {:ok, max_cycles} when is_integer(max_cycles) and max_cycles in 0..2 ->
        {:ok, max_cycles}

      :error ->
        {:error, {:invalid_semantic_policy, :missing_rework_max_cycles}}

      {:ok, other} ->
        {:error, {:invalid_semantic_policy, {:invalid_rework_max_cycles, other}}}
    end
  end

  defp normalize_validation_timeout_ms(opts) do
    case Keyword.fetch(opts, :validation_timeout_ms) do
      {:ok, timeout_ms} when is_integer(timeout_ms) and timeout_ms > 0 ->
        {:ok, timeout_ms}

      :error ->
        {:error, {:invalid_semantic_policy, :missing_validation_timeout_ms}}

      {:ok, other} ->
        {:error, {:invalid_semantic_policy, {:invalid_validation_timeout_ms, other}}}
    end
  end

  defp normalize_validation_test_stage_timeout_ms(opts) do
    case Keyword.fetch(opts, :validation_test_stage_timeout_ms) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, timeout_ms} when is_integer(timeout_ms) and timeout_ms > 0 ->
        {:ok, timeout_ms}

      :error ->
        # Optional except for profiles that emit param.test_stage_timeout.
        {:ok, nil}

      {:ok, other} ->
        {:error, {:invalid_semantic_policy, {:invalid_validation_test_stage_timeout_ms, other}}}
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

  # Exact node-identity action bindings. Allowed action names alone are not a
  # placement contract: an extra allowlisted git_pr node (or a swapped pair of
  # allowed actions) must fail closed.
  defp check_action_placement_bindings(errors, graph, policy) do
    placements = policy["action_placements"]

    if placements == [] do
      errors
    else
      expected = Map.new(placements, &{&1["node_id"], &1["action"]})

      exec_nodes =
        graph.nodes
        |> Enum.filter(fn {_id, node} -> Registry.node_type(node) == "exec" end)
        |> Enum.sort_by(&elem(&1, 0))

      present_ids = MapSet.new(exec_nodes, &elem(&1, 0))

      errors =
        Enum.reduce(exec_nodes, errors, fn {node_id, node}, acc ->
          action = Map.get(node.attrs, "action")

          case Map.fetch(expected, node_id) do
            {:ok, ^action} ->
              acc

            {:ok, required_action} ->
              [
                error("action_placement_mismatch", node_id, %{
                  "action" => action,
                  "required_action" => required_action
                })
                | acc
              ]

            :error ->
              [
                error("action_placement_extra_node", node_id, %{
                  "action" => action
                })
                | acc
              ]
          end
        end)

      Enum.reduce(placements, errors, fn placement, acc ->
        node_id = placement["node_id"]

        if MapSet.member?(present_ids, node_id) do
          acc
        else
          [
            error("action_placement_missing_node", node_id, %{
              "action" => placement["action"]
            })
            | acc
          ]
        end
      end)
    end
  end

  # Commit approval must be a reviewed top-level coding action, never a generic
  # handler opt-in that could turn denial into success for arbitrary graphs.
  @commit_approval_node "commit_change"
  @commit_approval_action "coding_reviewed_commit"
  @approval_route_node "route_commit_interaction"
  @approval_denied_condition "context.commit.interaction_outcome=denied"
  @approval_rework_condition "context.commit.interaction_outcome=rework"
  @approval_cleanup_node "close_worker"
  @rework_exhaustion_marker "mark_operator_rework_exhausted_error"
  @rework_exhaustion_status "status_rework_exhausted"
  @rework_dispatch_node "build_operator_rework_prompt"
  # Pre-turn fingerprint capture is mandatory before each implement send.
  @rework_dispatch_target "capture_pre_turn_workspace"

  @workspace_cleanup_node_attrs %{
    "prep_release_mode_only" => %{
      "type" => "transform",
      "transform" => "constant",
      "expression" => "retain",
      "output_key" => "mode"
    },
    "prep_release_mode_remove" => %{
      "type" => "transform",
      "transform" => "constant",
      "expression" => "publish",
      "output_key" => "mode"
    },
    "prep_release_mode_publish_retain" => %{
      "type" => "transform",
      "transform" => "constant",
      "expression" => "publish_retain",
      "output_key" => "mode"
    },
    "prep_release_mode_discard" => %{
      "type" => "transform",
      "transform" => "constant",
      "expression" => "discard",
      "output_key" => "mode"
    },
    "prep_release_mode_retain" => %{
      "type" => "transform",
      "transform" => "constant",
      "expression" => "retain",
      "output_key" => "mode"
    },
    "publish_workspace" => %{
      "type" => "exec",
      "target" => "action",
      "action" => "coding_workspace_release",
      "context_keys" => "workspace_id,mode,commit_hash,repo_path",
      "output_prefix" => "release",
      "max_retries" => "0"
    },
    "release_workspace" => %{
      "type" => "exec",
      "target" => "action",
      "action" => "coding_workspace_release",
      "context_keys" => "workspace_id,mode",
      "output_prefix" => "release",
      "max_retries" => "0"
    },
    "release_workspace_only" => %{
      "type" => "exec",
      "target" => "action",
      "action" => "coding_workspace_release",
      "context_keys" => "workspace_id,mode",
      "output_prefix" => "release",
      "max_retries" => "0"
    },
    "route_release_mode" => %{
      "type" => "branch",
      "shape" => "diamond",
      "fan_out" => "false"
    },
    "route_success_workspace_retention" => %{
      "type" => "branch",
      "shape" => "diamond",
      "fan_out" => "false"
    }
  }

  @workspace_cleanup_outgoing %{
    "close_worker" => [
      {"route_release_mode", "outcome=fail"},
      {"route_release_mode", "outcome=success"}
    ],
    "open_worker" => [
      {"hoist_worker_session_id", "outcome=success"},
      {"prep_release_mode_only", "outcome=fail"}
    ],
    "prep_release_mode_only" => [{"release_workspace_only", nil}],
    "prep_release_mode_remove" => [{"publish_workspace", nil}],
    "prep_release_mode_discard" => [{"release_workspace", nil}],
    "prep_release_mode_publish_retain" => [{"publish_workspace", nil}],
    "prep_release_mode_retain" => [{"release_workspace", nil}],
    "publish_workspace" => [{"done", nil}],
    "release_workspace" => [{"done", nil}],
    "release_workspace_only" => [{"status_pipeline_error", nil}],
    "route_release_mode" => [
      {"prep_release_mode_discard", "context.status=declined"},
      {"prep_release_mode_discard", "context.status=no_changes"},
      {"prep_release_mode_retain", "context.status=approval_denied"},
      {"prep_release_mode_retain", "context.status=pipeline_error"},
      {"prep_release_mode_retain", "context.status=pr_failed"},
      {"prep_release_mode_retain", "context.status=review_failed"},
      {"prep_release_mode_retain", "context.status=review_rejected"},
      {"prep_release_mode_retain", "context.status=rework_exhausted"},
      {"prep_release_mode_retain", "context.status=validation_failed"},
      {"prep_release_mode_retain", "context.status=validation_capacity_exceeded"},
      {"prep_release_mode_retain", nil},
      {"route_success_workspace_retention", "context.status=change_committed"},
      {"route_success_workspace_retention", "context.status=human_review_required"},
      {"route_success_workspace_retention", "context.status=pr_created"}
    ],
    "route_success_workspace_retention" => [
      {"prep_release_mode_remove", "context.retain_workspace=false"},
      {"prep_release_mode_publish_retain", "context.retain_workspace=true"},
      {"prep_release_mode_publish_retain", nil}
    ],
    "status_pipeline_error" => [{"done", nil}]
  }

  defp check_workspace_cleanup_topology(errors, graph) do
    errors =
      Enum.reduce(@workspace_cleanup_node_attrs, errors, fn {node_id, expected}, acc ->
        case Map.fetch(graph.nodes, node_id) do
          {:ok, node} when is_map(node.attrs) ->
            actual = Map.take(node.attrs, Map.keys(expected))

            if actual == expected do
              acc
            else
              [
                error("workspace_cleanup_node_mismatch", node_id, %{
                  "expected" => expected,
                  "actual" => actual
                })
                | acc
              ]
            end

          _other ->
            [error("workspace_cleanup_node_mismatch", node_id, %{"expected" => expected}) | acc]
        end
      end)

    errors =
      Enum.reduce(@workspace_cleanup_outgoing, errors, fn {node_id, expected}, acc ->
        actual =
          graph
          |> Graph.outgoing_edges(node_id)
          |> Enum.map(&{&1.to, edge_condition(&1)})
          |> Enum.sort()

        if actual == Enum.sort(expected) do
          acc
        else
          [
            error("workspace_cleanup_topology_mismatch", node_id, %{
              "expected" => Enum.map(Enum.sort(expected), &edge_binding_to_json/1),
              "actual" => Enum.map(actual, &edge_binding_to_json/1)
            })
            | acc
          ]
        end
      end)

    errors
    |> require_all_paths_through_any(
      graph,
      "close_worker",
      MapSet.new(["publish_workspace", "release_workspace"]),
      "workspace_cleanup_release"
    )
    |> require_all_paths_through(
      graph,
      "prep_release_mode_only",
      "release_workspace_only",
      "workspace_cleanup_release_only"
    )
  end

  @precommit_abort_origins %{
    "status_no_changes" => "route_no_progress",
    # Pre-turn fingerprint capture precedes every implement/rework send and is
    # the earliest owner-observed gate that may abort into the shared cleanup
    # status without re-entering the commit gate.
    "status_pipeline_error_then_close" => "capture_pre_turn_workspace",
    "status_validation_failed" => "validate",
    "status_validation_capacity_exceeded" => "validate"
  }

  @operator_rework_chain ~w(
    check_operator_rework_category_budget
    check_operator_rework_total_budget
    inc_operator_rework_count
    inc_operator_total_rework_count
  )

  @post_commit_review_nodes ~w(
    route_commit_interaction
    hoist_commit_hash
    route_after_commit
    prep_expected_commit
    load_committed_change
    review_change
    route_review
    route_publish
    prep_pr_path
    status_change_committed
    status_pr_created
    status_human_review_required
  )
  @forbidden_denial_bypass_attrs MapSet.new(~w[
    project_interaction_control
    treat_deny_as_success
    deny_as_success
    project_control
    force_success_on_deny
  ])

  defp check_commit_approval_gate(errors, graph) do
    case Map.get(graph.nodes, @commit_approval_node) do
      nil ->
        [error("missing_commit_approval_gate", @commit_approval_node, %{}) | errors]

      node ->
        action = Map.get(node.attrs, "action")

        cond do
          action != @commit_approval_action ->
            [
              error("invalid_commit_approval_action", @commit_approval_node, %{
                "action" => action,
                "required_action" => @commit_approval_action
              })
              | errors
            ]

          Map.get(node.attrs, "target") not in [nil, "action"] ->
            [
              error("invalid_commit_approval_target", @commit_approval_node, %{
                "target" => Map.get(node.attrs, "target")
              })
              | errors
            ]

          true ->
            errors
        end
    end
  end

  # Prove deny cleanup and all operator rework budget counters are wired.
  # Dominance/all-path proofs (not mere reachability):
  #   * success/deny/rework post-commit nodes are dominated by the reviewed gate
  #   * every deny path reaches cleanup and cannot reach publication
  #   * every operator rework path passes category+total budget then fresh gate
  #   * direct bypass edges (commit_change -> hoist/route_after) fail closed
  defp check_operator_approval_routing(errors, graph) do
    errors = check_approval_graph_shape(errors, graph)

    required =
      ~w(
        route_commit_interaction
        status_approval_denied
        mark_operator_rework_exhausted_error
      ) ++ @operator_rework_chain

    errors =
      Enum.reduce(required, errors, fn node_id, acc ->
        if Map.has_key?(graph.nodes, node_id) do
          acc
        else
          [error("missing_operator_approval_node", node_id, %{}) | acc]
        end
      end)

    {_entry, reachable, dominators} = approval_dominance_context(graph)

    # Reviewed gate dominates every post-commit branch (success hoist, deny, rework).
    post_gate_nodes =
      ~w(
        route_commit_interaction
        hoist_commit_hash
        status_approval_denied
        check_operator_rework_category_budget
        check_operator_rework_total_budget
      )

    errors =
      Enum.reduce(post_gate_nodes, errors, fn node_id, acc ->
        require_dominates(
          acc,
          @commit_approval_node,
          node_id,
          reachable,
          dominators,
          "reviewed_commit_gate"
        )
      end)

    # route_commit_interaction dominates success hoist / deny / rework budgets.
    errors =
      Enum.reduce(
        ~w(hoist_commit_hash status_approval_denied check_operator_rework_category_budget),
        errors,
        fn node_id, acc ->
          require_dominates(
            acc,
            "route_commit_interaction",
            node_id,
            reachable,
            dominators,
            "commit_interaction_route"
          )
        end
      )

    errors = check_approval_denied_paths(errors, graph, reachable)

    # Operator rework: category budget dominates total budget; both dominate
    # the subsequent rework increment. Total budget also reaches a fresh
    # commit gate on the rework-success path (via worker loop -> commit_change).
    errors =
      errors
      |> require_dominates(
        "check_operator_rework_category_budget",
        "check_operator_rework_total_budget",
        reachable,
        dominators,
        "operator_rework_budget"
      )
      |> require_dominates(
        "check_operator_rework_total_budget",
        "inc_operator_rework_count",
        reachable,
        dominators,
        "operator_rework_budget"
      )
      |> check_operator_rework_paths(graph, reachable)

    # Reject direct bypass edges from the commit gate.
    errors =
      if approval_edge?(graph, "commit_change", "hoist_commit_hash") or
           approval_edge?(graph, "commit_change", "route_after_commit") or
           approval_edge?(graph, "commit_change", "status_approval_denied") do
        [
          error("commit_approval_bypass_edge", "commit_change", %{
            "detail" => "commit_change must route through route_commit_interaction"
          })
          | errors
        ]
      else
        errors
      end

    # Indirect bypass: any edge into post-gate success/deny/rework that is not
    # dominated by commit_change fails closed (extra edge from outside the gate).
    reject_indirect_commit_bypasses(errors, graph, reachable, dominators)
  end

  defp approval_dominance_context(graph) do
    case Graph.find_start_node(graph) do
      nil ->
        {nil, MapSet.new(), %{}}

      start_node ->
        entry = start_node.id
        reachable = reachable_from(graph, entry)
        dominators = compute_dominators(graph, entry, reachable)
        {entry, reachable, dominators}
    end
  end

  defp check_approval_graph_shape(errors, graph) do
    errors =
      case Graph.find_exit_nodes(graph) do
        [_terminal] ->
          errors

        terminals ->
          [
            error("invalid_approval_terminal_set", nil, %{
              "terminal_nodes" => terminals |> Enum.map(& &1.id) |> Enum.sort()
            })
            | errors
          ]
      end

    graph.edges
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {edge, index}, acc ->
      cond do
        not is_binary(edge.from) or not is_binary(edge.to) ->
          [error("malformed_approval_edge", nil, %{"edge_index" => index}) | acc]

        not Map.has_key?(graph.nodes, edge.from) or not Map.has_key?(graph.nodes, edge.to) ->
          [
            error("malformed_approval_edge", edge.from, %{
              "edge_index" => index,
              "to" => edge.to
            })
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp check_approval_denied_paths(errors, graph, reachable) do
    denied_targets = approval_outcome_targets(graph, @approval_denied_condition)

    errors =
      if denied_targets == [] do
        [
          error("missing_approval_denied_route", @approval_route_node, %{
            "condition" => @approval_denied_condition
          })
          | errors
        ]
      else
        errors
      end

    Enum.reduce(denied_targets, errors, fn denied_entry, acc ->
      acc
      |> require_reachable_outcome(reachable, denied_entry, "approval_denied")
      |> require_all_paths_through(
        graph,
        denied_entry,
        "status_approval_denied",
        "approval_denied_status"
      )
      |> require_all_paths_through(
        graph,
        "status_approval_denied",
        @approval_cleanup_node,
        "approval_denied_cleanup"
      )
      |> reject_deny_publication_paths(graph, reachable)
    end)
  end

  defp check_operator_rework_paths(errors, graph, reachable) do
    rework_targets = approval_outcome_targets(graph, @approval_rework_condition)

    errors =
      if rework_targets == [] do
        [
          error("missing_operator_rework_route", @approval_route_node, %{
            "condition" => @approval_rework_condition
          })
          | errors
        ]
      else
        errors
      end

    Enum.reduce(rework_targets, errors, fn rework_entry, acc ->
      rework_reachable = reachable_from(graph, rework_entry)
      rework_dominators = compute_dominators(graph, rework_entry, rework_reachable)

      acc =
        acc
        |> require_reachable_outcome(reachable, rework_entry, "operator_rework")
        |> require_all_paths_through(
          graph,
          rework_entry,
          "check_operator_rework_category_budget",
          "operator_rework_category_budget"
        )
        |> require_dominates(
          "check_operator_rework_category_budget",
          "inc_operator_total_rework_count",
          rework_reachable,
          rework_dominators,
          "operator_rework_category_budget"
        )
        |> require_dominates(
          "check_operator_rework_total_budget",
          "inc_operator_total_rework_count",
          rework_reachable,
          rework_dominators,
          "operator_rework_total_budget"
        )
        |> require_dominates(
          "inc_operator_rework_count",
          "inc_operator_total_rework_count",
          rework_reachable,
          rework_dominators,
          "operator_rework_counter"
        )
        |> require_dominates(
          @approval_cleanup_node,
          terminal_id(graph),
          rework_reachable,
          rework_dominators,
          "operator_rework_cleanup"
        )
        |> require_all_paths_through_any(
          graph,
          rework_entry,
          MapSet.new([@rework_dispatch_node, @rework_exhaustion_marker]),
          "operator_rework_resolution"
        )
        |> require_all_paths_through(
          graph,
          @rework_exhaustion_marker,
          @rework_exhaustion_status,
          "operator_rework_exhaustion_status"
        )
        |> require_all_paths_through(
          graph,
          @rework_exhaustion_status,
          @approval_cleanup_node,
          "operator_rework_exhaustion_cleanup"
        )
        |> require_all_paths_through(
          graph,
          @rework_dispatch_node,
          @rework_dispatch_target,
          "operator_rework_dispatch"
        )
        |> check_rework_status_edges(graph, rework_reachable, rework_dominators)
        |> check_rework_completion_shape(graph, rework_entry, rework_reachable)

      Enum.reduce(@post_commit_review_nodes, acc, fn target, inner ->
        require_dominates(
          inner,
          @commit_approval_node,
          target,
          rework_reachable,
          rework_dominators,
          "fresh_reviewed_commit_gate"
        )
      end)
    end)
  end

  defp check_rework_status_edges(errors, graph, reachable, dominators) do
    graph.edges
    |> Enum.filter(fn edge ->
      MapSet.member?(reachable, edge.from) and MapSet.member?(reachable, edge.to) and
        String.starts_with?(edge.to, "status_")
    end)
    |> Enum.reduce(errors, fn edge, acc ->
      origin = Map.get(@precommit_abort_origins, edge.to)

      allowed? =
        dominates?(dominators, @commit_approval_node, edge.from) or
          (is_binary(origin) and dominates?(dominators, origin, edge.from)) or
          (edge.to == @rework_exhaustion_status and edge.from == @rework_exhaustion_marker)

      if allowed? do
        acc
      else
        [
          error("rework_status_bypass", edge.from, %{
            "kind" => "operator_rework_status_origin",
            "status_node" => edge.to
          })
          | acc
        ]
      end
    end)
  end

  defp check_rework_completion_shape(errors, graph, source, reachable) do
    terminals = graph |> Graph.find_exit_nodes() |> Enum.map(& &1.id) |> MapSet.new()

    dead_ends =
      reachable
      |> Enum.reject(&MapSet.member?(terminals, &1))
      |> Enum.filter(&(Graph.outgoing_edges(graph, &1) == []))
      |> Enum.sort()

    errors =
      Enum.reduce(dead_ends, errors, fn node_id, acc ->
        [
          error("all_path_violation", source, %{
            "kind" => "operator_rework_completion",
            "violation" => %{"type" => "dead_end", "node_id" => node_id}
          })
          | acc
        ]
      end)

    terminating_seeds = MapSet.union(terminals, MapSet.new(dead_ends))
    can_terminate = reverse_reachable(graph, terminating_seeds, reachable)
    nonterminating = MapSet.difference(reachable, can_terminate)

    case nonterminating |> Enum.sort() |> List.first() do
      nil ->
        errors

      node_id ->
        [
          error("all_path_violation", source, %{
            "kind" => "operator_rework_completion",
            "violation" => %{"type" => "cycle", "node_id" => node_id}
          })
          | errors
        ]
    end
  end

  defp reverse_reachable(graph, seeds, allowed) do
    do_reverse_reachable(graph, :queue.from_list(Enum.to_list(seeds)), MapSet.new(), allowed)
  end

  defp do_reverse_reachable(graph, queue, visited, allowed) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        visited

      {{:value, node_id}, rest} ->
        if MapSet.member?(visited, node_id) or not MapSet.member?(allowed, node_id) do
          do_reverse_reachable(graph, rest, visited, allowed)
        else
          previous =
            graph
            |> Graph.incoming_edges(node_id)
            |> Enum.map(& &1.from)

          do_reverse_reachable(
            graph,
            enqueue_all(rest, previous),
            MapSet.put(visited, node_id),
            allowed
          )
        end
    end
  end

  defp require_reachable_outcome(errors, reachable, node_id, kind) do
    if MapSet.member?(reachable, node_id) do
      errors
    else
      [error("unreachable_approval_outcome", node_id, %{"kind" => kind}) | errors]
    end
  end

  defp approval_outcome_targets(graph, condition) do
    graph
    |> Graph.outgoing_edges(@approval_route_node)
    |> Enum.filter(&(edge_condition(&1) == condition))
    |> Enum.map(& &1.to)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp edge_condition(edge) do
    Map.get(edge.attrs, "condition") || Map.get(edge, :condition)
  end

  # Prove a post-dominance barrier without enumerating paths. If traversal from
  # source while treating required as a cut can reach a terminal, dead end, or
  # cycle, then some finite or infinite path avoids the required node.
  defp require_all_paths_through(errors, graph, source, required, kind) do
    cond do
      not Map.has_key?(graph.nodes, source) ->
        [error("missing_all_path_source", source, %{"kind" => kind}) | errors]

      not Map.has_key?(graph.nodes, required) ->
        [error("missing_all_path_gate", required, %{"kind" => kind, "source" => source}) | errors]

      true ->
        {avoiding, reached_required?} = reachable_until(graph, source, required)
        violation = all_path_violation(graph, avoiding)

        cond do
          not reached_required? ->
            [
              error("all_path_gate_unreachable", source, %{
                "kind" => kind,
                "required_node" => required
              })
              | errors
            ]

          violation != nil ->
            [
              error("all_path_violation", source, %{
                "kind" => kind,
                "required_node" => required,
                "violation" => violation
              })
              | errors
            ]

          true ->
            errors
        end
    end
  end

  defp reachable_until(graph, source, cut) do
    {visited, reached} = reachable_until_any(graph, source, MapSet.new([cut]))
    {visited, MapSet.member?(reached, cut)}
  end

  defp require_all_paths_through_any(errors, graph, source, required, kind) do
    cond do
      not Map.has_key?(graph.nodes, source) ->
        [error("missing_all_path_source", source, %{"kind" => kind}) | errors]

      Enum.any?(required, &(not Map.has_key?(graph.nodes, &1))) ->
        missing = required |> Enum.reject(&Map.has_key?(graph.nodes, &1)) |> Enum.sort()

        [
          error("missing_all_path_gate", List.first(missing), %{
            "kind" => kind,
            "source" => source,
            "required_nodes" => Enum.sort(required)
          })
          | errors
        ]

      true ->
        {avoiding, reached} = reachable_until_any(graph, source, required)
        violation = all_path_violation(graph, avoiding)

        cond do
          MapSet.size(reached) == 0 ->
            [
              error("all_path_gate_unreachable", source, %{
                "kind" => kind,
                "required_nodes" => Enum.sort(required)
              })
              | errors
            ]

          violation != nil ->
            [
              error("all_path_violation", source, %{
                "kind" => kind,
                "required_nodes" => Enum.sort(required),
                "violation" => violation
              })
              | errors
            ]

          true ->
            errors
        end
    end
  end

  defp reachable_until_any(graph, source, cuts) do
    do_reachable_until_any(graph, :queue.from_list([source]), MapSet.new(), cuts, MapSet.new())
  end

  defp do_reachable_until_any(graph, queue, visited, cuts, reached) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {visited, reached}

      {{:value, node_id}, rest} ->
        cond do
          MapSet.member?(cuts, node_id) ->
            do_reachable_until_any(
              graph,
              rest,
              visited,
              cuts,
              MapSet.put(reached, node_id)
            )

          MapSet.member?(visited, node_id) or not Map.has_key?(graph.nodes, node_id) ->
            do_reachable_until_any(graph, rest, visited, cuts, reached)

          true ->
            next = graph |> Graph.outgoing_edges(node_id) |> Enum.map(& &1.to)

            do_reachable_until_any(
              graph,
              enqueue_all(rest, next),
              MapSet.put(visited, node_id),
              cuts,
              reached
            )
        end
    end
  end

  defp all_path_violation(graph, avoiding) do
    terminals = graph |> Graph.find_exit_nodes() |> Enum.map(& &1.id) |> MapSet.new()

    cond do
      terminal = Enum.find(avoiding, &MapSet.member?(terminals, &1)) ->
        %{"type" => "terminal", "node_id" => terminal}

      dead_end = Enum.find(avoiding, &(Graph.outgoing_edges(graph, &1) == [])) ->
        %{"type" => "dead_end", "node_id" => dead_end}

      cycle_node = cycle_node(graph, avoiding) ->
        %{"type" => "cycle", "node_id" => cycle_node}

      true ->
        nil
    end
  end

  defp cycle_node(graph, nodes) do
    indegrees =
      Map.new(nodes, fn node_id ->
        count =
          graph
          |> Graph.incoming_edges(node_id)
          |> Enum.count(&MapSet.member?(nodes, &1.from))

        {node_id, count}
      end)

    queue = :queue.from_list(for {node_id, 0} <- indegrees, do: node_id)
    remaining = prune_acyclic_nodes(graph, queue, nodes, indegrees)

    remaining |> Enum.sort() |> List.first()
  end

  defp prune_acyclic_nodes(graph, queue, remaining, indegrees) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        remaining

      {{:value, node_id}, rest} ->
        if MapSet.member?(remaining, node_id) do
          remaining = MapSet.delete(remaining, node_id)

          {indegrees, newly_zero} =
            graph
            |> Graph.outgoing_edges(node_id)
            |> Enum.map(& &1.to)
            |> Enum.filter(&MapSet.member?(remaining, &1))
            |> Enum.reduce({indegrees, []}, fn target, {degrees, zeroes} ->
              degree = Map.fetch!(degrees, target) - 1
              degrees = Map.put(degrees, target, degree)
              zeroes = if degree == 0, do: [target | zeroes], else: zeroes
              {degrees, zeroes}
            end)

          prune_acyclic_nodes(
            graph,
            enqueue_all(rest, newly_zero),
            remaining,
            indegrees
          )
        else
          prune_acyclic_nodes(graph, rest, remaining, indegrees)
        end
    end
  end

  defp terminal_id(graph) do
    case Graph.find_exit_nodes(graph) do
      [terminal] -> terminal.id
      _other -> "__invalid_terminal__"
    end
  end

  # Deny terminals must not be able to reach any publication success node.
  defp reject_deny_publication_paths(errors, graph, reachable) do
    publication =
      ~w(
        route_publish
        status_change_committed
        status_pr_created
        status_human_review_required
        prep_pr_path
      )
      |> Enum.filter(&MapSet.member?(reachable, &1))

    Enum.reduce(publication, errors, fn pub, acc ->
      if approval_reaches?(graph, "status_approval_denied", pub) do
        [
          error("approval_denied_reaches_publication", "status_approval_denied", %{
            "publication_node" => pub
          })
          | acc
        ]
      else
        acc
      end
    end)
  end

  # Extra edges into post-gate nodes from sources other than the reviewed gate
  # / route_commit_interaction chain are indirect bypasses.
  defp reject_indirect_commit_bypasses(errors, graph, reachable, dominators) do
    guarded =
      MapSet.new(~w(
          route_commit_interaction
          hoist_commit_hash
          status_approval_denied
          check_operator_rework_category_budget
          check_operator_rework_total_budget
          inc_operator_rework_count
        ))

    allowed_predecessors = MapSet.new([@commit_approval_node, "route_commit_interaction"])

    graph.edges
    |> Enum.reduce(errors, fn edge, acc ->
      cond do
        not MapSet.member?(guarded, edge.to) ->
          acc

        MapSet.member?(allowed_predecessors, edge.from) ->
          acc

        # Nodes already dominated by the reviewed gate (downstream of route)
        # may chain among themselves; only edges from undominated sources fail.
        MapSet.member?(reachable, edge.from) and
            dominates?(dominators, @commit_approval_node, edge.from) ->
          acc

        true ->
          [
            error("commit_approval_bypass_edge", edge.from, %{
              "detail" => "indirect bypass into post-commit gate node",
              "to" => edge.to
            })
            | acc
          ]
      end
    end)
  end

  defp check_forbidden_denial_bypass_attrs(errors, graph) do
    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(errors, fn {node_id, node}, acc ->
      hits =
        node.attrs
        |> Map.keys()
        |> Enum.filter(&(is_binary(&1) and MapSet.member?(@forbidden_denial_bypass_attrs, &1)))
        |> Enum.sort()

      Enum.reduce(hits, acc, fn key, inner ->
        [
          error("forbidden_denial_bypass_attribute", node_id, %{"attribute" => key})
          | inner
        ]
      end)
    end)
  end

  defp approval_edge?(%Graph{} = graph, from, to) do
    graph
    |> Graph.outgoing_edges(from)
    |> Enum.any?(&(&1.to == to))
  end

  defp approval_edge?(_, _, _), do: false

  defp approval_reaches?(%Graph{} = graph, from, to) do
    graph
    |> Graph.outgoing_edges(from)
    |> Enum.map(& &1.to)
    |> then(fn seeds ->
      approval_bfs(graph, :queue.from_list(seeds), MapSet.new([from]), to)
    end)
  end

  defp approval_reaches?(_, _, _), do: false

  defp approval_bfs(graph, queue, seen, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        false

      {{:value, node}, rest} ->
        cond do
          node == target ->
            true

          MapSet.member?(seen, node) ->
            approval_bfs(graph, rest, seen, target)

          true ->
            next =
              graph
              |> Graph.outgoing_edges(node)
              |> Enum.map(& &1.to)

            approval_bfs(graph, enqueue_all(rest, next), MapSet.put(seen, node), target)
        end
    end
  end

  defp check_worker_continuity_bindings(errors, graph, continuity) do
    expected_nodes = [
      {"capture_pre_turn_workspace",
       %{
         "type" => "exec",
         "target" => "action",
         "action" => "coding_workspace_inspect",
         "context_keys" => "workspace_id",
         "output_prefix" => "pre_turn",
         "max_retries" => "0"
       }},
      {"check_pre_turn_workspace_exists",
       %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}},
      {"hoist_baseline_fingerprint",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "pre_turn.fingerprint",
         "output_key" => "baseline_fingerprint"
       }},
      {"hoist_worker_provider_session_id",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "worker.session_id",
         "output_key" => "worker_provider_session_id"
       }},
      {"hoist_worker_provider_session_id_from_message",
       %{
         "type" => "transform",
         "transform" => "identity",
         "source_key" => "worker_msg.session_id",
         "output_key" => "worker_provider_session_id"
       }},
      {"check_worker_stop_reason",
       %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}},
      {"inspect_workspace",
       %{
         "type" => "exec",
         "target" => "action",
         "action" => "coding_workspace_inspect",
         "context_keys" => "workspace_id,baseline_fingerprint",
         "output_prefix" => "inspect",
         "max_retries" => "0"
       }},
      {"check_workspace_exists",
       %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}}
    ]

    expected_edges = [
      {"open_worker", "hoist_worker_session_id", "outcome=success"},
      {"hoist_worker_session_id", "hoist_worker_provider_session_id", nil},
      {"hoist_worker_provider_session_id", "build_implement_prompt", nil},
      {"build_implement_prompt", "capture_pre_turn_workspace", nil},
      {"capture_pre_turn_workspace", "status_pipeline_error_then_close", "outcome=fail"},
      {"capture_pre_turn_workspace", "check_pre_turn_workspace_exists", "outcome=success"},
      {"check_pre_turn_workspace_exists", "error_workspace_missing",
       "context.pre_turn.exists!=true"},
      {"check_pre_turn_workspace_exists", "hoist_baseline_fingerprint",
       "context.pre_turn.exists=true"},
      {"hoist_baseline_fingerprint", "implement", nil},
      {"implement", "hoist_worker_provider_session_id_from_message", "outcome=success"},
      {"hoist_worker_provider_session_id_from_message", "check_worker_stop_reason", nil},
      {"check_worker_stop_reason", "inspect_workspace",
       "context.worker_msg.stop_reason=end_turn"},
      {"check_worker_stop_reason", "error_worker_stop_reason_not_end_turn", nil},
      {"inspect_workspace", "status_pipeline_error_then_close", "outcome=fail"},
      {"inspect_workspace", "check_workspace_exists", "outcome=success"},
      {"check_workspace_exists", "error_workspace_missing", "context.inspect.exists!=true"},
      {"check_workspace_exists", "hoist_dirty", "context.inspect.exists=true"}
    ]

    errors =
      Enum.reduce(expected_nodes, errors, fn {node_id, expected}, acc ->
        require_worker_continuity_node_attrs(acc, graph, node_id, expected)
      end)

    errors = check_worker_open_continuity(errors, graph, continuity)
    errors = check_worker_close_continuity(errors, graph, continuity)

    Enum.reduce(expected_edges, errors, fn {from, to, condition}, acc ->
      require_worker_continuity_edge(acc, graph, from, to, condition)
    end)
  end

  defp check_worker_recovery_bindings(errors, graph, policy, continuity) do
    recovery = policy["worker_recovery"]

    errors =
      Enum.reduce(recovery["node_attrs"], errors, fn %{"node_id" => node_id, "attrs" => expected},
                                                     acc ->
        case Map.fetch(graph.nodes, node_id) do
          {:ok, %{attrs: ^expected}} ->
            acc

          {:ok, node} ->
            [
              error("worker_recovery_node_mismatch", node_id, %{
                "expected" => expected,
                "actual" => node.attrs
              })
              | acc
            ]

          :error ->
            [error("worker_recovery_missing_node", node_id, %{}) | acc]
        end
      end)

    errors =
      Enum.reduce(recovery["protected_writers"], errors, fn {attribute, expected_nodes}, acc ->
        actual_nodes =
          graph.nodes
          |> Enum.flat_map(fn {node_id, node} ->
            if Map.get(node.attrs, "output_key") == attribute, do: [node_id], else: []
          end)
          |> Enum.sort()

        if actual_nodes == expected_nodes do
          acc
        else
          [
            error("worker_recovery_writer_violation", nil, %{
              "attribute" => attribute,
              "expected_nodes" => expected_nodes,
              "actual_nodes" => actual_nodes
            })
            | acc
          ]
        end
      end)

    errors =
      Enum.reduce(
        recovery["edges"]
        |> Enum.map(fn [from, to, condition] -> {from, to, condition} end)
        |> Enum.group_by(&elem(&1, 0)),
        errors,
        fn {from, expected}, acc ->
          actual =
            graph
            |> Graph.outgoing_edges(from)
            |> Enum.map(&{&1.from, &1.to, Map.get(&1.attrs, "condition")})
            |> Enum.sort()

          if actual == expected do
            acc
          else
            [
              error("worker_recovery_topology_mismatch", from, %{
                "expected" => Enum.map(expected, &recovery_edge_json/1),
                "actual" => Enum.map(actual, &recovery_edge_json/1)
              })
              | acc
            ]
          end
        end
      )

    check_worker_recovery_start_nodes(errors, graph, continuity)
  end

  defp check_review_convergence_bindings(errors, graph, policy, rework_max_cycles) do
    convergence = policy["review_convergence"]

    errors =
      Enum.reduce(convergence["node_attrs"], errors, fn %{
                                                          "node_id" => node_id,
                                                          "attrs" => expected
                                                        },
                                                        acc ->
        case Map.fetch(graph.nodes, node_id) do
          {:ok, %{attrs: ^expected}} ->
            acc

          {:ok, node} ->
            [
              error("review_convergence_node_mismatch", node_id, %{
                "expected" => expected,
                "actual" => node.attrs
              })
              | acc
            ]

          :error ->
            [error("review_convergence_missing_node", node_id, %{}) | acc]
        end
      end)

    errors =
      Enum.reduce(convergence["protected_writers"], errors, fn {context_key, expected_nodes},
                                                               acc ->
        actual_nodes = writer_nodes(graph, "output_key", context_key)

        if actual_nodes == expected_nodes do
          acc
        else
          [
            error("review_convergence_writer_violation", nil, %{
              "context_key" => context_key,
              "expected_nodes" => expected_nodes,
              "actual_nodes" => actual_nodes
            })
            | acc
          ]
        end
      end)

    errors =
      Enum.reduce(
        convergence["edges"]
        |> Enum.map(fn [from, to, condition] -> {from, to, condition} end)
        |> Enum.group_by(&elem(&1, 0)),
        errors,
        fn {from, expected}, acc ->
          actual =
            graph
            |> Graph.outgoing_edges(from)
            |> Enum.map(&{&1.from, &1.to, Map.get(&1.attrs, "condition")})
            |> Enum.sort()

          if actual == expected do
            acc
          else
            [
              error("review_convergence_topology_mismatch", from, %{
                "expected" => Enum.map(expected, &recovery_edge_json/1),
                "actual" => Enum.map(actual, &recovery_edge_json/1)
              })
              | acc
            ]
          end
        end
      )

    validation_admitted_target =
      if Enum.any?(convergence["node_attrs"], &(&1["node_id"] == "inc_validation_review_cycle")) do
        "snapshot_validation_prior_commit"
      else
        "inc_validation_rework_count"
      end

    errors
    |> check_dynamic_total_budget_edges(
      graph,
      "check_review_total_budget",
      "legacy_status_review_requires_rework",
      "snapshot_review_prior_commit",
      rework_max_cycles
    )
    |> check_dynamic_total_budget_edges(
      graph,
      "check_validation_total_budget",
      "status_validation_failed",
      validation_admitted_target,
      rework_max_cycles
    )
    |> check_dynamic_total_budget_edges(
      graph,
      "check_operator_rework_total_budget",
      "legacy_status_operator_approval_rework",
      "inc_operator_rework_count",
      rework_max_cycles
    )
  end

  defp check_dynamic_total_budget_edges(
         errors,
         graph,
         source,
         exhausted_target,
         admitted_target,
         rework_max_cycles
       ) do
    outgoing = Graph.outgoing_edges(graph, source)

    thresholds =
      Enum.map(outgoing, fn edge ->
        {edge.to, Map.get(edge.attrs, "condition")}
      end)

    valid? =
      Enum.sort(thresholds) ==
        Enum.sort([
          {exhausted_target, "context.total_rework_count>=#{rework_max_cycles}"},
          {admitted_target, "context.total_rework_count<#{rework_max_cycles}"}
        ])

    if valid? do
      errors
    else
      [
        error("review_convergence_budget_topology_mismatch", source, %{
          "actual" =>
            thresholds
            |> Enum.sort()
            |> Enum.map(fn {target, condition} -> [target, condition] end),
          "admitted_target" => admitted_target,
          "exhausted_target" => exhausted_target,
          "expected_max_cycles" => rework_max_cycles
        })
        | errors
      ]
    end
  end

  defp recovery_edge_json({from, to, condition}), do: [from, to, condition]

  defp check_worker_recovery_start_nodes(errors, graph, continuity) do
    errors
    |> require_recovery_start_attrs(graph, "open_worker", false, continuity)
    |> require_recovery_start_attrs(graph, "open_recovery_worker", true, continuity)
  end

  defp require_recovery_start_attrs(errors, graph, node_id, recovery?, continuity) do
    case Map.fetch(graph.nodes, node_id) do
      :error ->
        [error("worker_recovery_missing_node", node_id, %{}) | errors]

      {:ok, node} ->
        attrs = node.attrs
        expected_use_pool = continuity_value(continuity, :use_pool, attrs["param.use_pool"])
        expected_permission = continuity_value(continuity, :permission_mode, nil)
        expected_model = continuity_value(continuity, :model, :unknown)

        # Bound to reviewed worker_resume_session_id: true for explicit resume
        # or recovery reopen; absent for ordinary fresh open_worker.
        expected_fallback =
          cond do
            recovery? ->
              true

            match?(%{resume_session_id: sid} when is_binary(sid), continuity) ->
              true

            true ->
              nil
          end

        expected_context_keys =
          case {recovery?, expected_model} do
            {false, nil} -> "provider,cwd,workspace_id"
            {false, :unknown} -> attrs["context_keys"]
            {false, _model} -> "provider,cwd,workspace_id,model"
            {true, nil} -> "provider,cwd,workspace_id,session_id"
            {true, :unknown} -> attrs["context_keys"]
            {true, _model} -> "provider,cwd,workspace_id,session_id,model"
          end

        expected_static =
          %{
            "param.use_pool" => expected_use_pool,
            "context_keys" => expected_context_keys
          }
          |> maybe_expected(
            "param.fallback_to_fresh_on_resume_unavailable",
            expected_fallback
          )
          |> maybe_expected("param.permission_mode", expected_permission)

        errors =
          Enum.reduce(expected_static, errors, fn {attribute, expected}, acc ->
            actual = Map.get(attrs, attribute)

            if actual == expected do
              acc
            else
              [
                error("worker_recovery_start_binding_mismatch", node_id, %{
                  "attribute" => attribute,
                  "expected" => expected,
                  "actual" => actual
                })
                | acc
              ]
            end
          end)

        cond do
          recovery? and not Map.has_key?(attrs, "param.session_id") ->
            errors

          recovery? ->
            [
              error("worker_recovery_dynamic_session_id_violation", node_id, %{
                "attribute" => "param.session_id",
                "expected" => nil,
                "actual" => Map.get(attrs, "param.session_id")
              })
              | errors
            ]

          # Ordinary fresh open_worker: flag must be absent (forged true/false fails).
          is_nil(expected_fallback) and
              Map.has_key?(attrs, "param.fallback_to_fresh_on_resume_unavailable") ->
            [
              error("worker_recovery_start_binding_mismatch", node_id, %{
                "attribute" => "param.fallback_to_fresh_on_resume_unavailable",
                "expected" => nil,
                "actual" => Map.get(attrs, "param.fallback_to_fresh_on_resume_unavailable")
              })
              | errors
            ]

          true ->
            errors
        end
    end
  end

  defp continuity_value(%{use_pool: value}, :use_pool, _default), do: bool_string(value)
  defp continuity_value(%{permission_mode: value}, :permission_mode, _default), do: value
  defp continuity_value(%{model: value}, :model, _default), do: value
  defp continuity_value(_continuity, _key, default), do: default

  defp maybe_expected(map, _key, nil), do: map
  defp maybe_expected(map, key, value), do: Map.put(map, key, value)

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  defp require_worker_continuity_node_attrs(errors, graph, node_id, expected) do
    case Map.fetch(graph.nodes, node_id) do
      :error ->
        [error("worker_continuity_missing_node", node_id, %{}) | errors]

      {:ok, node} ->
        Enum.reduce(expected, errors, fn {attribute, expected_value}, acc ->
          actual = Map.get(node.attrs, attribute)

          if actual == expected_value do
            acc
          else
            [
              error("worker_continuity_binding_mismatch", node_id, %{
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

  defp check_worker_open_continuity(errors, graph, continuity) do
    case Map.fetch(graph.nodes, "open_worker") do
      :error ->
        errors

      {:ok, node} ->
        attrs = node.attrs
        context_keys = Map.get(attrs, "context_keys")

        errors
        |> require_worker_open_value(
          "context_keys",
          context_keys in [
            "provider,cwd,workspace_id",
            "provider,cwd,workspace_id,model"
          ],
          "provider,cwd,workspace_id or provider,cwd,workspace_id,model",
          context_keys
        )
        |> check_worker_pool_binding(attrs, continuity)
        |> check_worker_resume_binding(attrs, continuity)
    end
  end

  defp check_worker_pool_binding(errors, attrs, :unbound) do
    actual = Map.get(attrs, "param.use_pool")

    require_worker_open_value(
      errors,
      "param.use_pool",
      actual in ["true", "false"],
      "true or false",
      actual
    )
  end

  defp check_worker_pool_binding(errors, attrs, %{use_pool: use_pool}) do
    actual = Map.get(attrs, "param.use_pool")
    expected = if(use_pool, do: "true", else: "false")

    require_worker_open_value(
      errors,
      "param.use_pool",
      actual == expected,
      expected,
      actual
    )
  end

  defp check_worker_close_continuity(errors, graph, continuity) do
    case Map.fetch(graph.nodes, "close_worker") do
      :error ->
        errors

      {:ok, node} ->
        actual = Map.get(node.attrs, "param.return_to_pool")

        valid? =
          case continuity do
            :unbound -> actual in [true, false, "true", "false"]
            %{use_pool: expected} -> actual == expected
          end

        expected =
          case continuity do
            :unbound -> "true or false"
            %{use_pool: value} -> value
          end

        if valid? do
          errors
        else
          [
            error("worker_continuity_binding_mismatch", "close_worker", %{
              "attribute" => "param.return_to_pool",
              "expected" => expected,
              "actual" => actual
            })
            | errors
          ]
        end
    end
  end

  defp check_worker_resume_binding(errors, attrs, :unbound) do
    actual = Map.get(attrs, "param.session_id")

    valid? =
      is_nil(actual) or
        (is_binary(actual) and String.valid?(actual) and String.trim(actual) != "")

    require_worker_open_value(
      errors,
      "param.session_id",
      valid?,
      "absent or a nonblank provider session id",
      actual
    )
  end

  defp check_worker_resume_binding(errors, attrs, %{resume_session_id: nil}) do
    require_worker_open_value(
      errors,
      "param.session_id",
      not Map.has_key?(attrs, "param.session_id"),
      nil,
      Map.get(attrs, "param.session_id")
    )
  end

  defp check_worker_resume_binding(errors, attrs, %{resume_session_id: expected}) do
    actual = Map.get(attrs, "param.session_id")

    require_worker_open_value(
      errors,
      "param.session_id",
      actual == expected,
      expected,
      actual
    )
  end

  defp require_worker_open_value(errors, _attribute, true, _expected, _actual), do: errors

  defp require_worker_open_value(errors, attribute, false, expected, actual) do
    [
      error("worker_continuity_binding_mismatch", "open_worker", %{
        "attribute" => attribute,
        "expected" => expected,
        "actual" => actual
      })
      | errors
    ]
  end

  defp require_worker_continuity_edge(errors, graph, from, to, condition) do
    if Enum.any?(graph.edges, fn edge ->
         edge.from == from and edge.to == to and Map.get(edge.attrs, "condition") == condition
       end) do
      errors
    else
      [
        error("worker_continuity_missing_edge", from, %{
          "to" => to,
          "condition" => condition
        })
        | errors
      ]
    end
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

  defp check_profile_bindings(
         errors,
         graph,
         %{"validation_profile" => "default"},
         _review,
         validation_timeout_ms,
         _validation_test_stage_timeout_ms
       ) do
    check_validation_parameters(
      errors,
      graph,
      %{
        "param.timeout" => validation_timeout_ms,
        "param.warnings_as_errors" => true
      },
      "validation_parameter_violation"
    )
  end

  defp check_profile_bindings(
         errors,
         graph,
         %{"validation_profile" => "cross_app"},
         _review,
         validation_timeout_ms,
         validation_test_stage_timeout_ms
       )
       when is_integer(validation_test_stage_timeout_ms) and
              validation_test_stage_timeout_ms > 0 do
    check_validation_parameters(
      errors,
      graph,
      %{
        "param.timeout" => validation_timeout_ms,
        "param.test_stage_timeout" => validation_test_stage_timeout_ms
      },
      "validation_parameter_violation"
    )
  end

  defp check_profile_bindings(
         errors,
         _graph,
         %{"validation_profile" => "cross_app"},
         _review,
         _validation_timeout_ms,
         validation_test_stage_timeout_ms
       ) do
    [
      error("validation_parameter_violation", "validate", %{
        "missing_validation_test_stage_timeout_ms" => true,
        "got" => validation_test_stage_timeout_ms
      })
      | errors
    ]
  end

  defp check_profile_bindings(
         errors,
         graph,
         %{"validation_profile" => "security_regression"},
         review_profile,
         validation_timeout_ms,
         _validation_test_stage_timeout_ms
       ) do
    errors
    |> reject_security_review_none(review_profile)
    |> check_security_node_bindings(graph)
    |> check_security_validator_parameters(graph, validation_timeout_ms)
    |> check_security_protected_writers(graph)
    |> check_security_topology(graph, review_profile)
  end

  defp check_profile_bindings(
         errors,
         _graph,
         _policy,
         _review_profile,
         _validation_timeout_ms,
         _validation_test_stage_timeout_ms
       ),
       do: errors

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
         "context_keys" => "workspace_id,commit,prior_commit",
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
           "diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash,review_cycle,finding_ledger,prior_candidate_commit,delta_diff,delta_files,delta_ranges,test_paths,validation_profile",
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

  defp check_security_validator_parameters(errors, graph, validation_timeout_ms) do
    check_validation_parameters(
      errors,
      graph,
      %{"param.timeout" => validation_timeout_ms},
      "security_validator_parameter_violation"
    )
  end

  defp check_validation_parameters(errors, graph, expected, error_code) do
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

        if actual == expected do
          errors
        else
          [
            error(error_code, "validate", %{
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
      {"output_key", "commit_hash", ["hoist_change_commit", "hoist_commit_hash"]},
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
      {"route_prepared_review", [{"prep_review_validation_profile", nil}]},
      {"review_change",
       [
         {"error_council_review", "outcome=fail"},
         {"hoist_review_finding_ledger", "outcome=success"}
       ]},
      {"route_review",
       [
         {"remember_review_reviewed_commit", "context.review.tier_decision=rework"},
         {"status_review_rejected", "context.review.tier_decision=stop"},
         {"route_security_attested_human", "context.review.tier_decision=human_review"},
         {"route_security_attested_auto", "context.review.tier_decision=auto_proceed"},
         {"error_review_tier_invalid", nil}
       ]},
      {"route_security_attested_human",
       [
         {"hoist_review_attestation_id", @attestation_present},
         {"status_human_review_required", @attestation_absent}
       ]},
      {"route_security_attested_auto",
       [
         {"hoist_review_attestation_id", @attestation_present},
         {"error_review_tier_invalid", nil}
       ]},
      {"remember_review_reviewed_commit", [{"check_review_category_budget", nil}]},
      {"hoist_review_attestation_id", [{"validate", nil}]},
      {"validate",
       [
         {"status_validation_failed", "outcome=fail"},
         {"status_validation_capacity_exceeded",
          "outcome=success&&context.validation.reason=validation_capacity_exceeded"},
         {"check_validation_passed",
          "outcome=success&&context.validation.reason!=validation_capacity_exceeded"}
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
        |> check_action_placement_dominance(
          graph,
          policy,
          entry,
          reachable,
          dominators,
          review_profile
        )
        |> check_dominance(
          policy,
          dominators,
          reachable,
          review_profile
        )
        |> check_worker_continuity_dominance(reachable, dominators)
        |> check_security_rework_dominance(graph, policy)
    end
  end

  defp check_worker_continuity_dominance(errors, reachable, dominators) do
    errors
    |> require_dominates(
      "check_pre_turn_workspace_exists",
      "implement",
      reachable,
      dominators,
      "worker_pre_turn_workspace_exists_gate"
    )
    |> require_dominates(
      "hoist_worker_provider_session_id",
      "implement",
      reachable,
      dominators,
      "worker_provider_session_open_capture"
    )
    |> require_dominates(
      "hoist_worker_provider_session_id_from_message",
      "check_worker_stop_reason",
      reachable,
      dominators,
      "worker_provider_session_message_capture"
    )
    |> require_dominates(
      "check_worker_stop_reason",
      "inspect_workspace",
      reachable,
      dominators,
      "worker_stop_reason_gate"
    )
    |> require_dominates(
      "check_workspace_exists",
      "route_turn_progress",
      reachable,
      dominators,
      "worker_post_turn_workspace_exists_gate"
    )
  end

  # Prove each reviewed action node is reachable and that its policy-encoded
  # gates dominate the node where the side effect occurs. Unreachable or missing
  # targets fail closed (unlike optional publication dominance skips).
  defp check_action_placement_dominance(
         errors,
         graph,
         policy,
         entry,
         reachable,
         dominators,
         review_profile
       ) do
    Enum.reduce(policy["action_placements"], errors, fn placement, acc ->
      node_id = placement["node_id"]

      acc =
        if MapSet.member?(reachable, node_id) do
          acc
        else
          [
            error("unreachable_action_placement", node_id, %{
              "action" => placement["action"]
            })
            | acc
          ]
        end

      dominator_list =
        placement["required_dominators"] ++
          if review_profile in ["binding", "human_required"] do
            placement["review_required_dominators"]
          else
            []
          end

      acc =
        Enum.reduce(dominator_list, acc, fn dominator, inner ->
          require_placement_dominates(
            inner,
            dominator,
            node_id,
            reachable,
            dominators,
            "action_placement"
          )
        end)

      Enum.reduce(placement["required_dominator_sets"], acc, fn set, inner ->
        require_placement_set_dominates(
          inner,
          graph,
          entry,
          set,
          node_id,
          reachable,
          "action_placement_set"
        )
      end)
    end)
  end

  defp require_placement_dominates(errors, dominator, node, reachable, dominators, kind) do
    cond do
      not MapSet.member?(reachable, node) ->
        # Unreachable placement nodes are already reported.
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

  # Every path from entry to target must hit at least one member of the set.
  # Missing/unreachable sets fail closed rather than being skipped.
  defp require_placement_set_dominates(
         errors,
         graph,
         entry,
         dominator_set,
         target,
         reachable,
         kind
       ) do
    present =
      dominator_set
      |> Enum.filter(&MapSet.member?(reachable, &1))
      |> Enum.sort()

    cond do
      not MapSet.member?(reachable, target) ->
        errors

      present == [] ->
        [
          error("unreachable_dominator", nil, %{
            "kind" => kind,
            "target" => target,
            "required_dominator_set" => Enum.sort(dominator_set)
          })
          | errors
        ]

      can_reach_avoiding?(graph, entry, MapSet.new(present), target) ->
        [
          error("dominance_violation", target, %{
            "kind" => kind,
            "required_dominator_set" => Enum.sort(dominator_set)
          })
          | errors
        ]

      true ->
        errors
    end
  end

  defp can_reach_avoiding?(graph, entry, cuts, target) do
    do_can_reach_avoiding(graph, :queue.from_list([entry]), MapSet.new(), cuts, target)
  end

  defp do_can_reach_avoiding(graph, queue, visited, cuts, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        false

      {{:value, node_id}, rest} ->
        cond do
          node_id == target ->
            true

          MapSet.member?(visited, node_id) ->
            do_can_reach_avoiding(graph, rest, visited, cuts, target)

          MapSet.member?(cuts, node_id) ->
            # Cut barrier: path is satisfied; do not expand past the gate.
            do_can_reach_avoiding(graph, rest, visited, cuts, target)

          not Map.has_key?(graph.nodes, node_id) ->
            do_can_reach_avoiding(graph, rest, visited, cuts, target)

          true ->
            next = graph |> Graph.outgoing_edges(node_id) |> Enum.map(& &1.to)

            do_can_reach_avoiding(
              graph,
              enqueue_all(rest, next),
              MapSet.put(visited, node_id),
              cuts,
              target
            )
        end
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
      if target != @human_handoff_publication_node do
        # Unattended success still requires attestation + validation + exact head.
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
        |> require_dominates(
          attestation_source,
          target,
          reachable,
          dominators,
          "review_attestation"
        )
      else
        # status_human_review_required may be unattested; review still dominates.
        acc
        |> require_dominates(review_gate, target, reachable, dominators, "review")
        |> require_dominates(review_routing, target, reachable, dominators, "review_routing")
      end
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
        if target != @human_handoff_publication_node do
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
        else
          inner
          |> require_dominates(
            policy["review_gate"],
            target,
            reachable,
            dominators,
            "#{rework_kind}.fresh_review_terminal"
          )
          |> require_dominates(
            policy["review_routing_gate"],
            target,
            reachable,
            dominators,
            "#{rework_kind}.fresh_review_routing_terminal"
          )
        end
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
    do_reachable(graph, :queue.from_list([entry]), MapSet.new())
  end

  defp do_reachable(graph, queue, visited) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        visited

      {{:value, node_id}, rest} ->
        if MapSet.member?(visited, node_id) or not Map.has_key?(graph.nodes, node_id) do
          do_reachable(graph, rest, visited)
        else
          next =
            graph
            |> Graph.outgoing_edges(node_id)
            |> Enum.map(& &1.to)

          do_reachable(graph, enqueue_all(rest, next), MapSet.put(visited, node_id))
        end
    end
  end

  defp enqueue_all(queue, values) do
    Enum.reduce(values, queue, &:queue.in(&1, &2))
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
