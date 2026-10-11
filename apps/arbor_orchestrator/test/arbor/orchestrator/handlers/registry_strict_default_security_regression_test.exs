defmodule Arbor.Orchestrator.Handlers.RegistryStrictDefaultSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Graph.Node, as: GraphNode
  alias Arbor.Orchestrator.Handlers.Registry

  # 2026-10-11 cross-library review F-016: `strict_unknown_handlers?/0`
  # defaulted to a RUNTIME `Mix.env() == :prod`, so under `mix arbor.start`
  # an unknown (typo'd or model-authored) node type silently dispatched to
  # LlmHandler, and a release crashed because Mix is absent.
  setup do
    previous = Application.get_env(:arbor_orchestrator, :strict_unknown_handlers)
    Application.delete_env(:arbor_orchestrator, :strict_unknown_handlers)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:arbor_orchestrator, :strict_unknown_handlers)
        value -> Application.put_env(:arbor_orchestrator, :strict_unknown_handlers, value)
      end
    end)

    :ok
  end

  test "security regression (F-016): unknown handler types fail closed by default" do
    assert Registry.strict_unknown_handlers?() == true

    node = %GraphNode{id: "n1", attrs: %{"type" => "definitely_not_a_handler_f016"}}

    assert_raise ArgumentError, ~r/Unknown handler type/, fn ->
      Registry.resolve(node)
    end
  end
end
