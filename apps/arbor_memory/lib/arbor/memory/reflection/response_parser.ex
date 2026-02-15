defmodule Arbor.Memory.Reflection.ResponseParser do
  @moduledoc """
  Parses LLM reflection responses from JSON format.

  Extracted from `Arbor.Memory.ReflectionProcessor` — handles JSON
  extraction, parsing, and normalization of reflection responses.
  """

  require Logger

  @doc """
  Parse a raw LLM response string into a structured reflection result.

  Extracts JSON from markdown code fences if present, then normalizes
  the parsed data into a consistent map structure. Returns a default
  empty response on parse failure.
  """
  def parse_reflection_response(response) do
    json_text = extract_json_text(response)

    case Jason.decode(json_text) do
      {:ok, parsed} ->
        {:ok, normalize_parsed_response(parsed)}

      {:error, _} ->
        Logger.warning("Failed to parse reflection JSON response",
          response_preview: String.slice(response, 0, 200)
        )

        {:ok, empty_parsed_response()}
    end
  end

  @doc """
  Returns an empty parsed response structure.
  """
  def empty_parsed_response do
    %{
      goal_updates: [],
      new_goals: [],
      insights: [],
      learnings: [],
      knowledge_nodes: [],
      knowledge_edges: [],
      self_insight_suggestions: [],
      relationships: [],
      thinking: nil
    }
  end

  defp extract_json_text(response) do
    case Regex.run(~r/```(?:json)?\s*(\{[\s\S]*?\})\s*```/, response) do
      [_, json] -> json
      nil -> String.trim(response)
    end
  end

  defp normalize_parsed_response(parsed) do
    %{
      goal_updates: parsed["goal_updates"] || [],
      new_goals: parsed["new_goals"] || [],
      insights: parsed["insights"] || [],
      learnings: parsed["learnings"] || [],
      knowledge_nodes: parsed["knowledge_nodes"] || [],
      knowledge_edges: parsed["knowledge_edges"] || [],
      self_insight_suggestions: parsed["self_insight_suggestions"] || [],
      relationships: parsed["relationships"] || [],
      thinking: parsed["thinking"]
    }
  end
end
