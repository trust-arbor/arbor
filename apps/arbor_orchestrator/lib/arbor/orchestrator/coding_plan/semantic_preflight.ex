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
