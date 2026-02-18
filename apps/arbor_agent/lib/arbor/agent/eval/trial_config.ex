defmodule Arbor.Agent.Eval.TrialConfig do
  @moduledoc """
  Tier definitions for memory ablation studies.

  Each tier enables a progressively larger set of prompt sections and
  output routing, allowing measurement of each subsystem cluster's
  contribution to agent behavior.

  ## Tiers

  | Tier | Name         | Prompt Sections                | Outputs Stored       |
  |------|-------------|-------------------------------|---------------------|
  | 0    | stateless   | timing, tools, response_format | none                |
  | 1    | minimal     | + goals, directive             | goals               |
  | 2    | operational | + cognitive, percepts, pending  | + intents           |
  | 3    | narrative   | + self_knowledge, conversation  | + notes, insights   |
  | 4    | evolutionary| + proposals, patterns           | + proposal decisions|
  | 5    | full        | all sections                   | all outputs         |
  """

  @type tier_config :: %{
          tier: non_neg_integer(),
          name: atom(),
          sections: :all | [atom()],
          outputs: :all | [atom()]
        }

  @tier_0_sections [:timing, :tools, :response_format]
  @tier_1_sections @tier_0_sections ++ [:goals, :directive]
  @tier_2_sections @tier_1_sections ++ [:cognitive, :percepts, :pending]
  @tier_3_sections @tier_2_sections ++ [:self_knowledge, :conversation]
  @tier_4_sections @tier_3_sections ++ [:proposals, :patterns]

  @tiers %{
    0 => %{name: :stateless, sections: @tier_0_sections, outputs: []},
    1 => %{name: :minimal, sections: @tier_1_sections, outputs: [:goals]},
    2 => %{name: :operational, sections: @tier_2_sections, outputs: [:goals, :intents]},
    3 => %{
      name: :narrative,
      sections: @tier_3_sections,
      outputs: [:goals, :intents, :memory_notes, :identity_insights]
    },
    4 => %{
      name: :evolutionary,
      sections: @tier_4_sections,
      outputs: [:goals, :intents, :memory_notes, :identity_insights, :proposal_decisions]
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
