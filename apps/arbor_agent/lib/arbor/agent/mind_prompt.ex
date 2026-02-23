defmodule Arbor.Agent.MindPrompt do
  @moduledoc """
  Lean capability-only prompt for the Mind LLM.

  Generates ~200-token prompts focused on what the Mind can do,
  not tool schemas. Uses progressive disclosure from Capabilities.

  ## Prompt Sections

  1. **Role** — one-line identity statement
  2. **Goal** — current active goal + progress
  3. **Last Percept** — result of previous action
  4. **Capabilities** — goal-aware auto-expanded list
  5. **Mental Tools** — inline descriptions of available mental ops
  6. **Response Format** — JSON schema for mental_actions/intent/wait
  """

  alias Arbor.Agent.Capabilities
  alias Arbor.Contracts.Memory.Percept

  @doc """
  Build the Mind system prompt for a mental cycle.

  ## Options

  - `:goal` — current goal map (%{id, description, progress})
  - `:last_percept` — most recent percept
  - `:goals` — list of all active goals (for goal-aware expansion)
  - `:agent_name` — agent's display name
  - `:identity` — brief identity context
  """
  @spec build(keyword()) :: String.t()
  def build(opts \\ []) do
    [
      role_section(opts),
      goal_section(opts),
      percept_section(opts),
      capabilities_section(opts),
      response_section(opts)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Build a compact user message for a mental cycle turn.

  Includes recent percepts from mental actions executed this cycle.
  """
  @spec build_iteration(keyword()) :: String.t()
  def build_iteration(opts \\ []) do
    recent_percepts = Keyword.get(opts, :recent_percepts, [])

    parts =
      if recent_percepts != [] do
        summaries =
          recent_percepts
          |> Enum.take(5)
          |> Enum.map_join("\n", fn p ->
            "- [#{p.outcome}] #{p.summary || "no summary"}"
          end)

        ["Results from mental actions:\n#{summaries}"]
      else
        []
      end

    parts = parts ++ ["What's next? Respond with JSON."]

    Enum.join(parts, "\n")
  end

  # ── Sections ──────────────────────────────────────────────────────────

  defp role_section(opts) do
    name = Keyword.get(opts, :agent_name, "Agent")
    identity = Keyword.get(opts, :identity)

    if identity do
      "You are #{name}. #{identity}"
    else
      "You are #{name}."
    end
  end

  defp goal_section(opts) do
    case Keyword.get(opts, :goal) do
      nil ->
        nil

      goal when is_map(goal) ->
        desc = Map.get(goal, :description) || Map.get(goal, "description", "")
        progress = Map.get(goal, :progress) || Map.get(goal, "progress", 0.0)
        pct = round(progress * 100)
        "GOAL: #{desc} (#{pct}% complete)"
    end
  end

  defp percept_section(opts) do
    case Keyword.get(opts, :last_percept) do
      nil ->
        nil

      %Percept{} = p ->
        "LAST RESULT: [#{p.outcome}] #{p.summary || "no details"}"

      _ ->
        nil
    end
  end

  defp capabilities_section(opts) do
    goals = Keyword.get(opts, :goals, [])

    cap_prompt =
      if goals != [] do
        Capabilities.goal_aware_prompt(goals)
      else
        Capabilities.prompt(1)
      end

    "CAPABILITIES:\n#{cap_prompt}"
  end

  defp response_section(_opts) do
    """
    RESPOND WITH JSON:
    {
      "mental_actions": [{"capability": "...", "op": "...", "params": {...}}],
      "intent": {"capability": "...", "op": "...", "target": "...", "reason": "..."} | null,
      "wait": false
    }

    RULES:
    - Use mental_actions for thinking, memory, goals, planning (unlimited per turn)
    - Set intent for ONE physical action (fs, shell, code, git, etc.) or null to keep thinking
    - Set wait=true to exit without acting
    - Physical capabilities: #{Enum.join(Capabilities.physical_capabilities(), ", ")}
    - Mental capabilities: #{Enum.join(Capabilities.mental_capabilities(), ", ")}\
    """
    |> String.trim()
  end
end
