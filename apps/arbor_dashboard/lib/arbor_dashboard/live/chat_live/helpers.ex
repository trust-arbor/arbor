defmodule Arbor.Dashboard.Live.ChatLive.Helpers do
  @moduledoc """
  Pure helper functions for ChatLive formatting and styling.

  These functions do not touch the socket — they only transform data
  for display purposes.
  """

  # ── Message & Role Styling ─────────────────────────────────────────

  def message_style(role, sender_type, group_mode)

  # Group mode: neutral background for all messages, no margins
  def message_style(_role, _sender_type, true) do
    "background: rgba(74, 158, 255, 0.05); border-left: 3px solid rgba(74, 158, 255, 0.3);"
  end

  # Single-agent mode: use role-based styling
  def message_style(:user, _sender_type, false),
    do: "background: rgba(74, 158, 255, 0.1); margin-left: 2rem;"

  def message_style(:assistant, _sender_type, false),
    do: "background: rgba(74, 255, 158, 0.1); margin-right: 2rem;"

  def message_style(_, _, _), do: ""

  def role_label(:user), do: "You"
  def role_label(:assistant), do: "Claude"
  def role_label(_), do: "System"

  def sender_color(hue) when is_integer(hue) do
    "hsl(#{hue}, 70%, 60%)"
  end

  def sender_color(_), do: "#94a3b8"

  def participant_badge_style(participant) do
    base =
      "background: hsl(#{participant.color}, 60%, 20%); border: 1px solid hsl(#{participant.color}, 60%, 40%);"

    if participant.type == :agent do
      base <> " color: hsl(#{participant.color}, 70%, 70%);"
    else
      base <> " color: #94a3b8;"
    end
  end

  # ── Signal & Action Styling ────────────────────────────────────────

  def signal_icon(:agent), do: "🤖"
  def signal_icon(:memory), do: "📝"
  def signal_icon(:action), do: "⚡"
  def signal_icon(:security), do: "🔒"
  def signal_icon(:consensus), do: "🗳️"
  def signal_icon(:monitor), do: "📊"
  def signal_icon(_), do: "▶"

  def action_style(:success), do: "background: rgba(74, 255, 158, 0.1);"
  def action_style(:failure), do: "background: rgba(255, 74, 74, 0.1);"
  def action_style(:blocked), do: "background: rgba(255, 165, 0, 0.1);"
  def action_style(_), do: "background: rgba(128, 128, 128, 0.1);"

  def outcome_color(:success), do: :green
  def outcome_color(:failure), do: :red
  def outcome_color(:blocked), do: :yellow
  def outcome_color(_), do: :gray

  def action_input_summary(%{input: input}) when is_map(input) and map_size(input) > 0 do
    cond do
      Map.has_key?(input, "command") -> String.slice(to_string(input["command"]), 0, 60)
      Map.has_key?(input, "file_path") -> Path.basename(to_string(input["file_path"]))
      Map.has_key?(input, "pattern") -> to_string(input["pattern"])
      Map.has_key?(input, "query") -> String.slice(to_string(input["query"]), 0, 60)
      true -> input |> Map.keys() |> Enum.take(2) |> Enum.join(", ")
    end
  end

  def action_input_summary(_), do: ""

  # ── Tool Display Helpers ───────────────────────────────────────────

  def tool_badge_style(name) do
    cond do
      name in ~w(Read Glob Grep) ->
        "background: rgba(74, 158, 255, 0.2); color: #4a9eff;"

      name in ~w(Edit Write NotebookEdit) ->
        "background: rgba(255, 167, 38, 0.2); color: #ffa726;"

      name in ~w(Bash) ->
        "background: rgba(255, 74, 74, 0.2); color: #ff4a4a;"

      name in ~w(Task WebFetch WebSearch) ->
        "background: rgba(171, 71, 188, 0.2); color: #ab47bc;"

      true ->
        "background: rgba(255, 255, 255, 0.1); color: #aaa;"
    end
  end

  def format_tool_input(input) when is_map(input) do
    Jason.encode!(input, pretty: true)
  rescue
    _ -> inspect(input, pretty: true, limit: 500)
  end

  def format_tool_input(input), do: inspect(input, pretty: true, limit: 500)

  def format_tool_result({:ok, result}), do: format_tool_result(result)
  def format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"
  def format_tool_result(nil), do: "(handled by CLI)"

  def format_tool_result(result) when is_binary(result) do
    if String.length(result) > 2000 do
      String.slice(result, 0, 2000) <> "\n... (truncated)"
    else
      result
    end
  end

  def format_tool_result(result), do: inspect(result, pretty: true, limit: 500)

  # ── Goal Styling ───────────────────────────────────────────────────

  def goal_status_color(:active), do: :green
  def goal_status_color(:achieved), do: :blue
  def goal_status_color(:abandoned), do: :red
  def goal_status_color(_), do: :gray

  def goal_progress_color(p) when p >= 0.8, do: "#22c55e"
  def goal_progress_color(p) when p >= 0.5, do: "#4a9eff"
  def goal_progress_color(p) when p >= 0.2, do: "#eab308"
  def goal_progress_color(_), do: "#888"

  def goal_background_style(:active), do: "background: rgba(74, 255, 158, 0.05);"
  def goal_background_style(:achieved), do: "background: rgba(74, 158, 255, 0.05); opacity: 0.7;"
  def goal_background_style(:abandoned), do: "background: rgba(255, 74, 74, 0.05); opacity: 0.7;"
  def goal_background_style(:failed), do: "background: rgba(255, 74, 74, 0.05); opacity: 0.7;"
  def goal_background_style(_), do: "background: rgba(128, 128, 128, 0.05); opacity: 0.7;"

  def goal_text_style(:active), do: ""
  def goal_text_style(_), do: "opacity: 0.8;"

  # ── Time & Token Formatting ────────────────────────────────────────

  def format_time(%DateTime{} = dt), do: Arbor.Web.Helpers.format_relative_time(dt)
  def format_time(_), do: ""

  # ── Query Error Formatting ─────────────────────────────────────────

  def format_query_error(:string_too_long) do
    "Conversation too long for the model's context window. Try starting a new conversation."
  end

  def format_query_error(:empty_response) do
    "Model returned an empty response (may be rate-limited). Try again in a moment."
  end

  def format_query_error(reason) do
    "Query failed: #{inspect(reason)}"
  end
end
