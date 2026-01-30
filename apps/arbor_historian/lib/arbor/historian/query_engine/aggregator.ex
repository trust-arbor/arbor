defmodule Arbor.Historian.QueryEngine.Aggregator do
  @moduledoc """
  Aggregation functions over history entries.

  Provides counting, distribution analysis, and activity summaries.
  All functions operate on lists of HistoryEntry structs.
  """

  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.QueryEngine

  @doc """
  Count entries matching a category in the global stream.
  """
  @spec count_by_category(atom(), keyword()) :: non_neg_integer()
  def count_by_category(category, opts) do
    {:ok, entries} = QueryEngine.read_global(opts)
    Enum.count(entries, &(&1.category == category))
  end

  @doc """
  Count error entries (category :logs, type :error or :warn).
  """
  @spec error_count(keyword()) :: non_neg_integer()
  def error_count(opts) do
    {:ok, entries} = QueryEngine.read_global(opts)
    Enum.count(entries, &(&1.category == :logs and &1.type in [:error, :warn]))
  end

  @doc """
  Get the distribution of entries by category.

  Returns a map of `%{category_atom => count}`.
  """
  @spec category_distribution(keyword()) :: %{atom() => non_neg_integer()}
  def category_distribution(opts) do
    {:ok, entries} = QueryEngine.read_global(opts)
    Enum.frequencies_by(entries, & &1.category)
  end

  @doc """
  Get the distribution of entries by type.

  Returns a map of `%{type_atom => count}`.
  """
  @spec type_distribution(keyword()) :: %{atom() => non_neg_integer()}
  def type_distribution(opts) do
    {:ok, entries} = QueryEngine.read_global(opts)
    Enum.frequencies_by(entries, & &1.type)
  end

  @doc """
  Get activity summary for a specific agent.

  Returns a map with event count, categories, first/last timestamps.
  """
  @spec agent_activity(String.t(), keyword()) :: map()
  def agent_activity(agent_id, opts) do
    {:ok, entries} = QueryEngine.read_agent(agent_id, opts)
    build_summary(entries)
  end

  @doc """
  Build a summary from a list of entries.
  """
  @spec build_summary([HistoryEntry.t()]) :: map()
  def build_summary(entries) do
    if Enum.empty?(entries) do
      %{total: 0, categories: %{}, types: %{}, first: nil, last: nil, errors: 0}
    else
      sorted = Enum.sort_by(entries, & &1.timestamp, DateTime)

      %{
        total: length(entries),
        categories: Enum.frequencies_by(entries, & &1.category),
        types: Enum.frequencies_by(entries, & &1.type),
        first: List.first(sorted).timestamp,
        last: List.last(sorted).timestamp,
        errors: Enum.count(entries, &(&1.category == :logs and &1.type in [:error, :warn]))
      }
    end
  end
end
