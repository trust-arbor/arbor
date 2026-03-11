defmodule Arbor.Gateway.MCP.EndpointRegistry.DistributedTest do
  @moduledoc """
  Tests for distributed endpoint discovery via signals.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Gateway.MCP.EndpointRegistry

  @table :arbor_mcp_endpoints

  setup do
    case EndpointRegistry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      # Clean up any remote entries we added
      if :ets.info(@table) != :undefined do
        :ets.tab2list(@table)
        |> Enum.each(fn
          {id, {:remote, _}, _, _} -> :ets.delete(@table, id)
          _ -> :ok
        end)
      end
    end)

    :ok
  end

  describe "distributed endpoint discovery" do
    test "registers remote endpoint on signal" do
      agent_id = "agent_remote_ep_#{System.unique_integer([:positive])}"

      send(
        Process.whereis(EndpointRegistry),
        {:signal_received,
         %{
           type: :endpoint_registered,
           data: %{
             agent_id: agent_id,
             tools: [%{name: "test_tool"}],
             origin_node: :remote@node
           }
         }}
      )

      Process.sleep(10)

      # Should show as a remote entry
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, {:remote, :remote@node}, tools, _ts}] ->
          assert length(tools) == 1

        _ ->
          flunk("Expected remote endpoint entry in ETS")
      end
    end

    test "removes remote endpoint on unregister signal" do
      agent_id = "agent_remote_unreg_#{System.unique_integer([:positive])}"

      # First register it
      :ets.insert(@table, {agent_id, {:remote, :remote@node}, [], DateTime.utc_now()})

      send(
        Process.whereis(EndpointRegistry),
        {:signal_received,
         %{
           type: :endpoint_unregistered,
           data: %{
             agent_id: agent_id,
             origin_node: :remote@node
           }
         }}
      )

      Process.sleep(10)

      assert :ets.lookup(@table, agent_id) == []
    end

    test "does not remove local endpoint on remote unregister signal" do
      agent_id = "agent_local_ep_#{System.unique_integer([:positive])}"
      local_pid = self()

      # Register as local endpoint (pid, not {:remote, node})
      :ets.insert(@table, {agent_id, local_pid, [], DateTime.utc_now()})

      send(
        Process.whereis(EndpointRegistry),
        {:signal_received,
         %{
           type: :endpoint_unregistered,
           data: %{
             agent_id: agent_id,
             origin_node: :remote@node
           }
         }}
      )

      Process.sleep(10)

      # Local entry should be preserved
      assert [{^agent_id, ^local_pid, [], _}] = :ets.lookup(@table, agent_id)
    end

    test "ignores signals from own node" do
      agent_id = "agent_self_ep_#{System.unique_integer([:positive])}"

      send(
        Process.whereis(EndpointRegistry),
        {:signal_received,
         %{
           type: :endpoint_registered,
           data: %{
             agent_id: agent_id,
             tools: [],
             origin_node: node()
           }
         }}
      )

      Process.sleep(10)

      # Should not have been inserted (self-signal ignored)
      assert :ets.lookup(@table, agent_id) == []
    end
  end
end
