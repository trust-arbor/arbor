defmodule Arbor.Agent.Templates.CouncilEvaluator do
  @moduledoc """
  Template for advisory council evaluator agents.

  Each council perspective (security, stability, vision, etc.) is a persistent
  agent with read-only research capabilities. Evaluators can search the codebase,
  query the Historian, and browse the web to verify claims before making
  recommendations.

  ## Trust Profile

  Evaluators have a restrictive read-only trust profile:
  - File/code read: auto (codebase research)
  - Web search/browse: auto (external research)
  - Historian queries: auto (past decisions)
  - Tool discovery: auto (find research tools)
  - All writes/execution: blocked

  ## Usage

  Council evaluator agents are auto-created on first consultation.
  The perspective name is set via the `:perspective` option:

      Lifecycle.create("council-security",
        template: Arbor.Agent.Templates.CouncilEvaluator,
        perspective: :security)
  """

  @behaviour Arbor.Agent.Template

  @impl true
  def description do
    "Advisory council evaluator agent with read-only research capabilities. " <>
      "Searches codebase, web, and history to provide evidence-backed analysis."
  end

  @impl true
  def trust_tier, do: :established

  @impl true
  def character do
    Arbor.Agent.Character.new(
      name: "Council Evaluator",
      values: ["evidence-based analysis", "intellectual honesty", "thorough research"],
      style: "analytical, structured, evidence-backed",
      background: "Advisory council member that researches before recommending"
    )
  end

  @impl true
  def required_capabilities do
    [
      %{resource: "arbor://orchestrator/execute", description: "Run DOT session pipelines"}
    ]
  end

  @impl true
  def initial_goals, do: []

  @impl true
  def metadata do
    %{
      role: :council_evaluator,
      auto_start: false
    }
  end

  @doc """
  Trust preset for council evaluators — read-only research capabilities.
  """
  def trust_preset do
    %{
      baseline: :block,
      rules: %{
        # Required for agent functioning
        "arbor://orchestrator" => :auto,
        # Codebase research (read-only)
        "arbor://fs/read" => :auto,
        "arbor://fs/list" => :auto,
        "arbor://code/read" => :auto,
        # Web research
        "arbor://net/search" => :auto,
        "arbor://net/http" => :auto,
        # Past decisions and events
        "arbor://historian" => :auto,
        # Tool discovery
        "arbor://agent/discover_tools" => :auto,
        # Memory for cross-consultation learning
        "arbor://memory" => :auto,
        # Explicit blocks
        "arbor://fs/write" => :block,
        "arbor://code/write" => :block,
        "arbor://shell" => :block,
        "arbor://consensus" => :block
      }
    }
  end
end
