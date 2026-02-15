defmodule Arbor.Web.Helpers do
  @moduledoc """
  Pure helper functions for use in Arbor dashboard templates.

  Provides formatting, truncation, and CSS class mapping utilities.
  """

  @doc """
  Formats a datetime as a relative time string (e.g., "2 minutes ago", "just now").

  Accepts `DateTime`, `NaiveDateTime`, or `nil`.

  ## Examples

      iex> now = DateTime.utc_now()
      iex> Arbor.Web.Helpers.format_relative_time(now)
      "just now"

      iex> Arbor.Web.Helpers.format_relative_time(nil)
      "never"
  """
  @spec format_relative_time(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_relative_time(nil), do: "never"

  def format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)
    relative_from_seconds(diff)
  end

  def format_relative_time(%NaiveDateTime{} = ndt) do
    diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), ndt, :second)
    relative_from_seconds(diff)
  end

  defp relative_from_seconds(diff) when diff < 5, do: "just now"
  defp relative_from_seconds(diff) when diff < 60, do: "#{diff} seconds ago"
  defp relative_from_seconds(diff) when diff < 120, do: "1 minute ago"
  defp relative_from_seconds(diff) when diff < 3600, do: "#{div(diff, 60)} minutes ago"
  defp relative_from_seconds(diff) when diff < 7200, do: "1 hour ago"
  defp relative_from_seconds(diff) when diff < 86_400, do: "#{div(diff, 3600)} hours ago"
  defp relative_from_seconds(diff) when diff < 172_800, do: "1 day ago"
  defp relative_from_seconds(diff), do: "#{div(diff, 86_400)} days ago"

  @doc """
  Formats a datetime as a timestamp string (e.g., "2026-01-27 14:30:05").

  ## Examples

      iex> dt = ~U[2026-01-27 14:30:05Z]
      iex> Arbor.Web.Helpers.format_timestamp(dt)
      "2026-01-27 14:30:05"

      iex> Arbor.Web.Helpers.format_timestamp(nil)
      "-"
  """
  @spec format_timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_timestamp(nil), do: "-"

  def format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  def format_timestamp(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  @doc """
  Truncates a string to the given length, appending "..." if truncated.

  ## Examples

      iex> Arbor.Web.Helpers.truncate("Hello, world!", 5)
      "He..."

      iex> Arbor.Web.Helpers.truncate("Hi", 10)
      "Hi"

      iex> Arbor.Web.Helpers.truncate(nil, 10)
      ""
  """
  @spec truncate(String.t() | nil, pos_integer()) :: String.t()
  def truncate(nil, _length), do: ""
  def truncate(string, length) when is_binary(string) and is_integer(length) and length > 3 do
    if String.length(string) <= length do
      string
    else
      String.slice(string, 0, length - 3) <> "..."
    end
  end

  def truncate(string, length) when is_binary(string) and is_integer(length) do
    String.slice(string, 0, length)
  end

  @doc """
  Maps a status atom to a CSS class string.

  ## Examples

      iex> Arbor.Web.Helpers.status_class(:running)
      "aw-status-running"

      iex> Arbor.Web.Helpers.status_class(:failed)
      "aw-status-failed"
  """
  @spec status_class(atom()) :: String.t()
  def status_class(status) when is_atom(status) do
    "aw-status-#{status}"
  end

  @doc """
  Maps a category atom to a CSS class string.

  ## Examples

      iex> Arbor.Web.Helpers.category_class(:consensus)
      "aw-cat-consensus"
  """
  @spec category_class(atom()) :: String.t()
  def category_class(category) when is_atom(category) do
    "aw-cat-#{category}"
  end

  @doc """
  Safely calls a zero-arity function, returning nil on any error or exit.

  ## Examples

      iex> Arbor.Web.Helpers.safe_call(fn -> 42 end)
      42

      iex> Arbor.Web.Helpers.safe_call(fn -> raise "boom" end)
      nil
  """
  def safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  Unwraps `{:ok, list}` tuples, returning the list or `[]` on error/nil.

  ## Examples

      iex> Arbor.Web.Helpers.unwrap_list({:ok, [1, 2]})
      [1, 2]

      iex> Arbor.Web.Helpers.unwrap_list({:error, :not_found})
      []

      iex> Arbor.Web.Helpers.unwrap_list([3, 4])
      [3, 4]
  """
  def unwrap_list({:ok, val}) when is_list(val), do: val
  def unwrap_list({:error, _}), do: []
  def unwrap_list(val) when is_list(val), do: val
  def unwrap_list(_), do: []

  @doc """
  Unwraps `{:ok, map}` tuples, returning the map or nil on error/nil.

  ## Examples

      iex> Arbor.Web.Helpers.unwrap_map({:ok, %{a: 1}})
      %{a: 1}

      iex> Arbor.Web.Helpers.unwrap_map({:error, :not_found})
      nil

      iex> Arbor.Web.Helpers.unwrap_map(%{b: 2})
      %{b: 2}
  """
  def unwrap_map({:ok, val}) when is_map(val), do: val
  def unwrap_map({:error, _}), do: nil
  def unwrap_map(nil), do: nil
  def unwrap_map(val) when is_map(val), do: val
  def unwrap_map(_), do: nil

  @doc """
  Checks if a LiveView stream is empty.

  ## Examples

      iex> Arbor.Web.Helpers.stream_empty?(%Phoenix.LiveView.LiveStream{inserts: []})
      true
  """
  def stream_empty?(%Phoenix.LiveView.LiveStream{inserts: []}), do: true
  def stream_empty?(_), do: false

  @doc """
  Formats a token count as a human-readable string (e.g., "1.2k", "3.4M").

  ## Examples

      iex> Arbor.Web.Helpers.format_token_count(500)
      "500"

      iex> Arbor.Web.Helpers.format_token_count(1500)
      "1.5k"

      iex> Arbor.Web.Helpers.format_token_count(2_500_000)
      "2.5M"
  """
  def format_token_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_token_count(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  def format_token_count(n), do: to_string(n)

  @doc """
  Formats a duration in milliseconds as a human-readable string.

  ## Examples

      iex> Arbor.Web.Helpers.format_duration(1500)
      "1.5s"

      iex> Arbor.Web.Helpers.format_duration(450)
      "450ms"
  """
  def format_duration(ms) when is_number(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  def format_duration(ms) when is_number(ms), do: "#{ms}ms"
  def format_duration(_), do: ""

  @doc """
  Checks if a signal's metadata or data contains a matching agent_id.
  """
  def signal_matches_agent?(signal, agent_id) do
    matches_in?(signal.metadata, agent_id) or matches_in?(signal.data, agent_id)
  end

  @doc """
  Checks if a map contains an agent_id or id field matching the given value.
  Handles both atom and string keys.
  """
  def matches_in?(%{agent_id: id}, agent_id) when id == agent_id, do: true
  def matches_in?(%{"agent_id" => id}, agent_id) when id == agent_id, do: true
  def matches_in?(%{id: id}, agent_id) when id == agent_id, do: true
  def matches_in?(%{"id" => id}, agent_id) when id == agent_id, do: true
  def matches_in?(_, _), do: false

  @doc """
  Pluralizes a word based on count.

  ## Examples

      iex> Arbor.Web.Helpers.pluralize(1, "event")
      "1 event"

      iex> Arbor.Web.Helpers.pluralize(3, "event")
      "3 events"

      iex> Arbor.Web.Helpers.pluralize(0, "event")
      "0 events"

      iex> Arbor.Web.Helpers.pluralize(2, "status", "statuses")
      "2 statuses"
  """
  @spec pluralize(integer(), String.t(), String.t() | nil) :: String.t()
  def pluralize(count, singular, plural \\ nil)
  def pluralize(1, singular, _plural), do: "1 #{singular}"
  def pluralize(count, singular, nil), do: "#{count} #{singular}s"
  def pluralize(count, _singular, plural), do: "#{count} #{plural}"
end
