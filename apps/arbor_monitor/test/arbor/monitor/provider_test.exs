defmodule Arbor.Monitor.ProviderTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Monitor.Config.Testing
  alias Arbor.Monitor.Provider

  setup do
    Testing.isolate_namespace()
    Testing.delete(:channel_bridge_module)
    Testing.delete(:agent_directory_module)
    :ok
  end

  test "absent providers skip without invoking a callback" do
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :absent}
    assert Provider.create_ops_room("ops-room", []) == {:skip, :absent}
    assert Provider.list_agents() == {:skip, :absent}
  end

  test "invalid providers skip before invocation" do
    Testing.put(:channel_bridge_module, "not-a-module")
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :invalid_provider}

    Testing.put(:channel_bridge_module, true)
    assert Provider.create_ops_room("ops-room", []) == {:skip, :invalid_provider}

    Testing.put(:agent_directory_module, false)
    assert Provider.list_agents() == {:skip, :invalid_provider}
  end

  test "missing callbacks skip before invocation" do
    Testing.put(:channel_bridge_module, __MODULE__.Empty)
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :missing_callback}
    assert Provider.create_ops_room("ops-room", []) == {:skip, :missing_callback}

    Testing.put(:agent_directory_module, __MODULE__.Empty)
    assert Provider.list_agents() == {:skip, :missing_callback}
  end

  test "deliver admits :ok and {:ok, :delivered}" do
    Testing.put(:channel_bridge_module, __MODULE__.DeliverOk)
    assert Provider.deliver("chan", "s", "n", :system, "m") == :ok

    Testing.put(:channel_bridge_module, __MODULE__.DeliverDelivered)
    assert Provider.deliver("chan", "s", "n", :system, "m") == :ok
  end

  test "deliver admits closed errors and rejects malformed results" do
    Testing.put(:channel_bridge_module, __MODULE__.DeliverNotMember)
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:error, :not_member}

    Testing.put(:channel_bridge_module, __MODULE__.DeliverMalformedOk)
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :malformed_result}

    Testing.put(:channel_bridge_module, __MODULE__.DeliverBoomError)
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :malformed_result}
  end

  test "deliver normalizes raise, throw, and exit" do
    Testing.put(:channel_bridge_module, __MODULE__.DeliverRaise)

    assert Provider.deliver("chan", "s", "n", :system, "m") ==
             {:skip, :provider_raised, RuntimeError}

    Testing.put(:channel_bridge_module, __MODULE__.DeliverThrow)
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :provider_threw}

    Testing.put(:channel_bridge_module, __MODULE__.DeliverExit)
    assert Provider.deliver("chan", "s", "n", :system, "m") == {:skip, :provider_exited}
  end

  test "create admits a nonempty channel id and closed errors" do
    Testing.put(:channel_bridge_module, __MODULE__.CreateOk)
    assert Provider.create_ops_room("ops-room", []) == {:ok, "chan_ok"}

    Testing.put(:channel_bridge_module, __MODULE__.CreateFailed)
    assert Provider.create_ops_room("ops-room", []) == {:error, :create_failed}

    Testing.put(:channel_bridge_module, __MODULE__.CreateMalformed)
    assert Provider.create_ops_room("ops-room", []) == {:skip, :malformed_result}
  end

  test "create normalizes raise, throw, and exit" do
    Testing.put(:channel_bridge_module, __MODULE__.CreateRaise)

    assert Provider.create_ops_room("ops-room", []) ==
             {:skip, :provider_raised, RuntimeError}

    Testing.put(:channel_bridge_module, __MODULE__.CreateThrow)
    assert Provider.create_ops_room("ops-room", []) == {:skip, :provider_threw}

    Testing.put(:channel_bridge_module, __MODULE__.CreateExit)
    assert Provider.create_ops_room("ops-room", []) == {:skip, :provider_exited}
  end

  test "list admits projected maps and rejects structs or malformed rows" do
    Testing.put(:agent_directory_module, __MODULE__.ListOk)

    assert Provider.list_agents() ==
             {:ok, [%{agent_id: "agent_1", display_name: "diagnostician"}]}

    Testing.put(:agent_directory_module, __MODULE__.ListUnavailable)
    assert Provider.list_agents() == {:error, :directory_unavailable}

    Testing.put(:agent_directory_module, __MODULE__.ListStruct)
    assert Provider.list_agents() == {:skip, :malformed_result}

    Testing.put(:agent_directory_module, __MODULE__.ListBadId)
    assert Provider.list_agents() == {:skip, :malformed_result}
  end

  test "list normalizes raise, throw, and exit" do
    Testing.put(:agent_directory_module, __MODULE__.ListRaise)
    assert Provider.list_agents() == {:skip, :provider_raised, RuntimeError}

    Testing.put(:agent_directory_module, __MODULE__.ListThrow)
    assert Provider.list_agents() == {:skip, :provider_threw}

    Testing.put(:agent_directory_module, __MODULE__.ListExit)
    assert Provider.list_agents() == {:skip, :provider_exited}
  end

  defmodule Empty do
  end

  defmodule DeliverOk do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: :ok
  end

  defmodule DeliverDelivered do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: {:ok, :delivered}
  end

  defmodule DeliverNotMember do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: {:error, :not_member}
  end

  defmodule DeliverMalformedOk do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: {:ok, %{id: "msg"}}
  end

  defmodule DeliverBoomError do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: {:error, "boom"}
  end

  defmodule DeliverRaise do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: raise("provider boom")
  end

  defmodule DeliverThrow do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: throw(:provider_throw)
  end

  defmodule DeliverExit do
    def deliver_channel_message(_c, _s, _n, _t, _m), do: exit(:provider_exit)
  end

  defmodule CreateOk do
    def create_ops_room(_name, _participants), do: {:ok, "chan_ok"}
  end

  defmodule CreateFailed do
    def create_ops_room(_name, _participants), do: {:error, :create_failed}
  end

  defmodule CreateMalformed do
    def create_ops_room(_name, _participants), do: {:ok, :not_an_id}
  end

  defmodule CreateRaise do
    def create_ops_room(_name, _participants), do: raise("create boom")
  end

  defmodule CreateThrow do
    def create_ops_room(_name, _participants), do: throw(:create_throw)
  end

  defmodule CreateExit do
    def create_ops_room(_name, _participants), do: exit(:create_exit)
  end

  defmodule ListOk do
    def list_monitor_agents do
      {:ok, [%{agent_id: "agent_1", display_name: "diagnostician", extra: true}]}
    end
  end

  defmodule ListUnavailable do
    def list_monitor_agents, do: {:error, :directory_unavailable}
  end

  defmodule ListStruct do
    defmodule Row do
      defstruct [:agent_id, :display_name]
    end

    def list_monitor_agents do
      {:ok, [%Row{agent_id: "agent_1", display_name: "diagnostician"}]}
    end
  end

  defmodule ListBadId do
    def list_monitor_agents, do: {:ok, [%{agent_id: 1, display_name: "diagnostician"}]}
  end

  defmodule ListRaise do
    def list_monitor_agents, do: raise("list boom")
  end

  defmodule ListThrow do
    def list_monitor_agents, do: throw(:list_throw)
  end

  defmodule ListExit do
    def list_monitor_agents, do: exit(:list_exit)
  end
end
