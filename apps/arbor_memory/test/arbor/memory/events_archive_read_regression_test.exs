defmodule Arbor.Memory.EventsArchiveReadRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.Events
  alias Arbor.Memory.Test.DurableEventLog
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast

  defmodule ProbeEventLog do
    @moduledoc false

    def stream_version(_stream_id, opts) do
      notify(opts, :stream_version)
      Keyword.get(opts, :probe_version_reply, {:ok, 0})
    end

    def read_stream_range(_stream_id, opts) do
      notify(opts, :read_stream_range)
      Keyword.get(opts, :probe_range_reply, {:ok, []})
    end

    def event_identity(_stream_id, event_id, opts) do
      identities = Keyword.get(opts, :probe_identities, %{})
      {:ok, Map.get(identities, event_id)}
    end

    defp notify(opts, operation) do
      if probe_pid = Keyword.get(opts, :probe_pid) do
        send(probe_pid, {:archive_read_probe, Keyword.get(opts, :probe_ref), operation, opts})
      end
    end
  end

  defmodule RaisingEventLog do
    @moduledoc false
    def stream_version(_stream_id, _opts), do: raise("secret database exception")
  end

  defmodule ExitingEventLog do
    @moduledoc false
    def stream_version(_stream_id, _opts), do: exit({:secret_database_exit, "credential"})
  end

  defmodule RawEctoErrorEventLog do
    @moduledoc false

    def stream_version(_stream_id, _opts) do
      {:error, {:read_failed, %RuntimeError{message: "secret Ecto error"}}}
    end
  end

  test "source range reads retain the bounded caller page and override target offsets" do
    agent_id = unique_id("bounded_sources")
    probe_ref = make_ref()
    base = ~U[2026-08-05 12:00:00Z]

    events =
      for number <- 20..14//-1 do
        Event.new(
          stream_id(agent_id),
          "knowledge_archived",
          %{"sequence" => number},
          id: unique_id("probe_event"),
          event_number: number,
          timestamp: DateTime.add(base, number, :second)
        )
      end

    lease_probe_target(probe_ref,
      probe_version_reply: {:ok, 20},
      probe_range_reply: {:ok, events},
      limit: 700,
      from: 700,
      to: 700,
      direction: :forward
    )

    assert {:ok, page} =
             Events.get_history_page(agent_id, limit: 7, direction: :backward)

    assert Enum.map(page.events, & &1.event_number) == Enum.to_list(20..14//-1)

    assert_receive {:archive_read_probe, ^probe_ref, :stream_version, _head_opts}
    assert_receive {:archive_read_probe, ^probe_ref, :read_stream_range, durable_opts}
    assert Keyword.get(durable_opts, :limit) == 7
    assert Keyword.get(durable_opts, :from) == 1
    assert Keyword.get(durable_opts, :to) == 20
    assert Keyword.get(durable_opts, :direction) == :backward
  end

  test "read limits are capped and scalar cross-source offsets fail before dispatch" do
    agent_id = unique_id("bounded_options")
    probe_ref = make_ref()
    base = ~U[2026-08-05 12:00:00Z]

    events =
      for number <- 1..1_000 do
        Event.new(
          stream_id(agent_id),
          "knowledge_archived",
          %{"sequence" => number},
          id: unique_id("capped_event"),
          event_number: number,
          timestamp: DateTime.add(base, number, :second)
        )
      end

    lease_probe_target(probe_ref,
      probe_version_reply: {:ok, 2_000},
      probe_range_reply: {:ok, events}
    )

    assert {:ok, %{events: capped, next_cursor: next_cursor}} =
             Events.get_history_page(agent_id, limit: 10_000)

    assert length(capped) == 1_000
    assert not is_nil(next_cursor)
    assert_receive {:archive_read_probe, ^probe_ref, :stream_version, _head_opts}
    assert_receive {:archive_read_probe, ^probe_ref, :read_stream_range, range_opts}
    assert Keyword.get(range_opts, :limit) == 1_000

    for invalid_opts <- [
          [limit: 0],
          [limit: -1],
          [limit: "many"],
          [from: 1],
          [direction: :sideways],
          [unknown: true],
          [{:limit, 1} | :improper]
        ] do
      assert {:error, :invalid_archive_read_options} =
               Events.get_history_page(agent_id, invalid_opts)
    end

    refute_receive {:archive_read_probe, ^probe_ref, _operation, _opts}
  end

  test "legacy first-page helpers retain source order and recent direction" do
    agent_id = unique_id("legacy_order")
    lease_probe_target(make_ref())
    base = ~U[2026-08-05 12:00:00Z]

    ids =
      for number <- 1..5 do
        event =
          archive_event(agent_id, "legacy-#{number}",
            timestamp: DateTime.add(base, 10 - number, :second),
            data: %{"sequence" => number}
          )

        append_legacy!(event).id
      end

    assert {:ok, forward} = Events.get_history(agent_id, limit: 2)
    assert Enum.map(forward, & &1.id) == Enum.take(ids, 2)

    assert {:ok, backward} = Events.get_history(agent_id, direction: :backward, limit: 2)
    assert Enum.map(backward, & &1.id) == ids |> Enum.reverse() |> Enum.take(2)

    assert {:ok, recent} = Events.get_recent(agent_id, 2)
    assert Enum.map(recent, & &1.id) == Enum.take(ids, -2)
  end

  test "typed pages scan a bounded page for matches in either direction" do
    lease_probe_target(make_ref())
    base = ~U[2026-08-05 12:00:00Z]

    forward_agent = unique_id("typed_forward")

    for number <- 1..4 do
      append_legacy!(ordinary_event(forward_agent, number, DateTime.add(base, number, :second)))
    end

    forward_archive =
      forward_agent
      |> archive_event(unique_id("forward_archive"), timestamp: DateTime.add(base, 5, :second))
      |> append_legacy!()

    assert {:ok, [%Event{id: forward_id}]} =
             Events.get_by_type(forward_agent, :knowledge_archived, limit: 1)

    assert forward_id == forward_archive.id

    backward_agent = unique_id("typed_backward")

    backward_archive =
      backward_agent
      |> archive_event(unique_id("backward_archive"), timestamp: base)
      |> append_legacy!()

    for number <- 1..4 do
      append_legacy!(ordinary_event(backward_agent, number, DateTime.add(base, number, :second)))
    end

    assert {:ok, [%Event{id: backward_id}]} =
             Events.get_by_type(backward_agent, :knowledge_archived,
               direction: :backward,
               limit: 1
             )

    assert backward_id == backward_archive.id
  end

  test "snapshot cursors reach more than 1000 legacy and durable events in both directions" do
    %{target: target} = DurableEventLog.start!()
    agent_id = unique_id("large_snapshot")
    base = ~U[2026-08-05 12:00:00Z]

    legacy_events =
      for number <- 1..1_005 do
        archive_event(agent_id, "legacy-page-#{number}",
          timestamp: DateTime.add(base, number, :second),
          data: %{"source" => "legacy", "sequence" => number}
        )
      end

    durable_events =
      for number <- 1..11 do
        archive_event(agent_id, "durable-page-#{number}",
          timestamp: DateTime.add(base, 2_000 + number, :second),
          data: %{"source" => "durable", "sequence" => number}
        )
      end

    legacy_ids = append_legacy_batch!(legacy_events)
    durable_ids = append_target_batch!(target, durable_events)
    expected = legacy_ids ++ durable_ids

    forward = collect_history_pages(agent_id, :forward, 137)
    backward = collect_history_pages(agent_id, :backward, 131)

    assert forward == expected
    assert backward == Enum.reverse(expected)
    assert length(Enum.uniq(forward)) == 1_016
    assert {:ok, 1_016} = Events.count_by_type(agent_id, :knowledge_archived)
  end

  test "cursor high-water marks exclude writes appended after the first page" do
    DurableEventLog.start!()
    agent_id = unique_id("snapshot_high_water")
    base = ~U[2026-08-05 12:00:00Z]

    initial_ids =
      1..3
      |> Enum.map(fn number ->
        archive_event(agent_id, "snapshot-#{number}",
          timestamp: DateTime.add(base, number, :second)
        )
      end)
      |> append_legacy_batch!()

    assert {:ok, %{events: first, next_cursor: cursor}} =
             Events.get_history_page(agent_id, limit: 2)

    late =
      agent_id
      |> archive_event("snapshot-late", timestamp: DateTime.add(base, 10, :second))
      |> append_legacy!()

    remaining = collect_history_pages(agent_id, :forward, 2, cursor)

    assert Enum.map(first, & &1.id) ++ remaining == initial_ids
    refute late.id in remaining
  end

  test "legacy identity is global authority for equal cross-source duplicates" do
    %{target: target} = DurableEventLog.start!()
    agent_id = unique_id("equal_identity")
    shared_id = unique_id("shared_event")
    timestamp = ~U[2026-08-05 12:00:00Z]

    shared =
      archive_event(agent_id, shared_id,
        timestamp: timestamp,
        data: %{"same" => true}
      )

    append_legacy!(shared)

    predecessor =
      append_target!(
        target,
        archive_event(agent_id, unique_id("durable_predecessor"),
          timestamp: DateTime.add(timestamp, -1, :second)
        )
      )

    append_target!(target, shared)

    assert {:ok, events} = Events.get_history(agent_id, limit: 10)
    assert Enum.count(events, &(&1.id == shared_id)) == 1
    assert Enum.map(events, & &1.id) == [shared_id, predecessor.id]
    assert {:ok, 2} = Events.count_by_type(agent_id, :knowledge_archived)
  end

  test "a conflicting same ID is detected without counterpart page overlap" do
    %{target: target} = DurableEventLog.start!()
    agent_id = unique_id("identity_conflict")
    shared_id = unique_id("conflicting_event")
    timestamp = ~U[2026-08-05 12:00:00Z]

    append_legacy!(
      archive_event(agent_id, shared_id,
        timestamp: timestamp,
        data: %{"version" => "legacy"}
      )
    )

    predecessors =
      for number <- 1..1_000 do
        archive_event(agent_id, "conflict-prefix-#{number}",
          timestamp: DateTime.add(timestamp, number, :second)
        )
      end

    append_target_batch!(target, predecessors)

    append_target!(
      target,
      archive_event(agent_id, shared_id,
        timestamp: timestamp,
        data: %{"version" => "durable"}
      )
    )

    assert {:error, :archive_event_conflict} =
             Events.get_history_page(agent_id, limit: 1, direction: :forward)
  end

  test "count_by_type traverses every bounded page instead of returning a capped count" do
    DurableEventLog.start!()
    agent_id = unique_id("exact_count")
    base = ~U[2026-08-05 12:00:00Z]

    events =
      for number <- 1..1_007 do
        ordinary_event(agent_id, number, DateTime.add(base, number, :second))
      end

    append_legacy_batch!(events)

    assert {:ok, 1_007} = Events.count_by_type(agent_id, :identity_changed)
    assert {:ok, 0} = Events.count_by_type(agent_id, :knowledge_archived)
  end

  test "backend exceptions, exits, and raw Ecto errors are redacted to one public atom" do
    agent_id = unique_id("redacted_errors")

    for backend <- [RaisingEventLog, ExitingEventLog, RawEctoErrorEventLog] do
      DurableEventLog.lease_target!(%{
        name: unique_name(:failing_archive_target),
        backend: backend,
        opts: []
      })

      assert {:error, :archive_read_unavailable} = Events.get_history(agent_id)
    end
  end

  defp lease_probe_target(probe_ref, target_opts \\ []) do
    DurableEventLog.lease_target!(%{
      name: unique_name(:archive_read_probe),
      backend: ProbeEventLog,
      opts: Keyword.merge([probe_pid: self(), probe_ref: probe_ref], target_opts)
    })
  end

  defp collect_history_pages(agent_id, direction, limit, cursor \\ nil, events \\ []) do
    opts = [direction: direction, limit: limit]
    opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    assert {:ok, page} = Events.get_history_page(agent_id, opts)
    ids = Enum.map(page.events, & &1.id)
    events = events ++ ids

    case page.next_cursor do
      nil -> events
      ^cursor -> flunk("archive cursor did not advance")
      next_cursor -> collect_history_pages(agent_id, direction, limit, next_cursor, events)
    end
  end

  defp archive_event(agent_id, id, opts) do
    Event.new(
      stream_id(agent_id),
      "knowledge_archived",
      Keyword.get(opts, :data, %{"agent_id" => agent_id}),
      id: id,
      timestamp: Keyword.fetch!(opts, :timestamp)
    )
  end

  defp ordinary_event(agent_id, number, timestamp) do
    Event.new(
      stream_id(agent_id),
      "identity_changed",
      %{"sequence" => number},
      id: "ordinary-#{agent_id}-#{number}",
      timestamp: timestamp
    )
  end

  defp append_legacy!(event) do
    assert {:ok, [persisted]} =
             Persistence.append(:memory_events, ETS, event.stream_id, event)

    persisted
  end

  defp append_legacy_batch!(events) do
    events
    |> Enum.chunk_every(1_000)
    |> Enum.flat_map(fn chunk ->
      assert {:ok, persisted} =
               Persistence.append(:memory_events, ETS, hd(chunk).stream_id, chunk)

      Enum.map(persisted, & &1.id)
    end)
  end

  defp append_target!(target, event) do
    assert {:ok, [persisted]} =
             Persistence.append(
               target.name,
               target.backend,
               event.stream_id,
               event,
               target.opts
             )

    persisted
  end

  defp append_target_batch!(target, events) do
    events
    |> Enum.chunk_every(1_000)
    |> Enum.flat_map(fn chunk ->
      assert {:ok, persisted} =
               Persistence.append(
                 target.name,
                 target.backend,
                 hd(chunk).stream_id,
                 chunk,
                 target.opts
               )

      Enum.map(persisted, & &1.id)
    end)
  end

  defp stream_id(agent_id), do: "memory:#{agent_id}"
  defp unique_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
