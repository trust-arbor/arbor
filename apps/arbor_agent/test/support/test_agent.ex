defmodule Arbor.Agent.Test.IncrementAction do
  @moduledoc "Increments a counter value."

  use Jido.Action,
    name: "increment",
    description: "Increment the counter",
    schema: [
      amount: [type: :integer, default: 1, doc: "Amount to increment by"]
    ]

  @impl true
  def run(params, context) do
    amount = Map.get(params, :amount, 1)
    current = get_in(context, [:state, :value]) || 0
    new_value = current + amount
    {:ok, %{action: :increment, new_value: new_value}}
  end
end

defmodule Arbor.Agent.Test.SetValueAction do
  @moduledoc "Sets a key-value pair in the agent's data map."

  use Jido.Action,
    name: "set_value",
    description: "Set a value in the data map",
    schema: [
      key: [type: :atom, required: true, doc: "Key to set"],
      value: [type: :any, required: true, doc: "Value to set"]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{action: :set_value, key: params.key, value: params.value}}
  end
end

defmodule Arbor.Agent.Test.FailingAction do
  @moduledoc "An action that always fails, for testing error handling."

  use Jido.Action,
    name: "failing_action",
    description: "Always fails",
    schema: [
      reason: [type: :string, default: "intentional failure"]
    ]

  @impl true
  def run(params, _context) do
    {:error, Map.get(params, :reason, "intentional failure")}
  end
end

defmodule Arbor.Agent.Test.TestAgent do
  @moduledoc """
  A simple Jido agent for testing the agent framework.

  Provides basic counter and value operations used in
  supervision, checkpoint, and action runner tests.
  """

  use Jido.Agent,
    name: "test_agent",
    description: "Simple test agent for framework testing",
    category: "testing",
    tags: ["test", "framework"],
    vsn: "1.0.0",
    actions: [
      Arbor.Agent.Test.IncrementAction,
      Arbor.Agent.Test.SetValueAction,
      Arbor.Agent.Test.FailingAction
    ],
    schema: [
      value: [
        type: :integer,
        default: 0,
        doc: "Current counter value"
      ],
      data: [
        type: :map,
        default: %{},
        doc: "Arbitrary data storage"
      ],
      events: [
        type: {:list, :any},
        default: [],
        doc: "List of events for tracking state changes"
      ]
    ]
end

defmodule Arbor.Agent.Test.NoActionsAgent do
  @moduledoc "An agent with no actions, for testing edge cases."

  use Jido.Agent,
    name: "no_actions_agent",
    description: "Agent with no registered actions",
    actions: [],
    schema: [
      status: [type: :atom, default: :idle]
    ]
end
