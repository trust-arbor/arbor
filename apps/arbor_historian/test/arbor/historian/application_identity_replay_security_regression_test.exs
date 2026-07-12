defmodule Arbor.Historian.ApplicationIdentityReplaySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @repo_name :historian_identity_replay_repo
  @config_keys [
    :start_children,
    :identity_replay_repo,
    :identity_replay_durable_event_log,
    :identity_replay_cache_event_log
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

  defp positioned_event(position) do
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
