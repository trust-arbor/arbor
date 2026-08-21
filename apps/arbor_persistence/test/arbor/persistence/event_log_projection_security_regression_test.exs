defmodule Arbor.Persistence.EventLogProjectionSecurityRegressionTest do
  @moduledoc """
  Security regressions for the non-authoritative EventLog projection mode.

  A projection caches events another component already committed. If any of
  these gates drifts open, the projection silently becomes authority it never
  earned: it could mint positions, resurrect purged identities, claim a stream
  is absent, hand a stale head to a freshness precondition, or write a snapshot
  that a later boot would restore as truth. Each test names the gate it holds
  shut; do not delete one as redundant with the behavioural suites.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  import ExUnit.CaptureLog

  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Persistence.EventLog.Snapshotter

  @timestamp ~U[2026-08-21 00:00:00.000000Z]

  defmodule SnapshotStore do
    @moduledoc false

    use Agent

    def start_link(opts), do: Agent.start_link(fn -> %{} end, name: Keyword.fetch!(opts, :name))

    def put(key, value, opts) do
      Agent.update(Keyword.fetch!(opts, :name), &Map.put(&1, key, value))
    end

    def get(key, opts) do
      case Agent.get(Keyword.fetch!(opts, :name), &Map.fetch(&1, key)) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end

    def delete(key, opts) do
      Agent.update(Keyword.fetch!(opts, :name), &Map.delete(&1, key))
    end

    def contents(name), do: Agent.get(name, & &1)
  end

  # A snapshot store already holding a complete authoritative snapshot. An
  # authoritative log restores from it; a projection must not.
  defmodule PopulatedStore do
    @moduledoc false

    def get("projection_restore:meta", _opts), do: {:ok, %{"latest_id" => "1"}}

    def get("projection_restore:snapshot:1", _opts) do
      event = %Event{
        id: "evt_restored",
        stream_id: "restored",
        event_number: 1,
        global_position: 1,
        type: "started",
        data: %{},
        metadata: %{},
        timestamp: ~U[2099-01-01 00:00:00.000000Z]
      }

      fingerprint = EventLog.event_fingerprint("restored", event)

      {:ok,
       %{
         "global_position" => 1,
         "stream_versions" => %{"restored" => 1},
         "events" => [
           %{
             "id" => "evt_restored",
             "stream_id" => "restored",
             "event_number" => 1,
             "global_position" => 1,
             "type" => "started",
             "data" => %{},
             "metadata" => %{},
             "timestamp" => "2099-01-01T00:00:00.000000Z",
             "operation_fingerprint" => fingerprint
           }
         ]
       }}
    end

    def get(_key, _opts), do: {:error, :not_found}
  end

  setup do
    {:ok, name: start_projection()}
  end

  test "security regression: projection append is read-only and mints no position", %{name: name} do
    unpositioned = Event.new("stream", "attempted", %{"value" => "v"}, id: "evt_append")

    assert {:error, :projection_read_only} = ETS.append("stream", [unpositioned], name: name)

    assert {:error, :projection_read_only} =
             Persistence.append(name, ETS, "stream", [unpositioned])

    assert {:ok, 0} = ETS.event_count(name: name)
    assert {:ok, []} = ETS.list_streams(name: name)

    assert {:ok, %{global_position: 0, observed_global_position: 0}} =
             ETS.projection_status(name: name)
  end

  test "security regression: projection reconciliation is read-only", %{name: name} do
    event = positioned("evt_a", 1, 1)
    {:ok, operation} = EventLog.build_operation("stream", [event])

    assert {:error, :projection_read_only} = ETS.reconcile_append(operation, name: name)

    assert {:error, :projection_read_only} =
             Persistence.reconcile_append(name, ETS, operation)
  end

  test "security regression: projection identity replay and metadata rehydrate are read-only",
       %{name: name} do
    assert {:error, :projection_read_only} =
             ETS.replay_identity_history([positioned("evt_a", 1, 1)], name: name, complete: true)

    assert {:error, :projection_read_only} =
             ETS.rehydrate_metadata(
               %{stream_versions: %{"stream" => 5}, global_position: 5},
               name: name
             )

    # Neither call may grant the projection authority it lacked.
    assert {:ok, {:identity_history_unavailable, %{reason: :projection_mode}}} =
             ETS.identity_history_status(name: name)

    assert {:ok, []} = ETS.list_streams(name: name)
    assert {:ok, %{global_position: 0}} = ETS.projection_status(name: name)
  end

  test "security regression: projection refuses snapshot export while authoritative still exports",
       %{name: name} do
    store_name = unique_name("snap_store")
    start_supervised!({SnapshotStore, name: store_name}, id: store_name)

    assert {:ok, _} = ETS.project_committed_events([positioned("evt_a", 1, 1)], name: name)

    projection_snapshotter = unique_name("snapshotter_projection")

    start_supervised!(
      {Snapshotter,
       name: projection_snapshotter,
       event_log_name: name,
       store: SnapshotStore,
       store_opts: [name: store_name],
       namespace: "projection_seal",
       interval_ms: 3_600_000},
      id: projection_snapshotter
    )

    assert {:error, :projection_not_snapshottable} =
             Snapshotter.snapshot_now(projection_snapshotter)

    assert SnapshotStore.contents(store_name) == %{}

    # Contrast: the identical wiring against an authoritative log does snapshot.
    authoritative = unique_name("el_auth")
    start_supervised!({ETS, name: authoritative}, id: authoritative)

    {:ok, _} =
      ETS.append("stream", [Event.new("stream", "committed", %{})], name: authoritative)

    authoritative_snapshotter = unique_name("snapshotter_authoritative")

    start_supervised!(
      {Snapshotter,
       name: authoritative_snapshotter,
       event_log_name: authoritative,
       store: SnapshotStore,
       store_opts: [name: store_name],
       namespace: "authoritative_seal",
       interval_ms: 3_600_000},
      id: authoritative_snapshotter
    )

    assert :ok = Snapshotter.snapshot_now(authoritative_snapshotter)
    assert map_size(SnapshotStore.contents(store_name)) > 0
  end

  test "security regression: projection ignores a configured snapshot store instead of restoring" do
    name = unique_name("el_projection_restore")

    log =
      capture_log(fn ->
        start_supervised!(
          {ETS,
           name: name,
           mode: :projection,
           snapshot_store: PopulatedStore,
           snapshot_namespace: "projection_restore"},
          id: name
        )

        # A restored snapshot would have created stream "restored" at position 1.
        assert {:ok, []} = ETS.list_streams(name: name)
        assert {:ok, 0} = ETS.event_count(name: name)
        assert {:ok, %{global_position: 0}} = ETS.projection_status(name: name)
      end)

    assert log =~ "ignoring :snapshot_store in projection mode"

    # Contrast: the same store restores into an authoritative log.
    authoritative = unique_name("el_auth_restore")

    start_supervised!(
      {ETS,
       name: authoritative,
       snapshot_store: PopulatedStore,
       snapshot_namespace: "projection_restore"},
      id: authoritative
    )

    assert {:ok, ["restored"]} = ETS.list_streams(name: authoritative)
  end

  test "security regression: projection never asserts stream absence", %{name: name} do
    assert {:error, :absence_not_supported} = ETS.stream_absent("never_seen", name: name)

    assert {:error, :absence_not_supported} =
             Persistence.event_stream_absent?(name, ETS, "never_seen")

    assert {:ok, _} = ETS.project_committed_events([positioned("evt_a", 1, 1)], name: name)
    assert {:error, :absence_not_supported} = ETS.stream_absent("stream", name: name)
  end

  test "security regression: projection identity lookups never claim a missing event is absent",
       %{name: name} do
    assert {:error, :identity_history_unavailable} =
             ETS.event_identity("stream", "evt_never_written", name: name)

    assert {:ok, _} = ETS.project_committed_events([positioned("evt_a", 1, 1)], name: name)

    assert {:ok, fingerprint} = ETS.event_identity("stream", "evt_a", name: name)
    assert is_binary(fingerprint)

    assert {:error, :identity_history_unavailable} =
             ETS.event_identity("stream", "evt_b", name: name)
  end

  test "security regression: projection reports head_unavailable rather than an empty head",
       %{name: name} do
    # Reporting {:ok, nil} would let a `:max_current_age_ms` freshness
    # precondition pass against a stream the projection does not fully hold.
    assert {:error, :head_unavailable} = ETS.read_stream_head("stream", name: name)

    assert {:ok, _} = ETS.project_committed_events([positioned("evt_a", 1, 1)], name: name)

    assert {:error, :head_unavailable} = ETS.read_stream_head("stream", name: name)

    assert {:error, :head_unavailable} =
             ETS.read_stream_head("stream", name: name, max_current_age_ms: 60_000)

    assert {:error, :head_unavailable} = Persistence.read_stream_head(name, ETS, "stream")
  end

  test "security regression: projected events never notify subscribers", %{name: name} do
    assert {:ok, _ref} = ETS.subscribe(:all, self(), name: name)
    assert {:ok, _ref} = ETS.subscribe("stream", self(), name: name)

    assert {:ok, %{projected: 2}} =
             ETS.project_committed_events(
               [positioned("evt_a", 1, 1), positioned("evt_b", 2, 2)],
               name: name
             )

    refute_receive {:event, %Event{}}, 100
  end

  test "security regression: aggregate projection byte rejection admits no events or metadata",
       %{name: name} do
    bounded_event_bytes = 900_000

    events =
      for n <- 1..5 do
        positioned_with_external_size(
          "evt_bounded_#{n}",
          n,
          n,
          bounded_event_bytes
        )
      end

    assert Enum.all?(events, &(:erlang.external_size(&1) == bounded_event_bytes))

    assert {:error, :projection_batch_bytes_exceeded} =
             Persistence.project_committed_events(name, ETS, events)

    assert {:ok, 0} = Persistence.event_count(name, ETS)
    assert {:ok, []} = Persistence.list_streams(name, ETS)
    assert {:ok, 0} = Persistence.stream_version(name, ETS, "stream")

    assert {:ok, %{global_position: 0, observed_global_position: 0}} =
             ETS.projection_status(name: name)

    assert {:error, :identity_history_unavailable} =
             ETS.event_identity("stream", "evt_bounded_1", name: name)

    # Four fixtures remain below the aggregate ceiling; the fifth crosses it.
    assert {:ok, %{projected: 4, skipped: 0}} =
             Persistence.project_committed_events(name, ETS, Enum.take(events, 4))

    assert {:ok, 4} = Persistence.event_count(name, ETS)
    assert {:ok, 4} = Persistence.stream_version(name, ETS, "stream")
  end

  test "security regression: a tampered third event leaves all five projection surfaces unchanged",
       %{name: name} do
    original = positioned("evt_a", 1, 1)
    assert {:ok, %{projected: 1}} = ETS.project_committed_events([original], name: name)

    tampered = %Event{original | data: %{"value" => "escalated"}}
    tampered = %Event{tampered | operation_fingerprint: original.operation_fingerprint}

    batch = [positioned("evt_b", 2, 2), positioned("evt_c", 3, 3), tampered]

    assert {:error, :projection_fingerprint_mismatch} =
             ETS.project_committed_events(batch, name: name)

    # Payload surface: the original content is intact and nothing was admitted.
    assert {:ok, [resident]} = ETS.read_stream("stream", name: name)
    assert resident.data == %{"value" => "v"}
    assert {:ok, 1} = ETS.event_count(name: name)

    # Stream-pointer and stream-version surfaces.
    assert {:ok, 1} = ETS.stream_version("stream", name: name)

    # Identity surface: the two legitimate leading events left no tombstone.
    assert {:error, :identity_history_unavailable} =
             ETS.event_identity("stream", "evt_b", name: name)

    assert {:error, :identity_history_unavailable} =
             ETS.event_identity("stream", "evt_c", name: name)

    # Identity-position and identity-stream-position surfaces: a surviving row
    # at either position would make this a conflict instead of a clean project.
    assert {:ok, %{projected: 2, skipped: 0}} =
             ETS.project_committed_events(Enum.take(batch, 2), name: name)
  end

  test "security regression: retention clears all five projection surfaces" do
    name = start_projection(max_age_ms: 0, trim_interval_ms: :disabled)
    events = [positioned("evt_a", 1, 1), positioned("evt_b", 2, 2)]

    assert {:ok, %{projected: 2}} = ETS.project_committed_events(events, name: name)

    send(name, :trim_old_events)
    assert {:ok, 0} = ETS.event_count(name: name)

    # Payload and stream-pointer surfaces.
    assert {:ok, []} = ETS.read_stream("stream", name: name)
    # Stream metadata surface.
    assert {:ok, []} = ETS.list_streams(name: name)
    refute ETS.stream_exists?("stream", name: name)
    # Identity surface: no retained tombstone, unlike authoritative retention.
    assert {:error, :identity_history_unavailable} =
             ETS.event_identity("stream", "evt_a", name: name)

    # Identity-position and identity-stream-position surfaces: any surviving row
    # would make re-projection a conflict or a skip rather than a fresh project.
    assert {:ok, %{projected: 2, skipped: 0}} =
             ETS.project_committed_events(events, name: name)
  end

  test "security regression: authoritative retention still retains identity tombstones" do
    name = unique_name("el_auth_retention")

    start_supervised!({ETS, name: name, max_age_ms: 0, trim_interval_ms: :disabled}, id: name)

    stale = Event.new("stream", "committed", %{}, id: "evt_stale", timestamp: @timestamp)
    assert {:ok, [persisted]} = ETS.append("stream", [stale], name: name)

    send(name, :trim_old_events)
    assert {:ok, []} = ETS.read_stream("stream", name: name)

    # The tombstone must survive so a retried append cannot double-commit.
    assert {:ok, fingerprint} = ETS.event_identity("stream", "evt_stale", name: name)
    assert fingerprint == persisted.operation_fingerprint

    # Lifetime metadata is retained too: the count is a lifetime counter and the
    # stream is still known even with zero retained payload rows.
    assert {:ok, 1} = ETS.event_count(name: name)
    assert {:ok, ["stream"]} = ETS.list_streams(name: name)
    assert {:ok, 1} = ETS.stream_version("stream", name: name)
  end

  test "security regression: authoritative mode refuses projection and keeps assigning positions" do
    name = unique_name("el_auth_seal")
    start_supervised!({ETS, name: name}, id: name)

    assert {:error, :projection_mode_required} =
             ETS.project_committed_events([positioned("evt_a", 1, 1)], name: name)

    assert {:error, :projection_mode_required} =
             Persistence.project_committed_events(name, ETS, [positioned("evt_a", 1, 1)])

    assert {:ok, 0} = ETS.event_count(name: name)

    # Authoritative append still assigns positions and notifies subscribers.
    assert {:ok, _ref} = ETS.subscribe(:all, self(), name: name)

    assert {:ok, [persisted]} =
             ETS.append("stream", [Event.new("stream", "committed", %{})], name: name)

    assert persisted.event_number == 1
    assert persisted.global_position == 1
    assert_receive {:event, %Event{id: id}}, 500
    assert id == persisted.id

    assert {:ok, :identity_history_complete} = ETS.identity_history_status(name: name)
    assert {:ok, nil} = ETS.event_identity("stream", "evt_absent", name: name)
    assert {:ok, ^persisted} = ETS.read_stream_head("stream", name: name)
  end

  # --- helpers ---

  defp start_projection(opts \\ []) do
    name = unique_name("el_projection_sec")
    start_supervised!({ETS, Keyword.merge([name: name, mode: :projection], opts)}, id: name)
    name
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{prefix}_#{:erlang.unique_integer([:positive])}"
  end

  defp positioned(id, event_number, global_position) do
    event = %Event{
      id: id,
      stream_id: "stream",
      event_number: event_number,
      global_position: global_position,
      type: "projected",
      data: %{"value" => "v"},
      metadata: %{},
      timestamp: @timestamp
    }

    %Event{event | operation_fingerprint: EventLog.event_fingerprint("stream", event)}
  end

  defp positioned_with_external_size(id, event_number, global_position, target_bytes) do
    id
    |> positioned(event_number, global_position)
    |> then(fn %Event{} = event -> %Event{event | data: %{"blob" => ""}} end)
    |> resize_event(target_bytes)
    |> then(fn %Event{} = event ->
      %Event{event | operation_fingerprint: EventLog.event_fingerprint("stream", event)}
    end)
  end

  defp resize_event(%Event{} = event, target_bytes) do
    difference = target_bytes - :erlang.external_size(event)

    cond do
      difference == 0 ->
        event

      difference > 0 ->
        blob = event.data["blob"] <> String.duplicate("x", difference)
        resize_event(%Event{event | data: %{"blob" => blob}}, target_bytes)

      true ->
        blob = event.data["blob"]
        keep = byte_size(blob) + difference
        resize_event(%Event{event | data: %{"blob" => binary_part(blob, 0, keep)}}, target_bytes)
    end
  end
end
