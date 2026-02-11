defmodule Arbor.Orchestrator.Dot.Duration do
  @moduledoc """
  Parses human-readable duration strings into milliseconds.

  Supported formats:
    - `"500ms"` → 500
    - `"30s"`  → 30_000
    - `"5m"`   → 300_000
    - `"1h"`   → 3_600_000
    - `"2d"`   → 172_800_000
    - `"15000"` → 15_000 (bare integer string)
    - integer passthrough
    - nil passthrough
  """

  @spec parse(nil) :: nil
  def parse(nil), do: nil

  @spec parse(integer()) :: integer()
  def parse(v) when is_integer(v), do: v

  @spec parse(String.t()) :: integer() | nil
  def parse(s) when is_binary(s) do
    cond do
      String.ends_with?(s, "ms") ->
        parse_numeric(String.trim_trailing(s, "ms"), 1)

      String.ends_with?(s, "s") ->
        parse_numeric(String.trim_trailing(s, "s"), 1_000)

      String.ends_with?(s, "m") ->
        parse_numeric(String.trim_trailing(s, "m"), 60_000)

      String.ends_with?(s, "h") ->
        parse_numeric(String.trim_trailing(s, "h"), 3_600_000)

      String.ends_with?(s, "d") ->
        parse_numeric(String.trim_trailing(s, "d"), 86_400_000)

      true ->
        parse_numeric(s, 1)
    end
  end

  def parse(_), do: nil

  defp parse_numeric(s, multiplier) do
    case Integer.parse(s) do
      {n, ""} -> n * multiplier
      _ -> nil
    end
  end
end
