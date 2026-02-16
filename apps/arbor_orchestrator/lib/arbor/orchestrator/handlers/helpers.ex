defmodule Arbor.Orchestrator.Handlers.Helpers do
  @moduledoc """
  Shared utilities for orchestrator handler modules.

  Contains small, commonly-needed functions that were previously duplicated
  across 14+ handler modules. Import this module in handlers that need
  `parse_int/2`, `parse_csv/1`, or `maybe_add/3`.

  ## Usage

      import Arbor.Orchestrator.Handlers.Helpers
  """

  @doc """
  Parse a string or integer value to an integer with a default fallback.

  ## Examples

      iex> Arbor.Orchestrator.Handlers.Helpers.parse_int("42", 0)
      42

      iex> Arbor.Orchestrator.Handlers.Helpers.parse_int(nil, 10)
      10

      iex> Arbor.Orchestrator.Handlers.Helpers.parse_int("not_a_number", 5)
      5
  """
  @spec parse_int(binary() | integer() | nil, integer()) :: integer()
  def parse_int(nil, default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(val, _default) when is_integer(val), do: val
  def parse_int(_, default), do: default

  @doc """
  Split a comma-separated string into a trimmed list, rejecting blanks.

  ## Examples

      iex> Arbor.Orchestrator.Handlers.Helpers.parse_csv("a, b, c")
      ["a", "b", "c"]

      iex> Arbor.Orchestrator.Handlers.Helpers.parse_csv(nil)
      []

      iex> Arbor.Orchestrator.Handlers.Helpers.parse_csv("")
      []
  """
  @spec parse_csv(binary() | nil) :: [String.t()]
  def parse_csv(nil), do: []
  def parse_csv(""), do: []

  def parse_csv(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_csv(_), do: []

  @doc """
  Conditionally add a key-value pair to a keyword list.

  Skips nil values, which makes it useful for building optional parameter lists.

  ## Examples

      iex> Arbor.Orchestrator.Handlers.Helpers.maybe_add([], :model, "gpt-4")
      [model: "gpt-4"]

      iex> Arbor.Orchestrator.Handlers.Helpers.maybe_add([], :model, nil)
      []
  """
  @spec maybe_add(keyword(), atom(), term()) :: keyword()
  def maybe_add(opts, _key, nil), do: opts
  def maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
