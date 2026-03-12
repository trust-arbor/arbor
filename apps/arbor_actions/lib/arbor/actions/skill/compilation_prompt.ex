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
  | `parallel` | Fan-out to parallel branches | `fan_out="true"` |
  | `parallel.fan_in` | Wait for parallel branches | (none required) |
  | `accumulator` | Collect/aggregate results | `prompt` |
  | `feedback.loop` | Iterative refinement | `prompt`, `max_iterations` |

  ### Notes:
  - `llm` and `codergen` both route to LLM calls; use `llm` for pure reasoning/analysis, `codergen` for generating files/artifacts
  - `shell` nodes MUST have `simulate="true"` unless the skill explicitly requires real execution
  - All loop-back edges MUST have `max_iterations="N"` to prevent infinite loops
  - Use `exec target="action"` for domain-specific operations (eval, memory, consensus, etc.).
    Action parameters are passed via `arg.NAME` or `param.NAME` attributes. Use `context_keys`
    (comma-separated) to pull values from pipeline context into action params.
  - Example: `type="exec" target="action" action="eval_pipeline.load_dataset" arg.path="data.jsonl"`
  - Consensus example: `type="exec" target="action" action="consensus.decide" param.quorum="majority" context_keys="parallel.results,council.question"`
  """

  @few_shot_examples """
  ## Examples

  ### Example 1: Pipeline Workflow (mcp-builder)

  Input skill describes building an MCP server in 4 phases: Research (3 steps), Implementation (3 steps), Review & Test (2 steps), Evaluation (1 step).

  Note: Each bullet point in the skill becomes its own node. Do NOT merge multiple steps into one node.

  ```dot
  digraph mcp_builder {
    start [label="start" type="start"]

    // Phase 1: Research — 3 separate steps = 3 nodes
    study_mcp_docs [label="Study MCP Docs" type="llm"
      prompt="Read the MCP specification and understand transport, tools, resources."]
    study_framework [label="Study Framework" type="llm"
      prompt="Load TypeScript or Python SDK docs based on chosen language."]
    plan_impl [label="Plan Implementation" type="llm"
      prompt="Review API docs, identify endpoints, plan tool list."]

    // Phase 2: Implementation — 3 separate steps = 3 nodes
    setup_project [label="Setup Project" type="codergen"
      prompt="Create project structure: package.json, tsconfig, src/"]
    impl_infra [label="Implement Infrastructure" type="codergen"
      prompt="Create API client, error handling, pagination helpers."]
    impl_tools [label="Implement Tools" type="codergen"
      prompt="Implement each MCP tool with Zod schemas, handlers, annotations."]

    // Phase 3: Review & Test
    code_review [label="Code Review" type="llm"
      prompt="Review for DRY, error handling, type coverage, descriptions."]
    build_test [label="Build & Test" type="shell"
      simulate="true"
      prompt="Run npm build, test with MCP Inspector."]

    // Phase 4: Evaluation
    create_evals [label="Create Evaluations" type="codergen"
      prompt="Create 10 complex eval questions in XML format."]

    // Error handling
    handle_build_error [label="Fix Build Errors" type="codergen"
      prompt="Analyze build errors, fix issues in source code, retry."]

    done [label="done" type="exit"]

    start -> study_mcp_docs
    study_mcp_docs -> study_framework
    study_framework -> plan_impl
    plan_impl -> setup_project
    setup_project -> impl_infra
    impl_infra -> impl_tools
    impl_tools -> code_review
    code_review -> build_test
    build_test -> create_evals [label="success"]
    build_test -> handle_build_error [label="failure"]
    handle_build_error -> build_test [label="retry" max_iterations="3"]
    create_evals -> done
  }
  ```

  ### Example 2: Decision Tree (webapp-testing)

  Input skill describes testing a webapp with branching: check if static HTML or dynamic, different paths for each.

  ```dot
  digraph webapp_testing {
    start [label="start" type="start"]

    check_static [label="Check If Static" type="llm"
      prompt="Determine if target is static HTML or dynamic webapp."]

    // Static path
    read_html [label="Read HTML" type="shell"
      simulate="true"
      prompt="Read HTML file to identify selectors."]
    write_playwright [label="Write Playwright Script" type="codergen"
      prompt="Write Playwright script using discovered selectors."]

    // Dynamic path
    check_server [label="Check Server Status" type="shell"
      simulate="true"
      prompt="Check if server is already running on expected port."]
    start_server [label="Start Server" type="shell"
      simulate="true"
      prompt="Use with_server.py to start server with correct ports."]
    recon [label="Reconnaissance" type="shell"
      simulate="true"
      prompt="Navigate, wait for networkidle, screenshot, inspect DOM."]
    discover_selectors [label="Discover Selectors" type="llm"
      prompt="Identify selectors from rendered state."]
    execute_actions [label="Execute Actions" type="codergen"
      prompt="Write Playwright actions using discovered selectors."]

    // Error handling
    handle_error [label="Report Error" type="llm"
      prompt="Summarize what failed and suggest manual steps to resolve."]

    done [label="done" type="exit"]

    start -> check_static
    check_static -> read_html [label="static"]
    check_static -> check_server [label="dynamic"]
    read_html -> write_playwright [label="success"]
    read_html -> check_server [label="failure"]
    write_playwright -> done
    check_server -> recon [label="running"]
    check_server -> start_server [label="not_running"]
    start_server -> recon [label="success"]
    start_server -> handle_error [label="failure"]
    recon -> discover_selectors
    discover_selectors -> execute_actions
    execute_actions -> done
    handle_error -> done
  }
  ```

  ### Example 3: Loops (doc-coauthoring)

  Input skill describes collaborative document writing with 3 stages: Context Gathering (3 steps), Section-by-Section Refinement (loop), Reader Testing (loop).

  Note: Each distinct step in a stage becomes its own node, even within loops.

  ```dot
  digraph doc_coauthoring {
    start [label="start" type="start"]

    // Stage 1: Context Gathering — 3 separate steps
    ask_meta [label="Ask Meta Questions" type="llm"
      prompt="Ask: doc type, audience, desired impact, template, constraints."]
    info_dump [label="Process Info Dump" type="llm"
      prompt="Encourage context dump. Track what's learned and what's unclear."]
    clarify [label="Clarifying Questions" type="llm"
      prompt="Generate 5-10 gap-filling questions based on context so far."]

    // Stage 2: Refinement (per-section loop)
    plan_sections [label="Plan Sections" type="llm"
      prompt="Propose 3-5 sections. Create scaffold with placeholders."]
    brainstorm [label="Brainstorm Section" type="llm"
      prompt="For current section: brainstorm 5-20 items to include."]
    curate [label="Curate & Draft" type="llm"
      prompt="User selects items. Draft section content."]
    refine [label="Iterative Refinement" type="llm"
      prompt="Apply user edits. After 3 iterations with no changes, suggest pruning."]

    // Stage 3: Reader Testing
    full_review [label="Full Document Review" type="llm"
      prompt="Re-read entire document. Check flow, consistency, redundancy."]
    predict_questions [label="Predict Reader Questions" type="llm"
      prompt="Generate 5-10 realistic reader questions."]
    reader_test [label="Test with Fresh Agent" type="llm"
      prompt="Sub-agent reads doc with no context, answers questions."]
    fix_gaps [label="Fix Gaps" type="llm"
      prompt="Fix issues found by reader test. Loop back if needed."]

    done [label="done" type="exit"]

    start -> ask_meta
    ask_meta -> info_dump
    info_dump -> clarify
    clarify -> plan_sections
    plan_sections -> brainstorm
    brainstorm -> curate
    curate -> refine
    refine -> brainstorm [label="next_section" max_iterations="10"]
    refine -> full_review [label="all_sections_done"]
    full_review -> predict_questions
    predict_questions -> reader_test
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
    11. **Node granularity**: Each distinct step or bullet point in the skill description becomes its own node. Do NOT merge multiple steps into a single node. If the skill says "Study X", "Load Y", "Review Z" — that's 3 nodes, not 1 "Research" node.

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
