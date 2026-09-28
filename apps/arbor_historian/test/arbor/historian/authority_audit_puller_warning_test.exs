defmodule Arbor.Historian.AuthorityAuditPullerWarningTest do
  @moduledoc """
  The authority audit puller reports stuck operations (Floor-and-Ledger v3,
  slice 4e): an operation whose committed EventLog content conflicts, whose
  stream cannot be read back exactly, or whose acknowledgement the journal
  answers `:audit_content_conflict` stays `effect_applied`, is retried every
  poll and is never retired. Each stuck episode is logged and signalled once,
  not on every 250 ms poll.

  On the parent 52a2cc3fa the puller is silent for all three (no warning, no
  telemetry): the operation is simply counted as pending.

  Uses a Security double through Historian's configured `:security_module`
  seam and a node-restart-reporting wrapper around the ETS EventLog backend;
  the real SQL sink lanes are in
  `authority_audit_retirement_database_test.exs` and
  `authority_audit_retirement_peer_restart_test.exs`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Historian
  alias Arbor.Historian.AuthorityAuditPuller
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @conflict_event [:arbor, :historian, :authority_audit, :conflict]

  defmodule FakeSecurity do
    @moduledoc false
    # Security facade double: the delivery batch and per-operation ACK
    # answers live in an Agent owned by the test.
    def reconcile_authority_audit, do: :ok

    def authority_audit_delivery_batch,
      do: {:ok, Agent.get(__MODULE__, fn state -> Enum.map(state.batch, & &1.item) end)}

    def acknowledge_authority_audit(id, _digest) do
      Agent.get_and_update(__MODULE__, fn state ->
        answer = Map.get(state.ack_answers, id, {:ok, :committed})
        {answer, %{state | acked: [id | state.acked]}}
      end)
    end
  end

  defmodule NodeRestartETS do
    @moduledoc false
    # The ETS EventLog reporting node-restart durability so the puller's
    # content path runs; selected streams answer a read error.
    def durability_class(_opts), do: :node_restart

    def read_stream(stream_id, opts) do
      if stream_id in :persistent_term.get({__MODULE__, :unreadable}, []),
        do: {:error, :injected_read_failure},
        else: ETS.read_stream(stream_id, opts)
    end

    def append(stream_id, events, opts), do: ETS.append(stream_id, events, opts)
  end

  setup do
    name = :"authority_audit_puller_warning_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})

    start_supervised!(%{
      id: FakeSecurity,
      start:
        {Agent, :start_link,
         [fn -> %{batch: [], ack_answers: %{}, acked: []} end, [name: FakeSecurity]]}
    })

    old_target = Application.fetch_env(:arbor_historian, :durable_event_log_target)
    old_security = Application.fetch_env(:arbor_historian, :security_module)

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: name,
      backend: NodeRestartETS,
      opts: []
    })

    Application.put_env(:arbor_historian, :security_module, FakeSecurity)

    handler = "authority-audit-puller-warning-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @conflict_event,
        fn _event, measurements, metadata, pid ->
          send(pid, {:conflict, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      :persistent_term.erase({NodeRestartETS, :unreadable})
      restore_env(:durable_event_log_target, old_target)
      restore_env(:security_module, old_security)
    end)

    start_supervised!({AuthorityAuditPuller, poll_interval_ms: 60_000})
    %{name: name}
  end

  test "stuck operations are logged and signalled once per episode, with reason and source",
       %{name: name} do
    conflict = op(1)
    unreadable = op(2)
    journal_conflict = op(3)
    healthy = op(4)

    # A conflicting row already holds the conflict operation's id.
    bad = Event.new(conflict.stream, "capability_granted", %{"wrong" => "body"}, id: conflict.id)
    assert {:ok, [_]} = Persistence.append(name, ETS, conflict.stream, bad, [])
    :persistent_term.put({NodeRestartETS, :unreadable}, [unreadable.stream])
    answer(journal_conflict.id, {:error, :audit_content_conflict})
    set_batch([conflict, unreadable, journal_conflict, healthy])

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 1, pending: 3}} = Historian.flush_authority_audit()
      end)

    assert log =~ "stuck for 3 newly affected operation(s) (3 stuck in total)"
    assert log =~ "#{conflict.id} (audit_content_conflict, event_log)"
    assert log =~ "#{unreadable.id} (audit_content_unavailable, event_log)"
    assert log =~ "#{journal_conflict.id} (audit_content_conflict, journal)"
    refute log =~ healthy.id

    assert Enum.sort(drain()) ==
             Enum.sort([
               {conflict.id, :audit_content_conflict, :event_log},
               {unreadable.id, :audit_content_unavailable, :event_log},
               {journal_conflict.id, :audit_content_conflict, :journal}
             ])

    # The healthy operation was acknowledged; the stuck ones stay pending and
    # are retried on every pass, without repeating the report.
    set_batch([conflict, unreadable, journal_conflict])

    log =
      capture_log(fn ->
        for _ <- 1..3 do
          assert {:ok, %{delivered: 0, pending: 3}} = Historian.flush_authority_audit()
        end
      end)

    refute log =~ "stuck"
    assert drain() == []

    # An operation that leaves the batch is forgotten; its recurrence is a new
    # episode and is reported again (alone).
    set_batch([unreadable, journal_conflict])
    assert {:ok, %{delivered: 0, pending: 2}} = Historian.flush_authority_audit()
    set_batch([conflict, unreadable, journal_conflict])

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 0, pending: 3}} = Historian.flush_authority_audit()
      end)

    assert log =~ "stuck for 1 newly affected operation(s) (3 stuck in total)"
    assert log =~ conflict.id
    assert drain() == [{conflict.id, :audit_content_conflict, :event_log}]

    # A changed reason is a new episode for that operation: the unreadable
    # stream becomes readable, but the journal now refuses its ACK.
    :persistent_term.put({NodeRestartETS, :unreadable}, [])
    answer(unreadable.id, {:error, :audit_content_conflict})

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 0, pending: 3}} = Historian.flush_authority_audit()
      end)

    assert log =~ "stuck for 1 newly affected operation(s) (3 stuck in total)"
    assert log =~ "#{unreadable.id} (audit_content_conflict, journal)"
    assert drain() == [{unreadable.id, :audit_content_conflict, :journal}]

    # Once the journal accepts it, it is delivered and leaves the stuck set.
    answer(unreadable.id, {:ok, :committed})

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 1, pending: 2}} = Historian.flush_authority_audit()
      end)

    refute log =~ "stuck for"
    assert drain() == []
  end

  test "a batch of healthy operations logs nothing and emits no conflict telemetry" do
    set_batch([op(10), op(11)])

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 2, pending: 0}} = Historian.flush_authority_audit()
      end)

    refute log =~ "stuck"
    assert drain() == []
  end

  # ---------------------------------------------------------------------------

  defp op(n) do
    id = :crypto.hash(:sha256, "puller-warning-#{n}") |> Base.encode16(case: :lower)
    stream = "security:authority_mutation:" <> id

    item = %{
      "operation_id" => id,
      "intent_sha256" => String.duplicate("a", 64),
      "event" => %{
        "id" => id,
        "stream_id" => stream,
        "type" => "capability_granted",
        "timestamp" => "2026-09-28T12:00:00Z",
        "agent_id" => "agent_puller_warning",
        "correlation_id" => nil,
        "causation_id" => nil,
        "data" => %{"intent" => %{"operation_id" => id}, "effect" => "applied"},
        "metadata" => %{"audit_source" => "security.authority_journal"}
      }
    }

    %{id: id, stream: stream, item: item}
  end

  defp set_batch(ops), do: Agent.update(FakeSecurity, &%{&1 | batch: ops})

  defp answer(id, reply),
    do: Agent.update(FakeSecurity, &%{&1 | ack_answers: Map.put(&1.ack_answers, id, reply)})

  defp drain(acc \\ []) do
    receive do
      {:conflict, %{count: 1}, %{operation_id: id, reason: reason, source: source}} ->
        drain([{id, reason, source} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_historian, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_historian, key)
end
