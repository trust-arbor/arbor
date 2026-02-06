defmodule Arbor.Agent.TimingContext do
  @moduledoc """
  Computes and formats temporal context for agent prompts.

  Tells the agent how long since the user messaged and whether
  a response is pending. Affects conversational tone.
  """

  @doc """
  Compute timing metrics from agent state.

  Returns a map with:
  - `:seconds_since_user_message` - seconds since last user message (nil if never)
  - `:seconds_since_last_output` - seconds since last agent output (nil if never)
  - `:responded_to_last_user_message` - whether the last user message was responded to
  - `:user_waiting` - whether the user appears to be waiting for a response
  """
  @spec compute(map()) :: map()
  def compute(state) do
    now = DateTime.utc_now()

    %{
      seconds_since_user_message: diff_seconds(state[:last_user_message_at], now),
      seconds_since_last_output: diff_seconds(state[:last_assistant_output_at], now),
      responded_to_last_user_message: state[:responded_to_last_user_message] != false,
      user_waiting: user_waiting?(state, now)
    }
  end

  @doc """
  Build markdown timing context for prompt injection.
  """
  @spec to_markdown(map()) :: String.t()
  def to_markdown(timing) do
    format = config(:timing_format, :human)

    lines =
      [
        "## Conversational Timing",
        "- Last user message: #{format_duration(timing.seconds_since_user_message, format)}",
        "- Your last output: #{format_duration(timing.seconds_since_last_output, format)}",
        "- Responded to last message: #{if timing.responded_to_last_user_message, do: "yes", else: "no"}"
      ] ++
        if timing.user_waiting do
          ["- User may be waiting for a response"]
        else
          []
        end

    Enum.join(lines, "\n") <> "\n"
  end

  @doc """
  Update state when a user message arrives.
  """
  @spec on_user_message(map()) :: map()
  def on_user_message(state) do
    Map.merge(state, %{
      last_user_message_at: DateTime.utc_now(),
      responded_to_last_user_message: false
    })
  end

  @doc """
  Update state when the agent produces output.
  """
  @spec on_agent_output(map()) :: map()
  def on_agent_output(state) do
    Map.merge(state, %{
      last_assistant_output_at: DateTime.utc_now(),
      responded_to_last_user_message: true
    })
  end

  # Private helpers

  defp diff_seconds(nil, _now), do: nil
  defp diff_seconds(ts, now), do: DateTime.diff(now, ts, :second)

  defp user_waiting?(state, now) do
    threshold = config(:response_urgency_threshold_ms, 120_000)

    state[:responded_to_last_user_message] == false and
      state[:last_user_message_at] != nil and
      DateTime.diff(now, state[:last_user_message_at], :millisecond) > threshold
  end

  defp format_duration(nil, _format), do: "never"
  defp format_duration(seconds, :human), do: humanize_duration(seconds)
  defp format_duration(seconds, :seconds), do: "#{seconds}s ago"

  defp format_duration(seconds, :iso8601) do
    DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.to_iso8601()
  end

  defp humanize_duration(s) when s < 60, do: "#{s} seconds ago"
  defp humanize_duration(s) when s < 3600, do: "#{div(s, 60)} minutes ago"
  defp humanize_duration(s), do: "#{div(s, 3600)} hours ago"

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end
end
