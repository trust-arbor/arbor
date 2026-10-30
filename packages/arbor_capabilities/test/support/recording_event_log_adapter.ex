defmodule Arbor.Security.TestSupport.RecordingEventLogAdapter do
  @moduledoc false
  @behaviour Arbor.Security.Contracts.EventLogAdapter

  @table __MODULE__

  @doc """
  Create the recording table if needed and clear prior events.

  The table is owned by the first caller (typically the mix test process via
  `test_helper.exs`) so it outlives individual test processes.
  """
  @spec setup() :: :ok
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :ordered_set])

      _tid ->
        :ok
    end

    reset()
  end

  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @spec invocations() :: [{:persist_security_event, atom(), map()}]
  def invocations do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @impl true
  def persist_security_event(event_type, data) do
    seq = System.unique_integer([:monotonic, :positive])
    event = stored_event(event_type, data)
    :ets.insert(@table, {seq, {:persist_security_event, event_type, data}, event})
    :ok
  end

  @impl true
  def read_security_events(opts) do
    events =
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 2))

    events =
      case Keyword.get(opts, :direction, :forward) do
        :backward -> Enum.reverse(events)
        _forward -> events
      end

    events =
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n >= 0 -> Enum.take(events, n)
        _unlimited -> events
      end

    {:ok, events}
  end

  defp stored_event(event_type, data) do
    %{type: to_string(event_type), data: json_canonicalize(data)}
  end

  # Match the production EventLog read shape: JSON-canonical string keys at
  # every depth, type as a string. Persist invocations keep the original
  # atom-keyed envelope for Events unit tests.
  defp json_canonicalize(data) when is_map(data) do
    case Jason.encode(data) do
      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _invalid -> stringify_keys(data)
        end

      {:error, _reason} ->
        stringify_keys(data)
    end
  end

  defp json_canonicalize(_data), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: Atom.to_string(value)

  defp stringify_value(value), do: value
end
