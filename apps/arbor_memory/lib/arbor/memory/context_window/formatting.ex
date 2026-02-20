defmodule Arbor.Memory.ContextWindow.Formatting do
  @moduledoc false
  # Internal formatting and rendering helpers for ContextWindow.
  # Extracted to reduce parent module size. Not a public API.

  alias Arbor.Memory.ContextWindow

  # ============================================================================
  # Context Building (Public via parent delegation)
  # ============================================================================

  @doc false
  @spec build_context(ContextWindow.t()) :: [map()]
  def build_context(%{multi_layer: true} = window) do
    sections = []

    # Distant summary
    sections =
      if (window.distant_summary || "") != "" do
        [
          %{
            type: :distant_summary,
            content: "[DISTANT CONTEXT - weeks/months ago]\n#{window.distant_summary}"
          }
          | sections
        ]
      else
        sections
      end

    # Recent summary
    sections =
      if (window.recent_summary || "") != "" do
        time_label = format_summary_time(window.clarity_boundary)

        [
          %{
            type: :recent_summary,
            content: "[RECENT CONTEXT - #{time_label}]\n#{window.recent_summary}"
          }
          | sections
        ]
      else
        sections
      end

    # Clarity boundary marker
    sections = [
      %{type: :clarity_boundary, content: format_clarity_boundary(window.clarity_boundary)}
      | sections
    ]

    # Retrieved context
    sections =
      if window.retrieved_context != [] do
        retrieved_text = format_retrieved_context(window.retrieved_context)
        [%{type: :retrieved, content: retrieved_text} | sections]
      else
        sections
      end

    # Full detail (most recent)
    sections =
      if window.full_detail != [] do
        detail_text = format_full_detail(window.full_detail)
        [%{type: :full_detail, content: detail_text} | sections]
      else
        sections
      end

    Enum.reverse(sections)
  end

  def build_context(window) do
    [%{type: :entries, content: to_prompt_text(window)}]
  end

  @doc false
  @spec to_prompt_text(ContextWindow.t()) :: String.t()
  def to_prompt_text(%{multi_layer: true} = window) do
    window
    |> build_context()
    |> Enum.map_join("\n\n", & &1.content)
  end

  def to_prompt_text(window) do
    Enum.map_join(window.entries, "\n\n", &format_entry/1)
  end

  @doc false
  @spec to_system_prompt(ContextWindow.t()) :: String.t()
  def to_system_prompt(%{multi_layer: true} = window) do
    sections = []

    sections =
      if (window.distant_summary || "") != "" do
        ["[DISTANT CONTEXT - weeks/months ago]\n#{window.distant_summary}" | sections]
      else
        sections
      end

    sections =
      if (window.recent_summary || "") != "" do
        time_label = format_summary_time(window.clarity_boundary)
        ["[RECENT CONTEXT - #{time_label}]\n#{window.recent_summary}" | sections]
      else
        sections
      end

    sections
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  def to_system_prompt(_window), do: ""

  @doc false
  @spec to_user_context(ContextWindow.t()) :: String.t()
  def to_user_context(%{multi_layer: true} = window) do
    sections = []

    boundary_text = format_clarity_boundary(window.clarity_boundary)
    sections = [boundary_text | sections]

    sections =
      if window.retrieved_context != [] do
        [format_retrieved_context(window.retrieved_context) | sections]
      else
        sections
      end

    sections =
      if window.full_detail != [] do
        ["[CONVERSATION]\n#{format_full_detail(window.full_detail)}" | sections]
      else
        sections
      end

    sections
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  def to_user_context(_window), do: ""

  # ============================================================================
  # Legacy Entry Formatting
  # ============================================================================

  @doc false
  def format_entry({:summary, content, _timestamp}) do
    "[Previous Context Summary]\n#{content}"
  end

  def format_entry({:message, content, %DateTime{} = ts}) do
    "[#{Calendar.strftime(ts, "%H:%M")}] #{content}"
  end

  def format_entry({:message, content, _timestamp}) do
    content
  end

  # ============================================================================
  # Multi-Layer Formatting Helpers
  # ============================================================================

  @doc false
  def format_messages_for_summary(messages) do
    Enum.map_join(messages, "\n", &format_single_message_for_summary/1)
  end

  @doc false
  def format_messages_as_bullets(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      role = msg[:role] || msg["role"] || "unknown"
      content = msg[:content] || msg["content"] || ""
      truncated = String.slice(content, 0, 100)

      case role do
        r when r in [:user, "user"] -> "- User: #{truncated}"
        r when r in [:assistant, "assistant"] -> "- Agent: #{truncated}"
        _ -> "- #{role}: #{truncated}"
      end
    end)
  end

  @doc false
  def messages_from_text(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line -> %{role: :unknown, content: line} end)
  end

  @doc false
  def format_action_result(%{action: action, outcome: outcome, result: result}) do
    result_text =
      cond do
        is_binary(result) -> result
        is_list(result) -> Enum.join(result, "\n")
        is_map(result) -> json_encode_safe(result)
        true -> inspect(result, pretty: true)
      end

    truncated =
      if String.length(result_text) > 8000 do
        String.slice(result_text, 0, 8000) <>
          "\n... (truncated, #{String.length(result_text)} bytes total)"
      else
        result_text
      end

    "**#{action}** (#{outcome}):\n```\n#{truncated}\n```"
  end

  def format_action_result(result) do
    inspect(result, pretty: true)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp format_single_message_for_summary(msg) do
    role = msg[:role] || msg["role"] || "unknown"
    content = msg[:content] || msg["content"] || ""
    speaker = msg[:speaker] || msg["speaker"]
    time_str = format_message_time(msg[:timestamp])
    speaker_label = resolve_speaker_label(role, speaker)

    "[#{time_str}] #{speaker_label}: #{truncate_content(content, 500)}"
  end

  defp format_message_time(nil), do: ""
  defp format_message_time(timestamp), do: Calendar.strftime(timestamp, "%Y-%m-%d %H:%M")

  defp resolve_speaker_label(role, speaker) when role in [:user, "user"], do: speaker || "Human"
  defp resolve_speaker_label(role, _speaker), do: to_string(role)

  defp truncate_content(content, max_length) when byte_size(content) > max_length do
    String.slice(content, 0, max_length) <> "..."
  end

  defp truncate_content(content, _), do: content

  defp format_clarity_boundary(nil) do
    "[CLARITY BOUNDARY: Memory begins here. Earlier context is summarized above.]"
  end

  defp format_clarity_boundary(%DateTime{} = dt) do
    time_ago = DateTime.diff(DateTime.utc_now(), dt, :minute)

    period =
      cond do
        time_ago < 60 -> "#{time_ago} minutes ago"
        time_ago < 1440 -> "#{div(time_ago, 60)} hours ago"
        true -> "#{div(time_ago, 1440)} days ago"
      end

    "[CLARITY BOUNDARY: Full detail begins #{period}. Earlier memories are summarized and can be searched if needed.]"
  end

  defp format_summary_time(nil), do: "earlier"

  defp format_summary_time(%DateTime{} = boundary) do
    time_ago = DateTime.diff(DateTime.utc_now(), boundary, :minute)

    cond do
      time_ago < 60 -> "#{time_ago} minutes ago"
      time_ago < 1440 -> "#{div(time_ago, 60)} hours ago"
      true -> "#{div(time_ago, 1440)} days ago"
    end
  end

  defp format_retrieved_context(contexts) do
    header = "[RETRIEVED CONTEXT - surfaced from memory search]\n"

    content =
      Enum.map_join(contexts, "\n", fn ctx ->
        "- #{ctx[:content] || ctx["content"] || inspect(ctx)}"
      end)

    header <> content
  end

  defp format_full_detail(messages) do
    messages
    |> Enum.reverse()
    |> Enum.map_join("\n\n", &format_detail_message/1)
  end

  defp format_detail_message(msg) do
    role = msg[:role] || msg["role"] || "unknown"
    content = msg[:content] || msg["content"] || ""
    speaker = msg[:speaker] || msg["speaker"]
    label = detail_role_label(role, speaker)

    "[#{label}]\n#{content}"
  end

  defp detail_role_label(role, speaker) when role in [:user, "user"], do: speaker || "Human"
  defp detail_role_label(role, _speaker) when role in [:assistant, "assistant"], do: "Assistant"
  defp detail_role_label(role, _speaker) when role in [:system, "system"], do: "System"
  defp detail_role_label(role, _speaker), do: role

  defp json_encode_safe(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data, pretty: true)
    end
  end
end
