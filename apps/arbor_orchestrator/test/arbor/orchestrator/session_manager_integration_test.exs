defmodule Arbor.Orchestrator.SessionManagerIntegrationTest do
  @moduledoc """
  Integration tests for SessionManager + Session (full lifecycle).

  These tests create real DOT sessions and verify messaging works.
  They require both arbor_orchestrator and arbor_agent modules.

  Tagged :integration — excluded by default in most configs.
  Run with: `mix test --include integration` from the umbrella root
  with all apps loaded.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session

  @moduletag :integration

  @session_manager Arbor.Agent.SessionManager
  @session_available Code.ensure_loaded?(Arbor.Agent.SessionManager)

  if @session_available do
    setup do
      # Ensure EventRegistry is running
      case Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Start SessionManager if not running
      case Process.whereis(@session_manager) do
        nil ->
          {:ok, pid} = @session_manager.start_link([])
          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

        _pid ->
          :ok
      end

      agent_id = "int-test-agent-#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        try do
          @session_manager.stop_session(agent_id)
        catch
          :exit, _ -> :ok
        end
      end)

      %{agent_id: agent_id}
    end

    describe "ensure_session/2" do
      test "creates a real session and returns pid", %{agent_id: agent_id} do
        assert {:ok, pid} = @session_manager.ensure_session(agent_id, trust_tier: :established)
        assert is_pid(pid)
        assert Process.alive?(pid)
      end

      test "is idempotent — second call returns same pid", %{agent_id: agent_id} do
        assert {:ok, pid1} = @session_manager.ensure_session(agent_id, trust_tier: :established)
        assert {:ok, pid2} = @session_manager.ensure_session(agent_id, trust_tier: :established)
        assert pid1 == pid2
      end
    end

    describe "session messaging" do
      test "send_message works through the DOT graph", %{agent_id: agent_id} do
        {:ok, pid} =
          @session_manager.ensure_session(agent_id,
            trust_tier: :established,
            start_heartbeat: false
          )

        result = Session.send_message(pid, "Hello from integration test")
        assert {:ok, response} = result
        assert is_binary(response)
      end

      test "session state accumulates across turns", %{agent_id: agent_id} do
        {:ok, pid} =
          @session_manager.ensure_session(agent_id,
            trust_tier: :established,
            start_heartbeat: false
          )

        {:ok, _} = Session.send_message(pid, "First message")
        state1 = Session.get_state(pid)

        {:ok, _} = Session.send_message(pid, "Second message")
        state2 = Session.get_state(pid)

        assert state2.turn_count == state1.turn_count + 1
        assert length(state2.messages) > length(state1.messages)
      end
    end

    describe "crash cleanup" do
      test "DOWN monitor cleans up ETS entry", %{agent_id: agent_id} do
        {:ok, pid} = @session_manager.ensure_session(agent_id, trust_tier: :established)
        assert @session_manager.has_session?(agent_id)

        Process.exit(pid, :kill)
        Process.sleep(100)

        refute @session_manager.has_session?(agent_id)
      end
    end
  else
    @tag :skip
    test "skipped — SessionManager not available in this test context" do
      :ok
    end
  end
end
