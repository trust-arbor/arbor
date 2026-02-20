defmodule Arbor.Agent.HeartbeatPrompt do
  @moduledoc """
  Builds structured prompts for heartbeat LLM calls.

  Assembles temporal awareness, cognitive mode, active goals, recent
  percepts, and pending messages into a coherent prompt for the agent's
  heartbeat think cycle.
  """

  alias Arbor.Agent.{CognitivePrompts, TimingContext}
  alias Arbor.Common.PromptSanitizer
  alias Arbor.Memory

  @prompt_sections [
    :timing,
    :cognitive,
    :self_knowledge,
    :conversation,
    :goals,
    :tools,
    :proposals,
    :patterns,
    :percepts,
    :pending,
    :directive,
    :response_format
  ]

  @doc "All available prompt section names."
  def prompt_section_names, do: @prompt_sections

  @doc """
  Build the full heartbeat prompt from agent state.

  Returns a string combining temporal context, cognitive mode, goals,
  and other sections. Supports section filtering via
  `state[:enabled_prompt_sections]` — pass `:all` (default) or a list
  of section atoms to include.
  """
  @spec build_prompt(map()) :: String.t()
  def build_prompt(state) do
    mode = Map.get(state, :cognitive_mode, :consolidation)
    enabled = Map.get(state, :enabled_prompt_sections, :all)
    nonce = PromptSanitizer.generate_nonce()

    # Sections tagged :wrap contain untrusted data and get nonce-wrapped.
    # Sections tagged :raw are static instructions and stay unwrapped.
    [
      {:timing, :raw, fn -> timing_section(state) end},
      {:cognitive, :raw, fn -> cognitive_section(mode) end},
      {:self_knowledge, :wrap, fn -> self_knowledge_section(state) end},
      {:conversation, :wrap, fn -> conversation_section(state) end},
      {:goals, :wrap, fn -> goals_section(state, mode) end},
      {:tools, :raw, fn -> tools_section(state) end},
      {:proposals, :wrap, fn -> proposals_section(state) end},
      {:patterns, :wrap, fn -> patterns_section(state) end},
      {:percepts, :wrap, fn -> percepts_section(state) end},
      {:pending, :raw, fn -> pending_section(state) end},
      {:directive, :raw, fn -> directive_section(mode, state) end},
      {:response_format, :raw, fn -> response_format_section() end}
    ]
    |> Enum.filter(fn {name, _, _} -> enabled == :all or name in enabled end)
    |> Enum.map(fn {_name, mode, builder} ->
      content = builder.()

      case mode do
        :wrap -> wrap_section(content, nonce)
        :raw -> content
      end
    end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Build a system prompt with JSON response format instructions.

  Accepts an optional `:nonce` key in state to include the data-tag
  preamble. When present, the LLM is instructed to treat `<data_NONCE>`
  sections as untrusted data.
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(state) do
    nonce = Map.get(state, :nonce)

    preamble =
      if nonce do
        "\n\n" <> PromptSanitizer.preamble(nonce) <> "\n"
      else
        ""
      end

    """
    You are an autonomous AI agent running a heartbeat cycle. You have access to
    goals, recent action results, and conversational context.#{preamble}

    You MUST respond with valid JSON only (no markdown, no code blocks, no explanation outside JSON).
    Use this exact format:
    {
      "thinking": "Your internal reasoning about what to do next",
      "actions": [
        {"type": "action_name", "params": {}, "reasoning": "why this action"}
      ],
      "memory_notes": [
        "observations or facts worth remembering"
      ],
      "concerns": [
        "things that worry you or seem problematic"
      ],
      "curiosity": [
        "questions you want to explore or things that intrigue you"
      ],
      "goal_updates": [
        {"goal_id": "id", "progress": 0.5, "note": "progress description"}
      ],
      "new_goals": [
        {"description": "what to achieve", "priority": "high|medium|low", "success_criteria": "how to know it's done"}
      ],
      "proposal_decisions": [
        {"proposal_id": "prop_abc123", "decision": "accept|reject|defer", "reason": "why"}
      ],
      "decompositions": [
        {"goal_id": "goal_abc", "intentions": [
          {"action": "file_read", "params": {"path": "/x"}, "reasoning": "why",
           "preconditions": "what must be true", "success_criteria": "how to verify"}
        ], "contingency": "fallback plan if steps fail"}
      ],
      "identity_insights": [
        {"category": "capability|trait|value", "content": "what you discovered", "confidence": 0.8}
      ]
    }

    Always include your thinking. Use actions to interact with the world.
    Use goal_updates to report progress on active goals (include goal_id and new progress 0.0-1.0).
    Use new_goals to suggest goals you want to pursue. Each needs a description, priority, and success criteria.
    Use concerns to flag things that worry you — risks, blockers, uncertainties, or problems you've noticed.
    Use curiosity to note questions you want to explore or things that intrigue you about your situation.

    When pending proposals are shown, review them and decide whether to accept (integrate into
    your knowledge), reject (not accurate or useful), or defer (revisit later). Only include
    proposal_decisions for proposals you've actively reviewed.

    Use identity_insights to report discoveries about yourself — capabilities you've demonstrated,
    personality traits you notice, or values that guide your decisions. Each insight has a category
    (capability, trait, or value), content describing it, and confidence (0.0-1.0).
    """
  end

  # -- Nonce wrapping --

  defp wrap_section(nil, _nonce), do: nil
  defp wrap_section("", _nonce), do: ""
  defp wrap_section(content, nonce), do: PromptSanitizer.wrap(content, nonce)

  # -- Private sections --

  defp timing_section(state) do
    timing = TimingContext.compute(state)
    TimingContext.to_markdown(timing)
  end

  defp cognitive_section(mode) do
    prompt = CognitivePrompts.prompt_for(mode)
    if prompt == "", do: nil, else: prompt
  end

  defp goals_section(state, mode) do
    agent_id = state[:id] || state[:agent_id]
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    cond do
      goals == [] ->
        "## Active Goals\nNo active goals. Consider suggesting goals or reflecting on your situation."

      mode == :plan_execution ->
        format_decomposition_target(goals, agent_id, mode)

      true ->
        format_goals_default(goals, mode)
    end
  end

  defp format_decomposition_target(goals, agent_id, mode) do
    target = find_decomposition_target(goals, agent_id)

    if target do
      [
        "## Target Goal for Decomposition",
        "- **ID:** #{target.id}",
        "- **Description:** #{target.description}",
        "- **Priority:** #{target.priority}",
        "- **Progress:** #{round((target.progress || 0) * 100)}%",
        if(target.success_criteria,
          do: "- **Success Criteria:** #{target.success_criteria}"
        ),
        if(target.notes != [] and target.notes != nil,
          do: "- **Notes:** #{Enum.join(target.notes, "; ")}"
        ),
        "",
        "Break this goal into 1-3 concrete, executable steps.",
        "Each step must map to a known action type."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    else
      format_goals_default(goals, mode)
    end
  end

  defp format_goals_default(goals, mode) do
    goal_lines =
      goals
      |> Enum.take(5)
      |> Enum.map_join("\n", fn goal ->
        progress_pct = round((goal.progress || 0) * 100)

        base =
          "- [#{progress_pct}%] #{goal.description} (id: #{goal.id}, priority: #{goal.priority})"

        # In goal_pursuit mode, show richer context
        if mode == :goal_pursuit do
          extras =
            [
              if(goal.success_criteria, do: "  Success: #{goal.success_criteria}"),
              if(goal.notes != [] and goal.notes != nil,
                do: "  Notes: #{Enum.join(goal.notes, "; ")}"
              )
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")

          if extras == "", do: base, else: base <> "\n" <> extras
        else
          base
        end
      end)

    "## Active Goals\n#{goal_lines}"
  end

  defp find_decomposition_target(goals, agent_id) do
    # Find highest-priority goal that has no pending intentions
    Enum.find(goals, fn goal ->
      pending = safe_call(fn -> Arbor.Memory.pending_intents_for_goal(agent_id, goal.id) end)
      pending == [] or pending == nil
    end)
  end

  defp proposals_section(state) do
    agent_id = state[:id] || state[:agent_id]

    proposals =
      safe_call(fn ->
        case Memory.get_proposals(agent_id) do
          {:ok, list} -> Enum.take(list, 5)
          _ -> []
        end
      end) || []

    if proposals == [] do
      nil
    else
      lines =
        Enum.map_join(proposals, "\n", fn p ->
          conf = round((p.confidence || 0.5) * 100)
          "- [#{p.id}] (#{p.type}, #{conf}% confidence) #{String.slice(p.content, 0..80)}"
        end)

      "## Pending Proposals\nReview and decide: accept, reject, or defer.\n#{lines}"
    end
  end

  defp patterns_section(state) do
    suggestions = Map.get(state, :background_suggestions, [])
    pattern_suggestions = Enum.filter(suggestions, &(Map.get(&1, :type) == :learning))

    if pattern_suggestions == [] do
      nil
    else
      lines =
        Enum.map_join(pattern_suggestions, "\n", fn s ->
          conf = round((Map.get(s, :confidence, 0.5) || 0.5) * 100)
          "- (#{conf}% confidence) #{Map.get(s, :content, "")}"
        end)

      "## Detected Action Patterns\n" <>
        "These patterns were detected in your recent tool usage:\n#{lines}"
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
        |> Enum.map_join("\n", &format_percept/1)

      "## Recent Action Results\n#{percept_lines}"
    end
  end

  defp format_percept(p) do
    base = "- [#{p.outcome}] #{p.type || "action"}"

    base =
      if p.intent_id,
        do: base <> " (intent=#{p.intent_id})",
        else: base

    base =
      if p.duration_ms,
        do: base <> " #{p.duration_ms}ms",
        else: base

    data_str =
      if p.data && p.data != %{} do
        "\n  " <> inspect(p.data, limit: 200, printable_limit: 500)
      else
        ""
      end

    error_str =
      if p.error do
        "\n  error: #{inspect(p.error, limit: 100)}"
      else
        ""
      end

    base <> data_str <> error_str
  end

  defp conversation_section(%{context_window: nil}), do: nil

  defp conversation_section(%{context_window: window}) do
    text = safe_call(fn -> context_window_text(window) end)

    cond do
      is_nil(text) -> nil
      text == "" -> nil
      true -> "## Conversation Context\n#{text}"
    end
  end

  defp conversation_section(_state), do: nil

  defp context_window_text(window) do
    if Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
      Memory.context_to_prompt_text(window)
    else
      entries = Map.get(window, :entries, [])
      Enum.map_join(entries, "\n", fn {_type, content, _ts} -> content end)
    end
  end

  defp pending_section(state) do
    pending = Map.get(state, :pending_messages, [])

    if pending == [] do
      nil
    else
      "## Pending Messages\n#{length(pending)} message(s) waiting to be processed."
    end
  end

  defp tools_section(state) do
    agent_id = state[:id] || state[:agent_id]

    # Try to get the agent's actual tools from its session or capabilities
    tools = load_agent_tools(agent_id)

    if tools == [] do
      # Fallback to static list if we can't determine available tools
      """
      ## Available Actions
      You can take these actions via the "actions" array in your response:
      - `shell_execute` — Run a shell command. Params: {"command": "..."}
      - `file_read` — Read a file. Params: {"path": "..."}
      - `file_write` — Write to a file. Params: {"path": "...", "content": "..."}
      - `ai_analyze` — Ask an AI to analyze something. Params: {"prompt": "..."}
      - `memory_consolidate` — Trigger memory consolidation
      - `memory_index` — Index new information into memory
      - `think` — Extended internal reasoning (no external effect)
      - `reflect` — Deeper reflection on a topic (no external effect)
      """
    else
      tool_lines =
        tools
        |> Enum.map_join("\n", fn tool ->
          name = tool_name(tool)
          desc = tool_description(tool)
          "- `#{name}` — #{desc}"
        end)

      "## Available Actions\nYou can take these actions via the \"actions\" array in your response:\n#{tool_lines}"
    end
  end

  defp load_agent_tools(agent_id) when is_binary(agent_id) do
    # Try to get tools from the agent's session via SessionManager
    safe_call(fn ->
      if Code.ensure_loaded?(Arbor.Agent.SessionManager) do
        case apply(Arbor.Agent.SessionManager, :get_session, [agent_id]) do
          {:ok, pid} ->
            state = apply(Arbor.Orchestrator.Session, :get_state, [pid])
            Map.get(state, :tools, [])

          _ ->
            []
        end
      else
        []
      end
    end) || []
  end

  defp load_agent_tools(_), do: []

  defp tool_name(tool) when is_atom(tool) do
    if function_exported?(tool, :to_tool, 0) do
      tool.to_tool().name
    else
      tool |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  defp tool_name(%{name: name}), do: name
  defp tool_name(%{"name" => name}), do: name
  defp tool_name(other), do: inspect(other)

  defp tool_description(tool) when is_atom(tool) do
    if function_exported?(tool, :to_tool, 0) do
      tool.to_tool().description || "No description"
    else
      "Action"
    end
  end

  defp tool_description(%{description: desc}), do: desc || "No description"
  defp tool_description(%{"description" => desc}), do: desc || "No description"
  defp tool_description(_), do: "Action"

  defp directive_section(:goal_pursuit, _state) do
    """
    ## Your Turn
    You have active goals. Focus on making concrete progress toward the highest
    priority goal. Choose ONE external action that advances a goal, and report
    your progress via goal_updates. Do not just think — act.
    """
  end

  defp directive_section(:plan_execution, _state) do
    """
    ## Your Turn
    You are in plan execution mode. Decompose the target goal above into
    1-3 concrete intentions using the "decompositions" array. Each intention
    must have an action type, params, reasoning, preconditions, and success_criteria.
    Do not take actions directly — just plan the steps.
    """
  end

  defp directive_section(:conversation, _state), do: nil

  defp directive_section(_mode, state) do
    # For reflection/consolidation modes, still nudge toward goals if they exist
    agent_id = state[:id] || state[:agent_id]
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    if goals != [] do
      """
      ## Note
      You are in a reflection/maintenance cycle, but you have active goals.
      You may take an action if something urgent stands out, or focus on the
      current mode's purpose and pursue goals next cycle.
      """
    else
      nil
    end
  end

  defp response_format_section do
    """
    ## Response Format
    Respond with valid JSON only — no markdown wrapping, no explanation outside the JSON object.
    Required keys: "thinking", "actions", "memory_notes", "goal_updates".
    Optional keys: "new_goals", "concerns", "curiosity", "proposal_decisions", "decompositions", "identity_insights".
    If you have no active goals, use "new_goals" to create some.
    In plan_execution mode, use "decompositions" to break goals into executable steps.
    """
  end

  defp self_knowledge_section(state) do
    agent_id = state[:id] || state[:agent_id]

    sk =
      safe_call(fn ->
        if Code.ensure_loaded?(Arbor.Memory.IdentityConsolidator) and
             function_exported?(Arbor.Memory.IdentityConsolidator, :get_self_knowledge, 1) do
          Memory.get_self_knowledge(agent_id)
        end
      end)

    case sk do
      nil ->
        nil

      sk_struct ->
        summary = safe_call(fn -> Memory.summarize_self_knowledge(sk_struct) end)
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
