defmodule Arbor.Persistence.Ecto.EventLogIntegrationTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Ecto.EventLog
  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.Event

  @moduletag :database
  @moduletag :integration

  defmodule OrdinaryEvent do
    @moduledoc false
    defstruct [:value]
  end

  setup_all do
    previous_config = Application.get_env(:arbor_persistence_ecto, Store)
    Application.put_env(:arbor_persistence_ecto, Store, event_store_config())

    on_exit(fn ->
      if previous_config do
        Application.put_env(:arbor_persistence_ecto, Store, previous_config)
      else
        Application.delete_env(:arbor_persistence_ecto, Store)
      end
    end)

    start_supervised!(Store)
    :ok
  end

  setup do
    clean_event_store!()

    on_exit(fn ->
      if Process.whereis(Store), do: clean_event_store!()
    end)

    :ok
  end

  test "ordinary append uses EventStore's no-precondition sentinel" do
    stream_id = "ordinary-append-#{System.unique_integer([:positive])}"
    event_type = Atom.to_string(OrdinaryEvent)
    event = Event.new(stream_id, event_type, %{value: 1})

    assert {:ok, [%Event{} = persisted]} = EventLog.append(stream_id, event)
    assert persisted.stream_id == stream_id
    assert persisted.event_number == 1

    assert {:ok,
            [
              %Event{
                id: id,
                type: ^event_type,
                data: %OrdinaryEvent{value: 1},
                event_number: 1
              }
            ]} =
             EventLog.read_stream(stream_id)

    assert id == event.id
  end

  test "ordinary append reads back event 1001 by its submitted identity" do
    stream_id = "ordinary-1001"
    event_type = Atom.to_string(OrdinaryEvent)

    first_thousand =
      for value <- 1..1_000 do
        Event.new(stream_id, event_type, %{value: value})
      end

    assert {:ok, persisted} = EventLog.append(stream_id, first_thousand)
    assert length(persisted) == 1_000

    submitted = Event.new(stream_id, event_type, %{value: 1_001})

    assert {:ok,
            [
              %Event{
                id: submitted_id,
                event_number: 1_001,
                data: %{value: 1_001}
              }
            ]} = EventLog.append(stream_id, submitted)

    assert submitted_id == submitted.id

    assert {:ok, [%Event{id: read_id, event_number: 1_001}]} =
             EventLog.read_stream(stream_id, from: 1_001, limit: 1)

    assert read_id == submitted.id
  end

  test "concurrent ordinary writers each receive their own persisted event" do
    writer_count = 24
    stream_id = "ordinary-concurrent"
    event_type = Atom.to_string(OrdinaryEvent)

    results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          submitted = Event.new(stream_id, event_type, %{value: writer})
          {submitted, EventLog.append(stream_id, submitted)}
        end,
        max_concurrency: writer_count,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {%Event{} = submitted, {:ok, [%Event{} = persisted]}}} ->
               persisted.id == submitted.id and persisted.data == submitted.data

             _other ->
               false
           end),
           "ordinary writer received another append's event: #{inspect(results)}"

    returned_positions =
      Enum.map(results, fn {:ok, {_submitted, {:ok, [persisted]}}} ->
        {persisted.event_number, persisted.global_position}
      end)

    assert returned_positions |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             Enum.to_list(1..writer_count)

    assert returned_positions |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             Enum.to_list(1..writer_count)
  end

  test "concurrent exact-version appends have exactly one winner" do
    writer_count = 20
    stream_id = "event-store-cas"
    event_type = Atom.to_string(OrdinaryEvent)

    results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          EventLog.append(stream_id, Event.new(stream_id, event_type, %{value: writer}),
            expected_version: 0
          )
        end,
        max_concurrency: writer_count,
        timeout: 30_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :version_conflict})) == writer_count - 1
    assert {:ok, 1} = EventLog.stream_version(stream_id)
  end

  test "stream reads resolve exact global positions across two streams" do
    event_type = Atom.to_string(OrdinaryEvent)

    assert {:ok, [%Event{global_position: 1}]} =
             EventLog.append("global-a", Event.new("global-a", event_type, %{value: 1}))

    assert {:ok, [%Event{global_position: 2}]} =
             EventLog.append("global-b", Event.new("global-b", event_type, %{value: 2}))

    assert {:ok, [%Event{global_position: 1}]} = EventLog.read_stream("global-a")
    assert {:ok, [%Event{global_position: 2}]} = EventLog.read_stream("global-b")

    assert {:ok, all} = EventLog.read_all()
    assert Enum.map(all, & &1.global_position) == [1, 2]
    assert Enum.map(all, & &1.stream_id) == ["global-a", "global-b"]
  end

  defp clean_event_store! do
    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(
      conn,
      """
      TRUNCATE TABLE
        public.stream_events,
        public.events,
        public.subscriptions,
        public.snapshots,
        public.streams
      RESTART IDENTITY CASCADE
      """,
      [],
      timeout: 10_000
    )

    Postgrex.query!(
      conn,
      "INSERT INTO public.streams (stream_id, stream_uuid, stream_version) VALUES (0, '$all', 0)",
      [],
      timeout: 10_000
    )
  end

  defp event_store_config do
    [
      serializer: EventStore.JsonSerializer,
      username: System.get_env("POSTGRES_USER", "arbor_dev"),
      password: System.get_env("POSTGRES_PASSWORD", ""),
      database: System.get_env("POSTGRES_DB", "trust_arbor_test"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      pool_size: 10
    ]
  end
end
