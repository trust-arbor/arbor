defmodule Arbor.Memory.ThinkingExtractionTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Thinking

  @moduletag :fast

  # ============================================================================
  # Anthropic Extraction
  # ============================================================================

  describe "extract/3 :anthropic" do
    test "extracts from thinking content blocks" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me analyze this problem..."},
          %{"type" => "text", "text" => "The answer is 42."}
        ]
      }

      assert {:ok, text} = Thinking.extract(response, :anthropic)
      assert text == "Let me analyze this problem..."
    end

    test "joins multiple thinking blocks" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "First thought."},
          %{"type" => "text", "text" => "Middle text."},
          %{"type" => "thinking", "thinking" => "Second thought."}
        ]
      }

      assert {:ok, text} = Thinking.extract(response, :anthropic)
      assert text == "First thought.\n\nSecond thought."
    end

    test "returns :none when no thinking blocks" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Just text, no thinking."}
        ]
      }

      assert {:none, :no_thinking_blocks} = Thinking.extract(response, :anthropic)
    end

    test "returns :none for empty response" do
      assert {:none, :no_thinking_blocks} = Thinking.extract(%{}, :anthropic)
    end

    test "handles atom keys" do
      response = %{
        content: [
          %{type: "thinking", thinking: "Atom key thinking."}
        ]
      }

      assert {:ok, "Atom key thinking."} = Thinking.extract(response, :anthropic)
    end
  end

  # ============================================================================
  # DeepSeek Extraction
  # ============================================================================

  describe "extract/3 :deepseek" do
    test "extracts from reasoning_content field" do
      response = %{"reasoning_content" => "Deep reasoning about the problem..."}

      assert {:ok, text} = Thinking.extract(response, :deepseek)
      assert text == "Deep reasoning about the problem..."
    end

    test "handles atom key" do
      response = %{reasoning_content: "Atom key reasoning."}

      assert {:ok, "Atom key reasoning."} = Thinking.extract(response, :deepseek)
    end

    test "returns :none when no reasoning content" do
      response = %{"content" => "No reasoning here"}

      assert {:none, :no_reasoning_content} = Thinking.extract(response, :deepseek)
    end

    test "returns :none for empty string" do
      response = %{"reasoning_content" => ""}

      assert {:none, :no_reasoning_content} = Thinking.extract(response, :deepseek)
    end
  end

  # ============================================================================
  # OpenAI Extraction
  # ============================================================================

  describe "extract/3 :openai" do
    test "always returns hidden_reasoning" do
      response = %{"content" => "Any response"}

      assert {:none, :hidden_reasoning} = Thinking.extract(response, :openai)
    end

    test "returns hidden_reasoning even with thinking-like content" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "This shouldn't be extracted"}
        ]
      }

      assert {:none, :hidden_reasoning} = Thinking.extract(response, :openai)
    end
  end

  # ============================================================================
  # Generic Extraction
  # ============================================================================

  describe "extract/3 :generic" do
    test "tries anthropic-style first" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "Via content blocks"}
        ]
      }

      assert {:ok, "Via content blocks"} = Thinking.extract(response, :generic)
    end

    test "falls back to deepseek-style" do
      response = %{"reasoning_content" => "Via reasoning_content"}

      assert {:ok, "Via reasoning_content"} = Thinking.extract(response, :generic)
    end

    test "falls back to thinking field" do
      response = %{"thinking" => "Direct thinking field"}

      assert {:ok, "Direct thinking field"} = Thinking.extract(response, :generic)
    end

    test "extracts from XML thinking tags" do
      response = %{
        "content" => "<thinking>XML tagged thinking</thinking> The answer is 42."
      }

      assert {:ok, "XML tagged thinking"} = Thinking.extract(response, :generic)
    end

    test "extracts XML from text content blocks" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Before <thinking>Inner thoughts</thinking> after"}
        ]
      }

      assert {:ok, "Inner thoughts"} = Thinking.extract(response, :generic)
    end

    test "returns :none when nothing found" do
      response = %{"content" => "Plain text, no thinking"}

      assert {:none, :no_thinking_found} = Thinking.extract(response, :generic)
    end
  end

  # ============================================================================
  # Fallback to Generic
  # ============================================================================

  describe "fallback_to_generic option" do
    test "anthropic falls back to generic on failure" do
      response = %{"reasoning_content" => "DeepSeek-style in anthropic mode"}

      assert {:none, _} = Thinking.extract(response, :anthropic)
      assert {:ok, _} = Thinking.extract(response, :anthropic, fallback_to_generic: true)
    end

    test "deepseek falls back to generic on failure" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "Anthropic-style in deepseek mode"}
        ]
      }

      assert {:none, _} = Thinking.extract(response, :deepseek)
      assert {:ok, _} = Thinking.extract(response, :deepseek, fallback_to_generic: true)
    end
  end

  # ============================================================================
  # Identity Affecting Detection
  # ============================================================================

  describe "identity_affecting?/1" do
    test "detects goal-related patterns" do
      assert Thinking.identity_affecting?("My goal is to help the user")
      assert Thinking.identity_affecting?("I should focus on code quality")
      assert Thinking.identity_affecting?("I want to learn more about this")
      assert Thinking.identity_affecting?("I need to be more careful")
    end

    test "detects learning patterns" do
      assert Thinking.identity_affecting?("I learned that ETS is faster than GenServer")
      assert Thinking.identity_affecting?("I realize this approach is wrong")
      assert Thinking.identity_affecting?("I understand now how OTP works")
      assert Thinking.identity_affecting?("I discovered a new pattern")
    end

    test "detects self-reflection patterns" do
      assert Thinking.identity_affecting?("I am an AI assistant")
      assert Thinking.identity_affecting?("My purpose is to help developers")
      assert Thinking.identity_affecting?("My role in this project is")
      assert Thinking.identity_affecting?("My values include honesty")
    end

    test "detects constraint patterns" do
      assert Thinking.identity_affecting?("I cannot access the internet")
      assert Thinking.identity_affecting?("I must not share private data")
      assert Thinking.identity_affecting?("My constraints prevent this")
    end

    test "returns false for non-identity text" do
      refute Thinking.identity_affecting?("The function returns a list")
      refute Thinking.identity_affecting?("This code has a bug on line 42")
      refute Thinking.identity_affecting?("The test expects true but got false")
    end

    test "is case-insensitive" do
      assert Thinking.identity_affecting?("MY GOAL is clear")
      assert Thinking.identity_affecting?("I LEARNED something new")
    end

    test "returns false for nil and non-binary" do
      refute Thinking.identity_affecting?(nil)
      refute Thinking.identity_affecting?(42)
    end
  end

  # ============================================================================
  # Unknown Provider
  # ============================================================================

  describe "extract/3 unknown provider" do
    test "falls back to generic extraction" do
      response = %{"reasoning_content" => "Unknown provider reasoning"}

      assert {:ok, "Unknown provider reasoning"} = Thinking.extract(response, :some_new_provider)
    end
  end
end
