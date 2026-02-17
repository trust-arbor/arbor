defmodule Arbor.AI.SystemPromptBuilder do
  @moduledoc """
  Builds rich system prompts for API-backend agents.

  Extracted from `Arbor.AI` — assembles identity, self-knowledge, goals,
  working memory, knowledge graph, timing context, and tool guidance
  from the agent's memory subsystems. Each section gracefully degrades
  if the data isn't available.
  """

  # Per-section token budgets. {:fixed, N} for static sections,
  # {:min_max, min, max, pct} for dynamic sections sized to context window.
  @section_budgets %{
    identity: {:fixed, 400},
    self_knowledge: {:min_max, 500, 4000, 0.05},
    tool_guidance: {:fixed, 400},
    goals: {:min_max, 200, 4000, 0.05},
    working_memory: {:min_max, 500, 8000, 0.10},
    knowledge_graph: {:min_max, 200, 4000, 0.05},
    active_skills: {:min_max, 500, 16000, 0.15},
    timing: {:fixed, 200}
  }

  # Safety cap for total system prompt (stable + volatile combined)
  @max_total_prompt_chars 80_000

  # Approximate chars per token for budget→char conversion
  @chars_per_token 4

  @doc """
  Build the stable (cacheable) system prompt for API-backend agents.

  Contains sections that rarely change: identity, self-knowledge, and tool
  guidance. Suitable for Anthropic prompt caching since these sections
  remain constant across queries within a session.

  ## Options

  - `:context_size` - Model context window size in tokens (default: 100_000)
  """
  @spec build_stable_system_prompt(String.t(), keyword()) :: String.t()
  def build_stable_system_prompt(agent_id, opts \\ []) do
    budgets = resolve_section_budgets(opts)

    sections = [
      truncate_section(build_identity_section(), budgets.identity),
      truncate_section(build_self_knowledge_section(agent_id), budgets.self_knowledge),
      truncate_section(build_tool_guidance_section(), budgets.tool_guidance)
    ]

    sections
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Build the volatile (per-turn) context for API-backend agents.

  Contains sections that change frequently: goals, working memory,
  knowledge graph, and timing context. This should be prepended to
  the user message rather than included in the system prompt.

  ## Options

  - `:state` - Agent state map (for timing context)
  - `:context_size` - Model context window size in tokens (default: 100_000)
  """
  @spec build_volatile_context(String.t(), keyword()) :: String.t()
  def build_volatile_context(agent_id, opts \\ []) do
    budgets = resolve_section_budgets(opts)

    sections = [
      truncate_section(build_goals_section(agent_id), budgets.goals),
      truncate_section(build_working_memory_section(agent_id), budgets.working_memory),
      truncate_section(build_active_skills_section(agent_id), budgets.active_skills),
      truncate_section(build_knowledge_graph_section(agent_id), budgets.knowledge_graph),
      truncate_section(build_timing_section(opts), budgets.timing)
    ]

    sections
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Build a rich system prompt for API-backend agents.

  Backward-compatible wrapper that joins the stable system prompt
  and volatile context into a single string. New callers should prefer
  `build_stable_system_prompt/2` + `build_volatile_context/2` for better
  size control and prompt caching.

  ## Options

  - `:state` - Agent state map (for timing context)
  """
  @spec build_rich_system_prompt(String.t(), keyword()) :: String.t()
  def build_rich_system_prompt(agent_id, opts \\ []) do
    stable = build_stable_system_prompt(agent_id, opts)
    volatile = build_volatile_context(agent_id, opts)

    prompt =
      [stable, volatile]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    truncate_total_prompt(prompt, @max_total_prompt_chars)
  end

  # ── Section Truncation ────────────────────────────────────────────

  defp truncate_section(nil, _budget_tokens), do: nil
  defp truncate_section("", _budget_tokens), do: ""

  defp truncate_section(text, budget_tokens) do
    max_chars = budget_tokens * @chars_per_token

    if String.length(text) <= max_chars do
      text
    else
      truncated_length = max(0, max_chars - 40)

      String.slice(text, 0, truncated_length) <>
        "\n[...truncated to #{budget_tokens} token budget]"
    end
  end

  defp resolve_section_budgets(opts) do
    context_size = Keyword.get(opts, :context_size, 100_000)
    token_budget_mod = Arbor.Memory.TokenBudget

    if Code.ensure_loaded?(token_budget_mod) and
         function_exported?(token_budget_mod, :allocate, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(token_budget_mod, :allocate, [@section_budgets, context_size])
    else
      %{
        identity: 400,
        self_knowledge: 2000,
        tool_guidance: 400,
        goals: 1000,
        working_memory: 4000,
        knowledge_graph: 1000,
        active_skills: 4000,
        timing: 200
      }
    end
  end

  defp truncate_total_prompt(prompt, max_chars) when byte_size(prompt) <= max_chars, do: prompt

  defp truncate_total_prompt(prompt, max_chars) do
    truncated = String.slice(prompt, 0, max_chars)

    truncated <>
      "\n\n[System prompt truncated — #{byte_size(prompt)} chars exceeded #{max_chars} limit]"
  end

  # ── Section Builders ──────────────────────────────────────────────

  defp build_identity_section do
    """
    ## Identity
    You are Arbor, an autonomous AI agent. You have memory, goals, and tools.
    You can recall past conversations, store new knowledge, reflect on your
    experiences, and take actions through your available tools. You are helpful,
    thorough, and you actively use your tools when they can help answer questions.
    When asked about yourself, use your memory tools to introspect.\
    """
  end

  defp build_self_knowledge_section(agent_id) do
    mod = Arbor.Memory.IdentityConsolidator

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_self_knowledge, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      sk = apply(mod, :get_self_knowledge, [agent_id])
      format_self_knowledge(sk)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_self_knowledge(nil), do: nil

  defp format_self_knowledge(sk) do
    mod = Arbor.Memory.SelfKnowledge
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    summary = if Code.ensure_loaded?(mod), do: apply(mod, :summarize, [sk])
    if summary not in ["", nil], do: "## Self-Awareness\n#{summary}"
  end

  defp build_goals_section(agent_id) do
    mod = Arbor.Memory.GoalStore

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_active_goals, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      goals = apply(mod, :get_active_goals, [agent_id])
      format_goals(goals)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_goals([]), do: nil

  defp format_goals(goals) do
    lines =
      goals
      |> Enum.take(5)
      |> Enum.map_join("\n", &format_goal_line/1)

    "## Active Goals\n#{lines}"
  end

  defp format_goal_line(goal) do
    pct = round((goal.progress || 0) * 100)
    "- [#{pct}%] #{goal.description} (priority: #{goal.priority})"
  end

  defp build_working_memory_section(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory) and
         function_exported?(Arbor.Memory, :get_working_memory, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      wm = apply(Arbor.Memory, :get_working_memory, [agent_id])
      format_working_memory(wm)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_working_memory(nil), do: nil

  defp format_working_memory(wm) do
    filtered_wm = filter_heartbeat_entries(wm)
    mod = Arbor.Memory.WorkingMemory
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    text = if Code.ensure_loaded?(mod), do: apply(mod, :to_prompt_text, [filtered_wm])
    if text not in ["", nil], do: "## Working Memory\n#{text}"
  end

  defp filter_heartbeat_entries(wm) do
    filtered_thoughts =
      Enum.reject(wm.recent_thoughts, fn thought ->
        content = if is_map(thought), do: Map.get(thought, :content, ""), else: ""
        String.starts_with?(content, "[hb] ")
      end)

    filtered_curiosity =
      Enum.reject(wm.curiosity, fn item ->
        is_binary(item) and String.starts_with?(item, "[hb] ")
      end)

    %{wm | recent_thoughts: filtered_thoughts, curiosity: filtered_curiosity}
  rescue
    _ -> wm
  end

  defp build_active_skills_section(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory) and
         function_exported?(Arbor.Memory, :get_working_memory, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      wm = apply(Arbor.Memory, :get_working_memory, [agent_id])
      format_active_skills(wm)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_active_skills(nil), do: nil

  defp format_active_skills(wm) do
    skills = Map.get(wm, :active_skills, [])

    if skills == [] do
      nil
    else
      skill_sections =
        skills
        |> Enum.map_join("\n\n---\n\n", fn skill ->
          "### #{skill.name}\n\n#{skill.body}"
        end)

      "## Active Skills\n\n#{skill_sections}"
    end
  end

  defp build_knowledge_graph_section(agent_id) do
    if :ets.whereis(:arbor_memory_graphs) != :undefined do
      agent_id
      |> lookup_knowledge_graph()
      |> format_knowledge_graph()
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp lookup_knowledge_graph(agent_id) do
    case :ets.lookup(:arbor_memory_graphs, agent_id) do
      [{_id, graph}] -> graph
      [] -> nil
    end
  end

  defp format_knowledge_graph(nil), do: nil

  defp format_knowledge_graph(graph) do
    mod = Arbor.Memory.KnowledgeGraph
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    text = if Code.ensure_loaded?(mod), do: apply(mod, :to_prompt_text, [graph, [max_nodes: 20]])

    case text do
      nil -> nil
      "" -> nil
      text -> "## Knowledge\n#{text}"
    end
  end

  defp build_timing_section(opts) do
    state = Keyword.get(opts, :state)

    if state && Code.ensure_loaded?(Arbor.Agent.TimingContext) do
      # credo:disable-for-lines:2 Credo.Check.Refactor.Apply
      timing = apply(Arbor.Agent.TimingContext, :compute, [state])
      text = apply(Arbor.Agent.TimingContext, :to_markdown, [timing])
      if text not in ["", nil], do: text
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp build_tool_guidance_section do
    """
    ## Tool Usage
    You have access to tools for memory, files, code, shell, git, communication,
    and more. When a user's request can be fulfilled by using a tool, use the
    appropriate tool rather than just describing what you would do. For example:
    - To search memory: use memory_recall
    - To learn about yourself: use memory_read_self
    - To store knowledge: use memory_remember
    - To read files: use file_read
    - To run commands: use shell_execute
    Be concise. Use tools proactively.\
    """
  end
end
