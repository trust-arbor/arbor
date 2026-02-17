defmodule Arbor.AI.ResponseNormalizerTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Response
  alias Arbor.AI.ResponseNormalizer

  @moduletag :fast

  # ===========================================================================
  # normalize_response/1 with Response struct
  # ===========================================================================

  describe "normalize_response/1 with Response struct" do
    test "normalizes a full Response struct" do
      response = %Response{
        text: "Hello world",
        thinking: [%{text: "reasoning", signature: "sig"}],
        usage: %{input_tokens: 10, output_tokens: 20, total_tokens: 30},
        model: "claude-sonnet-4",
        provider: :anthropic
      }

      result = ResponseNormalizer.normalize_response(response)

      assert result.text == "Hello world"
      assert result.thinking == [%{text: "reasoning", signature: "sig"}]
      assert result.usage == %{input_tokens: 10, output_tokens: 20, total_tokens: 30}
      assert result.model == "claude-sonnet-4"
      assert result.provider == :anthropic
    end

    test "defaults nil text to empty string" do
      response = %Response{text: nil, provider: :anthropic}
      result = ResponseNormalizer.normalize_response(response)
      assert result.text == ""
    end

    test "defaults nil usage to zeroed map" do
      response = %Response{text: "hi", provider: :anthropic, usage: nil}
      result = ResponseNormalizer.normalize_response(response)
      assert result.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    end

    test "preserves nil thinking" do
      response = %Response{text: "hi", provider: :anthropic}
      result = ResponseNormalizer.normalize_response(response)
      assert result.thinking == nil
    end
  end

  # ===========================================================================
  # normalize_response/1 with plain map (atom keys)
  # ===========================================================================

  describe "normalize_response/1 with plain map" do
    test "normalizes map with atom keys" do
      response = %{
        text: "result",
        thinking: nil,
        usage: %{input_tokens: 5, output_tokens: 15},
        model: "gpt-4",
        provider: :openai
      }

      result = ResponseNormalizer.normalize_response(response)
      assert result.text == "result"
      assert result.model == "gpt-4"
      assert result.provider == :openai
    end

    test "normalizes map with string keys" do
      response = %{
        "text" => "string keyed",
        "thinking" => nil,
        "usage" => %{},
        "model" => "gemini-pro",
        "provider" => :gemini
      }

      result = ResponseNormalizer.normalize_response(response)
      assert result.text == "string keyed"
      assert result.model == "gemini-pro"
      assert result.provider == :gemini
    end

    test "defaults missing text to empty string" do
      result = ResponseNormalizer.normalize_response(%{})
      assert result.text == ""
    end

    test "defaults missing usage to empty map" do
      result = ResponseNormalizer.normalize_response(%{})
      assert result.usage == %{}
    end
  end

  # ===========================================================================
  # format_api_response/3
  # ===========================================================================

  describe "format_api_response/3" do
    test "formats a basic string response" do
      result = ResponseNormalizer.format_api_response("Hello", :anthropic, "claude-sonnet-4")

      assert result.text == "Hello"
      assert result.provider == :anthropic
      assert result.model == "claude-sonnet-4"
      assert result.thinking == nil
    end

    test "formats a map response with text field" do
      response = %{text: "Answer", usage: %{input_tokens: 1, output_tokens: 2}}
      result = ResponseNormalizer.format_api_response(response, :openai, "gpt-4")

      assert result.text == "Answer"
      assert result.model == "gpt-4"
      assert result.provider == :openai
      assert result.usage.input_tokens == 1
      assert result.usage.output_tokens == 2
    end

    test "formats a map response with content field" do
      response = %{content: "From content field"}
      result = ResponseNormalizer.format_api_response(response, :gemini, "gemini-pro")

      assert result.text == "From content field"
    end

    test "extracts usage with total_tokens calculation" do
      response = %{
        text: "test",
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      result = ResponseNormalizer.format_api_response(response, :anthropic, "claude")
      assert result.usage.total_tokens == 150
    end

    test "preserves explicit total_tokens" do
      response = %{
        text: "test",
        usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 200}
      }

      result = ResponseNormalizer.format_api_response(response, :anthropic, "claude")
      assert result.usage.total_tokens == 200
    end
  end

  # ===========================================================================
  # format_tools_response/3
  # ===========================================================================

  describe "format_tools_response/3" do
    test "formats a tool-calling response" do
      tool_result = %{
        text: "Used tool",
        tool_calls: [%{name: "read_file", args: %{path: "/foo"}}],
        turns: 3,
        type: :tool_use
      }

      result = ResponseNormalizer.format_tools_response(tool_result, :anthropic, "claude-opus-4")

      assert result.text == "Used tool"
      assert result.provider == :anthropic
      assert result.model == "claude-opus-4"
      assert result.thinking == nil
      assert length(result.tool_calls) == 1
      assert result.turns == 3
      assert result.type == :tool_use
    end

    test "defaults missing fields" do
      result = ResponseNormalizer.format_tools_response(%{}, :openai, "gpt-4")

      assert result.text == ""
      assert result.tool_calls == []
      assert result.usage == %{}
      assert result.turns == nil
      assert result.type == nil
    end
  end

  # ===========================================================================
  # extract_text/1
  # ===========================================================================

  describe "extract_text/1" do
    test "returns binary input directly" do
      assert ResponseNormalizer.extract_text("plain string") == "plain string"
    end

    test "extracts text from map with :text key" do
      assert ResponseNormalizer.extract_text(%{text: "from text"}) == "from text"
    end

    test "extracts text from map with :content key" do
      assert ResponseNormalizer.extract_text(%{content: "from content"}) == "from content"
    end

    test "extracts text from nested message.content" do
      response = %{message: %{content: "nested"}}
      assert ResponseNormalizer.extract_text(response) == "nested"
    end

    test "returns empty string for unrecognized input" do
      assert ResponseNormalizer.extract_text(42) == ""
      assert ResponseNormalizer.extract_text(nil) == ""
      assert ResponseNormalizer.extract_text([]) == ""
    end

    test "returns empty string for map without recognized keys" do
      assert ResponseNormalizer.extract_text(%{other: "value"}) == ""
    end
  end

  # ===========================================================================
  # extract_usage/1
  # ===========================================================================

  describe "extract_usage/1" do
    test "extracts usage from map with :usage key" do
      response = %{usage: %{input_tokens: 10, output_tokens: 20, total_tokens: 30}}
      result = ResponseNormalizer.extract_usage(response)

      assert result.input_tokens == 10
      assert result.output_tokens == 20
      assert result.total_tokens == 30
    end

    test "calculates total_tokens when not provided" do
      response = %{usage: %{input_tokens: 10, output_tokens: 20}}
      result = ResponseNormalizer.extract_usage(response)

      assert result.total_tokens == 30
    end

    test "extracts cache_read_input_tokens" do
      response = %{usage: %{input_tokens: 10, output_tokens: 20, cache_read_input_tokens: 5}}
      result = ResponseNormalizer.extract_usage(response)

      assert result.cache_read_input_tokens == 5
    end

    test "defaults all tokens to zero when usage is nil" do
      response = %{usage: nil}
      result = ResponseNormalizer.extract_usage(response)

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
    end

    test "defaults to zeroed map for non-map input" do
      result = ResponseNormalizer.extract_usage("not a map")

      assert result.input_tokens == 0
      assert result.output_tokens == 0
      assert result.total_tokens == 0
      assert result.cache_read_input_tokens == 0
    end
  end

  # ===========================================================================
  # extract_thinking/1
  # ===========================================================================

  describe "extract_thinking/1" do
    test "returns nil for response without thinking blocks" do
      assert ResponseNormalizer.extract_thinking(%{}) == nil
      assert ResponseNormalizer.extract_thinking(%{text: "hello"}) == nil
    end

    test "returns nil for non-matching input" do
      assert ResponseNormalizer.extract_thinking("string") == nil
      assert ResponseNormalizer.extract_thinking(42) == nil
      assert ResponseNormalizer.extract_thinking(nil) == nil
    end

    test "extracts thinking from message with content list" do
      response = %{
        message: %{
          content: [
            %{type: :thinking, thinking: "I need to think about this", signature: "abc123"},
            %{type: :text, text: "Here is my answer"}
          ]
        }
      }

      result = ResponseNormalizer.extract_thinking(response)

      assert is_list(result)
      assert length(result) == 1
      [block] = result
      assert block.text == "I need to think about this"
      assert block.signature == "abc123"
    end

    test "extracts thinking with string type key" do
      response = %{
        message: %{
          content: [
            %{type: "thinking", text: "chain of thought", signature: nil}
          ]
        }
      }

      result = ResponseNormalizer.extract_thinking(response)
      assert is_list(result)
      [block] = result
      assert block.text == "chain of thought"
    end

    test "returns nil when content has no thinking blocks" do
      response = %{
        message: %{
          content: [
            %{type: :text, text: "No thinking here"}
          ]
        }
      }

      assert ResponseNormalizer.extract_thinking(response) == nil
    end
  end
end
