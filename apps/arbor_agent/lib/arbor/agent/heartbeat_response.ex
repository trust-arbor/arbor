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
          goal_updates: [map()],
          proposal_decisions: [map()]
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
          goal_updates: parse_goal_updates(data),
          proposal_decisions: parse_proposal_decisions(data)
        }

      _ ->
        # Not valid JSON — treat as thinking-only response
        Logger.debug("Heartbeat response not JSON, treating as thinking")

        %{
          thinking: text,
          actions: [],
          memory_notes: [],
          goal_updates: [],
          proposal_decisions: []
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
      goal_updates: [],
      proposal_decisions: []
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

  defp parse_memory_notes(data) do
    case Map.get(data, "memory_notes") do
      notes when is_list(notes) ->
        notes
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

  defp parse_proposal_decisions(data) do
    case Map.get(data, "proposal_decisions") do
      decisions when is_list(decisions) ->
        Enum.map(decisions, fn
          d when is_map(d) ->
            decision = d["decision"] || ""

            if decision in ["accept", "reject", "defer"] do
              %{
                proposal_id: d["proposal_id"],
                decision: String.to_existing_atom(decision),
                reason: d["reason"] || ""
              }
            else
              nil
            end

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  # Known action types that the LLM may return
  @known_action_types ~w(
    think reflect wait introspect consolidate
    shell_execute file_read file_write
    ai_analyze proposal_submit code_hot_load
    memory_consolidate memory_index
    run_consolidation check_health
  )a

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
