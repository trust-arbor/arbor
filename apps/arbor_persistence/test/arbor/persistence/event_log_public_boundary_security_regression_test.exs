defmodule Arbor.Persistence.EventLogPublicBoundarySecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence
  alias Arbor.Persistence.{Event, EventLog}
  alias Arbor.Persistence.EventLog.Agent, as: AgentEventLog
  alias Arbor.Persistence.EventLog.BoundedWorker
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

  defmodule CrashingRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.Postgres
    def transaction(_fun), do: raise("simulated unavailable Repo")
    def transaction(_fun, _opts), do: raise("simulated unavailable Repo")
    def rollback(reason), do: throw({:rollback, reason})
    def one(_query), do: nil
    def insert!(_changeset), do: raise("unreachable")
  end

  defmodule CompletionCrossingRepo do
    @moduledoc false

    @controller_key {__MODULE__, :controller}

    def install(controller) do
      token = make_ref()
      :persistent_term.put(@controller_key, {controller, token})
      token
    end

    def clear, do: :persistent_term.erase(@controller_key)

    def __adapter__, do: Ecto.Adapters.Postgres
    def transaction(fun), do: transaction(fun, [])

    def transaction(_fun, _opts) do
      {controller, token} = :persistent_term.get(@controller_key)
      send(controller, {:completion_crossing_repo_waiting, token, self()})

      receive do
        {:release_completion_crossing_repo, ^token} -> {:error, :operation_timeout}
      after
        1_000 -> {:error, :operation_timeout}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})
    def one(_query), do: nil
    def insert!(_changeset), do: raise("unreachable")
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

  test "security regression: an unavailable Ecto Repo cannot terminate the caller" do
    event = Event.new("crashing-repo", "arbor.review.ordinary", %{value: 1})

    assert {:error, {:append_indeterminate, _operation}} =
             EctoEventLog.append("crashing-repo", event,
               repo: CrashingRepo,
               append_timeout_ms: 1_000
             )

    assert Process.alive?(self())
  end

  test "timeout cleanup waits for DOWN and drains the crossing worker completion" do
    result_ref = make_ref()
    parent = self()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {result_ref, EventLog.stamp_completion(:late_completion)})
        send(parent, {:completion_crossed_timeout, result_ref})
        Process.sleep(:infinity)
      end)

    assert_receive {:completion_crossed_timeout, ^result_ref}
    assert mailbox_contains_result_ref?(result_ref)

    assert :ok =
             Arbor.Persistence.EventLog.BoundedWorker.terminate(
               worker,
               monitor_ref,
               result_ref
             )

    refute Process.alive?(worker)
    refute mailbox_contains_result_ref?(result_ref)
    refute_receive {^result_ref, _completion}
    refute_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
  end

  test "security regression: timeout cleanup exposes no caller hook before kill" do
    refute function_exported?(BoundedWorker, :with_timeout_hook, 2)
  end

  test "public facade kills an Ecto worker before returning from timeout" do
    token = CompletionCrossingRepo.install(self())
    on_exit(&CompletionCrossingRepo.clear/0)

    event = Event.new("completion-crossing-repo", "arbor.review.ordinary", %{value: 1})

    assert {:error, {:append_indeterminate, _operation}} =
             Persistence.append(
               :public_ecto_timeout,
               EctoEventLog,
               "completion-crossing-repo",
               event,
               repo: CompletionCrossingRepo,
               append_timeout_ms: 250
             )

    assert_receive {:completion_crossing_repo_waiting, ^token, worker}, 1_000
    assert Process.alive?(self())
    refute Process.alive?(worker)
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

  defp mailbox_contains_result_ref?(result_ref) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.any?(messages, &match?({^result_ref, _completion}, &1))
  end
end
