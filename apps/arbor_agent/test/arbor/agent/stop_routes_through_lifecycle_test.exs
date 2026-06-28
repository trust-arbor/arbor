defmodule Arbor.Agent.StopRoutesThroughLifecycleTest do
  @moduledoc """
  Regression (2026-06-28): `Arbor.Agent.stop/1` must tear down agents that run
  under the MODERN supervision tree (UserSupervisor → user_sup:<principal> →
  BranchSupervisor), not just legacy ones.

  Pre-fix, `stop/1` delegated to `Supervisor.stop_agent_by_id/1`, which calls
  `DynamicSupervisor.terminate_child(Arbor.Agent.Supervisor, pid)`. Every agent
  created via `Lifecycle` lives under a per-user BranchSupervisor — NOT a child
  of the legacy `Arbor.Agent.Supervisor` — so `terminate_child` returned
  `{:error, :not_found}` and the agent was never stopped. (Surfaced live by the
  TUI `/stop` command: the agent was plainly running yet `/stop` reported "agent
  not running (404)".)

  The fix routes `stop/1` through `Lifecycle.stop/1` (which stops the whole
  BranchSupervisor tree and unregisters), guarded by a registry existence check
  so a genuinely-absent agent still reports `{:error, :not_found}`.

  This test mirrors `Arbor.Agent.BranchSupervisorTest`: a minimal stub-host
  supervisor registered under `ExecutorRegistry {:branch, agent_id}` (so
  `BranchSupervisor.whereis/1` resolves it) AND in `Arbor.Agent.Registry` (so
  `stop/1`'s existence check passes) — but NOT under `Arbor.Agent.Supervisor`,
  which is exactly the legacy-only teardown's blind spot.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Registry, as: AgentRegistry

  defmodule StubHost do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> :ok end)
  end

  test "stop/1 tears down a BranchSupervisor-backed (Lifecycle-style) agent" do
    agent_id = "stop-lifecycle-#{System.unique_integer([:positive])}"

    children = [Supervisor.child_spec({StubHost, []}, id: :host, restart: :permanent)]

    # A real per-agent supervisor registered the way Lifecycle registers it:
    # under ExecutorRegistry {:branch, agent_id}. NOT a child of
    # Arbor.Agent.Supervisor — the legacy teardown's blind spot.
    {:ok, sup_pid} =
      Supervisor.start_link(children,
        strategy: :rest_for_one,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}}}
      )

    on_exit(fn -> if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid) end)

    :ok = AgentRegistry.register(agent_id, sup_pid, %{supervisor_pid: sup_pid})
    assert {:ok, ^sup_pid} = AgentRegistry.whereis(agent_id)

    ref = Process.monitor(sup_pid)

    # The fix: stop/1 → Lifecycle.stop/1 stops the BranchSupervisor tree and
    # unregisters. Pre-fix this returned {:error, :not_found} and left the
    # supervisor running.
    assert :ok = Arbor.Agent.stop(agent_id)

    assert_receive {:DOWN, ^ref, :process, ^sup_pid, _}, 11_000
    refute Process.alive?(sup_pid)
    assert {:error, :not_found} = AgentRegistry.whereis(agent_id)
  end

  test "stop/1 still reports :not_found for an agent that isn't running" do
    refute_running = "stop-absent-#{System.unique_integer([:positive])}"
    assert {:error, :not_found} = Arbor.Agent.stop(refute_running)
  end
end
