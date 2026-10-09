defmodule Arbor.Persistence.EventRecordReadDatabaseTest do
  use Arbor.Persistence.DatabaseCase, async: false
  alias Arbor.Persistence
  alias Arbor.Persistence.{Event, EventLog}
  @moduletag :database

  test "durable exact records materialize only requested IDs and one pinned head" do
    events =
      for n <- 1..200, do: Event.new("exact_stream", "transition", %{value: n}, id: "exact_#{n}")

    assert {:ok, _} = Persistence.append(:journal, EventLog.Ecto, "exact_stream", events)
    observer = self()
    ref = "exact_records_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        ref,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _, measurements, metadata, pid ->
          send(pid, {:query, measurements, metadata})
        end,
        observer
      )

    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:ok, %{events: selected, head: head}} =
             Persistence.read_event_records(
               :journal,
               EventLog.Ecto,
               "exact_stream",
               ["exact_1", "exact_100", "exact_200", "absent"],
               max_event_number: 150
             )

    assert Enum.map(selected, & &1.id) == ["exact_1", "exact_100"]
    assert head.event_number == 150
    queries = collect_queries([]) |> Enum.filter(&String.starts_with?(&1.query, "SELECT"))
    assert length(queries) == 1
    ids_query = Enum.find(queries, &String.contains?(&1.query, " IN "))
    assert ids_query
    assert String.contains?(ids_query.query, "LIMIT")
    assert {:ok, %{num_rows: 4}} = ids_query.result
    assert Enum.all?(queries, &(not String.contains?(&1.query, "OFFSET")))

    assert {:error, :head_unavailable} =
             Persistence.read_event_records(:journal, EventLog.Ecto, "exact_stream", ["exact_1"],
               max_event_number: 201
             )

    assert {:ok, %{events: [], head: nil}} =
             Persistence.read_event_records(:journal, EventLog.Ecto, "exact_stream", ["exact_1"],
               max_event_number: 0
             )

    assert {:ok, %{events: [%{id: "exact_100"}], head: %{event_number: 200}}} =
             Persistence.read_event_records(:journal, EventLog.Ecto, "exact_stream", ["exact_100"])
  end

  test "security regression durable requested IDs from another stream fail closed" do
    assert {:ok, _} =
             Persistence.append(:journal, EventLog.Ecto, "owned", [
               Event.new("owned", "transition", %{}, id: "owned_event")
             ])

    assert {:ok, _} =
             Persistence.append(:journal, EventLog.Ecto, "foreign", [
               Event.new("foreign", "transition", %{}, id: "foreign_event")
             ])

    assert {:error, :event_records_invalid} =
             Persistence.read_event_records(:journal, EventLog.Ecto, "owned", ["foreign_event"],
               max_event_number: 1
             )
  end

  defp collect_queries(acc) do
    receive do
      {:query, _measurements, metadata} -> collect_queries([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
