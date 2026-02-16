defmodule Arbor.Actions.Judge.ProducersTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Judge.Evidence

  alias Arbor.Actions.Judge.Producers.{
    FormatCompliance,
    PerspectiveRelevance,
    ReferenceEngagement
  }

  # ============================================================================
  # FormatCompliance
  # ============================================================================

  describe "FormatCompliance" do
    test "name and description" do
      assert FormatCompliance.name() == :format_compliance
      assert is_binary(FormatCompliance.description())
    end

    test "scores valid JSON with all fields" do
      content =
        Jason.encode!(%{
          analysis: "deep analysis",
          considerations: ["one", "two"],
          alternatives: ["alt1"],
          recommendation: "proceed"
        })

      assert {:ok, %Evidence{score: 1.0, passed: true}} =
               FormatCompliance.produce(%{content: content}, %{}, [])
    end

    test "scores valid JSON with partial fields" do
      content = Jason.encode!(%{analysis: "some analysis", recommendation: "proceed"})

      assert {:ok, %Evidence{score: score, passed: true}} =
               FormatCompliance.produce(%{content: content}, %{}, [])

      assert score == 0.5
    end

    test "scores empty JSON object" do
      assert {:ok, %Evidence{passed: false} = e} =
               FormatCompliance.produce(%{content: "{}"}, %{}, [])

      assert e.score == 0.0
    end

    test "scores empty content" do
      assert {:ok, %Evidence{passed: false} = e} =
               FormatCompliance.produce(%{content: ""}, %{}, [])

      assert e.score == 0.0
    end

    test "scores text response with quality indicators" do
      content = """
      This is a detailed analysis of the system.
      We should consider the security implications because they are significant.
      I recommend implementing additional authentication checks.
      However, there are tradeoffs to consider.
      """

      assert {:ok, %Evidence{score: score, passed: true}} =
               FormatCompliance.produce(%{content: content}, %{}, [])

      assert score == 1.0
    end

    test "scores malformed JSON" do
      assert {:ok, %Evidence{score: 0.25, passed: false}} =
               FormatCompliance.produce(%{content: "{invalid json"}, %{}, [])
    end
  end

  # ============================================================================
  # PerspectiveRelevance
  # ============================================================================

  describe "PerspectiveRelevance" do
    test "name and description" do
      assert PerspectiveRelevance.name() == :perspective_relevance
      assert is_binary(PerspectiveRelevance.description())
    end

    test "high relevance for security content with security perspective" do
      content = "The security vulnerability in the authentication system allows unauthorized access through the trust boundary."
      subject = %{content: content, perspective: :security}

      assert {:ok, %Evidence{score: score, passed: true}} =
               PerspectiveRelevance.produce(subject, %{}, [])

      assert score >= 0.5
    end

    test "low relevance for unrelated content" do
      content = "The weather is nice today. I like cats and pizza."
      subject = %{content: content, perspective: :security}

      assert {:ok, %Evidence{score: score}} =
               PerspectiveRelevance.produce(subject, %{}, [])

      assert score < 0.5
    end

    test "uses context perspective_prompt keywords when available" do
      content = "The widget factory produces widgets efficiently"
      context = %{perspective_prompt: "Evaluate widget production quality and factory throughput"}
      subject = %{content: content}

      assert {:ok, %Evidence{}} =
               PerspectiveRelevance.produce(subject, context, [])
    end

    test "returns 0.5 for unknown perspective with no context" do
      subject = %{content: "some content", perspective: :unknown_thing}

      assert {:ok, %Evidence{score: 0.5}} =
               PerspectiveRelevance.produce(subject, %{}, [])
    end
  end

  # ============================================================================
  # ReferenceEngagement
  # ============================================================================

  describe "ReferenceEngagement" do
    test "name and description" do
      assert ReferenceEngagement.name() == :reference_engagement
      assert is_binary(ReferenceEngagement.description())
    end

    test "passes when no reference docs provided" do
      assert {:ok, %Evidence{score: 1.0, passed: true}} =
               ReferenceEngagement.produce(%{content: "anything"}, %{}, [])
    end

    test "high engagement when docs are mentioned" do
      content = "As described in the security audit document and the contract rules, we should..."
      context = %{reference_docs: ["docs/security-audit.md", "docs/CONTRACT_RULES.md"]}

      assert {:ok, %Evidence{score: score, passed: true}} =
               ReferenceEngagement.produce(%{content: content}, context, [])

      assert score >= 0.5
    end

    test "low engagement when no docs mentioned" do
      content = "This is generic content with no specific references"
      context = %{reference_docs: ["docs/architecture.md", "docs/security.md"]}

      assert {:ok, %Evidence{passed: false} = e} =
               ReferenceEngagement.produce(%{content: content}, context, [])

      assert e.score == 0.0
    end

    test "handles map-style docs with title" do
      content = "The API design guide recommends..."
      context = %{reference_docs: [%{path: "docs/api.md", title: "API Design Guide"}]}

      assert {:ok, %Evidence{score: score, passed: true}} =
               ReferenceEngagement.produce(%{content: content}, context, [])

      assert score > 0.0
    end
  end
end
