defmodule Arbor.Actions.Skill.StagedCompiler do
  @moduledoc """
  Multi-stage SKILL.md → DOT compiler.

  Goal: Produce high-fidelity, executable DOT pipelines that an autonomous
  Arbor agent can follow with confidence — often preferable to the raw SKILL.md.

  Current single-shot compilation produces decent mechanical translations.
  This module splits the work into deliberate stages so the LLM can reason
  more deeply about intent, decomposition, handler choice, robustness, and
  prompt quality.

  Stages (initial design):
  1. Analyze & Plan          — Classify + high-level execution plan
  2. Design Nodes            — Detailed node specs (type, prompt, edges, attributes)
  3. Assemble + Critique     — Produce DOT + self-critique against original skill intent
  4. (Optional) Validate+Fix — Reuse existing authoring validate_and_fix loop

  The CompilationPrompt remains the source of truth for rules, few-shots,
  and philosophy. Stage-specific instructions are lightweight overlays.

  This is early scaffolding. The public API will eventually replace or
  power `compile_skill_to_dot/1` in the Compile action.
  """

  alias Arbor.Actions.Skill.CompilationPrompt

  @type skill :: map()
  @type stage_result :: {:ok, map()} | {:error, term()}

  # Public entry point (will evolve)
  def compile(skill, opts \\ []) do
    backend = Keyword.get(opts, :backend, &default_backend/1)
    max_fixes = Keyword.get(opts, :max_fix_attempts, 2)

    with {:ok, plan} <- stage_analyze(skill, backend),
         {:ok, nodes} <- stage_design(skill, plan, backend),
         {:ok, dot_and_critique} <- stage_assemble_and_critique(skill, plan, nodes, backend),
         {:ok, final_dot} <- maybe_fix_loop(dot_and_critique, backend, max_fixes) do
      {:ok, final_dot}
    end
  end

  # --- Stage 1: Analyze & Plan ------------------------------------------------

  defp stage_analyze(skill, backend) do
    prompt = """
    #{system_prompt_for_stage(:analyze)}

    SKILL:
    #{format_skill_for_prompt(skill)}

    Produce a structured plan:
    - classification: reference | pipeline | decision_tree | cyclic
    - high_level_phases: list of 3-8 major phases
    - key_decisions: any branching or conditional logic implied
    - robustness_needs: error handling, retries, human checkpoints needed?
    - recommended_node_granularity: coarse | balanced | fine (justify briefly)

    Output as clean JSON only.
    """

    case backend.(prompt) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, plan} -> {:ok, plan}
          {:error, _} -> {:error, {:bad_plan_json, text}}
        end

      error ->
        error
    end
  end

  # --- Stage 2: Design Nodes --------------------------------------------------

  defp stage_design(skill, plan, backend) do
    prompt = """
    #{system_prompt_for_stage(:design)}

    ORIGINAL SKILL:
    #{format_skill_for_prompt(skill)}

    PLAN FROM PREVIOUS STAGE:
    #{inspect(plan, pretty: true)}

    For each phase in the plan, design the concrete nodes.
    For every node specify:
    - id (snake_case)
    - label
    - type (start | exit | llm | codergen | shell | exec | conditional | ...)
    - prompt (crisp, actionable instruction for the orchestrator node)
    - attributes (simulate, max_iterations, context_keys, etc. as needed)
    - outgoing edges (to which ids, with conditions/labels if relevant)

    Output as a JSON array of node objects + a "connections" list.
    Prioritize fidelity to the original skill's intent over brevity.
    """

    case backend.(prompt) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, design} -> {:ok, design}
          {:error, _} -> {:error, {:bad_design_json, text}}
        end

      error ->
        error
    end
  end

  # --- Stage 3: Assemble + Critique ------------------------------------------

  defp stage_assemble_and_critique(skill, plan, design, backend) do
    prompt = """
    #{system_prompt_for_stage(:assemble)}

    ORIGINAL SKILL (full intent):
    #{format_skill_for_prompt(skill)}

    PLAN: #{inspect(plan)}
    NODE DESIGN: #{inspect(design)}

    1. Assemble the complete, valid DOT graph (with // Category comment).
    2. Then provide a short critique:
       - Does this pipeline let an agent faithfully execute the entire skill?
       - Any missing steps, weak prompts, or poor handler choices?
       - Opportunities to add robustness?

    Output format:
    <<PIPELINE_SPEC>>
    [the full DOT here]
    <<END_PIPELINE_SPEC>>

    CRITIQUE:
    [bullet points]
    """

    backend.(prompt)
  end

  # --- Stage 4: Optional Fix Loop (reuses existing authoring logic) ---------

  defp maybe_fix_loop({:ok, response}, _backend, _max_fixes) do
    # For now, a simple placeholder. Later we will integrate
    # Arbor.Orchestrator.Authoring.DotGenerator.validate_and_fix/3
    # and extract the DOT using the improved logic in skill.ex.
    case extract_dot_from_response(response) do
      nil -> {:error, :no_dot_after_critique}
      dot -> {:ok, dot}
    end
  end

  defp maybe_fix_loop(error, _backend, _max_fixes), do: error

  # --- Helpers ----------------------------------------------------------------

  defp system_prompt_for_stage(:analyze) do
    base = CompilationPrompt.system_prompt()

    base <>
      """

      ## Current Task: Stage 1 — Analyze & Plan

      You are in the ANALYSIS phase only. Do not write the final DOT yet.
      Focus on deep understanding of the skill's true intent and how it should
      decompose into an executable state machine.
      """
  end

  defp system_prompt_for_stage(:design) do
    base = CompilationPrompt.system_prompt()

    base <>
      """

      ## Current Task: Stage 2 — Detailed Node Design

      You have a plan. Now design concrete, high-quality nodes.
      Every node prompt should be something an autonomous agent can follow
      without needing the original SKILL.md beside it.
      """
  end

  defp system_prompt_for_stage(:assemble) do
    base = CompilationPrompt.system_prompt()

    base <>
      """

      ## Current Task: Stage 3 — Assemble + Self-Critique

      Produce the final DOT, then ruthlessly critique it for fidelity to the
      original skill's intent. The critique is as important as the graph.
      """
  end

  defp format_skill_for_prompt(skill) do
    """
    Name: #{Map.get(skill, :name)}
    Description: #{Map.get(skill, :description, "")}

    #{Map.get(skill, :body, "")}
    """
  end

  # Temporary simple extractor (will be replaced by the improved one from skill.ex)
  defp extract_dot_from_response(response) when is_binary(response) do
    # Reuse the improved logic we added to skill.ex once we wire it
    case Regex.run(~r/(digraph\s+\w+\s*\{[\s\S]*\})/m, response) do
      [_, dot] -> String.trim(dot)
      _ -> nil
    end
  end

  # Placeholder backend (in real use this will be passed in, same pattern as DotGenerator)
  defp default_backend(prompt) do
    # In practice this will call Arbor.AI or the user's chosen provider
    {:ok, "PLACEHOLDER: would call LLM with prompt of length #{byte_size(prompt)}"}
  end
end
