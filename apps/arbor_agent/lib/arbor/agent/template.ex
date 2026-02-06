defmodule Arbor.Agent.Template do
  @moduledoc """
  Behaviour for agent templates.

  Templates define agent archetypes by combining personality (character)
  with Arbor security concerns (trust tier, capabilities, initial goals).

  Templates provide seeds for identity, not constraints. The `apply/1`
  function extracts all template callbacks into a keyword list that
  includes meta-awareness about its template origins.

  ## Required Callbacks

  - `character/0` - Personality definition (Character struct)
  - `trust_tier/0` - Security trust level
  - `initial_goals/0` - Starting goals
  - `required_capabilities/0` - Resource URIs needed

  ## Optional Callbacks

  - `metadata/0` - Template metadata
  - `description/0` - Human-readable description
  - `nature/0` - Core nature/essence of the agent
  - `values/0` - Core values (separate from character values for deeper identity)
  - `initial_interests/0` - Topics the agent is interested in exploring
  - `initial_thoughts/0` - Seed thoughts for working memory
  - `relationship_style/0` - How the agent approaches relationships
  - `domain_context/0` - Domain-specific context for prompts

  ## Implementing a Template

      defmodule MyTemplate do
        @behaviour Arbor.Agent.Template

        @impl true
        def character do
          Arbor.Agent.Character.new(
            name: "My Agent",
            role: "Helper",
            values: ["helpfulness"]
          )
        end

        @impl true
        def trust_tier, do: :probationary

        @impl true
        def initial_goals, do: [%{type: :maintain, description: "Be helpful"}]

        @impl true
        def required_capabilities, do: [%{resource: "arbor://fs/read/**"}]
      end
  """

  alias Arbor.Agent.Character

  # Required callbacks
  @callback character() :: Character.t()
  @callback trust_tier() :: atom()
  @callback initial_goals() :: [map()]
  @callback required_capabilities() :: [map()]

  # Optional callbacks
  @callback metadata() :: map()
  @callback description() :: String.t()
  @callback nature() :: String.t()
  @callback values() :: [String.t()]
  @callback initial_interests() :: [String.t()]
  @callback initial_thoughts() :: [String.t()]
  @callback relationship_style() :: map()
  @callback domain_context() :: String.t()

  @optional_callbacks [
    metadata: 0,
    description: 0,
    nature: 0,
    values: 0,
    initial_interests: 0,
    initial_thoughts: 0,
    relationship_style: 0,
    domain_context: 0
  ]

  @doc """
  Apply a template to create initial agent configuration.

  Extracts all callbacks (required and optional) from the template module
  and returns a keyword list with all values plus meta-awareness about
  the template origin.
  """
  @spec apply(module()) :: keyword()
  def apply(template_module) do
    [
      name: template_module.character().name,
      character: template_module.character(),
      trust_tier: template_module.trust_tier(),
      initial_goals: template_module.initial_goals(),
      required_capabilities: template_module.required_capabilities(),
      nature: safe_call(template_module, :nature, ""),
      values: safe_call(template_module, :values, []),
      interests: safe_call(template_module, :initial_interests, []),
      initial_thoughts: safe_call(template_module, :initial_thoughts, []),
      relationship_style: safe_call(template_module, :relationship_style, %{}),
      domain_context: safe_call(template_module, :domain_context, ""),
      description: safe_call(template_module, :description, ""),
      metadata: safe_call(template_module, :metadata, %{}),
      meta_awareness: %{
        grown_from_template: true,
        template_name: template_module.character().name,
        note: "These initial values came from a template. You can question them."
      }
    ]
  end

  defp safe_call(module, func, default) do
    if function_exported?(module, func, 0) do
      Kernel.apply(module, func, [])
    else
      default
    end
  end
end
