defmodule Arbor.Orchestrator.Handlers.CustomRegistryTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry

  defmodule CustomPassHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{
        status: :success,
        notes: "custom handler executed",
        context_updates: %{"custom.handler.executed" => true}
      }
    end
  end

  setup do
    on_exit(fn -> Registry.unregister_fixture("test.my_custom_type") end)
    :ok
  end

  test "custom handler registration routes type to custom module" do
    :ok = Registry.register_fixture("test.my_custom_type", CustomPassHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="test.my_custom_type"]
      exit [shape=Msquare]
      start -> custom -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["custom.handler.executed"] == true
  end
end
