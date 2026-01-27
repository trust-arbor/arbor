defmodule Arbor.Persistence.Filter do
  @moduledoc """
  Composable query DSL for filtering, ordering, and paginating records.

  Filters are data structures that describe a query. In-memory backends
  (ETS, Agent) use `matches?/2` and `apply/2` to evaluate filters against
  record lists. External backends (Ecto, etc.) translate Filter structs
  into native queries.

  ## Examples

      # Simple key-value conditions
      Filter.new()
      |> Filter.where(:type, :eq, "agent_started")
      |> Filter.since(~U[2024-01-01 00:00:00Z])
      |> Filter.order_by(:inserted_at, :desc)
      |> Filter.limit(10)

      # Check if a record matches
      Filter.matches?(filter, record)
  """

  use TypedStruct

  typedstruct do
    @typedoc "A composable query filter"

    field :conditions, list({atom(), atom(), term()}), default: []
    field :since, DateTime.t()
    field :until, DateTime.t()
    field :order_by, {atom(), :asc | :desc}
    field :limit, non_neg_integer()
    field :offset, non_neg_integer(), default: 0
  end

  @doc "Create a new empty filter."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add a condition. Operator can be :eq, :neq, :gt, :gte, :lt, :lte, :in, :contains.

  The field is accessed from the record's data map (or top-level struct fields).
  """
  @spec where(t(), atom(), atom(), term()) :: t()
  def where(%__MODULE__{} = filter, field, operator, value)
      when operator in [:eq, :neq, :gt, :gte, :lt, :lte, :in, :contains] do
    %{filter | conditions: filter.conditions ++ [{field, operator, value}]}
  end

  @doc "Filter records created after the given time."
  @spec since(t(), DateTime.t()) :: t()
  def since(%__MODULE__{} = filter, %DateTime{} = dt) do
    %{filter | since: dt}
  end

  @doc "Filter records created before the given time."
  @spec until(t(), DateTime.t()) :: t()
  def until(%__MODULE__{} = filter, %DateTime{} = dt) do
    %{filter | until: dt}
  end

  @doc "Set ordering. Field is a struct field name."
  @spec order_by(t(), atom(), :asc | :desc) :: t()
  def order_by(%__MODULE__{} = filter, field, direction \\ :asc)
      when direction in [:asc, :desc] do
    %{filter | order_by: {field, direction}}
  end

  @doc "Limit the number of results."
  @spec limit(t(), non_neg_integer()) :: t()
  def limit(%__MODULE__{} = filter, n) when is_integer(n) and n >= 0 do
    %{filter | limit: n}
  end

  @doc "Skip the first N results."
  @spec offset(t(), non_neg_integer()) :: t()
  def offset(%__MODULE__{} = filter, n) when is_integer(n) and n >= 0 do
    %{filter | offset: n}
  end

  @doc """
  Check if a record (map or struct) matches all filter conditions and time ranges.

  Does NOT apply ordering, limit, or offset — those are collection-level operations.
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{} = filter, record) when is_map(record) do
    matches_conditions?(filter.conditions, record) and
      matches_since?(filter.since, record) and
      matches_until?(filter.until, record)
  end

  @doc """
  Apply the full filter to a list of records: conditions, time range, ordering,
  offset, and limit.
  """
  @spec apply(t(), [map()]) :: [map()]
  def apply(%__MODULE__{} = filter, records) when is_list(records) do
    records
    |> Enum.filter(&matches?(filter, &1))
    |> maybe_sort(filter.order_by)
    |> maybe_offset(filter.offset)
    |> maybe_limit(filter.limit)
  end

  # --- Private helpers ---

  defp matches_conditions?([], _record), do: true

  defp matches_conditions?([{field, op, value} | rest], record) do
    record_value = get_field(record, field)

    if evaluate_op(op, record_value, value) do
      matches_conditions?(rest, record)
    else
      false
    end
  end

  defp matches_since?(nil, _record), do: true

  defp matches_since?(%DateTime{} = since, record) do
    case get_timestamp(record) do
      %DateTime{} = ts -> DateTime.compare(ts, since) in [:gt, :eq]
      _ -> true
    end
  end

  defp matches_until?(nil, _record), do: true

  defp matches_until?(%DateTime{} = until_dt, record) do
    case get_timestamp(record) do
      %DateTime{} = ts -> DateTime.compare(ts, until_dt) in [:lt, :eq]
      _ -> true
    end
  end

  defp get_field(%{__struct__: _} = record, field) do
    Map.get(record, field) || get_in_data(record, field)
  end

  defp get_field(record, field) when is_map(record) do
    case Map.get(record, field) do
      nil -> Map.get(record, to_string(field))
      val -> val
    end
  end

  defp get_in_data(record, field) do
    case Map.get(record, :data) do
      %{} = data ->
        Map.get(data, field) || Map.get(data, to_string(field))

      _ ->
        nil
    end
  end

  defp get_timestamp(record) do
    Map.get(record, :inserted_at) || Map.get(record, :timestamp)
  end

  defp evaluate_op(:eq, a, b), do: a == b
  defp evaluate_op(:neq, a, b), do: a != b
  defp evaluate_op(:gt, a, b), do: a > b
  defp evaluate_op(:gte, a, b), do: a >= b
  defp evaluate_op(:lt, a, b), do: a < b
  defp evaluate_op(:lte, a, b), do: a <= b
  defp evaluate_op(:in, a, b) when is_list(b), do: a in b
  defp evaluate_op(:in, _a, _b), do: false

  defp evaluate_op(:contains, a, b) when is_binary(a) and is_binary(b) do
    String.contains?(a, b)
  end

  defp evaluate_op(:contains, a, b) when is_list(a), do: b in a
  defp evaluate_op(:contains, %{} = a, b) when is_atom(b), do: Map.has_key?(a, b)

  defp evaluate_op(:contains, %{} = a, b) when is_binary(b) do
    Map.has_key?(a, b) or Map.has_key?(a, String.to_existing_atom(b))
  rescue
    ArgumentError -> Map.has_key?(a, b)
  end

  defp evaluate_op(:contains, _, _), do: false

  defp maybe_sort(records, nil), do: records

  defp maybe_sort(records, {field, :asc}) do
    Enum.sort_by(records, &Map.get(&1, field))
  end

  defp maybe_sort(records, {field, :desc}) do
    Enum.sort_by(records, &Map.get(&1, field), :desc)
  end

  defp maybe_offset(records, 0), do: records
  defp maybe_offset(records, n), do: Enum.drop(records, n)

  defp maybe_limit(records, nil), do: records
  defp maybe_limit(records, n), do: Enum.take(records, n)
end
