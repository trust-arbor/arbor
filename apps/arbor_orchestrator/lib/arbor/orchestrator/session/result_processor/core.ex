defmodule Arbor.Orchestrator.Session.ResultProcessor.Core do
  @moduledoc """
  Pure core for heartbeat/turn result processing.

  Builds proposals and aggregates goal changes from a result context with **no side
  effects** — no signal emission, no proposal persistence, no message sends. The
  effectful boundary is `Arbor.Orchestrator.Session.ResultProcessor`, which calls this
  core to construct proposals and then performs the effects (create + emit).

  ## CRC

  - **Construct** — `generate_heartbeat_proposals/3` builds a proposal list from a
    result context (and the session state, read-only via `ContextBuilder`).
  - **Reduce** — the `maybe_add_*` steps transform/accumulate the proposal list;
    `apply_goal_changes/3` merges goal updates into the existing goals.
  - **Convert** — returns plain proposal maps (`%{type:, content:, metadata:}`) that
    the boundary persists and emits.
  """

  alias Arbor.Orchestrator.Session.ContextBuilder

  # Maximum observation proposals per heartbeat to prevent volume explosion
  @max_observations_per_heartbeat 5

  # Internal monologue prefixes — these are self-instructions, not observations
  @intention_prefixes [
    "Should ",
    "Need to ",
    "Want to ",
    "Must ",
    "Have to ",
    "I should ",
    "I need to ",
    "I want to ",
    "I must ",
    "I have to "
  ]

  # ── Goal changes ──────────────────────────────────────────────────

  @doc false
  def apply_goal_changes(existing_goals, updates, new_goals) do
    updated =
      Enum.map(existing_goals, fn goal ->
        case Enum.find(updates, &(Map.get(&1, "id") == Map.get(goal, "id"))) do
          nil -> goal
          update -> Map.merge(goal, update)
        end
      end)

    updated ++ List.wrap(new_goals)
  end

  # ── Heartbeat proposal generation (Phase 3) ──────────────────────

  @doc false
  def generate_heartbeat_proposals(agent_id, state, result_ctx) do
    []
    |> maybe_add_cognitive_mode_proposal(state, result_ctx)
    |> maybe_add_goal_proposals(result_ctx)
    |> maybe_add_goal_update_proposals(result_ctx)
    |> maybe_add_wm_proposals(result_ctx)
    |> maybe_add_decomposition_proposals(result_ctx)
    |> maybe_add_identity_proposals(agent_id, result_ctx)
  end

  @doc false
  def maybe_add_cognitive_mode_proposal(proposals, state, result_ctx) do
    case Map.get(result_ctx, "session.cognitive_mode") do
      mode when is_binary(mode) and mode != "" ->
        current = to_string(ContextBuilder.get_cognitive_mode(state))

        if mode != current do
          [
            %{
              type: :cognitive_mode,
              content: "Switch to #{mode} mode",
              metadata: %{from: current, to: mode}
            }
            | proposals
          ]
        else
          proposals
        end

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_goal_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.new_goals", []) do
      goals when is_list(goals) and goals != [] ->
        goal_proposals =
          goals
          |> Enum.map(fn goal ->
            desc = Map.get(goal, "description", "")
            desc = if is_binary(desc), do: String.trim(desc), else: ""
            {desc, goal}
          end)
          |> Enum.reject(fn {desc, _goal} -> desc == "" end)
          |> Enum.map(fn {desc, goal} ->
            %{
              type: :goal,
              content: desc,
              metadata: %{goal_data: goal}
            }
          end)

        goal_proposals ++ proposals

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_goal_update_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.goal_updates", []) do
      updates when is_list(updates) and updates != [] ->
        update_proposals =
          Enum.map(updates, fn update ->
            %{
              type: :goal_update,
              content: "Update goal #{Map.get(update, "id", "?")}",
              metadata: %{update_data: update}
            }
          end)

        update_proposals ++ proposals

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_wm_proposals(proposals, result_ctx) do
    thoughts = Map.get(result_ctx, "session.memory_notes", [])
    concerns = Map.get(result_ctx, "session.concerns", [])
    curiosities = Map.get(result_ctx, "session.curiosity", [])

    thought_props =
      thoughts
      |> List.wrap()
      |> Enum.map(fn t ->
        {text, metadata} = extract_note_with_metadata(t)
        %{type: :thought, content: text, metadata: metadata}
      end)
      |> Enum.reject(&internal_monologue?/1)

    concern_props =
      Enum.map(List.wrap(concerns), fn c ->
        {text, metadata} = extract_note_with_metadata(c)
        %{type: :concern, content: text, metadata: metadata}
      end)

    curiosity_props =
      Enum.map(List.wrap(curiosities), fn c ->
        {text, metadata} = extract_note_with_metadata(c)
        %{type: :curiosity, content: text, metadata: metadata}
      end)

    wm_proposals = thought_props ++ concern_props ++ curiosity_props

    # Cap total observations per heartbeat — LLM puts most important first
    capped = Enum.take(wm_proposals, @max_observations_per_heartbeat)

    capped ++ proposals
  end

  @doc false
  def internal_monologue?(%{content: text}) do
    Enum.any?(@intention_prefixes, &String.starts_with?(text, &1))
  end

  @doc false
  def extract_note_with_metadata(note) when is_binary(note), do: {note, %{}}

  def extract_note_with_metadata(%{"text" => text} = note) when is_binary(text) do
    metadata =
      case Map.get(note, "referenced_date") do
        date_str when is_binary(date_str) -> %{referenced_date: date_str}
        _ -> %{}
      end

    {text, metadata}
  end

  def extract_note_with_metadata(other), do: {inspect(other), %{}}

  @doc false
  def maybe_add_decomposition_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.decompositions", []) do
      decomps when is_list(decomps) and decomps != [] ->
        intent_proposals =
          Enum.map(decomps, fn d ->
            %{
              type: :intent,
              content: Map.get(d, "description", "Decomposed intent"),
              metadata: %{decomposition: d}
            }
          end)

        intent_proposals ++ proposals

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_identity_proposals(proposals, _agent_id, result_ctx) do
    case Map.get(result_ctx, "session.identity_insights", []) do
      insights when is_list(insights) and insights != [] ->
        identity_proposals =
          Enum.map(insights, fn insight ->
            text =
              if is_binary(insight), do: insight, else: Map.get(insight, "text", inspect(insight))

            %{type: :identity, content: text, metadata: %{source: "heartbeat"}}
          end)

        identity_proposals ++ proposals

      _ ->
        proposals
    end
  end
end
