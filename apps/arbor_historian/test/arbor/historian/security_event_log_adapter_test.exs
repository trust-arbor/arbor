defmodule Arbor.Historian.Adapters.SecurityEventLogTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Historian.Adapters.SecurityEventLog
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Security.Events

  setup do
    suffix = System.unique_integer([:positive])
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    log_name = :"security_event_log_#{suffix}"

    {:ok, pid} = ETS.start_link(name: log_name)

    previous_hot = Application.get_env(:arbor_historian, :hot_event_log_target, :unset)
    previous_adapter = Application.get_env(:arbor_security, :event_log_adapter, :unset)

    Application.put_env(:arbor_historian, :hot_event_log_target, %{
      name: log_name,
      backend: ETS,
      opts: []
    })

    Application.put_env(:arbor_security, :event_log_adapter, SecurityEventLog)

    on_exit(fn ->
      restore(:arbor_historian, :hot_event_log_target, previous_hot)
      restore(:arbor_security, :event_log_adapter, previous_adapter)

      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{log_name: log_name}
  end

  test "appends a security envelope to security:events and reads it back" do
    assert :ok =
             SecurityEventLog.persist_security_event(:authorization_granted, %{
               principal_id: "agent_001",
               resource_uri: "arbor://fs/read/docs"
             })

    assert {:ok, [event]} = SecurityEventLog.read_security_events([])
    assert event.stream_id == "security:events"
    assert event.type == "authorization_granted"
    assert event.data["principal_id"] == "agent_001"
    assert event.data["resource_uri"] == "arbor://fs/read/docs"
    assert event.metadata["source_node"] in [node(), to_string(node())]
  end

  test "Events record and get_history round-trip through the real EventLog" do
    assert :ok =
             Events.record_orchestration_task_dispatched(
               "human_1",
               "task_123",
               "agent_1",
               task_preview: "write a patch",
               metadata: %{ticket: "A-1"},
               trace_id: "trace_abc"
             )

    assert {:ok, [event]} = Events.get_by_type(:orchestration_task_dispatched)
    assert event.stream_id == "security:events"
    assert event.data["actor_id"] == "human_1"
    assert event.data["task_id"] == "task_123"
    assert event.data["agent_id"] == "agent_1"
    assert event.data["task_preview"] == "write a patch"
    assert event.data["metadata"] == %{"ticket" => "A-1"}
    assert event.data["trace_id"] == "trace_abc"
  end

  test "read is unavailable when the EventLog process is down", %{log_name: log_name} do
    :ok = GenServer.stop(log_name)
    assert {:error, :event_log_unavailable} = SecurityEventLog.read_security_events([])
  end

  defp restore(app, key, :unset), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
