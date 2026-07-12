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
    migrate_event_log_schema_if_available!()
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

    event = Event.new(stream_id, "arbor.review.ordinary", %{value: 1})

    assert {:ok, [%Event{type: "arbor.review.ordinary", data: %{"value" => 1}}]} =
             EventLog.append(stream_id, event)

    assert {:ok, [%Event{type: "arbor.review.ordinary", data: %{"value" => 1}}]} =
             EventLog.read_stream(stream_id)

    refute_receive {:DOWN, ^monitor, :process, ^publisher, _reason}, 250
  end

  test "security regression: concurrent EventStore appends cannot exceed global capacity" do
    unless Code.ensure_loaded?(Arbor.Persistence.Ecto.EventLogSchema) do
      drop_position_capacity_constraints!()
      clear_position_capacity_cache!()
    end

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

  test "security regression: reconciliation cannot prove absence while append is uncommitted" do
    conn = EventStore.Config.lookup(Store, :conn)
    parent = self()
    stream_id = "parent-uncommitted-operation-fence"
    event = Event.new(stream_id, "arbor.review.ordinary", %{value: 1})
    assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation(stream_id, [event])

    locker =
      Task.async(fn ->
        Postgrex.transaction(
          conn,
          fn transaction ->
            Postgrex.query!(
              transaction,
              "SELECT stream_id FROM public.streams WHERE stream_id = 0 FOR UPDATE",
              []
            )

            send(parent, :parent_global_row_locked)

            receive do
              :release_parent_global_row -> :ok
            after
              3_000 -> raise "global row lock release timed out"
            end
          end,
          timeout: 4_000
        )
      end)

    assert_receive :parent_global_row_locked, 1_000

    append_task =
      Task.async(fn -> EventLog.append(stream_id, event, append_timeout_ms: 2_000) end)

    wait_for_blocked_append!(conn)

    reconciliation = EventLog.reconcile_append(operation, append_timeout_ms: 75)
    refute reconciliation == {:ok, :absent}
    assert match?({:error, {:append_indeterminate, ^operation}}, reconciliation)

    send(locker.pid, :release_parent_global_row)
    assert {:ok, :ok} = Task.await(locker, 1_000)
    assert {:ok, [%Event{id: committed_id}]} = Task.await(append_task, 2_000)

    assert {:ok, {:committed, [%Event{id: ^committed_id}]}} =
             EventLog.reconcile_append(operation, append_timeout_ms: 1_000)
  end

  test "security regression: marker-free late writers stay fenced after reconciled absence" do
    conn = EventStore.Config.lookup(Store, :conn)
    reinstall_r3_trigger_and_migrate!(conn)
    stream_id = "parent-marker-free-late-writer"

    event =
      Event.new(stream_id, "arbor.review.ordinary", %{value: 1},
        id: "evt_parent_marker_free_late_writer"
      )

    assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation(stream_id, [event])
    assert {:ok, :absent} = EventLog.reconcile_append(operation, [])

    for {label, operation_marker} <- [missing: :missing, null: nil, nonstring: 17] do
      raw_stream = if label == :missing, do: stream_id, else: "#{stream_id}-#{label}"
      raw_event_id = if label == :missing, do: event.id, else: "#{event.id}-#{label}"

      metadata = %{
        "event_id" => raw_event_id,
        "arbor_event_timestamp" => DateTime.to_iso8601(event.timestamp),
        "arbor_append_fingerprint" => Map.fetch!(operation.fingerprints, event.id)
      }

      metadata =
        if operation_marker == :missing,
          do: metadata,
          else: Map.put(metadata, "arbor_append_operation_id", operation_marker)

      raw_event = %EventStore.EventData{
        event_id: deterministic_storage_id(raw_event_id),
        event_type: event.type,
        data: event.data,
        metadata: metadata
      }

      assert {:error, _reason} = capture_event_store_append(raw_stream, raw_event)
      assert {:ok, 0} = EventLog.stream_version(raw_stream)
    end

    assert {:ok, 0} = EventLog.stream_version(stream_id)
    assert {:ok, :absent} = EventLog.reconcile_append(operation, [])

    assert %{rows: [[source]]} =
             Postgrex.query!(
               conn,
               "SELECT prosrc FROM pg_proc WHERE oid = 'public.arbor_event_log_enforce_operation_fence()'::regprocedure"
             )

    assert source =~ "? 'arbor_append_operation_id'"
    assert source =~ "IS DISTINCT FROM 'string'"
  end

  test "security regression: append runtime never repairs missing schema constraints" do
    conn = EventStore.Config.lookup(Store, :conn)

    Postgrex.query!(
      conn,
      "ALTER TABLE public.streams DROP CONSTRAINT arbor_eventlog_stream_position_capacity"
    )

    on_exit(fn -> restore_stream_capacity_constraint!(conn) end)

    event = Event.new("parent-runtime-ddl-forbidden", "arbor.review.ordinary", %{value: 1})

    assert {:error,
            {:event_log_schema_unavailable,
             {:constraint_missing_or_invalid, "arbor_eventlog_stream_position_capacity"}}} =
             EventLog.append("parent-runtime-ddl-forbidden", event)

    refute constraint_exists?(conn, "arbor_eventlog_stream_position_capacity")
    assert {:ok, 0} = EventLog.stream_version("parent-runtime-ddl-forbidden")
  end

  defp clean_event_store! do
    conn = EventStore.Config.lookup(Store, :conn)

    if Postgrex.query!(conn, "SELECT to_regclass('public.arbor_event_log_operations')").rows != [
         [nil]
       ] do
      Postgrex.query!(conn, "TRUNCATE TABLE public.arbor_event_log_operations")
    end

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

  defp capture_event_store_append(stream_id, event) do
    case Store.append_to_stream(stream_id, :any_version, [event]) do
      :ok -> :ok
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
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

  defp reinstall_r3_trigger_and_migrate!(conn) do
    install_r3_trigger!(conn)

    Postgrex.query!(
      conn,
      "DELETE FROM public.arbor_event_log_schema_migrations WHERE version = 20260712000003"
    )

    :ok = Arbor.Persistence.Ecto.EventLogSchema.migrate!(conn, "public")
  end

  defp install_r3_trigger!(conn) do
    assert %{rows: [[definition]]} =
             Postgrex.query!(
               conn,
               "SELECT pg_get_functiondef('public.arbor_event_log_enforce_operation_fence()'::regprocedure)"
             )

    vulnerable_definition =
      definition
      |> String.replace(
        "OR NOT (metadata_json ? 'arbor_append_operation_id')\n     OR jsonb_typeof(metadata_json -> 'arbor_append_operation_id') IS DISTINCT FROM 'string'",
        "OR jsonb_typeof(metadata_json -> 'arbor_append_operation_id') <> 'string'"
      )
      |> String.replace(
        "OR NOT (metadata_json ? 'arbor_append_fingerprint')\n     OR jsonb_typeof(metadata_json -> 'arbor_append_fingerprint') IS DISTINCT FROM 'string'",
        "OR jsonb_typeof(metadata_json -> 'arbor_append_fingerprint') <> 'string'"
      )
      |> String.replace(
        "OR NOT (metadata_json ? 'event_id')\n     OR jsonb_typeof(metadata_json -> 'event_id') IS DISTINCT FROM 'string'",
        "OR jsonb_typeof(metadata_json -> 'event_id') <> 'string'"
      )

    refute vulnerable_definition =~ "IS DISTINCT FROM 'string'"
    refute vulnerable_definition =~ "metadata_json ? 'arbor_append_operation_id'"
    assert vulnerable_definition =~ "arbor_append_operation_id') <> 'string'"

    Postgrex.query!(conn, vulnerable_definition)
  end

  defp migrate_event_log_schema_if_available! do
    module = Arbor.Persistence.Ecto.EventLogSchema

    if Code.ensure_loaded?(module) do
      conn = EventStore.Config.lookup(Store, :conn)
      schema = EventStore.Config.lookup(Store, :schema)

      unless 20_260_712_000_003 in apply(module, :migration_versions, []) do
        install_r3_trigger!(conn)
      end

      :ok = apply(module, :migrate!, [conn, schema])
    end
  end

  defp wait_for_blocked_append!(conn, attempts \\ 100)

  defp wait_for_blocked_append!(_conn, 0), do: flunk("append did not block on the global row")

  defp wait_for_blocked_append!(conn, attempts) do
    result =
      Postgrex.query!(
        conn,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE datname = current_database()
            AND state = 'active'
            AND wait_event_type = 'Lock'
            AND (
              query LIKE '%new_events_indexes%'
              OR query LIKE '%WHERE stream_id = 0%FOR UPDATE%'
            )
        )
        """
      )

    case result.rows do
      [[true]] ->
        :ok

      [[false]] ->
        Process.sleep(10)
        wait_for_blocked_append!(conn, attempts - 1)
    end
  end

  defp constraint_exists?(conn, name) do
    Postgrex.query!(
      conn,
      "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = $1)",
      [name]
    ).rows == [[true]]
  end

  defp restore_stream_capacity_constraint!(conn) do
    unless constraint_exists?(conn, "arbor_eventlog_stream_position_capacity") do
      Postgrex.query!(
        conn,
        """
        ALTER TABLE public.streams
        ADD CONSTRAINT arbor_eventlog_stream_position_capacity
        CHECK (stream_id = 0 OR (stream_version >= 0 AND stream_version <= 2147483647))
        """
      )
    end
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
