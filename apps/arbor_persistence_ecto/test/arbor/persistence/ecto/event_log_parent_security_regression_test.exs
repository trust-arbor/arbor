defmodule Arbor.Persistence.Ecto.EventLogParentSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Ecto.EventLog
  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.Event

  @moduletag :database
  @moduletag :integration

  defmodule CompatibleEvent do
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
    on_exit(&clean_event_store!/0)
    :ok
  end

  test "security regression: ordinary public type strings survive read and publication" do
    publisher_name = Module.concat([Store, EventStore.Notifications.Publisher])
    publisher = Process.whereis(publisher_name)
    assert is_pid(publisher)
    monitor = Process.monitor(publisher)

    stream_id = "parent-type-proof"

    event = %EventStore.EventData{
      event_type: "arbor.review.ordinary",
      data: %{value: 1},
      metadata: %{}
    }

    assert :ok = Store.append_to_stream(stream_id, :any_version, [event])

    assert {:ok, [%EventStore.RecordedEvent{event_type: "arbor.review.ordinary", data: data}]} =
             Store.read_stream_forward(stream_id, 0, 1)

    assert data == %{"value" => 1}

    refute_receive {:DOWN, ^monitor, :process, ^publisher, _reason}, 250
  end

  test "security regression: concurrent EventStore appends cannot exceed global capacity" do
    drop_position_capacity_constraints!()
    clear_position_capacity_cache!()

    event_type = Atom.to_string(CompatibleEvent)
    seed = Event.new("parent-capacity-seed", event_type, %{value: 0})
    assert {:ok, [_]} = EventLog.append("parent-capacity-seed", seed, expected_version: 0)
    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(conn, "UPDATE public.streams SET stream_version = $1 WHERE stream_id = 0", [
      2_147_483_646
    ])

    results =
      ["parent-capacity-a", "parent-capacity-b"]
      |> Task.async_stream(
        fn stream_id ->
          EventLog.append(stream_id, Event.new(stream_id, event_type, %{value: stream_id}),
            expected_version: 0
          )
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, [_event]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :global_position_exhausted})) == 1

    assert %{rows: [[2_147_483_647]]} =
             Postgrex.query!(
               conn,
               "SELECT stream_version FROM public.streams WHERE stream_id = 0",
               []
             )
  end

  test "security regression: exact reconciliation detects a globally reused event ID" do
    event_id = "evt_parent_global_identity_conflict"
    event_type = Atom.to_string(CompatibleEvent)

    original =
      Event.new("parent-identity-owner", event_type, %{value: 1}, id: event_id)

    assert {:ok, [_]} = EventLog.append("parent-identity-owner", original)

    conflicting =
      Event.new("parent-identity-claimant", event_type, %{value: 1},
        id: event_id,
        timestamp: original.timestamp
      )

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation(
               "parent-identity-claimant",
               [conflicting]
             )

    assert {:error, :event_identity_conflict} = EventLog.reconcile_append(operation, [])
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

  defp drop_position_capacity_constraints! do
    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(
      conn,
      """
      ALTER TABLE public.streams
        DROP CONSTRAINT IF EXISTS arbor_eventlog_stream_position_capacity,
        DROP CONSTRAINT IF EXISTS arbor_eventlog_global_position_capacity
      """,
      [],
      timeout: 10_000
    )
  end

  defp clear_position_capacity_cache! do
    :persistent_term.get()
    |> Enum.each(fn
      {{Arbor.Persistence.Ecto.EventLog, :position_capacity_constraints, _, _} = key, _value} ->
        :persistent_term.erase(key)

      _other ->
        :ok
    end)
  end

  defp event_store_config do
    [
      serializer: EventStore.JsonSerializer,
      username: System.get_env("POSTGRES_USER", "arbor_dev"),
      password: System.get_env("POSTGRES_PASSWORD", ""),
      database: System.get_env("POSTGRES_DB", "trust_arbor_test"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      prepare: :unnamed,
      pool_size: 10
    ]
  end
end
