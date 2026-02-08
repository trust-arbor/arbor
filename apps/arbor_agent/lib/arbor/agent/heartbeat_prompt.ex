defmodule Arbor.Agent.HeartbeatPrompt do
  @moduledoc """
  Builds structured prompts for heartbeat LLM calls.

  Assembles temporal awareness, cognitive mode, active goals, recent
  percepts, and pending messages into a coherent prompt for the agent's
  heartbeat think cycle.
  """

  alias Arbor.Agent.{CognitivePrompts, TimingContext}

  @doc """
  Build the full heartbeat prompt from agent state.

  Returns a string combining:
  - Temporal context (time since last user message, etc.)
  - Cognitive mode prompt (introspection, consolidation, etc.)
  - Self-knowledge summary
  - Conversation context from context window
  - Active goals summary
  - Recent percept results
  - Pending messages summary
  """
  @spec build_prompt(map()) :: String.t()
  def build_prompt(state) do
    mode = Map.get(state, :cognitive_mode, :consolidation)

    parts =
      [
        timing_section(state),
        cognitive_section(mode),
        self_knowledge_section(state),
        conversation_section(state),
        goals_section(state),
        percepts_section(state),
        pending_section(state),
        response_format_section()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, "\n\n")
  end

  @doc """
  Build a system prompt with JSON response format instructions.
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(_state) do
    """
    You are an autonomous AI agent running a heartbeat cycle. You have access to
    goals, recent action results, and conversational context.

    You MUST respond with valid JSON in the following format:
    {
      "thinking": "Your internal reasoning about what to do next",
      "actions": [
        {"type": "action_name", "params": {}, "reasoning": "why this action"}
      ],
      "memory_notes": [
        "observations or facts worth remembering"
      ],
      "goal_updates": [
        {"goal_id": "id", "progress": 0.5, "note": "progress description"}
      ]
    }

    If you have nothing to do, return empty arrays for actions, memory_notes, and goal_updates.
    Always include your thinking.
    """
  end

  # -- Private sections --

  defp timing_section(state) do
    timing = TimingContext.compute(state)
    TimingContext.to_markdown(timing)
  end

  defp cognitive_section(mode) do
    prompt = CognitivePrompts.prompt_for(mode)
    if prompt == "", do: nil, else: prompt
  end

  defp goals_section(state) do
    agent_id = state[:id] || state[:agent_id]
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    if goals == [] do
      "## Active Goals\nNo active goals."
    else
      goal_lines =
        goals
        |> Enum.take(5)
        |> Enum.map(fn goal ->
          progress_pct = round((goal.progress || 0) * 100)
          "- [#{progress_pct}%] #{goal.description} (priority: #{goal.priority})"
        end)
        |> Enum.join("\n")

      "## Active Goals\n#{goal_lines}"
    end
  end

  defp percepts_section(state) do
    agent_id = state[:id] || state[:agent_id]

    percepts =
      safe_call(fn -> Arbor.Memory.recent_percepts(agent_id, limit: 5) end) || []

    if percepts == [] do
      nil
    else
      percept_lines =
        percepts
        |> Enum.map(fn p ->
          "- [#{p.outcome}] intent=#{p.intent_id || "?"}, duration=#{p.duration_ms || "?"}ms"
        end)
        |> Enum.join("\n")

      "## Recent Action Results\n#{percept_lines}"
    end
  end

  defp conversation_section(%{context_window: nil}), do: nil

  defp conversation_section(%{context_window: window}) do
    text =
      safe_call(fn ->
        if Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
          Arbor.Memory.ContextWindow.to_prompt_text(window)
        else
          # Fallback for plain map context windows
          entries = Map.get(window, :entries, [])
          Enum.map_join(entries, "\n", fn {_type, content, _ts} -> content end)
        end
      end)

    cond do
      is_nil(text) -> nil
      text == "" -> nil
      true -> "## Conversation Context\n#{text}"
    end
  end

  defp conversation_section(_state), do: nil

  defp pending_section(state) do
    pending = Map.get(state, :pending_messages, [])

    if pending == [] do
      nil
    else
      "## Pending Messages\n#{length(pending)} message(s) waiting to be processed."
    end
  end

  defp response_format_section do
    """
    ## Response Format
    Respond with JSON only. Include "thinking", "actions", "memory_notes", and "goal_updates" keys.
    """
  end

  defp self_knowledge_section(state) do
    agent_id = state[:id] || state[:agent_id]

    sk =
      safe_call(fn ->
        if Code.ensure_loaded?(Arbor.Memory.IdentityConsolidator) and
             function_exported?(Arbor.Memory.IdentityConsolidator, :get_self_knowledge, 1) do
          Arbor.Memory.IdentityConsolidator.get_self_knowledge(agent_id)
        end
      end)

    case sk do
      nil ->
        nil

      sk_struct ->
        summary = safe_call(fn -> Arbor.Memory.SelfKnowledge.summarize(sk_struct) end)
        if summary && summary != "", do: "## Self-Awareness\n#{summary}", else: nil
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
