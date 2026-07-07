defmodule Arbor.Orchestrator.Middleware.ChainConfigTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.Chain

  setup do
    previous = Application.get_env(:arbor_orchestrator, :mandatory_middleware)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:arbor_orchestrator, :mandatory_middleware)
        value -> Application.put_env(:arbor_orchestrator, :mandatory_middleware, value)
      end
    end)

    :ok
  end

  test "B7 security regression: mandatory middleware defaults enabled when config is absent" do
    Application.delete_env(:arbor_orchestrator, :mandatory_middleware)

    assert Chain.mandatory_enabled?()

    graph = %Graph{id: "test", attrs: %{}}
    node = %Node{id: "test", attrs: %{}}

    assert Chain.build([], graph, node) == Chain.default_mandatory_chain()
  end

  test "documented emergency override can disable mandatory middleware locally" do
    Application.put_env(:arbor_orchestrator, :mandatory_middleware, false)

    refute Chain.mandatory_enabled?()

    graph = %Graph{id: "test", attrs: %{}}
    node = %Node{id: "test", attrs: %{}}

    assert Chain.build([], graph, node) == []
  end
end
