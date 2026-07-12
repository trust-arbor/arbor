defmodule Arbor.Historian.ApplicationIdentityReplaySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @repo_name :historian_identity_replay_repo
  @config_keys [
    :start_children,
    :identity_replay_repo,
    :identity_replay_durable_event_log,
    :identity_replay_cache_event_log,
    :identity_replay_test_pid
  ]

  defmodule ReplayDurable do
    def metadata_snapshot(opts) do
      opts
      |> Keyword.fetch!(:repo)
      |> Agent.get(&{:ok, &1.snapshot})
    end

    def read_all(opts) do
      repo = Keyword.fetch!(opts, :repo)
      from = Keyword.fetch!(opts, :from)
      limit = Keyword.fetch!(opts, :limit)

      Agent.get_and_update(repo, fn state ->
        events =
          state.events
          |> Enum.filter(&(&1.global_position >= from))
          |> Enum.take(limit)

        {{:ok, events}, %{state | reads: [{from, limit} | state.reads]}}
      end)
    end
  end

  defmodule BlockedDurable do
    def metadata_snapshot(_opts) do
      test_pid = Application.fetch_env!(:arbor_historian, :identity_replay_test_pid)
      send(test_pid, {:historian_metadata_snapshot_blocked, self()})

      receive do
        {:release_historian_metadata_snapshot, result} -> result
      after
        5_000 -> {:error, :blocked_snapshot_timeout}
      end
    end
  end

  setup do
    previous_env = Map.new(@config_keys, &{&1, Application.fetch_env(:arbor_historian, &1)})
    :ok = Application.stop(:arbor_historian)

    events = Enum.map(1..1_001, &positioned_event/1)

    {:ok, repo} =
      Agent.start_link(
        fn ->
          %{
            snapshot: %{
              stream_versions: %{"durable" => 1_001},
              global_position: 1_001,
              identity_history: {:unavailable, :metadata_only}
            },
            events: events,
            reads: []
          }
        end,
        name: @repo_name
      )

    Application.put_env(:arbor_historian, :start_children, true)
    Application.put_env(:arbor_historian, :identity_replay_repo, @repo_name)

    Application.put_env(
      :arbor_historian,
      :identity_replay_durable_event_log,
      ReplayDurable
    )

    Application.put_env(:arbor_historian, :identity_replay_cache_event_log, ETS)

    on_exit(fn ->
      Application.stop(:arbor_historian)

      if Process.alive?(repo), do: Agent.stop(repo)

      Enum.each(previous_env, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_historian, key, value)
        {key, :error} -> Application.delete_env(:arbor_historian, key)
      end)

      {:ok, _started} = Application.ensure_all_started(:arbor_historian)
      restore_test_children()
    end)

    :ok
  end

  test "security regression: public startup replays identities before accepting appends" do
    assert {:ok, _started} = Application.ensure_all_started(:arbor_historian)

    assert {:ok, :identity_history_complete} =
             ETS.identity_history_status(name: Arbor.Historian.EventLog.ETS)

    assert [{1, 1_000}, {1_001, 1}] =
             @repo_name
             |> Agent.get(& &1.reads)
             |> Enum.reverse()

    event = Event.new("durable", "arbor.review.ordinary", %{value: 1_002})

    assert {:ok, [%Event{event_number: 1_002, global_position: 1_002}]} =
             ETS.append("durable", event, name: Arbor.Historian.EventLog.ETS)
  end

  test "security regression: incomplete durable replay fails startup closed" do
    Agent.update(@repo_name, &%{&1 | events: []})

    assert {:error, {:arbor_historian, {startup_error, _application_mfa}}} =
             Application.ensure_all_started(:arbor_historian)

    assert match?({:event_log_rehydrate_failed, _reason}, startup_error)

    refute Process.whereis(Arbor.Historian.EventLog.ETS)
  end

  test "security regression: blocked metadata cannot expose an accepting cache" do
    Application.put_env(:arbor_historian, :identity_replay_test_pid, self())

    Application.put_env(
      :arbor_historian,
      :identity_replay_durable_event_log,
      BlockedDurable
    )

    startup = Task.async(fn -> Application.ensure_all_started(:arbor_historian) end)
    assert_receive {:historian_metadata_snapshot_blocked, snapshot_caller}, 1_000
    assert is_pid(Process.whereis(Arbor.Historian.EventLog.ETS))

    event = Event.new("blocked-startup", "arbor.review.ordinary", %{value: 1})

    assert {:ok, operation} =
             Arbor.Persistence.EventLog.build_operation("blocked-startup", [event])

    try do
      assert {:error, {:append_indeterminate, ^operation}} =
               ETS.append("blocked-startup", event, name: Arbor.Historian.EventLog.ETS)

      assert {:error, {:append_indeterminate, ^operation}} =
               ETS.reconcile_append(operation, name: Arbor.Historian.EventLog.ETS)
    after
      send(snapshot_caller, {:release_historian_metadata_snapshot, {:error, :blocked_failure}})
    end

    assert {:error, {:arbor_historian, {startup_error, _application_mfa}}} =
             Task.await(startup, 5_000)

    assert match?({:event_log_rehydrate_failed, _reason}, startup_error)
    refute Process.whereis(Arbor.Historian.EventLog.ETS)
  end

  defp positioned_event(position) do
    event =
      %Event{
        Event.new(
          "durable",
          "arbor.review.ordinary",
          %{value: position},
          id: "evt_durable_#{position}"
        )
        | event_number: position,
          global_position: position
      }

    fingerprint = Arbor.Persistence.EventLog.event_fingerprint(event.stream_id, event)
    Map.put(event, :operation_fingerprint, fingerprint)
  end

  defp restore_test_children do
    for child <- [
          {ETS, name: Arbor.Historian.EventLog.ETS},
          {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
        ] do
      case Supervisor.start_child(Arbor.Historian.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end
end
