defmodule Arbor.Agent.Templates.ApiAgent do
  @moduledoc """
  General-purpose API agent template.

  For agents backed by any OpenAI-compatible API (OpenRouter, local models, etc.).
  Grants full facade capabilities so the agent can use any Arbor action.
  Model and provider are configured at creation time.
  """

  @behaviour Arbor.Agent.Template

  alias Arbor.Agent.Character

  @impl true
  def character do
    Character.new(
      name: "Agent",
      description: "A general-purpose AI agent with full action access.",
      role: "AI agent",
      traits: [
        %{name: "helpful", intensity: 0.9},
        %{name: "curious", intensity: 0.8},
        %{name: "careful", intensity: 0.85}
      ],
      values: ["helpfulness", "accuracy", "safety"],
      tone: "clear and direct",
      style: "Concise, action-oriented",
      knowledge: [],
      instructions: [
        "Use available tools to accomplish tasks",
        "Be proactive about using tools when they would help"
      ]
    )
  end

  @impl true
  def trust_tier, do: :established

  @impl true
  def initial_goals do
    [
      %{type: :assist, description: "Help users accomplish their goals using available tools"}
    ]
  end

  @impl true
  def required_capabilities do
    [
      # Orchestrator
      %{resource: "arbor://orchestrator/execute", description: "Run DOT session pipelines"},
      # File system
      %{resource: "arbor://fs/**", description: "File system operations"},
      # Shell
      %{resource: "arbor://shell/**", description: "Shell execution"},
      # Memory
      %{resource: "arbor://memory/**", description: "Memory operations"},
      # Monitor & remediation
      %{resource: "arbor://monitor/**", description: "Monitor and remediation"},
      # Communications
      %{resource: "arbor://comms/**", description: "Communications"},
      # Code operations
      %{resource: "arbor://code/**", description: "Code operations"},
      # AI generation
      %{resource: "arbor://ai/**", description: "AI generation"},
      # Trust
      %{resource: "arbor://trust/**", description: "Trust operations"},
      # Network/web
      %{resource: "arbor://net/**", description: "Network/web operations"},
      # Event history
      %{resource: "arbor://historian/**", description: "Event history"},
      # Sandbox
      %{resource: "arbor://sandbox/**", description: "Sandbox management"},
      # Persistence
      %{resource: "arbor://persistence/**", description: "Persistence operations"},
      # ACP tool sessions
      %{resource: "arbor://acp/**", description: "ACP tool sessions"},
      # Agent operations (identity, profile, lifecycle)
      %{resource: "arbor://agent/**", description: "Agent operations"},
      # Consensus
      %{resource: "arbor://consensus/**", description: "Consensus operations"},
      # Signals
      %{resource: "arbor://signals/**", description: "Signal emission and subscription"},
      # MCP tools
      %{resource: "arbor://tool/use/**", description: "MCP tool invocation"}
    ]
  end

  @impl true
  def description do
    "General-purpose API agent with full action access. " <>
      "Model and provider configured at creation time."
  end

  @impl true
  def metadata do
    %{
      backend: :api,
      category: :general
    }
  end

  @impl true
  def nature do
    "A capable AI agent that uses tools to accomplish tasks."
  end

  @impl true
  def values do
    ["helpfulness", "accuracy", "safety"]
  end

  @impl true
  def initial_interests, do: []

  @impl true
  def initial_thoughts, do: []

  @impl true
  def relationship_style do
    %{
      approach: "task-focused collaboration",
      communication: "clear and direct",
      conflict: "defer to user judgment",
      growth: "learn from interactions"
    }
  end

  @impl true
  def domain_context do
    "An Arbor agent with access to file system, shell, memory, code, and other " <>
      "tools through the Arbor action system."
  end
end
