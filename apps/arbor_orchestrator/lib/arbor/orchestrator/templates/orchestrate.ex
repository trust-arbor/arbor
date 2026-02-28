defmodule Arbor.Orchestrator.Templates.Orchestrate do
  @moduledoc """
  Generates DOT pipeline strings for multi-agent orchestration.

  Produces a plan-fork-branches-collect-synthesize pipeline where each
  branch runs a `codergen` node with `llm_provider="acp"` routed to
  a specific CLI agent (claude, codex, gemini, etc.).
  """

  @default_tools "file_read,file_write,file_search,file_glob,shell"
  @default_max_turns "20"

  @doc """
  Generate a DOT pipeline string for multi-agent orchestration.

  ## Parameters

  - `goal` — the high-level goal description
  - `branches` — list of branch configs:
    ```
    [%{name: "branch_0", agent: "claude", workdir: "/path/to/worktree", tools: "file_read,..."}]
    ```
  - `opts`:
    - `:max_parallel` — max concurrent branches (default: branch count)
    - `:no_plan` — skip planning phase, send goal directly (default: false)
    - `:join_policy` — "wait_all" | "first_success" | "k_of_n" (default: "wait_all")
    - `:error_policy` — "continue" | "fail_fast" (default: "continue")
  """
  @spec generate(String.t(), [map()], keyword()) :: String.t()
  def generate(goal, branches, opts \\ []) do
    max_parallel = Keyword.get(opts, :max_parallel, length(branches))
    no_plan = Keyword.get(opts, :no_plan, false)
    join_policy = Keyword.get(opts, :join_policy, "wait_all")
    error_policy = Keyword.get(opts, :error_policy, "continue")

    branch_nodes = Enum.map(branches, &branch_node(&1, no_plan, goal))
    branch_edges = Enum.map(branches, &branch_edge/1)

    [
      "digraph orchestrate {",
      "  goal=#{quote_dot(goal)}",
      "",
      "  start [type=\"start\"]",
      "",
      plan_section(no_plan, length(branches)),
      "",
      "  fork [type=\"parallel\" join_policy=#{quote_dot(join_policy)} error_policy=#{quote_dot(error_policy)} max_parallel=\"#{max_parallel}\"]",
      "",
      Enum.join(branch_nodes, "\n\n"),
      "",
      "  collect [type=\"parallel.fan_in\"]",
      "",
      synthesize_node(),
      "",
      "  exit [type=\"exit\"]",
      "",
      "  // Edges",
      plan_edges(no_plan),
      Enum.join(branch_edges, "\n"),
      "  collect -> synthesize -> exit",
      "}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp plan_section(true = _no_plan, _branch_count) do
    [
      "  // No planning phase — goal sent directly to all branches"
    ]
  end

  defp plan_section(false = _no_plan, branch_count) do
    [
      "  plan [",
      "    type=\"codergen\"",
      "    simulate=\"false\"",
      "    use_tools=\"true\"",
      "    tools=\"file_read,file_search,file_glob\"",
      "    llm_provider=\"acp\"",
      "    max_turns=\"10\"",
      "    system_prompt=#{quote_dot(plan_system_prompt(branch_count))}",
      "  ]"
    ]
  end

  defp plan_system_prompt(branch_count) do
    """
    You are a planning agent. Analyze the goal and decompose it into exactly \
    #{branch_count} independent subtasks that can be worked on in parallel.\
    \n\nFor each subtask, write a clear description to the context key \
    "subtask.N" (where N is 0-indexed). Each subtask should be self-contained \
    and not depend on other subtasks.\
    \n\nExplore the codebase first to understand the structure, then create \
    focused, actionable subtask descriptions.\
    """
    |> String.trim()
  end

  defp branch_node(branch, no_plan, goal) do
    name = Map.fetch!(branch, :name)
    agent = Map.get(branch, :agent, "claude")
    workdir = Map.get(branch, :workdir, ".")
    tools = Map.get(branch, :tools, @default_tools)
    max_turns = Map.get(branch, :max_turns, @default_max_turns)

    prompt_line =
      if no_plan do
        "    system_prompt=#{quote_dot(goal)}"
      else
        "    prompt_context_key=\"subtask.#{branch_index(name)}\""
      end

    [
      "  #{name} [",
      "    type=\"codergen\"",
      "    simulate=\"false\"",
      "    use_tools=\"true\"",
      "    tools=#{quote_dot(tools)}",
      "    llm_provider=\"acp\"",
      "    provider_options=#{quote_dot("{\"agent\": \"#{agent}\"}")}",
      "    workdir=#{quote_dot(workdir)}",
      "    max_turns=\"#{max_turns}\"",
      prompt_line,
      "  ]"
    ]
    |> Enum.join("\n")
  end

  defp branch_edge(branch) do
    name = Map.fetch!(branch, :name)
    "  fork -> #{name} -> collect"
  end

  defp synthesize_node do
    [
      "  synthesize [",
      "    type=\"codergen\"",
      "    simulate=\"false\"",
      "    llm_provider=\"acp\"",
      "    max_turns=\"5\"",
      "    system_prompt=#{quote_dot(synthesize_prompt())}",
      "  ]"
    ]
    |> Enum.join("\n")
  end

  defp synthesize_prompt do
    """
    Review the results from all parallel branches in the context. \
    Summarize what each branch accomplished, identify any conflicts \
    or overlapping changes, and produce a final status report. \
    If branches modified the same files, note the conflicts.\
    """
    |> String.trim()
  end

  defp plan_edges(true = _no_plan), do: "  start -> fork"
  defp plan_edges(false = _no_plan), do: "  start -> plan -> fork"

  defp branch_index(name) do
    case Regex.run(~r/(\d+)$/, to_string(name)) do
      [_, idx] -> idx
      _ -> "0"
    end
  end

  defp quote_dot(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end
