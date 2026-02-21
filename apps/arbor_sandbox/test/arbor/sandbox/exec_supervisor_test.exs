defmodule Arbor.Sandbox.ExecSupervisorTest do
  use ExUnit.Case

  alias Arbor.Sandbox.{ExecSession, ExecSupervisor}

  setup do
    # Ensure supervisor and registry are running
    unless Process.whereis(ExecSupervisor) do
      start_supervised!({Registry, keys: :unique, name: Arbor.Sandbox.ExecRegistry})
      start_supervised!(ExecSupervisor)
    end

    :ok
  end

  describe "start_session/2" do
    test "starts a session for an agent" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      assert {:ok, pid} = ExecSupervisor.start_session(agent_id)
      assert is_pid(pid)
      assert Process.alive?(pid)
      # Cleanup
      ExecSupervisor.stop_session(agent_id)
    end

    test "returns existing session if already started" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      {:ok, pid1} = ExecSupervisor.start_session(agent_id)
      {:ok, pid2} = ExecSupervisor.start_session(agent_id)
      assert pid1 == pid2
      ExecSupervisor.stop_session(agent_id)
    end
  end

  describe "stop_session/1" do
    test "stops a running session" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      {:ok, pid} = ExecSupervisor.start_session(agent_id)
      assert Process.alive?(pid)
      assert :ok = ExecSupervisor.stop_session(agent_id)
      refute Process.alive?(pid)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = ExecSupervisor.stop_session("nonexistent-agent")
    end
  end

  describe "get_or_start_session/2" do
    test "starts new session if none exists" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      assert {:ok, pid} = ExecSupervisor.get_or_start_session(agent_id)
      assert is_pid(pid)
      ExecSupervisor.stop_session(agent_id)
    end

    test "returns existing session" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      {:ok, pid1} = ExecSupervisor.start_session(agent_id)
      {:ok, pid2} = ExecSupervisor.get_or_start_session(agent_id)
      assert pid1 == pid2
      ExecSupervisor.stop_session(agent_id)
    end

    test "session is functional after get_or_start" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      {:ok, pid} = ExecSupervisor.get_or_start_session(agent_id)
      assert {:ok, "2"} = ExecSession.eval(pid, "1 + 1")
      ExecSupervisor.stop_session(agent_id)
    end
  end

  describe "lookup/1" do
    test "finds a running session" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      {:ok, pid} = ExecSupervisor.start_session(agent_id)
      assert {:ok, ^pid} = ExecSupervisor.lookup(agent_id)
      ExecSupervisor.stop_session(agent_id)
    end

    test "returns error for missing session" do
      assert :error = ExecSupervisor.lookup("missing-agent")
    end
  end

  describe "supervisor restart" do
    test "session can be restarted after crash" do
      agent_id = "sup-test-#{System.unique_integer([:positive])}"
      {:ok, pid1} = ExecSupervisor.start_session(agent_id)

      # Kill the session process
      Process.exit(pid1, :kill)
      Process.sleep(50)

      # Should be able to start a new one
      {:ok, pid2} = ExecSupervisor.start_session(agent_id)
      assert pid1 != pid2
      assert {:ok, "2"} = ExecSession.eval(pid2, "1 + 1")
      ExecSupervisor.stop_session(agent_id)
    end
  end
end
