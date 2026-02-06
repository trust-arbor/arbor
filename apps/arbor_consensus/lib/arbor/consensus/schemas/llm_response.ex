defmodule Arbor.Consensus.Schemas.LLMResponse do
  @moduledoc """
  Zoi schemas for LLM response validation in the consensus system.

  Validates the structured JSON responses from LLM evaluators to ensure
  they contain the expected fields with valid values.
  """

  @doc """
  Schema for vote responses from LLM evaluators.

  Expected JSON format:
  ```json
  {
    "vote": "approve" | "reject",
    "reasoning": "your analysis",
    "concerns": ["list", "of", "concerns"],
    "suggestions": ["list", "of", "suggestions"],
    "confidence": 0.8
  }
  ```
  """
  def vote_response do
    Zoi.map(
      %{
        "vote" => Zoi.enum(["approve", "reject", "abstain"]),
        "reasoning" => Zoi.string(),
        "concerns" => Zoi.list(Zoi.string()) |> Zoi.optional(),
        "suggestions" => Zoi.list(Zoi.string()) |> Zoi.optional(),
        "confidence" => Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for advisory responses from LLM perspectives.

  Expected JSON format:
  ```json
  {
    "analysis": "your detailed analysis from this perspective",
    "considerations": ["key points to think about"],
    "alternatives": ["other approaches worth considering"],
    "recommendation": "what this perspective suggests"
  }
  ```
  """
  def advisory_response do
    Zoi.map(
      %{
        "analysis" => Zoi.string(),
        "considerations" => Zoi.list(Zoi.string()) |> Zoi.optional(),
        "alternatives" => Zoi.list(Zoi.string()) |> Zoi.optional(),
        "recommendation" => Zoi.string() |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Schema for topic classification responses.

  Used by TopicMatcher for LLM-based classification fallback.

  Expected JSON format:
  ```json
  {
    "topic": "security",
    "confidence": 0.9
  }
  ```
  """
  def topic_classification do
    Zoi.map(
      %{
        "topic" => Zoi.string() |> Zoi.min(1),
        "confidence" => Zoi.number() |> Zoi.min(0.0) |> Zoi.max(1.0) |> Zoi.optional()
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
