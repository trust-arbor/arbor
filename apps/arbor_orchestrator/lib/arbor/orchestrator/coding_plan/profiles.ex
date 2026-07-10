defmodule Arbor.Orchestrator.CodingPlan.Profiles do
  @moduledoc """
  Deterministic registry of reviewed coding-plan profiles.

  A declared profile is not necessarily executable. Call `fetch_executable/1`
  at execution boundaries so profiles whose enforcement contracts have not
  landed fail closed instead of falling back to `default`.
  """

  alias Arbor.Orchestrator.Graph

  @template_version "coding-change-v1"

  @required_nodes Enum.sort(~w[
                    acquire_workspace
                    adopt_head_commit
                    check_review_category_budget
                    check_review_total_budget
                    check_validation_category_budget
                    check_validation_passed
                    check_validation_total_budget
                    close_worker
                    commit_change
                    done
                    implement
                    inspect_workspace
                    load_committed_change
                    open_worker
                    release_workspace
                    review_change
                    route_after_commit
                    route_review
                    validate
                  ])

  @common_required_actions Enum.sort(~w[
                             acp_close_session
                             acp_send_message
                             acp_start_session
                             coding_workspace_acquire
                             coding_workspace_committed_change
                             coding_workspace_inspect
                             coding_workspace_release
                             council_review_change
                             git_commit
                           ])

  @binding_council_review %{
    "action" => "council_review_change",
    "binding" => true
  }

  @optional_reviewed_actions ["git_pr"]

  @mandatory_gate_nodes Enum.sort(~w[
                          validate
                          check_validation_passed
                          commit_change
                          route_after_commit
                          load_committed_change
                          review_change
                          route_review
                        ])

  @publication_nodes Enum.sort(~w[
                       status_change_committed
                       status_pr_created
                       status_human_review_required
                     ])

  @allowed_handlers Enum.sort(~w[start exit transform exec branch gate])
  @allowed_exec_targets ["action"]

  @default_required_actions Enum.sort(["mix_compile" | @common_required_actions])
  @security_required_actions Enum.sort(["mix_test" | @common_required_actions])

  @semantic_policy_base %{
    "allowed_handlers" => @allowed_handlers,
    "allowed_exec_targets" => @allowed_exec_targets,
    "optional_actions" => @optional_reviewed_actions,
    "mandatory_gate_nodes" => @mandatory_gate_nodes,
    "publication_nodes" => @publication_nodes,
    "validation_gate" => "validate",
    "post_validation_commit_routing" => "route_after_commit",
    "committed_change_routing" => "route_after_commit",
    "review_gate" => "review_change"
  }

  @profiles [
              %{
                "id" => "default",
                "executable" => true,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @default_required_actions,
                "validation_strategy" => %{"action" => "mix_compile"},
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@default_required_actions ++ @optional_reviewed_actions))
                  )
              },
              # Declaration preserves the reviewed future selector strategy. It is
              # not executable until one primitive proves both sides of the
              # regression contract against base and candidate revisions.
              %{
                "id" => "security_regression",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @security_required_actions,
                "validation_strategy" => %{
                  "action" => "mix_test",
                  "path_parameter" => "test_paths",
                  "path_source" => "requested_paths",
                  "requires_non_empty_paths" => true
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@security_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No reviewed validation primitive proves that the selected regression test " <>
                    "fails against the base/pre-fix code and passes against the candidate code."
              },
              %{
                "id" => "contract_change",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" =>
                    "contract_rules_preflight_and_consumer_api_compatibility"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No registered action enforces CONTRACT_RULES preflight and consumer/API " <>
                    "compatibility review for contract changes."
              },
              %{
                "id" => "frontend_visual",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" =>
                    "playwright_interaction_and_desktop_mobile_visual_evidence"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No registered action contract produces and verifies Playwright interaction " <>
                    "plus desktop/mobile visual evidence."
              },
              %{
                "id" => "docs_only",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" => "documentation_checks"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No registered documentation-validation action contract exists; " <>
                    "mix_compile is not an enforceable substitute for documentation checks."
              },
              %{
                "id" => "cross_app",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" => "dependency_surface_compile_xref_and_test_selection"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No enforceable action contract derives compile, xref, and test coverage from " <>
                    "the changed cross-app dependency surface."
              },
              %{
                "id" => "database_migration",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" => "reversible_database_migration_checks"
                },
                "review_strategy" => %{
                  "action" => "council_review_change",
                  "binding" => true,
                  "human_gate" => "required",
                  "unattended_publication" => "forbidden"
                },
                "semantic_policy" =>
                  Map.put(
                    @semantic_policy_base,
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No enforceable migration action contract combines reversible migration " <>
                    "checks, a mandatory human gate, and prohibition of unattended publication."
              }
            ]
            |> Enum.sort_by(& &1["id"])

  @profiles_by_id Map.new(@profiles, &{&1["id"], &1})

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type descriptor :: %{String.t() => json_value()}
  @type profile_selector :: String.t() | descriptor()
  @type inventory :: %{
          required(:nodes) => [String.t()] | MapSet.t(String.t()) | map(),
          required(:actions) => [String.t()] | MapSet.t(String.t()) | map()
        }
  @type requirement_error ::
          {:unknown_profile, term()}
          | {:profile_not_executable, String.t(), String.t()}
          | {:missing_requirements, %{required(String.t()) => [String.t()]}}
          | :invalid_requirement_inventory

  @doc "Returns every declared profile, sorted by profile ID."
  @spec all() :: [descriptor()]
  def all, do: @profiles

  @doc "Returns every declared profile ID in lexical order."
  @spec known_ids() :: [String.t()]
  def known_ids, do: Enum.map(@profiles, & &1["id"])

  @doc "Fetches a declared profile without changing or defaulting its ID."
  @spec fetch(term()) :: {:ok, descriptor()} | {:error, {:unknown_profile, term()}}
  def fetch(id) do
    case Map.fetch(@profiles_by_id, id) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:unknown_profile, id}}
    end
  end

  @doc "Fetches a profile only when all of its reviewed enforcement contracts exist."
  @spec fetch_executable(term()) ::
          {:ok, descriptor()}
          | {:error,
             {:unknown_profile, term()} | {:profile_not_executable, String.t(), String.t()}}
  def fetch_executable(id) do
    with {:ok, profile} <- fetch(id) do
      if profile["executable"] do
        {:ok, profile}
      else
        {:error, {:profile_not_executable, profile["id"], profile["unsupported_reason"]}}
      end
    end
  end

  @doc """
  Verifies that a graph or inventory contains every node and action required by
  a profile.

  The canonical call order is `validate_requirements(profile, graph)`. Graphs
  expose action names through each node's `"action"` attribute. A lightweight
  `%{nodes: ..., actions: ...}` inventory is accepted for deterministic unit
  tests and compiler boundaries. Subject-first calls are also accepted.
  """
  @spec validate_requirements(
          profile_selector() | Graph.t() | inventory(),
          profile_selector() | Graph.t() | inventory()
        ) ::
          :ok | {:error, requirement_error()}
  def validate_requirements(%Graph{} = graph, profile_or_id) do
    validate_profile_requirements(profile_or_id, graph)
  end

  def validate_requirements(%{nodes: _nodes, actions: _actions} = inventory, profile_or_id) do
    validate_profile_requirements(profile_or_id, inventory)
  end

  def validate_requirements(
        %{"nodes" => _nodes, "actions" => _actions} = inventory,
        profile_or_id
      ) do
    validate_profile_requirements(profile_or_id, inventory)
  end

  def validate_requirements(profile_or_id, graph_or_inventory) do
    validate_profile_requirements(profile_or_id, graph_or_inventory)
  end

  defp validate_profile_requirements(profile_or_id, graph_or_inventory) do
    with {:ok, profile} <- resolve_profile(profile_or_id),
         {:ok, inventory} <- requirement_inventory(graph_or_inventory) do
      missing = %{
        "missing_nodes" => missing(profile["required_nodes"], inventory.nodes),
        "missing_actions" => missing(profile["required_actions"], inventory.actions)
      }

      if missing == %{"missing_nodes" => [], "missing_actions" => []} do
        :ok
      else
        {:error, {:missing_requirements, missing}}
      end
    end
  end

  defp resolve_profile(%{"id" => id}), do: fetch(id)
  defp resolve_profile(id), do: fetch(id)

  defp requirement_inventory(%Graph{nodes: nodes}) do
    normalize_inventory(Map.keys(nodes), Enum.flat_map(nodes, &node_action/1))
  end

  defp requirement_inventory(%{nodes: nodes, actions: actions}) do
    normalize_inventory(nodes, actions)
  end

  defp requirement_inventory(%{"nodes" => nodes, "actions" => actions}) do
    normalize_inventory(nodes, actions)
  end

  defp requirement_inventory(_other), do: {:error, :invalid_requirement_inventory}

  defp normalize_inventory(nodes, actions) do
    with {:ok, nodes} <- string_set(nodes),
         {:ok, actions} <- string_set(actions) do
      {:ok, %{nodes: nodes, actions: actions}}
    else
      :error -> {:error, :invalid_requirement_inventory}
    end
  end

  defp string_set(%MapSet{} = values), do: string_set(MapSet.to_list(values))
  defp string_set(values) when is_map(values), do: string_set(Map.keys(values))

  defp string_set(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, MapSet.new(values)}
    else
      :error
    end
  end

  defp string_set(_values), do: :error

  defp node_action({_id, %{attrs: attrs}}) when is_map(attrs) do
    case Map.get(attrs, "action") || Map.get(attrs, :action) do
      action when is_binary(action) and action != "" -> [action]
      _other -> []
    end
  end

  defp node_action(_node), do: []

  defp missing(required, actual) do
    Enum.reject(required, &MapSet.member?(actual, &1))
  end
end
