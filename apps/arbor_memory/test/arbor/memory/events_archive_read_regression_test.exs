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

    def read_stream(_stream_id, opts) do
      if probe_pid = Keyword.get(opts, :probe_pid) do
        send(probe_pid, {:archive_read_probe, Keyword.get(opts, :probe_ref), opts})
      end

      Keyword.get(opts, :probe_reply, {:ok, []})
    end
  end

  defmodule RaisingEventLog do
    @moduledoc false
    def read_stream(_stream_id, _opts), do: raise("secret database exception")
  end

  defmodule ExitingEventLog do
    @moduledoc false
    def read_stream(_stream_id, _opts), do: exit({:secret_database_exit, "credential"})
  end

  defmodule RawEctoErrorEventLog do
    @moduledoc false

    def read_stream(_stream_id, _opts) do
      {:error, {:read_failed, %RuntimeError{message: "secret Ecto error"}}}
    end
  end

  test "source reads retain a bounded caller page and ETS scan ceiling" do
    agent_id = unique_id("bounded_sources")
    stream_id = stream_id(agent_id)
    probe_ref = make_ref()

    lease_probe_target(probe_ref,
      limit: 700,
      max_scan: 700,
      from: 700,
      direction: :forward
    )

    memory_events = Process.whereis(:memory_events)
    assert is_pid(memory_events)
    :ok = :sys.suspend(memory_events)
    on_exit(fn -> safely_resume(memory_events) end)

    task =
      Task.async(fn ->
        Events.get_history(agent_id, limit: 7, from: 2, direction: :backward)
      end)

    legacy_opts = await_queued_read_opts(memory_events, stream_id)
    assert Keyword.get(legacy_opts, :limit) == 7
    assert Keyword.get(legacy_opts, :max_scan) == 7
    assert Keyword.get(legacy_opts, :from) == 2
    assert Keyword.get(legacy_opts, :direction) == :backward

    :ok = :sys.resume(memory_events)
    assert {:ok, []} = Task.await(task, 1_000)

    assert_receive {:archive_read_probe, ^probe_ref, durable_opts}
    assert Keyword.get(durable_opts, :limit) == 7
    assert Keyword.get(durable_opts, :max_scan) == 7
    assert Keyword.get(durable_opts, :from) == 2
    assert Keyword.get(durable_opts, :direction) == :backward
  end

  test "read limits are capped and malformed options fail before backend dispatch" do
    agent_id = unique_id("bounded_options")
    probe_ref = make_ref()
    lease_probe_target(probe_ref)

    assert {:ok, []} = Events.get_history(agent_id, limit: 10_000)
    assert_receive {:archive_read_probe, ^probe_ref, capped_opts}
    assert Keyword.get(capped_opts, :limit) == 1_000
    assert Keyword.get(capped_opts, :max_scan) == 1_000

    for invalid_opts <- [
          [limit: -1],
          [limit: "many"],
          [from: -1],
          [direction: :sideways],
          [{:limit, 1} | :improper]
        ] do
      assert {:error, :invalid_archive_read_options} =
               Events.get_history(agent_id, invalid_opts)
    end

    refute_receive {:archive_read_probe, ^probe_ref, _opts}
  end

  test "legacy history keeps event-number order across forward, backward, limit, and from" do
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

    assert {:ok, from_forward} = Events.get_history(agent_id, from: 3, limit: 2)
    assert Enum.map(from_forward, & &1.id) == Enum.slice(ids, 2, 2)

    assert {:ok, from_backward} =
             Events.get_history(agent_id, from: 3, direction: :backward, limit: 2)

    assert Enum.map(from_backward, & &1.id) ==
             ids |> Enum.drop(2) |> Enum.reverse() |> Enum.take(2)

    assert {:ok, recent} = Events.get_recent(agent_id, 2)
    assert Enum.map(recent, & &1.id) == Enum.take(ids, -2)
  end

  test "typed archive pages widen within the source cap in both directions" do
    lease_probe_target(make_ref())
    base = ~U[2026-08-05 12:00:00Z]

    forward_agent = unique_id("typed_forward")

    for number <- 1..4 do
      append_legacy!(
        Event.new(
          stream_id(forward_agent),
          "identity_changed",
          %{"sequence" => number},
          id: unique_id("non_archive"),
          timestamp: DateTime.add(base, number, :second)
        )
      )
    end

    forward_archive =
      forward_agent
      |> archive_event(unique_id("forward_archive"),
        timestamp: DateTime.add(base, 5, :second)
      )
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
      append_legacy!(
        Event.new(
          stream_id(backward_agent),
          "identity_changed",
          %{"sequence" => number},
          id: unique_id("non_archive"),
          timestamp: DateTime.add(base, number, :second)
        )
      )
    end

    assert {:ok, [%Event{id: backward_id}]} =
             Events.get_by_type(backward_agent, :knowledge_archived,
               direction: :backward,
               limit: 1
             )

    assert backward_id == backward_archive.id
  end

  test "legacy and exact archives form deterministic source-local epochs" do
    %{target: target} = DurableEventLog.start!()
    agent_id = unique_id("merged_epochs")
    base = ~U[2026-08-05 12:00:00Z]

    legacy_ids =
      for number <- 1..2 do
        agent_id
        |> archive_event("legacy-epoch-#{number}",
          timestamp: DateTime.add(base, 100 - number, :second),
          data: %{"source" => "legacy", "sequence" => number}
        )
        |> append_legacy!()
        |> Map.fetch!(:id)
      end

    durable_ids =
      for number <- 1..2 do
        event =
          archive_event(agent_id, "durable-epoch-#{number}",
            timestamp: DateTime.add(base, number - 100, :second),
            data: %{"source" => "durable", "sequence" => number}
          )

        append_target!(target, event).id
      end

    assert {:ok, forward} = Events.get_history(agent_id, limit: 10)
    assert Enum.map(forward, & &1.id) == legacy_ids ++ durable_ids

    assert {:ok, backward} = Events.get_history(agent_id, direction: :backward, limit: 3)
    assert Enum.map(backward, & &1.id) == Enum.take(Enum.reverse(legacy_ids ++ durable_ids), 3)

    assert {:ok, source_local_from} = Events.get_history(agent_id, from: 2, limit: 10)
    assert Enum.map(source_local_from, & &1.id) == [List.last(legacy_ids), List.last(durable_ids)]

    assert {:ok, recent} = Events.get_recent(agent_id, 3)
    assert Enum.map(recent, & &1.id) == Enum.take(legacy_ids ++ durable_ids, -3)
  end

  test "equal immutable event identities deduplicate even when source positions differ" do
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

    target
    |> append_target!(
      archive_event(agent_id, unique_id("durable_predecessor"),
        timestamp: DateTime.add(timestamp, -1, :second)
      )
    )

    append_target!(target, shared)

    assert {:ok, events} = Events.get_history(agent_id, limit: 10)
    assert Enum.count(events, &(&1.id == shared_id)) == 1
  end

  test "conflicting payloads for one event ID fail the coherent read closed" do
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

    append_target!(
      target,
      archive_event(agent_id, shared_id,
        timestamp: timestamp,
        data: %{"version" => "durable"}
      )
    )

    assert {:error, :archive_event_conflict} = Events.get_history(agent_id, limit: 10)
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

  defp archive_event(agent_id, id, opts) do
    Event.new(
      stream_id(agent_id),
      "knowledge_archived",
      Keyword.get(opts, :data, %{"agent_id" => agent_id}),
      id: id,
      timestamp: Keyword.fetch!(opts, :timestamp)
    )
  end

  defp append_legacy!(event) do
    assert {:ok, [persisted]} =
             Persistence.append(:memory_events, ETS, event.stream_id, event)

    persisted
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

  defp await_queued_read_opts(pid, stream_id, attempts \\ 100)

  defp await_queued_read_opts(_pid, _stream_id, 0), do: flunk("legacy read was not queued")

  defp await_queued_read_opts(pid, stream_id, attempts) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", _from, {:read_stream, ^stream_id, opts}} -> opts
      _other -> nil
    end) ||
      (
        Process.sleep(1)
        await_queued_read_opts(pid, stream_id, attempts - 1)
      )
  end

  defp safely_resume(pid) do
    :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp stream_id(agent_id), do: "memory:#{agent_id}"
  defp unique_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
