defmodule Arbor.Orchestrator.Handlers.CustomRegistryTest do
  use ExUnit.Case, async: false

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
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok
  end

  test "custom handler registration routes type to custom module" do
    :ok = Registry.register("my_custom_type", CustomPassHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="my_custom_type"]
      exit [shape=Msquare]
      start -> custom -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["custom.handler.executed"] == true
  end
end
