defmodule Arbor.Dashboard.Cores.SignalsCore do
  @moduledoc """
  Pure display formatters and filter predicates for the signals_live dashboard.

  signals_live shows a real-time signal stream from the Arbor Signal Bus
  with category, time, and agent filters. This module owns the formatters
  and the filter predicates so the dashboard, future API, and tests share
  one shape.

  ## Functions

  - `time_label/1` — time filter atom → display label
  - `matches_time?/2` — predicate for the time filter
  - `matches_agent?/2` — predicate for the agent filter
  - `format_signal_data/1` — signal data → truncated key:value summary
  - `format_signal_json/1` — encode signal data as pretty JSON
  - `format_time/1` — DateTime → "HH:MM:SS"
  - `default_stats/0` — fallback stats when Signals is unavailable
  - `show_signal/1` — single signal → display map
  """

  alias Arbor.Web.Helpers

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc "Format a single signal for display."
  @spec show_signal(map()) :: map()
  def show_signal(signal) when is_map(signal) do
    %{
      id: Map.get(signal, :id),
      type: Map.get(signal, :type),
      category: Map.get(signal, :category),
      timestamp: Map.get(signal, :timestamp),
      time_label: format_time(Map.get(signal, :timestamp)),
      data: Map.get(signal, :data, %{}),
      data_summary: format_signal_data(Map.get(signal, :data, %{}))
    }
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

  @doc "Predicate for the time filter — returns true when the signal is within the window."
  @spec matches_time?(map(), :all | :hour | :today) :: boolean()
  def matches_time?(_signal, :all), do: true

  def matches_time?(signal, :hour) do
    DateTime.diff(DateTime.utc_now(), signal.timestamp, :second) < 3600
  end

  def matches_time?(signal, :today) do
    DateTime.diff(DateTime.utc_now(), signal.timestamp, :second) < 86_400
  end

  @doc """
  Predicate for the agent filter — true if the signal's data contains the
  agent_id (substring match). Returns true when no filter is set (nil).
  """
  @spec matches_agent?(map(), String.t() | nil) :: boolean()
  def matches_agent?(_signal, nil), do: true

  def matches_agent?(signal, agent_id) do
    data = Map.get(signal, :data, %{})
    sig_agent = get_in(data, [:agent_id]) || get_in(data, ["agent_id"]) || ""
    String.contains?(to_string(sig_agent), agent_id)
  end

  # ===========================================================================
  # Formatters
  # ===========================================================================

  @doc "Truncated 'key: value, key: value' summary of a signal's data map."
  @spec format_signal_data(map() | term()) :: String.t()
  def format_signal_data(data) when data == %{}, do: "(empty)"

  def format_signal_data(data) when is_map(data) do
    data
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Helpers.truncate(80)
  end

  def format_signal_data(_), do: "(empty)"

  @doc "Encode signal data as pretty JSON, falling back to inspect."
  @spec format_signal_json(term()) :: String.t()
  def format_signal_json(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true)
    end
  end

  @doc "Format a timestamp as HH:MM:SS for the signal stream display."
  @spec format_time(term()) :: String.t()
  def format_time(nil), do: "-"
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def format_time(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%H:%M:%S")
  def format_time(_), do: "-"

  # ===========================================================================
  # Stats
  # ===========================================================================

  @doc "Default stats map when Signals is unavailable."
  @spec default_stats() :: map()
  def default_stats, do: %{current_count: 0, active_subscriptions: 0, healthy: false}
end
