defmodule Arbor.SDLC.Schemas.LLMResponse do
  @moduledoc """
  Zoi schemas for LLM response validation in the SDLC system.

  Validates the structured JSON responses from LLM processors to ensure
  they contain the expected fields with valid values.
  """

  @valid_priorities ~w(critical high medium low someday)
  @valid_categories ~w(feature refactor bug infrastructure idea research documentation content)
  @valid_efforts ~w(small medium large ongoing)

  @doc """
  Schema for item expansion responses from the Expander processor.

  Expected JSON format:
  ```json
  {
    "priority": "high",
    "category": "feature",
    "effort": "medium",
    "summary": "...",
    "why_it_matters": "...",
    "acceptance_criteria": ["Criterion 1", "Criterion 2"],
    "definition_of_done": ["Tests pass", "Documentation updated"]
  }
  ```
  """
  def expansion_data do
    Zoi.map(
      %{
        "priority" => Zoi.enum(@valid_priorities) |> Zoi.optional(),
        "category" => Zoi.enum(@valid_categories) |> Zoi.optional(),
        "effort" => Zoi.enum(@valid_efforts) |> Zoi.optional(),
        "summary" => Zoi.string() |> Zoi.optional(),
        "why_it_matters" => Zoi.string() |> Zoi.optional(),
        "acceptance_criteria" => Zoi.list(Zoi.string()) |> Zoi.optional(),
        "definition_of_done" => Zoi.list(Zoi.string()) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for decision analysis responses.

  Used to analyze items that may need decision points before proceeding.

  Expected JSON format:
  ```json
  {
    "needs_decisions": true,
    "decision_points": [
      {"question": "...", "options": ["A", "B"], "impact": "high"}
    ]
  }
  ```
  """
  def decision_analysis do
    decision_point =
      Zoi.map(
        %{
          "question" => Zoi.string(),
          "options" => Zoi.list(Zoi.string()) |> Zoi.optional(),
          "impact" => Zoi.enum(["high", "medium", "low"]) |> Zoi.optional(),
          "recommendation" => Zoi.string() |> Zoi.optional()
        },
        coerce: true
      )

    Zoi.map(
      %{
        "needs_decisions" => Zoi.boolean(),
        "decision_points" => Zoi.list(decision_point) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for consistency check responses.

  Used by the ConsistencyChecker processor.

  Expected JSON format:
  ```json
  {
    "is_consistent": true,
    "issues": ["Issue 1", "Issue 2"],
    "suggestions": ["Fix 1", "Fix 2"]
  }
  ```
  """
  def consistency_check do
    Zoi.map(
      %{
        "is_consistent" => Zoi.boolean(),
        "issues" => Zoi.list(Zoi.string()) |> Zoi.optional(),
        "suggestions" => Zoi.list(Zoi.string()) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Parse and validate LLM response JSON against a schema.

  Returns `{:ok, validated}` for valid JSON, or error details.
  Attempts to extract JSON from text if direct parsing fails.
  """
  def validate(schema, json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} ->
        validate_map(schema, decoded)

      {:error, _} ->
        # Try to extract JSON from response
        case extract_json(json_string) do
          {:ok, decoded} ->
            validate_map(schema, decoded)

          :error ->
            {:error, :invalid_json}
        end
    end
  end

  def validate(schema, map) when is_map(map) do
    validate_map(schema, map)
  end

  defp validate_map(schema, map) do
    case Zoi.parse(schema, map) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error, {:invalid_schema, format_errors(errors)}}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> :error
        end

      nil ->
        :error
    end
  end

  defp format_errors(errors) do
    Enum.map(errors, fn error ->
      %{
        field: Enum.join(error.path, "."),
        message: error.message
      }
    end)
  end
end
