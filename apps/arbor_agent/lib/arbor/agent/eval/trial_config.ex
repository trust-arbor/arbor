defmodule Arbor.Agent.Eval.TrialConfig do
  @moduledoc """
  Tier definitions for memory ablation studies.

  Each tier enables a progressively larger set of prompt sections and
  output routing, allowing measurement of each subsystem cluster's
  contribution to agent behavior.

  ## Design Principles

  - Conversation history is infrastructure, not a feature to ablate.
    Every real agent has it, so it belongs in the baseline.
  - Directive (agent purpose) is similarly foundational.
  - Goals and self-knowledge are the two biggest behavioral levers,
    so they get isolated tiers (T1-G, T1-S) for independent testing.
  - T2 combines them to measure interaction effects.
  - Higher tiers add operational (T3) and evolutionary (T4) features.

  ## Tiers

  | Tier | Name         | Prompt Sections                              | Outputs Stored       |
  |------|-------------|---------------------------------------------|---------------------|
  | 0    | baseline    | timing, tools, format, conversation, directive| none                |
  | 1    | goals       | + goals                                      | goals               |
  | 2    | identity    | baseline + self_knowledge (no goals)         | identity_insights   |
  | 3    | combined    | baseline + goals + self_knowledge            | goals, notes, insights |
  | 4    | operational | + cognitive, percepts, pending               | + intents           |
  | 5    | full        | all sections                                 | all outputs         |

  ## Key Comparisons

  - T1 vs T0: What do goals add to an agent with conversation context?
  - T2 vs T0: What does self-knowledge add to an agent with conversation context?
  - T1 vs T2: Which is more impactful — goals or self-knowledge?
  - T3 vs T1: Does self-knowledge help a goal-focused agent? (resolves T3 confound)
  - T3 vs T2: Do goals help an identity-aware agent?
  - T4 vs T3: Do operational BDI features add measurable value?
  - T5 vs T4: Do proposals/patterns add measurable value?
  """

  @type tier_config :: %{
          tier: non_neg_integer(),
          name: atom(),
          sections: :all | [atom()],
          outputs: :all | [atom()]
        }

  # Baseline: conversation + directive are infrastructure
  @baseline_sections [:timing, :tools, :response_format, :conversation, :directive]

  @tier_sections %{
    0 => @baseline_sections,
    1 => @baseline_sections ++ [:goals],
    2 => @baseline_sections ++ [:self_knowledge],
    3 => @baseline_sections ++ [:goals, :self_knowledge],
    4 => @baseline_sections ++ [:goals, :self_knowledge, :cognitive, :percepts, :pending],
    5 => :all
  }

  @tiers %{
    0 => %{name: :baseline, sections: @tier_sections[0], outputs: []},
    1 => %{name: :goals, sections: @tier_sections[1], outputs: [:goals]},
    2 => %{name: :identity, sections: @tier_sections[2], outputs: [:identity_insights]},
    3 => %{
      name: :combined,
      sections: @tier_sections[3],
      outputs: [:goals, :memory_notes, :identity_insights]
    },
    4 => %{
      name: :operational,
      sections: @tier_sections[4],
      outputs: [:goals, :intents, :memory_notes, :identity_insights]
    },
    5 => %{name: :full, sections: :all, outputs: :all}
  }

  @doc "Returns the config for a given tier number (0-5)."
  @spec for_tier(non_neg_integer()) :: tier_config()
  def for_tier(tier) when tier in 0..5 do
    config = Map.fetch!(@tiers, tier)
    Map.put(config, :tier, tier)
  end

  @doc "Returns all tier configs."
  def all_tiers, do: Enum.map(0..5, &for_tier/1)

  @doc "Returns the tier numbers."
  def tier_numbers, do: Enum.to_list(0..5)

  @doc "Check if a given output category is enabled for this tier."
  def output_enabled?(%{outputs: :all}, _category), do: true
  def output_enabled?(%{outputs: outputs}, category), do: category in outputs

  @doc """
  Standardized seed data for all trials.

  Every tier gets the same initial state seeded into memory stores.
  The tier controls which prompt sections SHOW this data to the LLM.
  """
  def seed_data do
    %{
      goals: [
        %{
          description: "Analyze the project's test coverage and identify gaps",
          priority: :high,
          success_criteria: "Identified at least 3 modules with low coverage"
        },
        %{
          description: "Document the memory subsystem architecture",
          priority: :medium,
          success_criteria: "Written a clear summary of how memory stores interact"
        }
      ],
      self_knowledge: %{
        capabilities: ["code analysis", "test generation", "architecture review"],
        traits: ["methodical", "curious", "thorough"],
        values: ["code quality", "comprehensive testing", "clear documentation"]
      },
      chat_history: [
        %{role: "user", content: "Can you help me understand the memory system?"},
        %{
          role: "assistant",
          content:
            "The memory system has several subsystems including goals, working memory, and self-knowledge. Each serves a different purpose in the agent's cognitive loop."
        },
        %{role: "user", content: "What about the knowledge graph?"},
        %{
          role: "assistant",
          content:
            "The knowledge graph stores semantic relationships between concepts, with decay and reinforcement mechanisms for relevance tracking."
        }
      ],
      working_memory: %{
        thoughts: ["The memory system is well-structured but some subsystems may be disconnected"],
        concerns: ["Some subsystems might not be contributing to agent behavior"],
        curiosity: ["How does consolidation affect long-term identity formation?"]
      },
      proposals: [
        %{
          type: :insight,
          content:
            "Code analysis capability improves with repeated practice on diverse codebases",
          confidence: 0.7
        }
      ]
    }
  end
end
