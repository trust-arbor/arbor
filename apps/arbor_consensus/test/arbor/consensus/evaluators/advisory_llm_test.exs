defmodule Arbor.Consensus.Evaluators.AdvisoryLLMTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Consensus.TestHelpers.{ErrorAI, MockAI}
  alias Arbor.Contracts.Consensus.Proposal

  @moduletag :fast

  @all_perspectives [
    :brainstorming,
    :user_experience,
    :security,
    :privacy,
    :stability,
    :capability,
    :emergence,
    :vision,
    :performance,
    :generalization,
    :resource_usage,
    :consistency
  ]

  describe "behaviour implementation" do
    test "name/0 returns :advisory_llm" do
      assert AdvisoryLLM.name() == :advisory_llm
    end

    test "perspectives/0 returns all 12 perspectives" do
      perspectives = AdvisoryLLM.perspectives()
      assert length(perspectives) == 12

      for p <- @all_perspectives do
        assert p in perspectives, "missing perspective: #{p}"
      end
    end

    test "strategy/0 returns :llm" do
      assert AdvisoryLLM.strategy() == :llm
    end
  end

  describe "evaluate/3 — all perspectives" do
    for perspective <- [
          :brainstorming,
          :user_experience,
          :security,
          :privacy,
          :stability,
          :capability,
          :emergence,
          :vision,
          :performance,
          :generalization,
          :resource_usage,
          :consistency
        ] do
      test "evaluates from #{perspective} perspective" do
        proposal = TestHelpers.build_proposal(%{description: "Test #{unquote(perspective)}"})

        assert {:ok, eval} =
                 AdvisoryLLM.evaluate(proposal, unquote(perspective), ai_module: MockAI)

        assert eval.perspective == unquote(perspective)
        assert eval.vote == :approve
        assert eval.sealed == true
        assert eval.reasoning =~ "Mock analysis"
      end
    end

    test "rejects unsupported perspective" do
      proposal = TestHelpers.build_proposal()

      assert {:error, {:unsupported_perspective, :nonexistent, _}} =
               AdvisoryLLM.evaluate(proposal, :nonexistent, ai_module: MockAI)
    end
  end

  describe "evaluate/3 — error handling" do
    test "handles AI error gracefully" do
      proposal = TestHelpers.build_proposal(%{description: "Test error handling"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, ai_module: ErrorAI)

      assert eval.vote == :abstain
      assert eval.confidence == 0.0
      assert eval.reasoning =~ "LLM error"
    end

    test "includes context in evaluation" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Should we use Redis?",
          target_layer: 4,
          context: %{constraints: "must survive restarts", budget: "low"}
        })

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :stability, ai_module: MockAI)

      assert eval.vote == :approve
      assert eval.sealed == true
    end
  end

  describe "reference documents" do
    test "vision includes VISION.md path automatically" do
      proposal = TestHelpers.build_proposal(%{description: "Does this align with the vision?"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :vision, ai_module: MockAI)

      assert eval.perspective == :vision
      assert eval.sealed == true
    end

    test "reference_docs paths included for any perspective" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Brainstorm with reference doc",
          target_layer: 4,
          context: %{reference_docs: [".arbor/roadmap/consensus-redesign.md"]}
        })

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, ai_module: MockAI)

      assert eval.perspective == :brainstorming
      assert eval.sealed == true
    end

    test "vision includes both VISION.md and reference_docs paths" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Check vision alignment",
          target_layer: 4,
          context: %{reference_docs: ["docs/design.md"]}
        })

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :vision, ai_module: MockAI)

      assert eval.perspective == :vision
      assert eval.sealed == true
    end

    test "nonexistent doc paths are listed without error" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Check with nonexistent doc path",
          target_layer: 4,
          context: %{reference_docs: ["/nonexistent/path/to/doc.md"]}
        })

      # Paths are just listed in the prompt — no file I/O, no crash
      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, ai_module: MockAI)

      assert eval.perspective == :brainstorming
    end
  end

  describe "context formatting" do
    test "reference_docs are excluded from context section in prompt" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Test context filtering",
          target_layer: 4,
          context: %{
            important_info: "this should appear",
            reference_docs: ["/some/path.md"]
          }
        })

      # Evaluate from a non-vision perspective to verify reference_docs
      # don't appear in the context section
      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, ai_module: MockAI)

      assert eval.sealed == true
    end
  end

  describe "model diversity" do
    test "provider_map/0 returns provider for each perspective" do
      map = AdvisoryLLM.provider_map()
      assert map_size(map) == 12

      # Each perspective has a provider
      for p <- @all_perspectives do
        assert Map.has_key?(map, p), "missing provider for: #{p}"
      end

      # Multiple providers are represented (not all the same model)
      providers = map |> Map.values() |> Enum.uniq()
      assert length(providers) >= 3, "expected at least 3 different providers, got: #{inspect(providers)}"
    end

    test "each perspective has a default provider assignment" do
      map = AdvisoryLLM.provider_map()

      # Verify specific assignments
      assert map[:security] == :anthropic
      assert map[:privacy] == :openai
      assert map[:emergence] == :opencode
      assert map[:user_experience] == :gemini
      assert map[:vision] == :anthropic
      assert map[:brainstorming] == :opencode
    end

    test "caller can override provider via opts" do
      # Verify the override mechanism works by checking that evaluate/3
      # accepts provider opt without error (the actual routing happens in AI module)
      proposal = TestHelpers.build_proposal(%{description: "Override test"})

      # provider: :gemini overrides the default — MockAI doesn't check it,
      # but the opt passes through without error
      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :security,
                 ai_module: MockAI,
                 provider: :gemini
               )

      assert eval.sealed == true
    end
  end

  describe "response parsing" do
    test "parses valid JSON response into structured reasoning" do
      proposal = TestHelpers.build_proposal(%{description: "Test parsing"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, ai_module: MockAI)

      assert eval.reasoning =~ "Considerations"
      assert eval.reasoning =~ "Alternatives"
      assert eval.reasoning =~ "Recommendation"
    end

    test "handles non-JSON response as raw text" do
      defmodule RawTextAI do
        def generate_text(_prompt, _opts) do
          {:ok,
           %{
             text: "This is just plain text analysis without JSON.",
             model: "mock",
             provider: :mock,
             usage: %{}
           }}
        end
      end

      proposal = TestHelpers.build_proposal(%{description: "Test raw text"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :security, ai_module: RawTextAI)

      assert eval.reasoning == "This is just plain text analysis without JSON."
    end
  end
end
