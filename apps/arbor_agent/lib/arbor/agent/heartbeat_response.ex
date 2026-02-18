defmodule Arbor.Agent.HeartbeatResponse do
  @moduledoc """
  Parses structured LLM responses from heartbeat think cycles.

  Expects JSON with:
  - `thinking` — internal reasoning string
  - `actions` — list of `%{type, params, reasoning}` maps
  - `memory_notes` — list of observation strings
  - `goal_updates` — list of `%{goal_id, progress, note}` maps
  """

  require Logger

  @type parsed :: %{
          thinking: String.t(),
          actions: [map()],
          memory_notes: [String.t()],
          concerns: [String.t()],
          curiosity: [String.t()],
          goal_updates: [map()],
          new_goals: [map()],
          proposal_decisions: [map()],
          decompositions: [map()],
          identity_insights: [map()]
        }

  @doc """
  Parse an LLM response string into structured heartbeat data.

  If the response is valid JSON with the expected keys, returns a structured
  map. Otherwise, treats the entire text as thinking with no actions.
  """
  @spec parse(String.t() | nil) :: parsed()
  def parse(nil), do: empty_response()
  def parse(""), do: empty_response()

  def parse(text) when is_binary(text) do
    # Try to extract JSON from the response (may be wrapped in markdown code blocks)
    json_text = extract_json(text)

    case Jason.decode(json_text) do
      {:ok, data} when is_map(data) ->
        %{
          thinking: get_string(data, "thinking", text),
          actions: parse_actions(data),
          memory_notes: parse_memory_notes(data),
          concerns: parse_string_list(data, "concerns"),
          curiosity: parse_string_list(data, "curiosity"),
          goal_updates: parse_goal_updates(data),
          new_goals: parse_new_goals(data),
          proposal_decisions: parse_proposal_decisions(data),
          decompositions: parse_decompositions(data),
          identity_insights: parse_identity_insights(data)
        }

      _ ->
        # Not valid JSON — treat as thinking-only response
        Logger.debug("Heartbeat response not JSON, treating as thinking")

        %{
          thinking: text,
          actions: [],
          memory_notes: [],
          concerns: [],
          curiosity: [],
          goal_updates: [],
          new_goals: [],
          proposal_decisions: [],
          decompositions: [],
          identity_insights: []
        }
    end
  end

  @doc """
  Returns an empty response (no actions, no notes).
  """
  @spec empty_response() :: parsed()
  def empty_response do
    %{
      thinking: "",
      actions: [],
      memory_notes: [],
      concerns: [],
      curiosity: [],
      goal_updates: [],
      new_goals: [],
      proposal_decisions: [],
      decompositions: [],
      identity_insights: []
    }
  end

  # -- Private --

  defp extract_json(text) do
    # Try to find JSON in code blocks first
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?```/s, text) do
      [_, json] -> String.trim(json)
      nil -> String.trim(text)
    end
  end

  defp get_string(data, key, default) do
    case Map.get(data, key) do
      s when is_binary(s) -> s
      _ -> default
    end
  end

  defp parse_actions(data) do
    case Map.get(data, "actions") do
      actions when is_list(actions) ->
        Enum.map(actions, fn
          action when is_map(action) ->
            type = action["type"] || action["action"]

            %{
              type: safe_to_atom(type),
              params: Map.get(action, "params", %{}),
              reasoning: Map.get(action, "reasoning", "")
            }

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_memory_notes(data), do: parse_string_list(data, "memory_notes")

  defp parse_string_list(data, key) do
    case Map.get(data, key) do
      items when is_list(items) ->
        items
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp parse_goal_updates(data) do
    case Map.get(data, "goal_updates") do
      updates when is_list(updates) ->
        Enum.map(updates, fn
          update when is_map(update) ->
            %{
              goal_id: update["goal_id"],
              progress: parse_progress(update["progress"]),
              note: update["note"] || ""
            }

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_progress(p) when is_float(p) and p >= 0.0 and p <= 1.0, do: p
  defp parse_progress(p) when is_integer(p) and p >= 0 and p <= 100, do: p / 100.0
  defp parse_progress(_), do: nil

  defp parse_new_goals(data) do
    case Map.get(data, "new_goals") do
      goals when is_list(goals) ->
        goals
        |> Enum.map(fn
          goal when is_map(goal) ->
            desc = goal["description"]

            if desc && is_binary(desc) && String.trim(desc) != "" do
              %{
                description: desc,
                priority: parse_priority(goal["priority"]),
                success_criteria: goal["success_criteria"]
              }
            else
              nil
            end

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(3)

      _ ->
        []
    end
  end

  defp parse_priority("high"), do: :high
  defp parse_priority("medium"), do: :medium
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: :medium

  defp parse_proposal_decisions(data) do
    case Map.get(data, "proposal_decisions") do
      decisions when is_list(decisions) ->
        decisions
        |> Enum.map(&parse_single_decision/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_single_decision(%{"decision" => decision} = d)
       when decision in ["accept", "reject", "defer"] do
    %{
      proposal_id: d["proposal_id"],
      decision: String.to_existing_atom(decision),
      reason: d["reason"] || ""
    }
  end

  defp parse_single_decision(_), do: nil

  # Known action types that the LLM may return
  @known_action_types ~w(
    think reflect wait introspect consolidate
    shell_execute file_read file_write
    ai_analyze proposal_submit code_hot_load
    memory_consolidate memory_index
    run_consolidation check_health
  )a

  @doc false
  def known_action_types, do: @known_action_types

  @max_intentions_per_decomposition 3

  defp parse_decompositions(data) do
    case Map.get(data, "decompositions") do
      decomps when is_list(decomps) ->
        decomps
        |> Enum.map(&parse_single_decomposition/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_single_decomposition(%{"goal_id" => goal_id, "intentions" => intentions} = decomp)
       when is_binary(goal_id) and is_list(intentions) do
    parsed_intentions =
      intentions
      |> Enum.map(&parse_decomposition_intention/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_intentions_per_decomposition)

    if parsed_intentions == [] do
      nil
    else
      %{
        goal_id: goal_id,
        intentions: parsed_intentions,
        contingency: Map.get(decomp, "contingency")
      }
    end
  end

  defp parse_single_decomposition(_), do: nil

  defp parse_decomposition_intention(%{"action" => action} = intent)
       when is_binary(action) do
    if action in Enum.map(known_action_types(), &Atom.to_string/1) do
      %{
        action: String.to_existing_atom(action),
        params: Map.get(intent, "params", %{}),
        reasoning: Map.get(intent, "reasoning", ""),
        preconditions: Map.get(intent, "preconditions"),
        success_criteria: Map.get(intent, "success_criteria")
      }
    else
      Logger.warning("Unknown action in decomposition: #{action}, skipping")
      nil
    end
  end

  defp parse_decomposition_intention(_), do: nil

  @allowed_insight_categories ~w(capability skill trait personality value)

  defp parse_identity_insights(data) do
    case Map.get(data, "identity_insights") do
      insights when is_list(insights) ->
        insights
        |> Enum.map(&parse_single_insight/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(5)

      _ ->
        []
    end
  end

  defp parse_single_insight(%{"category" => cat, "content" => content} = insight)
       when is_binary(cat) and is_binary(content) and content != "" do
    if cat in @allowed_insight_categories do
      %{
        category: String.to_existing_atom(cat),
        content: content,
        confidence: parse_confidence(insight["confidence"])
      }
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  defp parse_single_insight(_), do: nil

  defp parse_confidence(c) when is_float(c) and c >= 0.0 and c <= 1.0, do: c
  defp parse_confidence(c) when is_integer(c) and c >= 0 and c <= 100, do: c / 100.0
  defp parse_confidence(_), do: 0.5

  # Convert string to atom safely — only allows known action types
  defp safe_to_atom(nil), do: :unknown
  defp safe_to_atom(s) when is_atom(s), do: s

  defp safe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError ->
      # Only convert to atom if it's a known action type
      if s in Enum.map(@known_action_types, &Atom.to_string/1) do
        String.to_existing_atom(s)
      else
        Logger.warning("Unknown action type from LLM: #{s}, using :unknown")
        :unknown
      end
  end
end
