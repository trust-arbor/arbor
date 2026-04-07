defmodule Arbor.Dashboard.Cores.EventsCore do
  @moduledoc """
  Pure display formatters for the events_live dashboard (Historian event stream).

  events_live displays a real-time event stream with category, time, and
  agent filters. This module owns the formatters and the agent-matching
  predicate used by the filter.

  ## Functions

  - `time_label/1` — time filter atom → display label
  - `format_event_subtitle/1` — event → "agent: X | stream: Y | data summary"
  - `format_data_summary/1` — event data map → truncated key:value summary
  - `format_json/1` — encode data as pretty JSON, fallback to inspect
  - `matches_agent?/2` — predicate for the agent_id filter
  - `default_stats/0` — fallback stats when Historian is unavailable
  - `show_event/1` — single event → display map
  """

  alias Arbor.Web.Helpers

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc "Format a single event for display."
  @spec show_event(map()) :: map()
  def show_event(event) when is_map(event) do
    %{
      id: Map.get(event, :id),
      type: Map.get(event, :type) || Map.get(event, :event_type),
      category: Map.get(event, :category),
      stream_id: Map.get(event, :stream_id),
      timestamp: Map.get(event, :timestamp),
      data: Map.get(event, :data, %{}),
      subtitle: format_event_subtitle(event),
      data_summary: format_data_summary(Map.get(event, :data, %{}))
    }
  end

  @doc "Format an 'agent: X | stream: Y | summary' line for an event."
  @spec format_event_subtitle(map()) :: String.t()
  def format_event_subtitle(event) do
    data = Map.get(event, :data, %{})
    parts = []

    agent = get_in(data, [:agent_id]) || get_in(data, ["agent_id"])
    parts = if agent, do: ["agent: #{agent}" | parts], else: parts

    stream_id = Map.get(event, :stream_id)

    stream_part =
      if stream_id && stream_id != "unknown",
        do: "stream: #{stream_id}",
        else: nil

    parts = if stream_part, do: [stream_part | parts], else: parts
    parts = [format_data_summary(data) | parts]
    Enum.join(parts, " | ")
  end

  @doc "Truncated 'key: value, key: value' summary of an event's data map."
  @spec format_data_summary(map() | term()) :: String.t()
  def format_data_summary(data) when data == %{}, do: "(empty)"

  def format_data_summary(data) when is_map(data) do
    data
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Helpers.truncate(60)
  end

  def format_data_summary(_), do: "(empty)"

  @doc "Encode a value as pretty JSON, falling back to inspect if encoding fails."
  @spec format_json(term()) :: String.t()
  def format_json(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true)
    end
  end

  # ===========================================================================
  # Filter helpers
  # ===========================================================================

  @doc "Display label for a time filter."
  @spec time_label(:all | :hour | :today | term()) :: String.t()
  def time_label(:all), do: "All time"
  def time_label(:hour), do: "Last hour"
  def time_label(:today), do: "Today"
  def time_label(other), do: to_string(other)

  @doc """
  Predicate for the agent_id filter — true if the event's data contains
  the agent_id (substring match).
  """
  @spec matches_agent?(map(), String.t()) :: boolean()
  def matches_agent?(event, agent_id) do
    data = Map.get(event, :data, %{})
    sig_agent = get_in(data, [:agent_id]) || get_in(data, ["agent_id"]) || ""
    String.contains?(to_string(sig_agent), agent_id)
  end

  # ===========================================================================
  # Stats
  # ===========================================================================

  @doc "Default stats map when Historian is unavailable."
  @spec default_stats() :: map()
  def default_stats, do: %{stream_count: 0, total_events: 0}
end
