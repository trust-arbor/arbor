defmodule Arbor.Orchestrator.Handlers.MapHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.MapHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp make_node(id, attrs) do
    %Node{id: id, attrs: Map.merge(%{"type" => "map"}, attrs)}
  end

  defp echo_handler do
    fn item, _context, _graph, _opts ->
      %Outcome{
        status: :success,
        notes: "processed",
        context_updates: %{"last_response" => "processed:#{item}"}
      }
    end
  end

  defp failing_handler(fail_indices) do
    fn item, context, _graph, _opts ->
      idx = String.to_integer(Context.get(context, "map.current_index"))

      if idx in fail_indices do
        %Outcome{status: :fail, failure_reason: "failed on item #{idx}"}
      else
        %Outcome{
          status: :success,
          context_updates: %{"last_response" => "ok:#{item}"}
        }
      end
    end
  end

  describe "execute/4 — sequential processing" do
    test "processes list items sequentially" do
      node = make_node("m1", %{"source_key" => "items"})
      items = Jason.encode!(["a", "b", "c"])
      context = Context.new(%{"items" => items})

      outcome = MapHandler.execute(node, context, @graph, item_handler: echo_handler())
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert results == ["processed:a", "processed:b", "processed:c"]
      assert outcome.context_updates["map.m1.count"] == "3"
      assert outcome.context_updates["map.m1.success_count"] == "3"
      assert outcome.context_updates["map.m1.error_count"] == "0"
    end

    test "processes native list" do
      node = make_node("m1b", %{"source_key" => "items"})
      context = Context.new(%{"items" => [1, 2, 3]})

      handler = fn item, _ctx, _g, _o ->
        %Outcome{
          status: :success,
          context_updates: %{"last_response" => item * 10}
        }
      end

      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert results == [10, 20, 30]
    end
  end

  describe "execute/4 — parallel processing" do
    test "processes items in parallel" do
      node =
        make_node("m2", %{
          "source_key" => "items",
          "max_concurrency" => "3"
        })

      items = Jason.encode!(["x", "y", "z"])
      context = Context.new(%{"items" => items})

      outcome = MapHandler.execute(node, context, @graph, item_handler: echo_handler())
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert length(results) == 3
    end
  end

  describe "execute/4 — collection parsing" do
    test "JSON string parsed as collection" do
      node = make_node("p1", %{"source_key" => "data"})
      context = Context.new(%{"data" => "[1, 2, 3]"})

      handler = fn item, _ctx, _g, _o ->
        %Outcome{status: :success, context_updates: %{"last_response" => item}}
      end

      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert results == [1, 2, 3]
    end

    test "newline-separated string parsed as collection" do
      node = make_node("p2", %{"source_key" => "lines"})
      context = Context.new(%{"lines" => "line1\nline2\nline3"})

      outcome = MapHandler.execute(node, context, @graph, item_handler: echo_handler())
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert length(results) == 3
    end
  end

  describe "execute/4 — item and index injection" do
    test "item and index injected into child context" do
      captured = Agent.start_link(fn -> [] end) |> elem(1)

      handler = fn item, context, _graph, _opts ->
        idx = Context.get(context, "map.current_index")
        Agent.update(captured, fn list -> [{item, idx} | list] end)

        %Outcome{
          status: :success,
          context_updates: %{"last_response" => "#{item}@#{idx}"}
        }
      end

      node = make_node("ij", %{"source_key" => "items"})
      context = Context.new(%{"items" => Jason.encode!(["a", "b"])})

      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :success

      pairs = Agent.get(captured, & &1) |> Enum.sort()
      assert {"a", "0"} in pairs
      assert {"b", "1"} in pairs
    end
  end

  describe "execute/4 — error handling" do
    test "on_item_error=skip skips failed items" do
      node =
        make_node("es", %{
          "source_key" => "items",
          "on_item_error" => "skip"
        })

      context = Context.new(%{"items" => Jason.encode!(["a", "b", "c"])})
      handler = failing_handler([1])

      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert length(results) == 2
      assert outcome.context_updates["map.es.error_count"] == "1"
    end

    test "on_item_error=fail aborts" do
      node =
        make_node("ef", %{
          "source_key" => "items",
          "on_item_error" => "fail"
        })

      context = Context.new(%{"items" => Jason.encode!(["a", "b", "c"])})
      handler = failing_handler([0])

      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "map failed")
    end

    test "on_item_error=collect_nil includes nil for failures" do
      node =
        make_node("ec", %{
          "source_key" => "items",
          "on_item_error" => "collect_nil"
        })

      context = Context.new(%{"items" => Jason.encode!(["a", "b", "c"])})
      handler = failing_handler([1])

      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :success
      results = Jason.decode!(outcome.context_updates["map.results"])
      assert length(results) == 3
      assert Enum.at(results, 1) == nil
    end

    test "empty collection — success with empty results" do
      node = make_node("em", %{"source_key" => "items"})
      context = Context.new(%{"items" => "[]"})

      outcome = MapHandler.execute(node, context, @graph, item_handler: echo_handler())
      assert outcome.status == :success
      assert Jason.decode!(outcome.context_updates["map.results"]) == []
      assert outcome.context_updates["map.em.count"] == "0"
    end

    test "missing source_key — fails" do
      node = make_node("ms", %{})
      context = Context.new()

      outcome = MapHandler.execute(node, context, @graph, item_handler: echo_handler())
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires 'source_key'")
    end

    test "source_key not found in context — fails" do
      node = make_node("nf", %{"source_key" => "missing"})
      context = Context.new()

      outcome = MapHandler.execute(node, context, @graph, item_handler: echo_handler())
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "not found in context")
    end
  end

  describe "execute/4 — custom keys" do
    test "custom collect_key and result_key" do
      handler = fn item, _ctx, _g, _o ->
        %Outcome{
          status: :success,
          context_updates: %{"output" => "done:#{item}"}
        }
      end

      node =
        make_node("ck", %{
          "source_key" => "items",
          "collect_key" => "my_results",
          "result_key" => "output"
        })

      context = Context.new(%{"items" => Jason.encode!(["a"])})
      outcome = MapHandler.execute(node, context, @graph, item_handler: handler)
      assert outcome.status == :success
      assert Jason.decode!(outcome.context_updates["my_results"]) == ["done:a"]
    end
  end

  describe "idempotency/0" do
    test "returns :side_effecting" do
      assert MapHandler.idempotency() == :side_effecting
    end
  end

  describe "registry" do
    test "map type resolves to MapHandler" do
      node = make_node("reg", %{})
      assert Arbor.Orchestrator.Handlers.Registry.resolve(node) == MapHandler
    end
  end
end
