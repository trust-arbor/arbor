defmodule Arbor.Orchestrator.Conformance412Test do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry

  defmodule FirstHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{status: :success, context_updates: %{"custom.which" => "first"}}
    end
  end

  defmodule SecondHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      %Outcome{status: :success, context_updates: %{"custom.which" => "second"}}
    end
  end

  defmodule CrashHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def execute(_node, _context, _graph, _opts) do
      raise "custom handler boom"
    end
  end

  setup do
    saved = Registry.snapshot_custom_handlers()
    Registry.reset_custom_handlers()
    on_exit(fn -> Registry.restore_custom_handlers(saved) end)
    :ok
  end

  test "4.12 custom handler can be registered by type string and executed" do
    :ok = Registry.register("custom.4_12", FirstHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="custom.4_12"]
      exit [shape=Msquare]
      start -> custom -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["custom.which"] == "first"
  end

  test "4.12 register replaces previously registered handler for same type" do
    :ok = Registry.register("custom.4_12", FirstHandler)
    :ok = Registry.register("custom.4_12", SecondHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="custom.4_12"]
      exit [shape=Msquare]
      start -> custom -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["custom.which"] == "second"
  end

  test "4.12 unregister restores fallback resolution for the type" do
    :ok = Registry.register("custom.4_12", FirstHandler)
    :ok = Registry.unregister("custom.4_12")

    node = %Node{id: "n1", attrs: %{"type" => "custom.4_12"}}
    resolved = Registry.resolve(node)

    assert resolved == Arbor.Orchestrator.Handlers.CodergenHandler
  end

  test "4.12 custom handler exceptions are caught and converted to fail outcome" do
    :ok = Registry.register("custom.4_12.crash", CrashHandler)

    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      custom [type="custom.4_12.crash"]
      exit [shape=Msquare]
      start -> custom
      custom -> exit [condition="outcome=success"]
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, sleep_fn: fn _ -> :ok end)
    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason =~ "custom handler boom"
  end
end
