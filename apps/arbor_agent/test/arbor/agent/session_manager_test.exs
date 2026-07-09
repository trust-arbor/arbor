defmodule Arbor.Agent.SessionManagerTest do
  @moduledoc """
  Unit tests for SessionManager.

  These tests run in the arbor_agent context where arbor_orchestrator may
  not be loaded. They verify:
  - SessionManager starts and is available
  - Graceful degradation when orchestrator is unavailable
  - ETS-level operations (get/has/stop for nonexistent agents)

  Integration tests that create real sessions live in
  arbor_orchestrator's test suite (session_manager_integration_test.exs).
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.SessionManager

  setup do
    assert Process.whereis(SessionManager) != nil
    agent_id = "test-agent-#{:erlang.unique_integer([:positive])}"
    %{agent_id: agent_id}
  end

  describe "graceful degradation" do
    test "ensure_session returns error when orchestrator unavailable", %{agent_id: agent_id} do
      # In arbor_agent's test env, orchestrator modules may not be loaded
      result = SessionManager.ensure_session(agent_id, [])

      case result do
        {:ok, _pid} ->
          # Orchestrator happened to be loaded — still valid
          SessionManager.stop_session(agent_id)

        {:error, :orchestrator_unavailable} ->
          :ok

        {:error, {:session_start_failed, _}} ->
          :ok
      end
    end
  end

  describe "get_session/1" do
    test "returns error for unknown agent" do
      assert {:error, :no_session} =
               SessionManager.get_session("nonexistent-#{:erlang.unique_integer([:positive])}")
    end
  end

  describe "has_session?/1" do
    test "false for unknown agent" do
      refute SessionManager.has_session?("nonexistent-#{:erlang.unique_integer([:positive])}")
    end
  end

  describe "stop_session/1" do
    test "no-op for unknown agent" do
      assert :ok =
               SessionManager.stop_session("nonexistent-#{:erlang.unique_integer([:positive])}")
    end
  end

  defmodule FakeSession do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, %{test_pid: test_pid, cancelled?: false}}

    @impl true
    def handle_call(:cancel_turn, _from, %{cancelled?: false} = state) do
      send(state.test_pid, {:session_cancel_turn, self()})
      {:reply, :ok, %{state | cancelled?: true}}
    end

    def handle_call(:cancel_turn, _from, state) do
      # Mirrors Session: second cancel with nothing in flight.
      {:reply, {:error, :no_turn_in_flight}, state}
    end

    def handle_call({:cancel_task, task_id}, _from, state) when is_binary(task_id) do
      send(state.test_pid, {:session_cancel_task, self(), task_id})
      {:reply, :ok, state}
    end

    def handle_call(:probe, _from, state), do: {:reply, :alive, state}
  end

  describe "cancel_turn/1" do
    test "bridges agent_id through the public ETS table to Session.cancel_turn semantics", %{
      agent_id: agent_id
    } do
      {:ok, fake_session} = FakeSession.start_link(self())

      # Unscoped user cancel: SessionManager.cancel_turn → ETS → Session.cancel_turn.
      true = :ets.insert(SessionManager, {agent_id, fake_session})

      try do
        assert {:ok, ^fake_session} = SessionManager.get_session(agent_id)
        assert :ok = SessionManager.cancel_turn(agent_id)
        assert_receive {:session_cancel_turn, ^fake_session}, 1_000

        # Second cancel reaches the same GenServer contract.
        assert {:error, :no_turn_in_flight} = SessionManager.cancel_turn(agent_id)

        # Entry remains usable until cleaned up.
        assert {:ok, ^fake_session} = SessionManager.get_session(agent_id)
        assert :alive = GenServer.call(fake_session, :probe)
      after
        :ets.delete(SessionManager, agent_id)

        if Process.alive?(fake_session) do
          GenServer.stop(fake_session, :normal, 1_000)
        end
      end

      assert {:error, :no_session} = SessionManager.get_session(agent_id)
      assert {:error, :no_session} = SessionManager.cancel_turn(agent_id)
    end
  end

  describe "cancel_task/2" do
    test "bridges agent_id + task_id through ETS to Session.cancel_task contract", %{
      agent_id: agent_id
    } do
      {:ok, fake_session} = FakeSession.start_link(self())
      true = :ets.insert(SessionManager, {agent_id, fake_session})

      try do
        # Production path: TaskStore → SessionManager.cancel_task/2 → Session.
        assert :ok = SessionManager.cancel_task(agent_id, "task_abc")
        assert_receive {:session_cancel_task, ^fake_session, "task_abc"}, 1_000

        # Unscoped cancel remains available for explicit user cancellation.
        assert :ok = SessionManager.cancel_turn(agent_id)
        assert_receive {:session_cancel_turn, ^fake_session}, 1_000
      after
        :ets.delete(SessionManager, agent_id)

        if Process.alive?(fake_session) do
          GenServer.stop(fake_session, :normal, 1_000)
        end
      end

      assert {:error, :no_session} = SessionManager.cancel_task(agent_id, "task_abc")
      assert {:error, :invalid_args} = SessionManager.cancel_task(agent_id, "")
      assert {:error, :invalid_args} = SessionManager.cancel_task(nil, "task_abc")
    end
  end
end
