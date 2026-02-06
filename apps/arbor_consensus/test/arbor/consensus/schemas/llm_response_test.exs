defmodule Arbor.Consensus.Schemas.LLMResponseTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Schemas.LLMResponse

  @moduletag :fast

  describe "vote_response schema" do
    test "validates minimal valid response" do
      schema = LLMResponse.vote_response()

      json = ~s({"vote": "approve", "reasoning": "Looks good"})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["vote"] == "approve"
      assert validated["reasoning"] == "Looks good"
    end

    test "validates full response with all fields" do
      schema = LLMResponse.vote_response()

      json = ~s({
        "vote": "reject",
        "reasoning": "Security concerns",
        "concerns": ["SQL injection", "XSS"],
        "suggestions": ["Use parameterized queries"],
        "confidence": 0.9
      })

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["vote"] == "reject"
      assert validated["concerns"] == ["SQL injection", "XSS"]
      assert validated["confidence"] == 0.9
    end

    test "rejects invalid vote values" do
      schema = LLMResponse.vote_response()

      json = ~s({"vote": "maybe", "reasoning": "unsure"})

      assert {:error, {:invalid_schema, _errors}} = LLMResponse.validate(schema, json)
    end

    test "rejects missing required fields" do
      schema = LLMResponse.vote_response()

      json = ~s({"vote": "approve"})

      assert {:error, {:invalid_schema, _errors}} = LLMResponse.validate(schema, json)
    end

    test "validates confidence bounds" do
      schema = LLMResponse.vote_response()

      # Above max
      json = ~s({"vote": "approve", "reasoning": "ok", "confidence": 1.5})
      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)

      # Below min
      json = ~s({"vote": "approve", "reasoning": "ok", "confidence": -0.1})
      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end

    test "handles map input directly" do
      schema = LLMResponse.vote_response()

      map = %{"vote" => "approve", "reasoning" => "good"}

      assert {:ok, validated} = LLMResponse.validate(schema, map)
      assert validated["vote"] == "approve"
    end
  end

  describe "advisory_response schema" do
    test "validates minimal valid response" do
      schema = LLMResponse.advisory_response()

      json = ~s({"analysis": "This approach works well"})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["analysis"] == "This approach works well"
    end

    test "validates full response" do
      schema = LLMResponse.advisory_response()

      json = ~s({
        "analysis": "Detailed analysis here",
        "considerations": ["point 1", "point 2"],
        "alternatives": ["option A", "option B"],
        "recommendation": "Go with option A"
      })

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["considerations"] == ["point 1", "point 2"]
      assert validated["recommendation"] == "Go with option A"
    end

    test "rejects missing analysis field" do
      schema = LLMResponse.advisory_response()

      json = ~s({"considerations": ["point 1"]})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end
  end

  describe "topic_classification schema" do
    test "validates valid response" do
      schema = LLMResponse.topic_classification()

      json = ~s({"topic": "security", "confidence": 0.85})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["topic"] == "security"
      assert validated["confidence"] == 0.85
    end

    test "validates without confidence" do
      schema = LLMResponse.topic_classification()

      json = ~s({"topic": "architecture"})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["topic"] == "architecture"
    end

    test "rejects empty topic" do
      schema = LLMResponse.topic_classification()

      json = ~s({"topic": ""})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end
  end

  describe "JSON extraction" do
    test "extracts JSON from text with surrounding content" do
      schema = LLMResponse.vote_response()

      text = """
      Here's my analysis:

      {"vote": "approve", "reasoning": "All good"}

      Thanks for asking!
      """

      assert {:ok, validated} = LLMResponse.validate(schema, text)
      assert validated["vote"] == "approve"
    end

    test "returns error for invalid JSON" do
      schema = LLMResponse.vote_response()

      assert {:error, :invalid_json} = LLMResponse.validate(schema, "not json at all")
    end

    test "returns error for malformed JSON" do
      schema = LLMResponse.vote_response()

      assert {:error, :invalid_json} = LLMResponse.validate(schema, "{invalid json}")
    end
  end
end
