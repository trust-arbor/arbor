defmodule Arbor.Actions.Trust do
  @moduledoc """
  Trust profile operations as Jido actions.

  These actions are designed for the InterviewAgent — a specialized agent
  that mediates trust decisions between humans and AI agents. They provide
  read/write access to trust profiles and the ability to explain trust
  resolution chains.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `ReadProfile` | Read an agent's trust profile and current rules |
  | `ProposeProfile` | Propose changes to an agent's trust profile |
  | `ExplainMode` | Explain how a trust mode is resolved for a URI |
  | `ListPresets` | List available trust presets with their rules |
  | `ListAgents` | List agents and their trust status |

  ## Authorization

  All actions require `arbor://trust/read` or `arbor://trust/write` capability.
  The InterviewAgent template grants only these actions.
  """

  defmodule ReadProfile do
    @moduledoc """
    Read an agent's trust profile including baseline, rules, and tier.

    Returns the full profile information needed for the InterviewAgent
    to understand an agent's current trust posture.
    """

    use Jido.Action,
      name: "trust_read_profile",
      description: "Read an agent's trust profile — baseline mode, URI rules, tier, and score",
      category: "trust",
      tags: ["trust", "profile", "read"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "The agent whose trust profile to read"
        ]
      ]

    def taint_roles, do: %{agent_id: :control}

    @impl true
    def run(params, _context) do
      %{agent_id: agent_id} = params

      case get_trust_profile(agent_id) do
        {:ok, profile} ->
          {:ok,
           %{
             agent_id: profile.agent_id,
             tier: profile.tier,
             trust_score: profile.trust_score,
             baseline: profile.baseline,
             rules: profile.rules,
             frozen: profile.frozen,
             created_at: to_string(profile.created_at),
             last_activity_at: to_string(profile.last_activity_at)
           }}

        {:error, :not_found} ->
          {:error, "No trust profile found for agent #{agent_id}"}

        {:error, reason} ->
          {:error, "Failed to read trust profile: #{inspect(reason)}"}
      end
    end

    defp get_trust_profile(agent_id) do
      mod = Arbor.Trust

      if Code.ensure_loaded?(mod) and function_exported?(mod, :get_trust_profile, 1) do
        apply(mod, :get_trust_profile, [agent_id])
      else
        {:error, :trust_unavailable}
      end
    end
  end

  defmodule ProposeProfile do
    @moduledoc """
    Propose changes to an agent's trust profile.

    Does NOT apply changes directly — returns a structured proposal
    that must be confirmed by the user before being applied. This
    enforces the draft-then-confirm pattern for trust modifications.

    The proposal includes the current profile, proposed changes, and
    a diff showing what would change.
    """

    use Jido.Action,
      name: "trust_propose_profile",
      description:
        "Propose trust profile changes for an agent — returns a draft for user confirmation",
      category: "trust",
      tags: ["trust", "profile", "write", "proposal"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "The agent whose trust profile to modify"
        ],
        preset: [
          type: :string,
          doc:
            "Optional preset to apply: cautious, balanced, hands_off, full_trust. Overrides baseline/rules if set."
        ],
        baseline: [
          type: :string,
          doc: "Proposed baseline mode: block, ask, allow, auto"
        ],
        rule_changes: [
          type: :map,
          default: %{},
          doc:
            "Map of URI prefix => mode to add/change. Use mode 'remove' to delete a rule. Example: %{\"arbor://shell/exec/git\" => \"ask\"}"
        ]
      ]

    require Logger

    def taint_roles do
      %{agent_id: :control, preset: :control, baseline: :control, rule_changes: :control}
    end

    @impl true
    def run(params, _context) do
      %{agent_id: agent_id} = params

      with {:ok, current_profile} <- get_trust_profile(agent_id) do
        {new_baseline, new_rules} = compute_proposed_changes(params, current_profile)

        diff = compute_diff(current_profile, new_baseline, new_rules)

        {:ok,
         %{
           agent_id: agent_id,
           status: :proposed,
           current: %{
             baseline: current_profile.baseline,
             rules: current_profile.rules
           },
           proposed: %{
             baseline: new_baseline,
             rules: new_rules
           },
           diff: diff,
           instructions:
             "Review the proposed changes above. To apply, call ApplyProfile with this agent_id and the proposed baseline/rules."
         }}
      end
    end

    defp compute_proposed_changes(params, current_profile) do
      case Map.get(params, :preset) do
        nil ->
          baseline =
            case Map.get(params, :baseline) do
              nil -> current_profile.baseline
              mode_str -> parse_mode(mode_str)
            end

          rules = apply_rule_changes(current_profile.rules, Map.get(params, :rule_changes, %{}))
          {baseline, rules}

        preset_name ->
          preset_atom = safe_preset_atom(preset_name)
          {preset_baseline, preset_rules} = get_preset_rules(preset_atom)

          # Apply any additional rule_changes on top of preset
          rules = apply_rule_changes(preset_rules, Map.get(params, :rule_changes, %{}))
          {preset_baseline, rules}
      end
    end

    defp apply_rule_changes(current_rules, changes) when is_map(changes) do
      Enum.reduce(changes, current_rules, fn {uri, mode}, rules ->
        if mode == "remove" do
          Map.delete(rules, uri)
        else
          Map.put(rules, uri, parse_mode(mode))
        end
      end)
    end

    defp compute_diff(current_profile, new_baseline, new_rules) do
      baseline_changed = current_profile.baseline != new_baseline

      added =
        new_rules
        |> Enum.reject(fn {uri, mode} -> Map.get(current_profile.rules, uri) == mode end)
        |> Enum.into(%{})

      removed =
        current_profile.rules
        |> Enum.reject(fn {uri, _mode} -> Map.has_key?(new_rules, uri) end)
        |> Enum.into(%{})

      %{
        baseline_changed: baseline_changed,
        baseline_from: if(baseline_changed, do: current_profile.baseline),
        baseline_to: if(baseline_changed, do: new_baseline),
        rules_added_or_changed: added,
        rules_removed: Map.keys(removed)
      }
    end

    defp parse_mode(mode) when is_atom(mode), do: mode
    defp parse_mode("block"), do: :block
    defp parse_mode("ask"), do: :ask
    defp parse_mode("allow"), do: :allow
    defp parse_mode("auto"), do: :auto
    defp parse_mode(_), do: :ask

    defp safe_preset_atom(name) when is_atom(name), do: name

    defp safe_preset_atom(name) when is_binary(name) do
      case name do
        "cautious" -> :cautious
        "balanced" -> :balanced
        "hands_off" -> :hands_off
        "full_trust" -> :full_trust
        _ -> :balanced
      end
    end

    defp get_trust_profile(agent_id) do
      mod = Arbor.Trust

      if Code.ensure_loaded?(mod) and function_exported?(mod, :get_trust_profile, 1) do
        apply(mod, :get_trust_profile, [agent_id])
      else
        {:error, :trust_unavailable}
      end
    end

    defp get_preset_rules(preset_atom) do
      mod = Arbor.Trust.Policy

      if Code.ensure_loaded?(mod) and function_exported?(mod, :preset_rules, 1) do
        apply(mod, :preset_rules, [preset_atom])
      else
        {:ask, %{}}
      end
    end
  end

  defmodule ApplyProfile do
    @moduledoc """
    Apply confirmed trust profile changes.

    This action is called after the user has reviewed and approved
    a proposal from ProposeProfile. It writes the changes to the
    trust profile store.
    """

    use Jido.Action,
      name: "trust_apply_profile",
      description: "Apply confirmed trust profile changes after user approval",
      category: "trust",
      tags: ["trust", "profile", "write", "apply"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "The agent whose trust profile to update"
        ],
        baseline: [
          type: :string,
          required: true,
          doc: "The confirmed baseline mode: block, ask, allow, auto"
        ],
        rules: [
          type: :map,
          required: true,
          doc: "The confirmed rules map of URI prefix => mode"
        ]
      ]

    require Logger

    def taint_roles do
      %{agent_id: :control, baseline: :control, rules: :control}
    end

    @impl true
    def run(params, _context) do
      %{agent_id: agent_id, baseline: baseline_str, rules: rules_raw} = params

      baseline = parse_mode(baseline_str)

      rules =
        rules_raw
        |> Enum.map(fn {uri, mode} -> {uri, parse_mode(mode)} end)
        |> Enum.into(%{})

      case update_trust_profile(agent_id, baseline, rules) do
        {:ok, _profile} ->
          Logger.info("[InterviewAgent] Applied trust profile changes for #{agent_id}")

          {:ok,
           %{
             agent_id: agent_id,
             status: :applied,
             baseline: baseline,
             rules: rules,
             message: "Trust profile updated successfully."
           }}

        {:error, reason} ->
          {:error, "Failed to apply profile changes: #{inspect(reason)}"}
      end
    end

    defp update_trust_profile(agent_id, baseline, rules) do
      if Code.ensure_loaded?(Arbor.Trust.Store) and
           function_exported?(Arbor.Trust.Store, :update_profile, 2) do
        Arbor.Trust.Store.update_profile(agent_id, fn profile ->
          %{profile | baseline: baseline, rules: rules}
        end)
      else
        {:error, :trust_unavailable}
      end
    end

    defp parse_mode(mode) when is_atom(mode), do: mode
    defp parse_mode("block"), do: :block
    defp parse_mode("ask"), do: :ask
    defp parse_mode("allow"), do: :allow
    defp parse_mode("auto"), do: :auto
    defp parse_mode(_), do: :ask
  end

  defmodule ExplainMode do
    @moduledoc """
    Explain how a trust mode is resolved for a specific agent and resource URI.

    Returns the full resolution chain: user preference, security ceiling,
    model constraint, and the resulting effective mode. Useful for helping
    users understand why a particular action is blocked, gated, or allowed.
    """

    use Jido.Action,
      name: "trust_explain_mode",
      description:
        "Explain how a trust mode is resolved — shows user preference, security ceiling, and effective mode",
      category: "trust",
      tags: ["trust", "explain", "debug"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "The agent to explain trust for"
        ],
        resource_uri: [
          type: :string,
          required: true,
          doc: "The resource URI to explain (e.g., arbor://shell/exec/git)"
        ]
      ]

    def taint_roles, do: %{agent_id: :control, resource_uri: :control}

    @impl true
    def run(params, _context) do
      %{agent_id: agent_id, resource_uri: resource_uri} = params

      explanation = get_explanation(agent_id, resource_uri)

      {:ok, explanation}
    end

    defp get_explanation(agent_id, resource_uri) do
      mod = Arbor.Trust

      if Code.ensure_loaded?(mod) and function_exported?(mod, :explain, 2) do
        apply(mod, :explain, [agent_id, resource_uri])
      else
        %{
          resource_uri: resource_uri,
          error: :trust_unavailable,
          effective_mode: :ask
        }
      end
    end
  end

  defmodule ListPresets do
    @moduledoc """
    List available trust presets with their baseline modes and rules.

    Used during onboarding to show the user what presets are available
    and what each one means in practice.
    """

    use Jido.Action,
      name: "trust_list_presets",
      description: "List available trust presets with their baseline modes and rules",
      category: "trust",
      tags: ["trust", "presets", "list"],
      schema: []

    def taint_roles, do: %{}

    @impl true
    def run(_params, _context) do
      presets =
        [:cautious, :balanced, :hands_off, :full_trust]
        |> Enum.map(fn name ->
          {baseline, rules} = get_preset_rules(name)

          %{
            name: name,
            baseline: baseline,
            rules: rules,
            description: preset_description(name)
          }
        end)

      {:ok, %{presets: presets}}
    end

    defp preset_description(:cautious) do
      "Conservative. Reads are automatic, writes and shell are blocked. Best for agents you're just getting to know."
    end

    defp preset_description(:balanced) do
      "Moderate. Reads are automatic, writes notify you, shell commands need approval. Good default for most agents."
    end

    defp preset_description(:hands_off) do
      "Permissive. Most operations proceed with notification. Shell and governance still require approval."
    end

    defp preset_description(:full_trust) do
      "Maximum autonomy. Everything is automatic except shell and governance (security ceiling enforced)."
    end

    defp get_preset_rules(preset_atom) do
      mod = Arbor.Trust.Policy

      if Code.ensure_loaded?(mod) and function_exported?(mod, :preset_rules, 1) do
        apply(mod, :preset_rules, [preset_atom])
      else
        {:ask, %{}}
      end
    end
  end

  defmodule ListAgents do
    @moduledoc """
    List agents and their trust profile summaries.

    Provides an overview of all agents in the system and their current
    trust posture — tier, baseline, frozen status.
    """

    use Jido.Action,
      name: "trust_list_agents",
      description: "List all agents with their trust profile summaries",
      category: "trust",
      tags: ["trust", "agents", "list"],
      schema: []

    def taint_roles, do: %{}

    @impl true
    def run(_params, _context) do
      case list_profiles() do
        {:ok, profiles} ->
          summaries =
            Enum.map(profiles, fn profile ->
              %{
                agent_id: profile.agent_id,
                tier: profile.tier,
                trust_score: profile.trust_score,
                baseline: profile.baseline,
                rule_count: map_size(profile.rules || %{}),
                frozen: profile.frozen
              }
            end)

          {:ok, %{agents: summaries, count: length(summaries)}}

        {:error, reason} ->
          {:error, "Failed to list agents: #{inspect(reason)}"}
      end
    end

    defp list_profiles do
      mod = Arbor.Trust

      if Code.ensure_loaded?(mod) and function_exported?(mod, :list_profiles, 1) do
        apply(mod, :list_profiles, [[]])
      else
        {:error, :trust_unavailable}
      end
    end
  end
end
