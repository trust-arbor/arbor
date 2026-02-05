defmodule Arbor.Agent.Template do
  @moduledoc """
  Behaviour for agent templates.

  Templates define agent archetypes by combining personality (character)
  with Arbor security concerns (trust tier, capabilities, initial goals).

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

  @callback character() :: Character.t()
  @callback trust_tier() :: atom()
  @callback initial_goals() :: [map()]
  @callback required_capabilities() :: [map()]

  @callback metadata() :: map()
  @callback description() :: String.t()

  @optional_callbacks [metadata: 0, description: 0]
end
