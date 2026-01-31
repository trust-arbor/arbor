defmodule Arbor.Actions.AITest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.AI

  @moduletag :fast

  # We use Mox for mocking - need to check if Arbor.AI is set up with a behaviour
  # For now, we'll use a simple approach with process dictionary to inject responses

  describe "GenerateText" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = AI.GenerateText.validate_params(%{})

      # Test that schema accepts valid params
      assert {:ok, _} = AI.GenerateText.validate_params(%{prompt: "Hello"})
    end

    test "validates action metadata" do
      assert AI.GenerateText.name() == "ai_generate_text"
      assert AI.GenerateText.category() == "ai"
      assert "generate" in AI.GenerateText.tags()
      assert "llm" in AI.GenerateText.tags()
    end

    test "generates tool schema" do
      tool = AI.GenerateText.to_tool()
      assert is_map(tool)
      assert tool[:name] == "ai_generate_text"
      assert tool[:description] =~ "Generate text"
    end
  end

  describe "AnalyzeCode" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = AI.AnalyzeCode.validate_params(%{})
      assert {:error, _} = AI.AnalyzeCode.validate_params(%{code: "def foo"})

      # Test that schema accepts valid params
      assert {:ok, _} =
               AI.AnalyzeCode.validate_params(%{
                 code: "def foo, do: :bar",
                 question: "What does this do?"
               })
    end

    test "validates action metadata" do
      assert AI.AnalyzeCode.name() == "ai_analyze_code"
      assert AI.AnalyzeCode.category() == "ai"
      assert "code" in AI.AnalyzeCode.tags()
      assert "analyze" in AI.AnalyzeCode.tags()
    end

    test "generates tool schema" do
      tool = AI.AnalyzeCode.to_tool()
      assert is_map(tool)
      assert tool[:name] == "ai_analyze_code"
      assert tool[:description] =~ "Analyze code"
    end
  end

  describe "GenerateText integration" do
    # These tests would call the real AI service - marked as :llm for filtering
    @describetag :llm

    @tag :skip
    test "generates text with real provider" do
      # This would make a real API call - skip by default
      assert {:ok, result} =
               AI.GenerateText.run(
                 %{prompt: "Say hello in one word", max_tokens: 10},
                 %{}
               )

      assert is_binary(result.text)
      assert result.provider_used != nil
    end
  end

  describe "AnalyzeCode integration" do
    @describetag :llm

    @tag :skip
    test "analyzes code with real provider" do
      # This would make a real API call - skip by default
      code = """
      def factorial(0), do: 1
      def factorial(n), do: n * factorial(n - 1)
      """

      assert {:ok, result} =
               AI.AnalyzeCode.run(
                 %{
                   code: code,
                   question: "What does this function compute?",
                   language: "elixir"
                 },
                 %{}
               )

      assert is_binary(result.analysis)
      assert is_list(result.suggestions)
    end
  end

  describe "suggestion extraction" do
    # Test the internal suggestion extraction logic via the module
    # We can't easily test run/2 without mocking Arbor.AI,
    # but we can test that the schema is correct and the action compiles

    test "module compiles and is usable" do
      # Ensure module is loaded and usable
      assert Code.ensure_loaded?(AI.GenerateText)
      assert Code.ensure_loaded?(AI.AnalyzeCode)

      # Ensure the run/2 function exists
      assert function_exported?(AI.GenerateText, :run, 2)
      assert function_exported?(AI.AnalyzeCode, :run, 2)
    end
  end
end
