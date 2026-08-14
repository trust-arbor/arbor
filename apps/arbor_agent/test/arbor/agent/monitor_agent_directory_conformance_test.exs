defmodule Arbor.Agent.MonitorAgentDirectoryConformanceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.{Character, Profile, ProfileStore}
  alias Arbor.Persistence.BufferedStore

  @store_name :arbor_agent_profiles

  setup do
    unless Process.whereis(@store_name) do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @store_name, backend: nil, write_mode: :sync},
          id: @store_name
        )
      )
    end

    :ok
  end

  test "list_monitor_agents projects stored profiles without leaking Profile structs" do
    agent_id = "agent_k1d_dir_#{System.unique_integer([:positive])}"
    display_name = "diagnostician-name"

    profile = %Profile{
      agent_id: agent_id,
      display_name: display_name,
      character: Character.new(name: "K1D Directory"),
      created_at: DateTime.utc_now(),
      version: 1
    }

    assert :ok = ProfileStore.store_profile(profile)

    on_exit(fn ->
      ProfileStore.delete_profile(agent_id)
    end)

    assert {:ok, agents} = Arbor.Agent.list_monitor_agents()
    assert is_list(agents)

    row = Enum.find(agents, &(&1.agent_id == agent_id))
    assert row == %{agent_id: agent_id, display_name: display_name}
    refute is_struct(row)
    assert Map.keys(row) -- [:agent_id, :display_name] == []
  end

  test "list_monitor_agents does not raise when the store is empty or unavailable" do
    result = Arbor.Agent.list_monitor_agents()

    assert match?({:ok, list} when is_list(list), result) or
             result == {:error, :directory_unavailable}
  end
end
