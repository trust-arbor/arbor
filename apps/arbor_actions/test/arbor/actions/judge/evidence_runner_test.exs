defmodule Arbor.Actions.Judge.EvidenceRunnerTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Judge.EvidenceRunner
  alias Arbor.Contracts.Judge.Evidence

  @subject %{
    content: "This is a security analysis. We recommend implementing authentication checks because they prevent unauthorized access.",
    perspective: :security
  }

  @context %{
    question: "Is the design secure?",
    reference_docs: ["docs/security.md"],
    perspective_prompt: "Evaluate security aspects"
  }

  describe "run/3" do
    test "returns evidence from all default producers" do
      evidence = EvidenceRunner.run(@subject, @context)

      assert is_list(evidence)
      assert length(evidence) == 3

      types = Enum.map(evidence, & &1.type)
      assert :format_compliance in types
      assert :perspective_relevance in types
      assert :reference_engagement in types
    end

    test "all evidence items are Evidence structs" do
      evidence = EvidenceRunner.run(@subject, @context)

      Enum.each(evidence, fn e ->
        assert %Evidence{} = e
        assert is_number(e.score)
        assert e.score >= 0.0 and e.score <= 1.0
        assert is_boolean(e.passed)
      end)
    end

    test "accepts custom producers list" do
      defmodule TestProducer do
        @behaviour Arbor.Contracts.Judge.EvidenceProducer

        @impl true
        def name, do: :test_check

        @impl true
        def description, do: "test"

        @impl true
        def produce(_subject, _context, _opts) do
          {:ok, %Evidence{type: :test_check, score: 0.9, passed: true, detail: "test"}}
        end
      end

      evidence = EvidenceRunner.run(@subject, @context, producers: [TestProducer])
      assert length(evidence) == 1
      assert hd(evidence).type == :test_check
    end

    test "skips failed producers gracefully" do
      defmodule FailProducer do
        @behaviour Arbor.Contracts.Judge.EvidenceProducer
        def name, do: :fail_check
        def description, do: "always fails"
        def produce(_s, _c, _o), do: {:error, :deliberate_failure}
      end

      evidence = EvidenceRunner.run(@subject, @context, producers: [FailProducer])
      assert evidence == []
    end
  end

  describe "aggregate_score/1" do
    test "returns mean of evidence scores" do
      evidence = [
        %Evidence{type: :a, score: 0.8, passed: true},
        %Evidence{type: :b, score: 0.6, passed: true}
      ]

      assert EvidenceRunner.aggregate_score(evidence) == 0.7
    end

    test "returns 0.5 for empty evidence" do
      assert EvidenceRunner.aggregate_score([]) == 0.5
    end
  end

  describe "summarize/1" do
    test "produces JSON-serializable summary" do
      evidence = EvidenceRunner.run(@subject, @context)
      summary = EvidenceRunner.summarize(evidence)

      assert is_number(summary["aggregate_score"])
      assert is_boolean(summary["all_passed"])
      assert is_list(summary["checks"])
      assert length(summary["checks"]) == 3
      assert is_binary(Jason.encode!(summary))
    end
  end
end
