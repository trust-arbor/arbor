defmodule Arbor.Persistence.EventLogPublicBoundarySecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Agent, as: AgentEventLog
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.EventLog.ETS

  defmodule DeadlineExtendingBackend do
    @moduledoc false

    def append(stream_id, events, opts) do
      Process.sleep(35)

      AgentEventLog.append(
        stream_id,
        events,
        Keyword.put(opts, :append_timeout_ms, 1_000)
      )
    end
  end

  defmodule DeadlineExtendingETSBackend do
    @moduledoc false

    def append(stream_id, events, opts) do
      Process.sleep(35)

      ETS.append(
        stream_id,
        events,
        Keyword.put(opts, :append_timeout_ms, 1_000)
      )
    end
  end

  defmodule CommitThenRaiseBackend do
    @moduledoc false

    def append(stream_id, events, opts) do
      {:ok, _persisted} = AgentEventLog.append(stream_id, events, opts)
      raise "simulated reply-path failure after commit"
    end

    def reconcile_append(operation, opts) do
      AgentEventLog.reconcile_append(operation, opts)
    end
  end

  defmodule ReconcileDispatchSpy do
    @moduledoc false

    def reconcile_append(_operation, opts) do
      send(Keyword.fetch!(opts, :test_pid), :reconcile_backend_dispatched)
      {:ok, :absent}
    end
  end

  setup do
    name = :"event_log_public_deadline_#{System.unique_integer([:positive])}"
    ets_name = :"event_log_public_ets_deadline_#{System.unique_integer([:positive])}"
    start_supervised!({AgentEventLog, name: name})
    start_supervised!({ETS, name: ets_name})
    {:ok, name: name, ets_name: ets_name}
  end

  test "security regression: facade validation and backend delegation cannot restart the deadline",
       %{name: name} do
    event = Event.new("public-deadline", "must-not-commit", %{})

    assert {:error, {:append_indeterminate, _operation}} =
             Persistence.append(name, DeadlineExtendingBackend, "public-deadline", event,
               append_timeout_ms: 10
             )

    assert {:ok, 0} = AgentEventLog.stream_version("public-deadline", name: name)
    refute AgentEventLog.stream_exists?("public-deadline", name: name)
  end

  test "security regression: the public deadline cannot restart before ETS delegation", %{
    ets_name: name
  } do
    event = Event.new("public-ets-deadline", "must-not-commit", %{})

    assert {:error, {:append_indeterminate, _operation}} =
             Persistence.append(name, DeadlineExtendingETSBackend, "public-ets-deadline", event,
               append_timeout_ms: 10
             )

    assert {:ok, 0} = ETS.stream_version("public-ets-deadline", name: name)
    refute ETS.stream_exists?("public-ets-deadline", name: name)
  end

  test "security regression: malformed authorization opts are rejected before authorization", %{
    name: name
  } do
    event = Event.new("invalid-auth-opts", "event", %{})

    assert {:error, :invalid_options} =
             Persistence.authorize_append(
               "agent_untrusted",
               name,
               AgentEventLog,
               "invalid-auth-opts",
               event,
               [{:trace_id, "trace"} | :improper]
             )
  end

  test "security regression: a backend exception after commit remains reconcilable", %{
    name: name
  } do
    stream_id = "facade-commit-then-raise"
    event = Event.new(stream_id, "arbor.review.ordinary", %{value: 1})

    assert {:error, {:append_indeterminate, operation}} =
             Persistence.append(name, CommitThenRaiseBackend, stream_id, event)

    assert {:ok, 1} = AgentEventLog.stream_version(stream_id, name: name)

    assert {:ok, {:committed, [%Event{id: committed_id}]}} =
             Persistence.reconcile_append(name, CommitThenRaiseBackend, operation)

    assert committed_id == event.id
  end

  test "security regression: public strings are valid UTF-8 and fit every backend schema", %{
    name: name,
    ets_name: ets_name
  } do
    event = Event.new("bounded", "arbor.review.ordinary", %{value: 1})

    for {backend, backend_name} <- [{AgentEventLog, name}, {ETS, ets_name}],
        invalid_stream <- [String.duplicate("s", 256), <<255>>] do
      assert {:error, :invalid_stream_id} =
               Persistence.append(backend_name, backend, invalid_stream, event)
    end

    oversized_type = %Event{event | type: String.duplicate("t", 256)}

    assert {:error, :invalid_events} =
             Persistence.append(name, AgentEventLog, "bounded", oversized_type)

    assert {:ok, 0} = AgentEventLog.stream_version("bounded", name: name)
  end

  test "security regression: malformed fingerprints fail before backend dispatch" do
    event = Event.new("fingerprint-boundary", "arbor.review.ordinary", %{value: 1})

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("fingerprint-boundary", [event])

    forged = %{
      operation
      | fingerprints: %{event.id => String.duplicate("z", 64)}
    }

    assert {:error, :invalid_append_operation} =
             Persistence.reconcile_append(
               :fingerprint_dispatch_spy,
               ReconcileDispatchSpy,
               forged,
               test_pid: self()
             )

    refute_receive :reconcile_backend_dispatched
  end

  test "malformed facade names are rejected without interpolation or backend dispatch" do
    event = Event.new("invalid-name", "event", %{})

    for invalid_name <- [%{not: :a_name}, nil] do
      assert {:error, :invalid_precondition} =
               Persistence.append(invalid_name, AgentEventLog, "invalid-name", event)
    end
  end

  test "malformed loaded repo modules are rejected before callback dispatch" do
    event = Event.new("invalid-loaded-repo", "event", %{})

    assert {:error, :invalid_precondition} =
             EctoEventLog.append("invalid-loaded-repo", event, repo: String)
  end
end
