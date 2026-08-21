defmodule Arbor.Persistence.EventLog.ETSProjectionTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.ETS

  @timestamp ~U[2026-08-21 00:00:00.000000Z]

  setup do
    {:ok, name: start_projection()}
  end

  describe "startup" do
    test "mode defaults to authoritative and projection starts on its own", %{name: name} do
      assert {:ok, :projection} = ETS.mode(name: name)

      authoritative = unique_name("el_auth")
      start_supervised!({ETS, name: authoritative}, id: authoritative)
      assert {:ok, :authoritative} = ETS.mode(name: authoritative)
    end

    test "any other mode refuses to start" do
      Process.flag(:trap_exit, true)
      name = unique_name("el_bad_mode")

      assert {:error, {{:invalid_event_log_mode, :read_only}, _}} =
               start_supervised({ETS, name: name, mode: :read_only}, id: name)
    end
  end

  describe "project_committed_events/2" do
    test "preserves exact positions and fingerprints without assigning any", %{name: name} do
      events = [
        event(id: "evt_a", stream_id: "alpha", event_number: 7, global_position: 41),
        event(id: "evt_b", stream_id: "beta", event_number: 2, global_position: 42)
      ]

      assert {:ok, %{projected: 2, skipped: 0}} = ETS.project_committed_events(events, name: name)

      assert {:ok, [alpha]} = ETS.read_stream("alpha", name: name)
      assert alpha.event_number == 7
      assert alpha.global_position == 41
      assert alpha.operation_fingerprint == EventLog.event_fingerprint("alpha", alpha)

      assert {:ok, 7} = ETS.resident_stream_version("alpha", name: name)
      assert {:ok, 2} = ETS.resident_stream_version("beta", name: name)
      assert {:ok, 2} = ETS.event_count(name: name)
    end

    test "is byte-identically idempotent", %{name: name} do
      events = [event(id: "evt_a", event_number: 1, global_position: 1)]

      assert {:ok, %{projected: 1, skipped: 0}} = ETS.project_committed_events(events, name: name)
      assert {:ok, %{projected: 0, skipped: 1}} = ETS.project_committed_events(events, name: name)
      assert {:ok, %{projected: 0, skipped: 1}} = ETS.project_committed_events(events, name: name)

      assert {:ok, 1} = ETS.event_count(name: name)
    end

    test "distinguishes event-id, global-position, and stream-position conflicts", %{name: name} do
      assert {:ok, _} =
               ETS.project_committed_events(
                 [event(id: "evt_a", event_number: 1, global_position: 1)],
                 name: name
               )

      same_id_other_content =
        event(id: "evt_a", event_number: 1, global_position: 1, data: %{"value" => "changed"})

      assert {:error, :event_id_conflict} =
               ETS.project_committed_events([same_id_other_content], name: name)

      assert {:error, :global_position_conflict} =
               ETS.project_committed_events(
                 [event(id: "evt_b", event_number: 2, global_position: 1)],
                 name: name
               )

      assert {:error, :stream_position_conflict} =
               ETS.project_committed_events(
                 [event(id: "evt_c", event_number: 1, global_position: 2)],
                 name: name
               )
    end

    test "rejects events without exact positive positions", %{name: name} do
      assert {:error, :invalid_projection_events} =
               ETS.project_committed_events(
                 [event(id: "evt_a", event_number: 0, global_position: 1)],
                 name: name
               )

      assert {:error, :invalid_projection_events} =
               ETS.project_committed_events(
                 [event(id: "evt_a", event_number: 1, global_position: 0)],
                 name: name
               )

      assert {:ok, 0} = ETS.event_count(name: name)
    end

    test "bounds one batch to 1000 events", %{name: name} do
      over_limit =
        for n <- 1..1_001, do: event(id: "evt_#{n}", event_number: n, global_position: n)

      assert {:error, :projection_batch_too_large} =
               ETS.project_committed_events(over_limit, name: name)

      assert {:ok, 0} = ETS.event_count(name: name)
    end

    test "refuses a batch that would exceed the resident ceiling" do
      name = start_projection(max_events: 2)

      batch =
        for n <- 1..3, do: event(id: "evt_#{n}", event_number: n, global_position: n)

      assert {:error, :projection_capacity_exceeded} =
               ETS.project_committed_events(batch, name: name)

      assert {:ok, 0} = ETS.event_count(name: name)

      assert {:ok, %{projected: 2}} =
               ETS.project_committed_events(Enum.take(batch, 2), name: name)
    end
  end

  describe "resident-only metadata and reads" do
    test "counts, lists, and existence describe resident rows only", %{name: name} do
      assert {:ok, []} = ETS.list_streams(name: name)
      assert {:ok, 0} = ETS.stream_count(name: name)
      assert {:ok, 0} = ETS.event_count(name: name)
      refute ETS.stream_exists?("alpha", name: name)

      assert {:ok, _} =
               ETS.project_committed_events(
                 [event(id: "evt_a", stream_id: "alpha", event_number: 9, global_position: 900)],
                 name: name
               )

      assert {:ok, ["alpha"]} = ETS.list_streams(name: name)
      assert {:ok, 1} = ETS.stream_count(name: name)
      # Resident row count, not the observed durable high-water mark of 900.
      assert {:ok, 1} = ETS.event_count(name: name)
      assert ETS.stream_exists?("alpha", name: name)
    end

    test "read_stream_head reports unavailable instead of projecting a head", %{name: name} do
      assert {:error, :head_unavailable} = ETS.read_stream_head("alpha", name: name)

      assert {:ok, _} =
               ETS.project_committed_events(
                 [event(id: "evt_a", stream_id: "alpha", event_number: 1, global_position: 1)],
                 name: name
               )

      assert {:error, :head_unavailable} = ETS.read_stream_head("alpha", name: name)
    end

    test "identity history is never complete", %{name: name} do
      assert {:ok, {:identity_history_unavailable, %{reason: :projection_mode}}} =
               ETS.identity_history_status(name: name)

      assert {:ok, _} =
               ETS.project_committed_events(
                 [event(id: "evt_a", event_number: 1, global_position: 1)],
                 name: name
               )

      assert {:ok, {:identity_history_unavailable, %{reason: :projection_mode}}} =
               ETS.identity_history_status(name: name)
    end
  end

  describe "retention" do
    test "eviction removes all five surfaces and permits safe re-projection" do
      name = start_projection(max_age_ms: 0, trim_interval_ms: :disabled)
      events = [event(id: "evt_a", event_number: 1, global_position: 1)]

      assert {:ok, %{projected: 1}} = ETS.project_committed_events(events, name: name)
      assert identity_state(name, "stream", "evt_a") == :resident

      trim(name)

      assert {:ok, 0} = ETS.event_count(name: name)
      assert {:ok, []} = ETS.read_stream("stream", name: name)
      assert identity_state(name, "stream", "evt_a") == :not_resident
      assert {:ok, []} = ETS.list_streams(name: name)
      refute ETS.stream_exists?("stream", name: name)

      # The same durable event may be projected again at its exact position.
      assert {:ok, %{projected: 1, skipped: 0}} =
               ETS.project_committed_events(events, name: name)

      assert {:ok, 1} = ETS.event_count(name: name)
    end

    test "partial eviction keeps stream metadata for the surviving rows" do
      name = start_projection(max_age_ms: 60_000, trim_interval_ms: :disabled)

      old = event(id: "evt_old", event_number: 1, global_position: 1, timestamp: @timestamp)

      fresh =
        event(
          id: "evt_fresh",
          event_number: 2,
          global_position: 2,
          timestamp: DateTime.utc_now()
        )

      assert {:ok, %{projected: 2}} = ETS.project_committed_events([old, fresh], name: name)

      trim(name)

      assert {:ok, 1} = ETS.event_count(name: name)
      assert {:ok, ["stream"]} = ETS.list_streams(name: name)
      assert {:ok, 2} = ETS.resident_stream_version("stream", name: name)
      assert identity_state(name, "stream", "evt_old") == :not_resident
      assert identity_state(name, "stream", "evt_fresh") == :resident
    end

    test "evicting the highest resident event number lowers the reported stream version" do
      name = start_projection(max_age_ms: 60_000, trim_interval_ms: :disabled)

      # Global order and stream order disagree: the stream head sits at the
      # lowest global position, so retention evicts it first.
      head =
        event(id: "evt_head", event_number: 9, global_position: 1, timestamp: @timestamp)

      tail =
        event(
          id: "evt_tail",
          event_number: 4,
          global_position: 2,
          timestamp: DateTime.utc_now()
        )

      assert {:ok, %{projected: 2}} = ETS.project_committed_events([head, tail], name: name)
      assert {:ok, 9} = ETS.resident_stream_version("stream", name: name)

      trim(name)

      assert {:ok, 1} = ETS.event_count(name: name)
      assert {:ok, ["stream"]} = ETS.list_streams(name: name)
      # Resident-only: version 9 is gone, so the projection must report 4.
      assert {:ok, 4} = ETS.resident_stream_version("stream", name: name)
    end
  end

  describe "batch atomicity" do
    test "a conflicting third event leaves all five ETS surfaces unchanged", %{name: name} do
      assert {:ok, %{projected: 1}} =
               ETS.project_committed_events(
                 [event(id: "evt_a", event_number: 1, global_position: 1)],
                 name: name
               )

      batch = [
        event(id: "evt_b", event_number: 2, global_position: 2),
        event(id: "evt_c", event_number: 3, global_position: 3),
        # Third event collides with the already-resident global position 1.
        event(id: "evt_d", event_number: 4, global_position: 1)
      ]

      assert {:error, :global_position_conflict} =
               ETS.project_committed_events(batch, name: name)

      # Payload and stream-pointer surfaces: only the original event survives.
      assert {:ok, 1} = ETS.event_count(name: name)
      assert {:ok, [resident]} = ETS.read_stream("stream", name: name)
      assert resident.id == "evt_a"
      assert {:ok, 1} = ETS.resident_stream_version("stream", name: name)

      # Identity surface: neither rejected event left a tombstone.
      assert identity_state(name, "stream", "evt_b") == :not_resident
      assert identity_state(name, "stream", "evt_c") == :not_resident

      # Identity-position and identity-stream-position surfaces: a surviving row
      # at position 2 or 3 would turn this into a conflict rather than a clean
      # projection of both events.
      assert {:ok, %{projected: 2, skipped: 0}} =
               ETS.project_committed_events(Enum.take(batch, 2), name: name)
    end
  end

  test "projection assigns no positions and tracks observation separately", %{name: name} do
    assert {:ok, status} = ETS.projection_status(name: name)

    assert status == %{
             global_position: 0,
             observed_global_position: 0,
             resident_events: 0,
             resident_streams: 0
           }

    assert {:ok, _} =
             ETS.project_committed_events(
               [event(id: "evt_a", event_number: 3, global_position: 5_000)],
               name: name
             )

    assert {:ok, status} = ETS.projection_status(name: name)
    # The projection's own position counter never advances; 5000 is only observed.
    assert status.global_position == 0
    assert status.observed_global_position == 5_000
    assert status.resident_events == 1
    assert status.resident_streams == 1
  end

  test "projection_status is refused by an authoritative log" do
    name = unique_name("el_auth_status")
    start_supervised!({ETS, name: name}, id: name)

    assert {:error, :projection_mode_required} = ETS.projection_status(name: name)
  end

  test "projection purge is rejected without mutating resident rows", %{name: name} do
    assert {:ok, _} =
             ETS.project_committed_events(
               [
                 event(id: "evt_a", stream_id: "alpha", event_number: 1, global_position: 1),
                 event(id: "evt_b", stream_id: "beta", event_number: 1, global_position: 2)
               ],
               name: name
             )

    assert {:error, :purge_not_supported} = ETS.purge_stream("alpha", name: name)

    assert {:ok, ["alpha", "beta"]} = ETS.list_streams(name: name)
    assert {:ok, 2} = ETS.event_count(name: name)
    assert identity_state(name, "alpha", "evt_a") == :resident

    assert {:ok, %{projected: 0, skipped: 1}} =
             ETS.project_committed_events(
               [event(id: "evt_a", stream_id: "alpha", event_number: 1, global_position: 1)],
               name: name
             )
  end

  test "projection eviction removes all five surfaces and is idempotent", %{name: name} do
    alpha =
      event(id: "evt_a", stream_id: "alpha", event_number: 7, global_position: 41)

    beta =
      event(id: "evt_b", stream_id: "beta", event_number: 2, global_position: 42)

    assert {:ok, %{projected: 2}} =
             ETS.project_committed_events([alpha, beta], name: name)

    assert {:ok, %{evicted: 1}} = ETS.evict_projected_stream("alpha", name: name)
    assert {:ok, %{evicted: 0}} = ETS.evict_projected_stream("alpha", name: name)

    assert {:ok, [^beta]} = ETS.read_stream("beta", name: name)
    assert {:ok, []} = ETS.read_stream("alpha", name: name)
    assert {:ok, ["beta"]} = ETS.list_streams(name: name)
    assert {:ok, 0} = ETS.resident_stream_version("alpha", name: name)
    assert identity_state(name, "alpha", "evt_a") == :not_resident

    # Clean re-projection at the same ID and both exact positions proves that
    # identity, global-position, stream-position, pointer, and payload surfaces
    # were all evicted.
    assert {:ok, %{projected: 1, skipped: 0}} =
             ETS.project_committed_events([alpha], name: name)
  end

  # --- helpers ---

  defp start_projection(opts \\ []) do
    name = unique_name("el_projection")
    start_supervised!({ETS, Keyword.merge([name: name, mode: :projection], opts)}, id: name)
    name
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{prefix}_#{:erlang.unique_integer([:positive])}"
  end

  defp trim(name) do
    send(name, :trim_old_events)
    # One synchronous call after the cast-like message flushes the mailbox.
    {:ok, _count} = ETS.event_count(name: name)
    :ok
  end

  # A projection never asserts absence, so a missing identity row surfaces as
  # `:identity_history_unavailable` rather than a confident `{:ok, nil}`.
  defp identity_state(name, stream_id, event_id) do
    case ETS.event_identity(stream_id, event_id, name: name) do
      {:ok, fingerprint} when is_binary(fingerprint) -> :resident
      {:error, :identity_history_unavailable} -> :not_resident
      other -> other
    end
  end

  defp event(opts) do
    stream_id = Keyword.get(opts, :stream_id, "stream")

    event = %Event{
      id: Keyword.fetch!(opts, :id),
      stream_id: stream_id,
      event_number: Keyword.fetch!(opts, :event_number),
      global_position: Keyword.fetch!(opts, :global_position),
      type: Keyword.get(opts, :type, "projected"),
      data: Keyword.get(opts, :data, %{"value" => "v"}),
      metadata: %{},
      timestamp: Keyword.get(opts, :timestamp, @timestamp)
    }

    %Event{event | operation_fingerprint: EventLog.event_fingerprint(stream_id, event)}
  end
end
