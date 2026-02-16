defmodule Arbor.Actions.Judge.EvaluateTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Judge.Evaluate

  @advisory_content """
  Security Analysis: The authentication system has several vulnerabilities.
  We recommend implementing rate limiting because brute force attacks are
  a significant threat. Additionally, consider adding MFA as an alternative
  to single-factor auth. The trust boundary should be reviewed since the
  current design allows privilege escalation through the API gateway.
  """

  @mock_llm_response Jason.encode!(%{
                       overall_score: 0.78,
                       dimension_scores: %{
                         depth: 0.85,
                         perspective_relevance: 0.9,
                         actionability: 0.75,
                         accuracy: 0.7,
                         originality: 0.6,
                         calibration: 0.8
                       },
                       strengths: ["Strong security focus", "Concrete recommendations"],
                       weaknesses: ["Could explore more alternatives"],
                       recommendation: "keep",
                       confidence: 0.82
                     })

  defp mock_llm_fn(_system, _user) do
    {:ok, @mock_llm_response, %{model: "test-model", provider: "test"}}
  end

  describe "verification mode" do
    test "evaluates without LLM call" do
      params = %{
        content: @advisory_content,
        mode: :verification,
        domain: "advisory",
        perspective: "security"
      }

      assert {:ok, result} = Evaluate.run(params, %{})
      assert result.verdict.mode == :verification
      assert is_float(result.verdict.overall_score)
      assert result.verdict.overall_score >= 0.0
      assert result.verdict.overall_score <= 1.0
      assert result.verdict.recommendation in [:keep, :revise, :reject]
      assert is_list(result.evidence)
      assert length(result.evidence) == 3
    end

    test "produces dimension scores" do
      params = %{content: @advisory_content, mode: :verification, domain: "advisory"}
      assert {:ok, result} = Evaluate.run(params, %{})
      assert map_size(result.verdict.dimension_scores) > 0
    end
  end

  describe "critique mode" do
    test "evaluates with mock LLM" do
      params = %{
        content: @advisory_content,
        mode: :critique,
        domain: "advisory",
        perspective: "security",
        llm_fn: &mock_llm_fn/2
      }

      assert {:ok, result} = Evaluate.run(params, %{})
      assert result.verdict.mode == :critique
      assert result.verdict.overall_score == 0.78
      assert result.verdict.recommendation == :keep
      assert "Strong security focus" in result.verdict.strengths
      assert is_list(result.evidence)
    end

    test "includes rubric in result" do
      params = %{
        content: @advisory_content,
        mode: :critique,
        domain: "advisory",
        llm_fn: &mock_llm_fn/2
      }

      assert {:ok, result} = Evaluate.run(params, %{})
      assert result.rubric.domain == "advisory"
    end

    test "tracks duration" do
      params = %{
        content: @advisory_content,
        mode: :critique,
        llm_fn: &mock_llm_fn/2
      }

      assert {:ok, result} = Evaluate.run(params, %{})
      assert is_integer(result.duration_ms)
      assert result.duration_ms >= 0
    end
  end

  describe "domain selection" do
    test "defaults to advisory domain" do
      params = %{content: @advisory_content, mode: :verification}
      assert {:ok, result} = Evaluate.run(params, %{})
      assert result.rubric.domain == "advisory"
    end

    test "accepts code domain" do
      params = %{
        content: "defmodule Foo do\n  def bar, do: :ok\nend",
        mode: :verification,
        domain: "code"
      }

      assert {:ok, result} = Evaluate.run(params, %{})
      assert result.rubric.domain == "code"
    end

    test "rejects unknown domain" do
      params = %{content: "test", mode: :verification, domain: "unknown"}
      assert {:error, {:unknown_domain, "unknown"}} = Evaluate.run(params, %{})
    end
  end

  describe "custom rubric" do
    test "accepts custom rubric struct" do
      rubric = %Arbor.Contracts.Judge.Rubric{
        domain: "custom",
        version: 1,
        dimensions: [
          %{name: :quality, weight: 0.6, description: "Overall quality"},
          %{name: :style, weight: 0.4, description: "Writing style"}
        ]
      }

      params = %{content: @advisory_content, mode: :verification, rubric: rubric}
      assert {:ok, result} = Evaluate.run(params, %{})
      assert result.rubric.domain == "custom"
    end
  end

  describe "error handling" do
    test "handles LLM failure gracefully" do
      fail_fn = fn _sys, _user -> {:error, :llm_timeout} end

      params = %{
        content: @advisory_content,
        mode: :critique,
        llm_fn: fail_fn
      }

      assert {:error, :llm_timeout} = Evaluate.run(params, %{})
    end
  end
end
