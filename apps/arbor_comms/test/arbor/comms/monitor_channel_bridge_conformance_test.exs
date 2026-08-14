defmodule Arbor.Comms.MonitorChannelBridgeConformanceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Comms

  setup do
    unless Process.whereis(Arbor.Comms.ChannelRegistry) do
      start_supervised!({Registry, keys: :unique, name: Arbor.Comms.ChannelRegistry})
    end

    unless Process.whereis(Arbor.Comms.ChannelSupervisor) do
      start_supervised!(
        {DynamicSupervisor, name: Arbor.Comms.ChannelSupervisor, strategy: :one_for_one}
      )
    end

    :ok
  end

  test "create_ops_room admits both intended members and delivers as the system sender" do
    participants = [
      %{id: "agent_diag", name: "Diagnostician", type: :agent},
      %{id: "anomaly_forwarder", name: "Monitor", type: :system}
    ]

    assert {:ok, chan_id} = Comms.create_ops_room("ops-room", participants)
    assert is_binary(chan_id)
    assert chan_id != ""

    assert {:ok, members} = Comms.channel_members(chan_id)

    diagnostician = Enum.find(members, &(&1.id == "agent_diag"))
    assert diagnostician.name == "Diagnostician"
    assert diagnostician.type == :agent

    forwarder = Enum.find(members, &(&1.id == "anomaly_forwarder"))
    assert forwarder.name == "Monitor"
    assert forwarder.type == :system

    assert Comms.deliver_channel_message(
             chan_id,
             "anomaly_forwarder",
             "Monitor",
             :system,
             "alert"
           ) in [:ok, {:ok, :delivered}]

    assert {:error, :not_member} =
             Comms.deliver_channel_message(chan_id, "stranger", "X", :human, "nope")

    assert {:error, :not_found} =
             Comms.deliver_channel_message(
               "chan_missing",
               "anomaly_forwarder",
               "Monitor",
               :system,
               "alert"
             )

    assert {:error, :invalid_participants} = Comms.create_ops_room("ops-room", [%{id: 1}])
    assert {:error, :invalid_participants} = Comms.create_ops_room("ops-room", "nope")
    assert {:error, :invalid_participants} = Comms.create_ops_room("ops-room", [])
    assert {:error, :invalid_participants} = Comms.create_ops_room("", participants)
    assert {:error, :invalid_participants} = Comms.create_ops_room("   ", participants)

    assert {:error, :delivery_failed} =
             Comms.deliver_channel_message(chan_id, "anomaly_forwarder", "Monitor", :bot, "alert")
  end
end
