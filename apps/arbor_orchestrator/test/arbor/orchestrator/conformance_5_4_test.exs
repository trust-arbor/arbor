defmodule Arbor.Orchestrator.Conformance54Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Fidelity}

  defp node_map(attrs), do: %{attrs: attrs}
  defp edge_map(attrs), do: %{attrs: attrs}
  defp graph_map(attrs), do: %{attrs: attrs}

  test "5.4 fidelity mode precedence is edge -> node -> graph -> compact default" do
    context = Context.new(%{})

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "summary:low"}),
        edge_map(%{"fidelity" => "full"}),
        graph_map(%{"default_fidelity" => "truncate"}),
        context
      )

    assert resolved.mode == "full"

    resolved =
      Fidelity.resolve(node_map(%{"fidelity" => "summary:medium"}), nil, graph_map(%{}), context)

    assert resolved.mode == "summary:medium"

    resolved =
      Fidelity.resolve(
        node_map(%{}),
        nil,
        graph_map(%{"default_fidelity" => "truncate"}),
        context
      )

    assert resolved.mode == "truncate"

    resolved = Fidelity.resolve(node_map(%{}), nil, graph_map(%{}), context)
    assert resolved.mode == "compact"
  end

  test "5.4 invalid fidelity mode normalizes to compact" do
    context = Context.new(%{})

    resolved =
      Fidelity.resolve(node_map(%{"fidelity" => "not-a-mode"}), nil, graph_map(%{}), context)

    assert resolved.mode == "compact"
  end

  test "5.4 full mode thread precedence is node -> edge -> graph -> class -> last_stage" do
    context = Context.new(%{"last_stage" => "prev-stage"})

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "full", "thread_id" => "node-thread", "class" => "plan"}),
        edge_map(%{"thread_id" => "edge-thread"}),
        graph_map(%{"thread_id" => "graph-thread"}),
        context
      )

    assert resolved.thread_id == "node-thread"

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "full"}),
        edge_map(%{"thread_id" => "edge-thread"}),
        graph_map(%{"thread_id" => "graph-thread"}),
        context
      )

    assert resolved.thread_id == "edge-thread"

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "full"}),
        edge_map(%{}),
        graph_map(%{"thread_id" => "graph-thread"}),
        context
      )

    assert resolved.thread_id == "graph-thread"

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "full", "class" => "derived-class,other"}),
        edge_map(%{}),
        graph_map(%{}),
        context
      )

    assert resolved.thread_id == "derived-class"

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "full"}),
        edge_map(%{}),
        graph_map(%{}),
        context
      )

    assert resolved.thread_id == "prev-stage"
  end

  test "5.4 non-full fidelity has nil thread_id" do
    context = Context.new(%{"last_stage" => "prev-stage"})

    resolved =
      Fidelity.resolve(
        node_map(%{"fidelity" => "summary:high", "thread_id" => "node-thread", "class" => "c1"}),
        edge_map(%{"thread_id" => "edge-thread"}),
        graph_map(%{"thread_id" => "graph-thread"}),
        context
      )

    assert resolved.mode == "summary:high"
    assert resolved.thread_id == nil
  end
end
