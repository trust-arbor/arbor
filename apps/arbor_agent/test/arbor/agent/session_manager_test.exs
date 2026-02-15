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

  alias Arbor.Agent.SessionManager

  setup do
    assert Process.whereis(SessionManager) != nil
    agent_id = "test-agent-#{:erlang.unique_integer([:positive])}"
    %{agent_id: agent_id}
  end

  describe "graceful degradation" do
    test "ensure_session returns error when orchestrator unavailable", %{agent_id: agent_id} do
      # In arbor_agent's test env, orchestrator modules may not be loaded
      result = SessionManager.ensure_session(agent_id, trust_tier: :established)

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
end
