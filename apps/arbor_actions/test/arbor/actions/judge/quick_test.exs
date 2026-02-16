defmodule Arbor.Actions.Judge.QuickTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Judge.Quick

  @mock_llm_response Jason.encode!(%{
    overall_score: 0.7,
    dimension_scores: %{},
    strengths: ["Reasonable"],
    weaknesses: [],
    recommendation: "keep",
    confidence: 0.6
  })

  defp mock_llm_fn(_system, _user) do
    {:ok, @mock_llm_response, %{model: "test-model", provider: "test"}}
  end

  describe "domain inference" do
    test "infers advisory for analysis-style content" do
      params = %{
        content: "We recommend implementing security checks. Consider the stability implications. This analysis suggests...",
        llm_fn: &mock_llm_fn/2
      }

      assert {:ok, result} = Quick.run(params, %{})
      assert result.rubric.domain == "advisory"
    end

    test "infers code for code-style content" do
      params = %{
        content: "defmodule MyApp.Router do\n  use Phoenix.Router\n  import Plug.Conn\n  def index(conn, _params), do: send_resp(conn, 200, \"ok\")\nend",
        mode: :verification
      }

      assert {:ok, result} = Quick.run(params, %{})
      assert result.rubric.domain == "code"
    end
  end

  describe "mode inference" do
    test "uses verification for short content" do
      params = %{content: "Short text."}
      assert {:ok, result} = Quick.run(params, %{})
      assert result.verdict.mode == :verification
    end
  end

  describe "explicit overrides" do
    test "respects explicit domain" do
      params = %{content: "test content", domain: "advisory", mode: :verification}
      assert {:ok, result} = Quick.run(params, %{})
      assert result.rubric.domain == "advisory"
    end

    test "respects explicit mode" do
      params = %{content: "test content", mode: :critique, llm_fn: &mock_llm_fn/2}
      assert {:ok, result} = Quick.run(params, %{})
      assert result.verdict.mode == :critique
    end
  end
end
