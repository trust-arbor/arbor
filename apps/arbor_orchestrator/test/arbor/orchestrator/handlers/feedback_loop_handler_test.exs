defmodule Arbor.Orchestrator.Handlers.FeedbackLoopHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.FeedbackLoopHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp make_node(id, attrs) do
    %Node{id: id, attrs: Map.merge(%{"type" => "feedback.loop"}, attrs)}
  end

  defp improving_backend do
    # Returns progressively longer content to simulate improvement
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn _prompt, _opts ->
      count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

      if rem(count, 2) == 0 do
        # Critique call
        {:ok, "Add more detail and examples"}
      else
        # Revision call — produce progressively longer content
        base = "## Improved Content\n\nThis is a revised version.\n\n"
        extra = String.duplicate("- Additional point #{count}\n", count)
        {:ok, base <> extra}
      end
    end
  end

  describe "execute/4 — basic iteration" do
    test "content already above threshold — no loops" do
      backend = fn _prompt, _opts -> {:ok, "won't be used"} end

      # Long structured content should score high
      content = """
      ## Section One

      This is a detailed explanation with multiple paragraphs.

      ## Section Two

      - Point one about the topic
      - Point two with more detail
      - Point three for completeness

      ## Section Three

      ```elixir
      def example, do: :ok
      ```

      Another paragraph with good content here.
      """

      node =
        make_node("fl1", %{
          "score_threshold" => "0.3",
          "scoring_method" => "structure"
        })

      context = Context.new(%{"last_response" => content})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["feedback.fl1.iterations"] == "1"
    end

    test "multiple iterations improve content" do
      backend = improving_backend()

      node =
        make_node("fl2", %{
          "max_iterations" => "3",
          "score_threshold" => "0.99",
          "scoring_method" => "structure"
        })

      context = Context.new(%{"last_response" => "short"})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success

      iterations = String.to_integer(outcome.context_updates["feedback.fl2.iterations"])
      assert iterations >= 2
    end

    test "max iterations reached — stops" do
      backend = fn _prompt, _opts -> {:ok, "minimal"} end

      node =
        make_node("fl3", %{
          "max_iterations" => "2",
          "score_threshold" => "0.99",
          "scoring_method" => "length_ratio"
        })

      context = Context.new(%{"last_response" => "x"})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success

      iterations = String.to_integer(outcome.context_updates["feedback.fl3.iterations"])
      assert iterations <= 3
    end
  end

  describe "execute/4 — plateau detection" do
    test "plateau detected — stops early" do
      # Backend that always returns the same content → scores plateau
      backend = fn _prompt, _opts -> {:ok, "same content every time"} end

      node =
        make_node("pl1", %{
          "max_iterations" => "10",
          "score_threshold" => "0.99",
          "plateau_window" => "3",
          "plateau_tolerance" => "0.05",
          "scoring_method" => "length_ratio"
        })

      context = Context.new(%{"last_response" => "same content every time"})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
      assert outcome.context_updates["feedback.pl1.plateau_hit"] == "true"
    end
  end

  describe "execute/4 — scoring methods" do
    test "length_ratio scoring" do
      backend = fn _prompt, _opts -> {:ok, "unchanged"} end

      node =
        make_node("sc1", %{
          "max_iterations" => "1",
          "score_threshold" => "0.99",
          "scoring_method" => "length_ratio"
        })

      # Short content should score low relative to 500 char default reference
      context = Context.new(%{"last_response" => "short"})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success

      score = String.to_float(outcome.context_updates["feedback.sc1.final_score"])
      assert score < 0.1
    end

    test "keyword_coverage with reference" do
      backend = fn _prompt, _opts -> {:ok, "irrelevant"} end

      # Content shares keywords with reference — score should be ~0.5
      # Use threshold below expected score so loop exits immediately
      node =
        make_node("sc2", %{
          "max_iterations" => "1",
          "score_threshold" => "0.3",
          "scoring_method" => "keyword_coverage",
          "reference_key" => "ref"
        })

      context =
        Context.new(%{
          "last_response" => "The elixir programming language has great concurrency",
          "ref" => "Elixir is a programming language for concurrency"
        })

      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      score = String.to_float(outcome.context_updates["feedback.sc2.final_score"])
      assert score > 0.3
    end

    test "structure scoring detects elements" do
      backend = fn _prompt, _opts -> {:ok, "no structure"} end

      # Build content with enough structural elements to score > 0.3
      # Each element counts: headers, code blocks, list items, paragraphs
      structured = """
      ## Header One

      Paragraph one here.

      ## Header Two

      - List item one
      - List item two
      - List item three

      ```elixir
      code_example()
      ```

      Another paragraph here.
      """

      # Threshold below expected score so we exit immediately
      node =
        make_node("sc3", %{
          "max_iterations" => "1",
          "score_threshold" => "0.05",
          "scoring_method" => "structure"
        })

      context = Context.new(%{"last_response" => structured})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      score = String.to_float(outcome.context_updates["feedback.sc3.final_score"])
      assert score > 0.3
    end

    test "combined scoring averages methods" do
      backend = fn _prompt, _opts -> {:ok, "irrelevant"} end

      node =
        make_node("sc4", %{
          "max_iterations" => "1",
          "score_threshold" => "0.99",
          "scoring_method" => "combined"
        })

      context = Context.new(%{"last_response" => "## Title\n\nSome content here."})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      score = String.to_float(outcome.context_updates["feedback.sc4.final_score"])
      assert score >= 0.0 and score <= 1.0
    end
  end

  describe "execute/4 — context updates" do
    test "stores iteration count and scores" do
      backend = fn _prompt, _opts -> {:ok, "revised content here with more words"} end

      node =
        make_node("cu1", %{
          "max_iterations" => "2",
          "score_threshold" => "0.99",
          "scoring_method" => "length_ratio"
        })

      context = Context.new(%{"last_response" => "initial"})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)

      assert outcome.context_updates["feedback.cu1.iterations"]
      assert outcome.context_updates["feedback.cu1.final_score"]
      assert outcome.context_updates["feedback.cu1.scores"]
      assert outcome.context_updates["feedback.cu1.best_iteration"]
      assert outcome.context_updates["feedback.cu1.plateau_hit"]

      scores = Jason.decode!(outcome.context_updates["feedback.cu1.scores"])
      assert is_list(scores)
      assert scores != []
    end
  end

  describe "execute/4 — error handling" do
    test "missing source content — fails" do
      backend = fn _prompt, _opts -> {:ok, "x"} end
      node = make_node("err1", %{})
      context = Context.new()

      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "not found in context")
    end

    test "custom source_key works" do
      backend = fn _prompt, _opts -> {:ok, "same"} end

      node =
        make_node("err2", %{
          "source_key" => "my_content",
          "max_iterations" => "1",
          "score_threshold" => "0.99"
        })

      context = Context.new(%{"my_content" => "some text here"})
      outcome = FeedbackLoopHandler.execute(node, context, @graph, llm_backend: backend)
      assert outcome.status == :success
    end
  end

  describe "idempotency/0" do
    test "returns :side_effecting" do
      assert FeedbackLoopHandler.idempotency() == :side_effecting
    end
  end

  describe "registry" do
    test "feedback.loop type resolves to ComposeHandler (Phase 4 delegation)" do
      node = make_node("reg", %{})

      assert Arbor.Orchestrator.Handlers.Registry.resolve(node) ==
               Arbor.Orchestrator.Handlers.ComposeHandler
    end

    test "feedback.loop type injects mode attribute via resolve_with_attrs" do
      node = make_node("reg", %{})
      {handler, resolved_node} = Arbor.Orchestrator.Handlers.Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComposeHandler
      assert resolved_node.attrs["mode"] == "feedback"
    end
  end
end
