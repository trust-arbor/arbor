defmodule Arbor.Persistence.Ecto.EventLogIntegrationTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Ecto.EventLog
  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.Test.PostgresDelayProxy

  @moduletag :database
  @moduletag :integration

  setup_all do
    previous_config = Application.get_env(:arbor_persistence_ecto, Store)
    direct_config = event_store_config()

    proxy =
      start_supervised!(
        {PostgresDelayProxy,
         upstream_host: Keyword.fetch!(direct_config, :hostname),
         upstream_port: Keyword.fetch!(direct_config, :port)}
      )

    proxied_config =
      direct_config
      |> Keyword.put(:hostname, "127.0.0.1")
      |> Keyword.put(:port, PostgresDelayProxy.port(proxy))

    Application.put_env(:arbor_persistence_ecto, Store, proxied_config)

    on_exit(fn ->
      if previous_config do
        Application.put_env(:arbor_persistence_ecto, Store, previous_config)
      else
        Application.delete_env(:arbor_persistence_ecto, Store)
      end
    end)

    start_supervised!(Store)
    {:ok, commit_proxy: proxy}
  end

  setup do
    clean_event_store!()

    on_exit(fn ->
      if Process.whereis(Store), do: clean_event_store!()
    end)

    :ok
  end

  test "ordinary append uses EventStore's no-precondition sentinel" do
    assert EventStore.Config.lookup(Store, :serializer) ==
             Arbor.Persistence.Ecto.EventSerializer

    stream_id = "ordinary-append-#{System.unique_integer([:positive])}"
    event_type = "arbor.review.ordinary"
    event = Event.new(stream_id, event_type, %{value: 1})

    assert {:ok, [%Event{} = persisted]} = EventLog.append(stream_id, event)
    assert persisted.stream_id == stream_id
    assert persisted.event_number == 1

    assert {:ok,
            [
              %Event{
                id: id,
                type: ^event_type,
                data: %{"value" => 1},
                event_number: 1
              }
            ]} =
             EventLog.read_stream(stream_id)

    assert id == event.id
  end

  test "ordinary type strings do not crash EventStore's notification publisher" do
    publisher_name = Module.concat([Store, EventStore.Notifications.Publisher])
    publisher = Process.whereis(publisher_name)
    assert is_pid(publisher)
    monitor = Process.monitor(publisher)

    stream_id = "ordinary-publisher-#{System.unique_integer([:positive])}"
    event = Event.new(stream_id, "arbor.review.ordinary", %{value: 1})

    assert {:ok, [%Event{type: "arbor.review.ordinary", data: %{"value" => 1}}]} =
             EventLog.append(stream_id, event)

    refute_receive {:DOWN, ^monitor, :process, ^publisher, _reason}, 250
  end

  test "ordinary append reads back event 1001 by its submitted identity" do
    stream_id = "ordinary-1001"
    event_type = "arbor.review.ordinary"

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
                data: %{"value" => 1_001}
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
    event_type = "arbor.review.ordinary"

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
               persisted.id == submitted.id and persisted.data == canonical_data(submitted.data)

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
    event_type = "arbor.review.ordinary"

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
    event_type = "arbor.review.ordinary"

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

  test "security regression: forged append markers cannot substitute for persisted content" do
    stream_id = "forged-operation"
    event_type = "arbor.review.ordinary"

    expected =
      Event.new(stream_id, event_type, %{value: 1},
        id: "evt_forged_marker",
        agent_id: "agent_expected"
      )

    {operation_id, fingerprint} = append_identity(stream_id, expected)

    forged = %EventStore.EventData{
      event_id: deterministic_storage_id(expected.id),
      event_type: event_type,
      data: %{value: 999},
      metadata: %{
        "event_id" => expected.id,
        "arbor_agent_id" => expected.agent_id,
        "arbor_event_timestamp" => DateTime.to_iso8601(expected.timestamp),
        "arbor_append_operation_id" => operation_id,
        "arbor_append_fingerprint" => fingerprint,
        "causation_id" => nil,
        "correlation_id" => nil
      }
    }

    assert :ok = Store.append_to_stream(stream_id, :any_version, [forged])

    assert {:error, :event_identity_conflict} = EventLog.append(stream_id, expected)
    assert {:ok, 1} = EventLog.stream_version(stream_id)
  end

  test "forged reconciliation operations are rejected before EventStore queries" do
    event = Event.new("forged-boundary", "arbor.review.ordinary", %{value: 1})

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("forged-boundary", [event])

    oversized_ids = Enum.map(1..1_001, &"evt_forged_#{&1}")

    for forged <- [
          rebuild_operation(operation, event_ids: [event.id | :improper]),
          rebuild_operation(operation, event_ids: oversized_ids, fingerprints: %{})
        ] do
      assert {:error, :invalid_append_operation} = EventLog.reconcile_append(forged, [])
    end

    assert {:error, :invalid_precondition} =
             EventLog.reconcile_append(
               operation,
               [{:append_timeout_ms, 10} | :improper]
             )
  end

  test "exact reconciliation detects an event ID committed to another stream" do
    event_id = "evt_global_identity_conflict"

    original =
      Event.new("identity-owner", "arbor.review.ordinary", %{value: 1}, id: event_id)

    assert {:ok, [_]} = EventLog.append("identity-owner", original)

    conflicting =
      Event.new("identity-claimant", "arbor.review.ordinary", %{value: 1},
        id: event_id,
        timestamp: original.timestamp
      )

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("identity-claimant", [conflicting])

    assert {:error, :event_identity_conflict} = EventLog.reconcile_append(operation, [])
  end

  test "agent identity round-trips and caller metadata cannot override reserved fields" do
    stream_id = "agent-round-trip"
    event_type = "arbor.review.ordinary"

    event =
      Event.new(stream_id, event_type, %{value: 7},
        id: "evt_agent_round_trip",
        agent_id: "agent_real",
        metadata: %{
          "visible" => "kept",
          "event_id" => "evt_attacker",
          "arbor_agent_id" => "agent_attacker",
          :arbor_append_fingerprint => String.duplicate("0", 64)
        }
      )

    assert {:ok, [%Event{} = persisted]} = EventLog.append(stream_id, event)
    assert persisted.agent_id == "agent_real"
    assert persisted.metadata == %{"visible" => "kept"}

    assert {:ok, [%Event{} = read]} = EventLog.read_stream(stream_id)
    assert read.agent_id == "agent_real"
    assert read.metadata == %{"visible" => "kept"}

    assert {:ok, [%Event{id: "evt_agent_round_trip", agent_id: "agent_real"}]} =
             EventLog.append(stream_id, event)

    changed_agent = %Event{event | agent_id: "agent_other"}
    assert {:error, :event_identity_conflict} = EventLog.append(stream_id, changed_agent)
  end

  test "append timeout bounds pool checkout and reconciles the undispatched operation as absent" do
    parent = self()
    conn = EventStore.Config.lookup(Store, :conn)
    pool_size = EventStore.Config.lookup(Store, :pool_size)

    holders =
      for holder <- 1..pool_size do
        Task.async(fn ->
          Postgrex.transaction(
            conn,
            fn _checked_out ->
              send(parent, {:event_store_pool_slot_held, holder})

              receive do
                :release_event_store_pool_slot -> :ok
              after
                2_000 -> raise "event store pool holder timed out"
              end
            end,
            timeout: 3_000
          )
        end)
      end

    for holder <- 1..pool_size do
      assert_receive {:event_store_pool_slot_held, ^holder}, 1_000
    end

    event = Event.new("event-store-checkout-timeout", "arbor.review.ordinary", %{value: 1})

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("event-store-checkout-timeout", [event])

    started_at = System.monotonic_time(:millisecond)

    result =
      try do
        EventLog.append("event-store-checkout-timeout", event, append_timeout_ms: 40)
      after
        Enum.each(holders, &send(&1.pid, :release_event_store_pool_slot))
      end

    assert result == {:error, {:append_indeterminate, operation}}
    assert System.monotonic_time(:millisecond) - started_at < 250
    Enum.each(holders, &Task.await(&1, 1_000))
    assert {:ok, :absent} = EventLog.reconcile_append(operation, append_timeout_ms: 1_000)
  end

  test "delayed EventStore COMMIT acknowledgement is reconcilable", %{commit_proxy: proxy} do
    stream_id = "event-store-delayed-commit"
    event = Event.new(stream_id, "arbor.review.ordinary", %{value: 11})

    :ok =
      PostgresDelayProxy.delay_next_match(
        proxy,
        self(),
        300,
        "new_events_indexes",
        :postgres_proxy_delaying_event_store_commit_reply,
        1
      )

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:append_indeterminate, operation}} =
             EventLog.append(stream_id, event, append_timeout_ms: 75)

    assert System.monotonic_time(:millisecond) - started_at < 250
    assert_receive :postgres_proxy_delaying_event_store_commit_reply, 1_000

    assert {:ok, {:committed, [%Event{id: committed_id, data: %{"value" => 11}}]}} =
             EventLog.reconcile_append(operation, append_timeout_ms: 1_000)

    assert committed_id == event.id

    assert {:ok, [%Event{id: retried_id, global_position: 1}]} =
             EventLog.append(stream_id, event)

    assert retried_id == event.id
    assert {:ok, 1} = EventLog.stream_version(stream_id)
  end

  test "stream and global position exhaustion fail before EventStore encoding" do
    event_type = "arbor.review.ordinary"
    assert {:ok, [_]} = EventLog.append("full-stream", Event.new("full-stream", event_type, %{}))
    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(
      conn,
      "UPDATE public.streams SET stream_version = $1 WHERE stream_uuid = $2",
      [2_147_483_647, "full-stream"]
    )

    assert {:error, :stream_position_exhausted} =
             EventLog.append("full-stream", Event.new("full-stream", event_type, %{}))

    Postgrex.query!(conn, "UPDATE public.streams SET stream_version = $1 WHERE stream_id = 0", [
      2_147_483_647
    ])

    assert {:error, :global_position_exhausted} =
             EventLog.append("global-full", Event.new("global-full", event_type, %{}))
  end

  test "concurrent appends cannot cross the global position capacity" do
    event_type = "arbor.review.ordinary"

    assert {:ok, [_]} =
             EventLog.append(
               "global-capacity-seed",
               Event.new("global-capacity-seed", event_type, %{})
             )

    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(conn, "UPDATE public.streams SET stream_version = $1 WHERE stream_id = 0", [
      2_147_483_646
    ])

    results =
      ["global-capacity-a", "global-capacity-b"]
      |> Task.async_stream(
        fn stream_id -> EventLog.append(stream_id, Event.new(stream_id, event_type, %{})) end,
        max_concurrency: 2,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, [%Event{global_position: 2_147_483_647}]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :global_position_exhausted})) == 1

    assert %{rows: [[2_147_483_647]]} =
             Postgrex.query!(
               conn,
               "SELECT stream_version FROM public.streams WHERE stream_id = 0",
               []
             )
  end

  test "concurrent appends cannot cross one stream's position capacity" do
    stream_id = "stream-capacity-race"
    event_type = "arbor.review.ordinary"
    assert {:ok, [_]} = EventLog.append(stream_id, Event.new(stream_id, event_type, %{}))
    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(
      conn,
      "UPDATE public.streams SET stream_version = $1 WHERE stream_uuid = $2",
      [2_147_483_646, stream_id]
    )

    results =
      1..2
      |> Task.async_stream(
        fn value ->
          EventLog.append(stream_id, Event.new(stream_id, event_type, %{value: value}))
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, [%Event{event_number: 2_147_483_647}]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stream_position_exhausted})) == 1

    assert %{rows: [[2_147_483_647]]} =
             Postgrex.query!(
               conn,
               "SELECT stream_version FROM public.streams WHERE stream_uuid = $1",
               [stream_id]
             )
  end

  test "stream head is reconstructed from one current database snapshot" do
    stream_id = "atomic-head"
    event_type = "arbor.review.ordinary"

    assert {:ok, [_first, second]} =
             EventLog.append(stream_id, [
               Event.new(stream_id, event_type, %{value: 1}),
               Event.new(stream_id, event_type, %{value: 2}, agent_id: "agent_head")
             ])

    assert {:ok,
            %Event{
              id: head_id,
              event_number: 2,
              global_position: 2,
              agent_id: "agent_head"
            }} = EventLog.read_stream_head(stream_id)

    assert head_id == second.id
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
      # EventStore.init/1 must override stale struct-oriented configuration.
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

  defp deterministic_storage_id(event_id) do
    hex =
      :crypto.hash(:sha256, event_id)
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    binary_part(hex, 0, 8) <>
      "-" <>
      binary_part(hex, 8, 4) <>
      "-" <>
      binary_part(hex, 12, 4) <>
      "-" <>
      binary_part(hex, 16, 4) <>
      "-" <> binary_part(hex, 20, 12)
  end

  defp append_identity(stream_id, %Event{} = event) do
    fingerprint =
      {1, stream_id, event.id, event.type, canonical_data(event.data),
       canonical_data(event.metadata), event.agent_id, event.causation_id, event.correlation_id,
       DateTime.to_iso8601(event.timestamp)}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    operation_id =
      {stream_id, [{event.id, fingerprint}]}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> then(&("append_" <> &1))

    {operation_id, fingerprint}
  end

  defp canonical_data(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp rebuild_operation(operation, attrs) do
    operation.__struct__
    |> struct(Map.merge(Map.from_struct(operation), Map.new(attrs)))
  end
end
