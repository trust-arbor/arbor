defmodule Arbor.Agent.UserSupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.UserSupervisor

  @moduletag :fast

  defmodule TestWorker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts), do: {:ok, opts}
  end

  setup do
    # Start UserSupervisor and Registry for tests
    start_supervised!({Arbor.Agent.UserSupervisor, name: Arbor.Agent.UserSupervisor})

    unless Process.whereis(Arbor.Agent.Registry) do
      start_supervised!(Arbor.Agent.Registry)
    end

    :ok
  end

  describe "ensure_user_supervisor/1 via start_child" do
    test "creates user supervisor on first use" do
      pid = start_test_agent("human_sup_test1", "agent_sup_1")
      assert is_pid(pid)
      assert UserSupervisor.count_agents("human_sup_test1") == 1
    end

    test "reuses existing user supervisor" do
      start_test_agent("human_sup_test2", "agent_sup_2a")
      start_test_agent("human_sup_test2", "agent_sup_2b")
      assert UserSupervisor.count_agents("human_sup_test2") == 2
    end
  end

  describe "which_agents/1" do
    test "lists agents for a specific user" do
      start_test_agent("human_sup_test3", "agent_sup_3a")
      start_test_agent("human_sup_test3", "agent_sup_3b")
      start_test_agent("human_sup_other", "agent_sup_3c")

      agents_3 = UserSupervisor.which_agents("human_sup_test3")
      agents_other = UserSupervisor.which_agents("human_sup_other")

      assert length(agents_3) == 2
      assert length(agents_other) == 1
    end

    test "returns empty list for unknown user" do
      assert UserSupervisor.which_agents("human_nonexistent") == []
    end
  end

  describe "terminate_user/1" do
    test "terminates all agents for a user" do
      pid1 = start_test_agent("human_sup_test4", "agent_sup_4a")
      pid2 = start_test_agent("human_sup_test4", "agent_sup_4b")

      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      assert :ok = UserSupervisor.terminate_user("human_sup_test4")

      # Give processes time to terminate
      Process.sleep(50)

      refute Process.alive?(pid1)
      refute Process.alive?(pid2)
      assert UserSupervisor.count_agents("human_sup_test4") == 0
    end

    test "returns :ok for unknown user" do
      assert :ok = UserSupervisor.terminate_user("human_nonexistent")
    end
  end

  describe "active_users/0" do
    test "lists users with active supervisors" do
      start_test_agent("human_active1", "agent_active_1")
      start_test_agent("human_active2", "agent_active_2")

      users = UserSupervisor.active_users()
      assert "human_active1" in users
      assert "human_active2" in users
    end
  end

  describe "quota enforcement" do
    test "enforces max agents per user" do
      # Set quota to 2 for testing
      Application.put_env(:arbor_agent, :max_agents_per_user, 2)

      on_exit(fn ->
        Application.delete_env(:arbor_agent, :max_agents_per_user)
      end)

      start_test_agent("human_quota", "agent_quota_1")
      start_test_agent("human_quota", "agent_quota_2")

      result =
        UserSupervisor.start_child(
          agent_id: "agent_quota_3",
          module: Arbor.Agent.UserSupervisorTest.TestWorker,
          principal_id: "human_quota",
          start_opts: [agent_id: "agent_quota_3"]
        )

      assert {:error, {:quota_exceeded, 2}} = result
    end
  end

  # Helper to start a simple Agent process under UserSupervisor
  defp start_test_agent(principal_id, agent_id) do
    {:ok, pid} =
      UserSupervisor.start_child(
        agent_id: agent_id,
        module: Arbor.Agent.UserSupervisorTest.TestWorker,
        principal_id: principal_id,
        start_opts: [agent_id: agent_id]
      )

    pid
  end
end
