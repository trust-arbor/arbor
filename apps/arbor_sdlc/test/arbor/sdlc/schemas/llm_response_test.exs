defmodule Arbor.SDLC.Schemas.LLMResponseTest do
  use ExUnit.Case, async: true

  alias Arbor.SDLC.Schemas.LLMResponse

  @moduletag :fast

  describe "expansion_data schema" do
    test "validates minimal valid response" do
      schema = LLMResponse.expansion_data()

      json = ~s({"summary": "A brief description"})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["summary"] == "A brief description"
    end

    test "validates full response with all fields" do
      schema = LLMResponse.expansion_data()

      json = ~s({
        "priority": "high",
        "category": "feature",
        "effort": "medium",
        "summary": "Implement user auth",
        "why_it_matters": "Security foundation",
        "acceptance_criteria": ["Users can login", "Sessions persist"],
        "definition_of_done": ["Tests pass", "Docs updated"]
      })

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["priority"] == "high"
      assert validated["category"] == "feature"
      assert validated["effort"] == "medium"
      assert validated["acceptance_criteria"] == ["Users can login", "Sessions persist"]
    end

    test "validates all priority values" do
      schema = LLMResponse.expansion_data()

      for priority <- ~w(critical high medium low someday) do
        json = ~s({"priority": "#{priority}"})
        assert {:ok, validated} = LLMResponse.validate(schema, json)
        assert validated["priority"] == priority
      end
    end

    test "rejects invalid priority" do
      schema = LLMResponse.expansion_data()

      json = ~s({"priority": "urgent"})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end

    test "validates all category values" do
      schema = LLMResponse.expansion_data()

      for category <- ~w(feature refactor bug infrastructure idea research documentation content) do
        json = ~s({"category": "#{category}"})
        assert {:ok, validated} = LLMResponse.validate(schema, json)
        assert validated["category"] == category
      end
    end

    test "rejects invalid category" do
      schema = LLMResponse.expansion_data()

      json = ~s({"category": "unknown"})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end

    test "validates all effort values" do
      schema = LLMResponse.expansion_data()

      for effort <- ~w(small medium large ongoing) do
        json = ~s({"effort": "#{effort}"})
        assert {:ok, validated} = LLMResponse.validate(schema, json)
        assert validated["effort"] == effort
      end
    end

    test "rejects invalid effort" do
      schema = LLMResponse.expansion_data()

      json = ~s({"effort": "huge"})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end
  end

  describe "decision_analysis schema" do
    test "validates response with no decisions needed" do
      schema = LLMResponse.decision_analysis()

      json = ~s({"needs_decisions": false})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["needs_decisions"] == false
    end

    test "validates response with decision points" do
      schema = LLMResponse.decision_analysis()

      json = ~s({
        "needs_decisions": true,
        "decision_points": [
          {
            "question": "Which database?",
            "options": ["PostgreSQL", "SQLite"],
            "impact": "high",
            "recommendation": "PostgreSQL for production"
          }
        ]
      })

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["needs_decisions"] == true
      assert length(validated["decision_points"]) == 1
      assert hd(validated["decision_points"])["question"] == "Which database?"
    end

    test "rejects missing needs_decisions field" do
      schema = LLMResponse.decision_analysis()

      json = ~s({"decision_points": []})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end

    test "validates decision point impact values" do
      schema = LLMResponse.decision_analysis()

      for impact <- ~w(high medium low) do
        json = ~s({
          "needs_decisions": true,
          "decision_points": [{"question": "Test?", "impact": "#{impact}"}]
        })

        assert {:ok, _} = LLMResponse.validate(schema, json)
      end
    end

    test "rejects invalid impact value" do
      schema = LLMResponse.decision_analysis()

      json = ~s({
        "needs_decisions": true,
        "decision_points": [{"question": "Test?", "impact": "critical"}]
      })

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end
  end

  describe "consistency_check schema" do
    test "validates consistent result" do
      schema = LLMResponse.consistency_check()

      json = ~s({"is_consistent": true})

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["is_consistent"] == true
    end

    test "validates inconsistent result with details" do
      schema = LLMResponse.consistency_check()

      json = ~s({
        "is_consistent": false,
        "issues": ["Missing test coverage", "Incomplete docs"],
        "suggestions": ["Add unit tests", "Update README"]
      })

      assert {:ok, validated} = LLMResponse.validate(schema, json)
      assert validated["is_consistent"] == false
      assert validated["issues"] == ["Missing test coverage", "Incomplete docs"]
    end

    test "rejects missing is_consistent field" do
      schema = LLMResponse.consistency_check()

      json = ~s({"issues": ["problem"]})

      assert {:error, {:invalid_schema, _}} = LLMResponse.validate(schema, json)
    end
  end

  describe "JSON extraction" do
    test "extracts JSON from markdown code block" do
      schema = LLMResponse.expansion_data()

      text = """
      Here's the expansion:

      ```json
      {"priority": "medium", "summary": "Test item"}
      ```
      """

      assert {:ok, validated} = LLMResponse.validate(schema, text)
      assert validated["priority"] == "medium"
    end

    test "handles map input directly" do
      schema = LLMResponse.expansion_data()

      map = %{"priority" => "high", "category" => "bug"}

      assert {:ok, validated} = LLMResponse.validate(schema, map)
      assert validated["priority"] == "high"
      assert validated["category"] == "bug"
    end

    test "returns error for non-JSON text" do
      schema = LLMResponse.expansion_data()

      assert {:error, :invalid_json} = LLMResponse.validate(schema, "Just plain text")
    end
  end
end
