defmodule Arbor.Historian.ApplicationProjectionStartupTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @config_keys [
    :start_children,
    :identity_replay_repo,
    :identity_replay_durable_event_log,
    :identity_replay_cache_event_log
  ]

  defmodule ReplayTrap do
    def metadata_snapshot(_opts), do: notify(:metadata_snapshot)
    def read_all(_opts), do: notify(:read_all)
    def rehydrate_metadata(_snapshot, _opts), do: notify(:rehydrate_metadata)
    def replay_identity_history(_events, _opts), do: notify(:replay_identity_history)

    defp notify(operation) do
      send(Application.fetch_env!(:arbor_historian, :projection_startup_test_pid), operation)
      {:error, :must_not_be_called}
    end
  end

  setup do
    previous_env =
      Map.new(
        [:projection_startup_test_pid | @config_keys],
        &{&1, Application.fetch_env(:arbor_historian, &1)}
      )

    :ok = Application.stop(:arbor_historian)
    Application.put_env(:arbor_historian, :start_children, true)
    Application.put_env(:arbor_historian, :projection_startup_test_pid, self())
    Application.put_env(:arbor_historian, :identity_replay_repo, :missing_replay_repo)
    Application.put_env(:arbor_historian, :identity_replay_durable_event_log, ReplayTrap)
    Application.put_env(:arbor_historian, :identity_replay_cache_event_log, ReplayTrap)

    on_exit(fn ->
      Application.stop(:arbor_historian)

      Enum.each(previous_env, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_historian, key, value)
        {key, :error} -> Application.delete_env(:arbor_historian, key)
      end)

      {:ok, _started} = Application.ensure_all_started(:arbor_historian)
      restore_test_children()
    end)

    :ok
  end

  test "startup creates an empty projection without durable metadata or event replay" do
    assert {:ok, _started} = Application.ensure_all_started(:arbor_historian)

    refute_receive :metadata_snapshot
    refute_receive :read_all
    refute_receive :rehydrate_metadata
    refute_receive :replay_identity_history

    assert {:ok,
            %{
              global_position: 0,
              observed_global_position: 0,
              resident_events: 0,
              resident_streams: 0
            }} = ETS.projection_status(name: Arbor.Historian.EventLog.ETS)

    event = Event.new("startup-projection", "arbor.review.ordinary", %{value: 1})

    assert {:error, :projection_read_only} =
             ETS.append("startup-projection", event, name: Arbor.Historian.EventLog.ETS)
  end

  defp restore_test_children do
    children = [
      {ETS, name: Arbor.Historian.EventLog.ETS, mode: :projection},
      {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
    ]

    Enum.each(children, fn child ->
      case Supervisor.start_child(Arbor.Historian.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)
  end
end
