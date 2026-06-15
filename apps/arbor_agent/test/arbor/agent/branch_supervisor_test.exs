defmodule Arbor.Agent.BranchSupervisorTest do
  @moduledoc """
  Regression: `host_pid/1` must resolve the CURRENT host pid from the supervisor,
  NOT a cached value. Under rest_for_one, a host crash restarts the host with a
  new pid; a consumer holding the old (cached `metadata[:host_pid]`) pid would
  get `:noproc`. This test kills the host and asserts `host_pid/1` returns the
  new live pid — the bug's exact manifestation.

  Uses a minimal stub :host child (not the real APIAgent) so the test exercises
  the supervisor/Registry resolution path without the agent's heavy deps. The
  suite's test_helper already starts `Arbor.Agent.ExecutorRegistry`, and the
  branch supervisor is started via `start_supervised!` so ExUnit tears it down
  before the next test (no global-state leakage into the shared suite).
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.BranchSupervisor

  defmodule StubHost do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> :ok end)
  end

  test "host_pid/1 resolves live and returns the NEW pid after a host restart" do
    agent_id = "branchsup-test-#{System.unique_integer([:positive])}"

    children = [Supervisor.child_spec({StubHost, []}, id: :host, restart: :permanent)]

    # start_supervised! ties the supervisor's lifetime to this test (ExUnit
    # removes it before the next test runs), so registering under the shared
    # ExecutorRegistry doesn't pollute other tests.
    start_supervised!(%{
      id: :test_branch_sup,
      start:
        {Supervisor, :start_link,
         [
           children,
           [
             strategy: :rest_for_one,
             name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}}}
           ]
         ]}
    })

    pid1 = BranchSupervisor.host_pid(agent_id)
    assert is_pid(pid1) and Process.alive?(pid1)

    # Kill the host — rest_for_one restarts it with a fresh pid.
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 1_000

    # The fix: host_pid/1 reads the supervisor live, so it returns the new pid,
    # never the dead cached one.
    pid2 = wait_for_new_host(agent_id, pid1)
    assert is_pid(pid2) and Process.alive?(pid2)
    refute pid2 == pid1
  end

  test "host_pid/1 returns nil for an unknown agent" do
    refute BranchSupervisor.host_pid("nonexistent-#{System.unique_integer([:positive])}")
  end

  defp wait_for_new_host(agent_id, old, tries \\ 50) do
    case BranchSupervisor.host_pid(agent_id) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when tries > 0 ->
        Process.sleep(10)
        wait_for_new_host(agent_id, old, tries - 1)

      other ->
        other
    end
  end
end
