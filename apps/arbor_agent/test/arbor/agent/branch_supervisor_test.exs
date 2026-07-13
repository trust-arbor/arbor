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
  alias Arbor.Agent.BranchSupervisor.BootstrapCleanup
  alias Arbor.Contracts.Security.Identity

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

  @tag :security_regression
  test "security regression: cleanup supervisor shutdown permanently closes its bootstrap" do
    ensure_signing_authority_stack!()
    {:ok, identity} = Identity.generate(name: "branch-bootstrap-cleanup")
    :ok = Arbor.Security.register_identity(Identity.public_only(identity))

    on_exit(fn ->
      _ = Arbor.Security.delete_signing_key(identity.agent_id)
      _ = Arbor.Security.deregister_identity(identity.agent_id)
    end)

    :ok = Arbor.Security.store_signing_key(identity.agent_id, identity.private_key)

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :branch_supervisor_cleanup,
        owner: self()
      )

    {:ok, bootstrap} = Arbor.Security.issue_signing_authority_bootstrap(proof)

    supervisor =
      start_supervised!(%{
        id: :bootstrap_cleanup_test_supervisor,
        start:
          {Supervisor, :start_link,
           [[{BootstrapCleanup, bootstraps: %{session: bootstrap}}], [strategy: :one_for_one]]}
      })

    [{_, cleanup, :worker, _}] = Supervisor.which_children(supervisor)
    cleanup_monitor = Process.monitor(cleanup)

    assert :ok = stop_supervised(:bootstrap_cleanup_test_supervisor)
    assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup, :shutdown}, 1_000

    assert {:error, :bootstrap_not_found} = Arbor.Security.claim_signing_authority(bootstrap)
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

  defp ensure_signing_authority_stack! do
    {:ok, _} = Application.ensure_all_started(:arbor_security)

    for {name, collection} <- [
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      unless Process.whereis(name) do
        child =
          Supervisor.child_spec(
            {Arbor.Persistence.BufferedStore,
             name: name, backend: nil, write_mode: :sync, collection: collection},
            id: name
          )

        case Supervisor.start_child(Arbor.Security.Supervisor, child) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, {:already_present, _id}} -> :ok
        end
      end
    end

    ensure_security_child!(Arbor.Security.Identity.Registry, [])
    ensure_security_child!(Arbor.Security.Identity.NonceCache, [])

    case {Process.whereis(Arbor.Security.SigningAuthorityStateOwner),
          Process.whereis(Arbor.Security.SigningAuthorityBroker)} do
      {nil, nil} ->
        token = make_ref()
        ensure_security_child!(Arbor.Security.SigningAuthorityStateOwner, broker_token: token)
        ensure_security_child!(Arbor.Security.SigningAuthorityBroker, state_owner_token: token)

      {owner, broker} when is_pid(owner) and is_pid(broker) ->
        :ok

      partial ->
        flunk("partial signing authority stack: #{inspect(partial)}")
    end
  end

  defp ensure_security_child!(module, opts) do
    unless Process.whereis(module) do
      case Supervisor.start_child(Arbor.Security.Supervisor, {module, opts}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _id}} -> :ok
      end
    end
  end
end
