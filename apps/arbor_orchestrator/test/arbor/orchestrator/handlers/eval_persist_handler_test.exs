defmodule Arbor.Orchestrator.Handlers.EvalPersistHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Handlers.EvalPersistHandler
  alias Arbor.Orchestrator.Engine.Context

  defp make_node(attrs) do
    %{
      id: "persist_node",
      type: "eval.persist",
      attrs: attrs
    }
  end

  defp make_graph, do: %{}

  describe "execute/4" do
    test "fails without domain attribute" do
      node = make_node(%{})
      context = Context.new()

      outcome = EvalPersistHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "domain"
    end

    test "succeeds with domain and results in context" do
      results = [
        %{
          "id" => "sample_1",
          "input" => "test input",
          "expected" => "test expected",
          "actual" => "test actual",
          "passed" => true,
          "scores" => [],
          "duration_ms" => 1500,
          "ttft_ms" => 200,
          "tokens_generated" => 50
        }
      ]

      context =
        Context.new(%{
          "eval.results.run_1" => results,
          "eval.model" => "test-model",
          "eval.provider" => "test-provider",
          "eval.dataset.path" => "test.jsonl"
        })

      node = make_node(%{"domain" => "coding"})
      outcome = EvalPersistHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.context_updates["eval.persist.run_id"]
      assert outcome.context_updates["eval.persist.status"] == "completed"
    end

    test "reads model and provider from node attrs" do
      context = Context.new(%{"eval.results.run_1" => []})

      node =
        make_node(%{
          "domain" => "heartbeat",
          "model" => "my-model",
          "provider" => "my-provider"
        })

      outcome = EvalPersistHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
    end

    test "uses explicit results_key" do
      results = [
        %{
          "id" => "s1",
          "input" => "x",
          "actual" => "y",
          "passed" => false,
          "duration_ms" => 500
        }
      ]

      context = Context.new(%{"my_results" => results})
      node = make_node(%{"domain" => "chat", "results_key" => "my_results"})

      outcome = EvalPersistHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.notes =~ "1 results"
    end

    test "handles empty results" do
      context = Context.new(%{})
      node = make_node(%{"domain" => "coding"})

      outcome = EvalPersistHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
      assert outcome.notes =~ "0 results"
    end

    test "computes timing aggregates" do
      results = [
        %{"id" => "s1", "passed" => true, "duration_ms" => 1000, "ttft_ms" => 100, "tokens_generated" => 50},
        %{"id" => "s2", "passed" => true, "duration_ms" => 2000, "ttft_ms" => 200, "tokens_generated" => 100},
        %{"id" => "s3", "passed" => false, "duration_ms" => 3000, "ttft_ms" => 300, "tokens_generated" => 75}
      ]

      context = Context.new(%{"eval.results.run" => results})
      node = make_node(%{"domain" => "coding"})

      outcome = EvalPersistHandler.execute(node, context, make_graph(), [])
      assert outcome.status == :success
    end
  end

  describe "idempotency/0" do
    test "returns :side_effecting" do
      assert EvalPersistHandler.idempotency() == :side_effecting
    end
  end
end
