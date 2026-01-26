defmodule Arbor.Common.Time do
  @moduledoc """
  Time formatting utilities for human-readable display.

  Provides consistent time formatting across Arbor applications:
  - Relative time ("just now", "5m ago", "2h ago", "3d ago")
  - Full datetime ("2026-01-26 17:00:00")
  - Time only ("17:00:00")
  - Event time (relative for recent, calendar for older)

  ## Examples

      iex> Arbor.Common.Time.relative(DateTime.utc_now())
      "just now"

      iex> Arbor.Common.Time.relative(DateTime.add(DateTime.utc_now(), -3600, :second))
      "1h ago"

      iex> Arbor.Common.Time.datetime(~U[2026-01-26 17:00:00Z])
      "2026-01-26 17:00:00"
  """

  @doc """
  Format a datetime as relative time ("just now", "5m ago", "2h ago", "3d ago").

  ## Examples

      iex> Arbor.Common.Time.relative(DateTime.utc_now())
      "just now"

      iex> Arbor.Common.Time.relative(nil)
      ""
  """
  @spec relative(DateTime.t() | nil) :: String.t()
  def relative(nil), do: ""

  def relative(%DateTime{} = datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 0 -> "in the future"
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  @doc """
  Format a datetime as full datetime string ("YYYY-MM-DD HH:MM:SS").

  ## Examples

      iex> Arbor.Common.Time.datetime(~U[2026-01-26 17:00:00Z])
      "2026-01-26 17:00:00"

      iex> Arbor.Common.Time.datetime(nil)
      "-"
  """
  @spec datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  def datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  def datetime(nil), do: "-"
  def datetime(_), do: "-"

  @doc """
  Format a datetime as time only ("HH:MM:SS").

  ## Examples

      iex> Arbor.Common.Time.time(~U[2026-01-26 17:30:45Z])
      "17:30:45"

      iex> Arbor.Common.Time.time(nil)
      ""
  """
  @spec time(DateTime.t() | nil) :: String.t()
  def time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  def time(_), do: ""

  @doc """
  Format a datetime as relative for recent times, calendar for older.

  Uses relative format for times within the last 24 hours,
  then switches to "MM/DD HH:MM" format for older timestamps.

  ## Examples

      iex> Arbor.Common.Time.event(DateTime.utc_now())
      "just now"

      iex> # For times > 24h ago, returns "01/25 14:30" format
  """
  @spec event(DateTime.t() | nil) :: String.t()
  def event(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 0 -> Calendar.strftime(dt, "%m/%d %H:%M")
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> Calendar.strftime(dt, "%m/%d %H:%M")
    end
  end

  def event(_), do: ""

  @doc """
  Format milliseconds as human-readable duration.

  ## Examples

      iex> Arbor.Common.Time.duration_ms(1500)
      "1.5s"

      iex> Arbor.Common.Time.duration_ms(65000)
      "1m 5s"

      iex> Arbor.Common.Time.duration_ms(3665000)
      "1h 1m"
  """
  @spec duration_ms(non_neg_integer()) :: String.t()
  def duration_ms(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 ->
        "#{Float.round(ms / 1000, 1)}s"

      seconds < 3600 ->
        minutes = div(seconds, 60)
        remaining_seconds = rem(seconds, 60)
        if remaining_seconds > 0, do: "#{minutes}m #{remaining_seconds}s", else: "#{minutes}m"

      true ->
        hours = div(seconds, 3600)
        remaining_minutes = div(rem(seconds, 3600), 60)
        if remaining_minutes > 0, do: "#{hours}h #{remaining_minutes}m", else: "#{hours}h"
    end
  end

  def duration_ms(_), do: "-"
end
