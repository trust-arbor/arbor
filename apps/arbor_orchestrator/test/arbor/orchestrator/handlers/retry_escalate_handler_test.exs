defmodule Arbor.Orchestrator.Handlers.RetryEscalateHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.RetryEscalateHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp make_node(id, attrs) do
    %Node{id: id, attrs: Map.merge(%{"type" => "retry.escalate"}, attrs)}
  end

  defp mock_backend(responses) do
    fn _prompt, opts ->
      model = Keyword.get(opts, :model, "unknown")
      Map.get(responses, model, {:error, "no response configured for #{model}"})
    end
  end

  describe "execute/4 — success paths" do
    test "first model succeeds — uses cheapest" do
      backend =
        mock_backend(%{
          "haiku" => {:ok, "haiku response"},
          "sonnet" => {:ok, "sonnet response"}
        })

      node = make_node("e1", %{"prompt" => "test prompt"})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["last_response"] == "haiku response"
      assert outcome.context_updates["escalate.e1.model_used"] == "haiku"
      assert outcome.context_updates["escalate.e1.attempts"] == "1"
    end

    test "first model fails, second succeeds — escalates" do
      backend =
        mock_backend(%{
          "haiku" => {:error, "too hard"},
          "sonnet" => {:ok, "sonnet response"},
          "opus" => {:ok, "opus response"}
        })

      node = make_node("e2", %{"prompt" => "complex task"})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["last_response"] == "sonnet response"
      assert outcome.context_updates["escalate.e2.model_used"] == "sonnet"
      assert outcome.context_updates["escalate.e2.attempts"] == "2"
    end

    test "reads prompt from source_key in context" do
      backend = mock_backend(%{"haiku" => {:ok, "done"}})

      node = make_node("e3", %{"source_key" => "my_prompt"})
      context = Context.new(%{"my_prompt" => "do this thing"})

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
    end
  end

  describe "execute/4 — failure paths" do
    test "all models fail — returns fail with history" do
      backend =
        mock_backend(%{
          "haiku" => {:error, "nope"},
          "sonnet" => {:error, "also nope"},
          "opus" => {:error, "still nope"}
        })

      node = make_node("f1", %{"prompt" => "impossible"})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "All models")

      history = Jason.decode!(outcome.context_updates["escalate.f1.history"])
      assert length(history) == 3
      assert Enum.all?(history, &(&1["status"] == "fail"))
    end

    test "missing prompt — fails" do
      backend = mock_backend(%{})
      node = make_node("f2", %{})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires a prompt")
    end
  end

  describe "execute/4 — timeout escalation" do
    test "timeout triggers escalation" do
      # Backend that sleeps on haiku but succeeds on sonnet
      backend = fn _prompt, opts ->
        model = Keyword.get(opts, :model)

        if model == "haiku" do
          Process.sleep(200)
          {:ok, "late haiku"}
        else
          {:ok, "sonnet fast"}
        end
      end

      node =
        make_node("t1", %{
          "prompt" => "test",
          "timeout_ms" => "50",
          "escalate_on" => "fail,timeout"
        })

      context = Context.new()
      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["escalate.t1.model_used"] == "sonnet"
    end
  end

  describe "execute/4 — low score escalation" do
    test "low score triggers escalation when in escalate_on" do
      backend =
        mock_backend(%{
          "haiku" => {:ok, "shallow answer"},
          "sonnet" => {:ok, "deeper answer"}
        })

      node =
        make_node("ls1", %{
          "prompt" => "test",
          "escalate_on" => "fail,low_score",
          "score_key" => "quality",
          "score_threshold" => "0.8"
        })

      context = Context.new(%{"quality" => "0.5"})
      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      # Haiku skipped due to low score, sonnet used instead
      assert outcome.context_updates["escalate.ls1.model_used"] == "sonnet"

      history = Jason.decode!(outcome.context_updates["escalate.ls1.history"])
      assert length(history) == 2
      assert Enum.at(history, 0)["status"] == "low_score"
    end

    test "low score does NOT escalate when not in escalate_on" do
      backend = mock_backend(%{"haiku" => {:ok, "answer"}})

      node =
        make_node("ls2", %{
          "prompt" => "test",
          "escalate_on" => "fail",
          "score_key" => "quality",
          "score_threshold" => "0.8"
        })

      context = Context.new(%{"quality" => "0.5"})
      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["escalate.ls2.model_used"] == "haiku"
    end
  end

  describe "execute/4 — custom models" do
    test "single model — no escalation possible" do
      backend = mock_backend(%{"gpt-4" => {:error, "down"}})

      node = make_node("cm1", %{"prompt" => "test", "models" => "gpt-4"})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :fail
    end

    test "custom model list used" do
      backend =
        mock_backend(%{
          "fast" => {:error, "nope"},
          "medium" => {:ok, "medium works"}
        })

      node = make_node("cm2", %{"prompt" => "test", "models" => "fast,medium,slow"})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["escalate.cm2.model_used"] == "medium"
    end
  end

  describe "execute/4 — history tracking" do
    test "history contains all attempts with model/status/reason" do
      backend =
        mock_backend(%{
          "haiku" => {:error, "bad"},
          "sonnet" => {:error, "worse"},
          "opus" => {:ok, "finally"}
        })

      node = make_node("h1", %{"prompt" => "test"})
      context = Context.new()

      outcome = RetryEscalateHandler.execute(node, context, @graph, llm_backend: backend)
      history = Jason.decode!(outcome.context_updates["escalate.h1.history"])
      assert length(history) == 3
      assert Enum.at(history, 0)["model"] == "haiku"
      assert Enum.at(history, 0)["status"] == "fail"
      assert Enum.at(history, 1)["model"] == "sonnet"
      assert Enum.at(history, 2)["model"] == "opus"
      assert Enum.at(history, 2)["status"] == "success"
    end
  end

  describe "idempotency/0" do
    test "returns :side_effecting" do
      assert RetryEscalateHandler.idempotency() == :side_effecting
    end
  end

  describe "registry" do
    test "retry.escalate type resolves to RetryEscalateHandler" do
      node = make_node("reg", %{})
      assert Arbor.Orchestrator.Handlers.Registry.resolve(node) == RetryEscalateHandler
    end
  end
end
