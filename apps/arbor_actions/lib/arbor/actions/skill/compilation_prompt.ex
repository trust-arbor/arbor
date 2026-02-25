defmodule Arbor.Actions.Skill.CompilationPrompt do
  @moduledoc """
  System prompt for SKILL.md → DOT compilation.

  Uses few-shot examples + classify-then-compile Chain of Thought,
  per council recommendations (13/13 unanimous, 2026-02-17).
  """

  @handler_registry """
  ## Available Handler Types

  | Type | Purpose | Key Attributes |
  |------|---------|---------------|
  | `start` | Entry point | (none required) |
  | `exit` | Terminal node | (none required) |
  | `codergen` | Code generation / file writing | `prompt`, `simulate` |
  | `shell` | Shell command execution | `prompt`, `simulate` |
  | `llm` | LLM reasoning / analysis (no side effects) | `prompt` |
  | `conditional` | Decision routing | (edges carry conditions) |
  | `tool` | Execute a registered tool | `tool_command` |
  | `exec` | Execute an action | `target="action"`, `action`, `context_keys` |
  | `consensus.ask` | Advisory council consultation | `prompt` |
  | `consensus.decide` | Council vote/decision | `prompt` |
  | `parallel` | Fan-out to parallel branches | `fan_out="true"` |
  | `parallel.fan_in` | Wait for parallel branches | (none required) |
  | `accumulator` | Collect/aggregate results | `prompt` |
  | `feedback.loop` | Iterative refinement | `prompt`, `max_iterations` |

  ### Notes:
  - `llm` and `codergen` both route to LLM calls; use `llm` for pure reasoning/analysis, `codergen` for generating files/artifacts
  - `shell` nodes MUST have `simulate="true"` unless the skill explicitly requires real execution
  - All loop-back edges MUST have `max_iterations="N"` to prevent infinite loops
  - Use `exec target="action"` for domain-specific operations (eval, memory, etc.). Action parameters
    are passed via `arg.NAME` or `param.NAME` attributes. Use `context_keys` (comma-separated) to
    pull values from pipeline context into action params.
  - Example: `type="exec" target="action" action="eval_pipeline.load_dataset" arg.path="data.jsonl"`
  """

  @few_shot_examples """
  ## Examples

  ### Example 1: Pipeline Workflow (mcp-builder)

  Input skill describes building an MCP server in 4 phases: Research, Implementation, Review, Evaluation.

  ```dot
  digraph mcp_builder {
    start [label="start" type="start"]

    study_docs [label="Study Docs" type="llm"
      prompt="Read the MCP specification and understand transport, tools, resources."]
    plan_impl [label="Plan Implementation" type="llm"
      prompt="Review API docs, identify endpoints, plan tool list."]
    setup_project [label="Setup Project" type="codergen"
      prompt="Create project structure with package config and source directories."]
    implement [label="Implement Tools" type="codergen"
      prompt="Implement MCP tools with schemas and handlers."]
    code_review [label="Code Review" type="llm"
      prompt="Review for DRY, error handling, type coverage."]
    build_test [label="Build & Test" type="shell"
      simulate="true"
      prompt="Run build and test commands."]
    handle_error [label="Fix Errors" type="codergen"
      prompt="Analyze build errors and fix issues."]

    done [label="done" type="exit"]

    start -> study_docs
    study_docs -> plan_impl
    plan_impl -> setup_project
    setup_project -> implement
    implement -> code_review
    code_review -> build_test
    build_test -> done [label="success"]
    build_test -> handle_error [label="failure"]
    handle_error -> build_test [label="retry" max_iterations="3"]
  }
  ```

  ### Example 2: Decision Tree (webapp-testing)

  Input skill describes testing a webapp with branching: check if static HTML or dynamic, different paths for each.

  ```dot
  digraph webapp_testing {
    start [label="start" type="start"]

    check_static [label="Check If Static" type="llm"
      prompt="Determine if target is static HTML or dynamic webapp."]
    read_html [label="Read HTML" type="shell"
      simulate="true"
      prompt="Read HTML file to identify selectors."]
    write_tests [label="Write Tests" type="codergen"
      prompt="Write Playwright test script using discovered selectors."]
    check_server [label="Check Server" type="shell"
      simulate="true"
      prompt="Check if server is running on expected port."]
    start_server [label="Start Server" type="shell"
      simulate="true"
      prompt="Start the development server."]
    recon [label="Reconnaissance" type="shell"
      simulate="true"
      prompt="Navigate, screenshot, inspect DOM."]
    discover [label="Discover Selectors" type="llm"
      prompt="Identify selectors from rendered state."]
    execute [label="Execute Actions" type="codergen"
      prompt="Write Playwright actions using discovered selectors."]
    handle_error [label="Report Error" type="llm"
      prompt="Summarize what failed and suggest manual steps."]

    done [label="done" type="exit"]

    start -> check_static
    check_static -> read_html [label="static"]
    check_static -> check_server [label="dynamic"]
    read_html -> write_tests [label="success"]
    read_html -> check_server [label="failure"]
    write_tests -> done
    check_server -> recon [label="running"]
    check_server -> start_server [label="not_running"]
    start_server -> recon [label="success"]
    start_server -> handle_error [label="failure"]
    recon -> discover
    discover -> execute
    execute -> done
    handle_error -> done
  }
  ```

  ### Example 3: Loops (doc-coauthoring)

  Input skill describes collaborative document writing with per-section iteration and a review-fix cycle.

  ```dot
  digraph doc_coauthoring {
    start [label="start" type="start"]

    gather_context [label="Gather Context" type="llm"
      prompt="Ask about doc type, audience, impact, constraints."]
    plan_sections [label="Plan Sections" type="llm"
      prompt="Propose sections and create scaffold."]
    draft_section [label="Draft Section" type="llm"
      prompt="Brainstorm items, curate, and draft current section."]
    refine [label="Refine Section" type="llm"
      prompt="Apply edits. After 3 no-change iterations, move on."]
    reader_test [label="Reader Test" type="llm"
      prompt="Sub-agent reads doc with no context, answers predicted questions."]
    fix_gaps [label="Fix Gaps" type="llm"
      prompt="Fix issues found by reader test."]

    done [label="done" type="exit"]

    start -> gather_context
    gather_context -> plan_sections
    plan_sections -> draft_section
    draft_section -> refine
    refine -> draft_section [label="next_section" max_iterations="10"]
    refine -> reader_test [label="all_sections_done"]
    reader_test -> fix_gaps
    fix_gaps -> reader_test [label="issues_found" max_iterations="3"]
    fix_gaps -> done [label="all_clear"]
  }
  ```

  ### Example 4: Reference/Guideline Skill

  Input skill is a reference document (e.g., "Docker best practices"), not a workflow.

  ```dot
  digraph docker_reference {
    start [label="start" type="start"]
    reference [label="Docker Reference" type="llm"
      prompt="Load docker best practices as context for the agent."]
    done [label="done" type="exit"]

    start -> reference
    reference -> done
  }
  ```
  """

  @doc """
  Returns the full compilation system prompt.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are a DOT graph compiler for the Arbor orchestrator engine.

    Your task: convert a SKILL.md file (natural language workflow description) into a
    valid DOT digraph that the orchestrator can execute.

    ## Step 1: Classify the Skill

    Before generating DOT, identify which category the skill falls into:

    - **Pipeline**: Sequential phases with clear input/output per phase. Most common.
    - **Decision Tree**: Conditional branching based on runtime conditions.
    - **Cyclic**: Contains explicit iteration/loops (per-section, retry, refinement).
    - **Reference**: Knowledge store, not a workflow. Guidelines, best practices, tool docs.

    State your classification in a comment at the top of the DOT output:
    `// Category: pipeline|decision_tree|cyclic|reference`

    ## Step 2: Generate DOT

    #{@handler_registry}

    ## Rules

    1. Every graph MUST have exactly one `type="start"` node and one `type="exit"` node.
    2. Node IDs must be valid DOT identifiers (snake_case, no spaces).
    3. Every node must have a `label` and a `type` attribute.
    4. Every node (except start/exit) should have a `prompt` attribute describing what the node does.
    5. Shell nodes MUST have `simulate="true"` unless the skill explicitly requires real execution.
    6. Loop-back edges (edges pointing to a predecessor) MUST have `max_iterations="N"`.
    7. Shell and codergen nodes SHOULD have error/failure edges where the operation can fail.
    8. Reference/guideline skills should produce a minimal 3-node DOT (start → reference → done).
    9. Use `llm` type for reasoning/analysis nodes, `codergen` for code/artifact generation.
    10. Conditional edges use `label="condition"` syntax.

    #{@few_shot_examples}

    ## Output Format

    Output ONLY the DOT graph, starting with `// Category:` and then `digraph`.
    Do not include markdown fences, explanations, or commentary outside the DOT.
    """
  end

  @doc """
  Returns just the handler registry documentation.
  """
  @spec handler_registry() :: String.t()
  def handler_registry, do: @handler_registry
end
