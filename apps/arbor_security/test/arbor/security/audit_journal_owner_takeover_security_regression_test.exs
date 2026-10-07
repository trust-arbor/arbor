defmodule Arbor.Security.AuditJournalOwnerTakeoverSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-011"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SupervisedOwner

  @tag spec: "SSEC-011"
  test "security regression: a predecessor journal name takeover cannot admit an unjournaled grant" do
    previous_fixture =
      Application.fetch_env(:arbor_security, :audit_journal_owner_test_fixture)

    :ok = AuditJournalOwner.clear_test_fixture()

    {:ok, actor} = Identity.generate(name: "audit-journal-takeover-actor")
    {:ok, target} = Identity.generate(name: "audit-journal-takeover-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)

    {:ok, mutation_capability} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/grant/#{target.agent_id}"
      )

    {:ok, authority} = open_authority(actor)

    {:ok, root} = SupervisedOwner.application_root(:arbor_security)

    journal =
      SupervisedOwner.registered_child(
        AuditJournalOwner,
        :arbor_security,
        [AuditJournalOwner]
      )

    store =
      SupervisedOwner.registered_child(CapabilityStore, :arbor_security, [CapabilityStore])

    assert is_pid(journal)
    assert is_pid(store)

    parent = self()
    resource = "arbor://memory/read/audit-journal-takeover-#{System.unique_integer([:positive])}"

    try do
      # Deterministically hold the predecessor down while its later
      # rest_for_one sibling remains live, then occupy the public name before
      # exercising the real capability facade.
      assert :ok = Supervisor.terminate_child(root, AuditJournalOwner)
      refute Process.alive?(journal)
      assert Process.alive?(store)

      squatter =
        spawn(fn ->
          true = Process.register(self(), AuditJournalOwner)
          send(parent, {:squatter_ready, self()})
          fake_journal_loop(parent)
        end)

      assert_receive {:squatter_ready, ^squatter}

      assert {:error, :audit_unavailable} =
               Security.grant(
                 principal: target.agent_id,
                 resource: resource,
                 actor_authority: authority
               )

      refute_receive {:fake_journal_called, _request}, 100
      assert {:ok, []} = Security.list_capabilities(target.agent_id)
    after
      stop_squatter()
      restart_journal(root)

      case Security.list_capabilities(target.agent_id) do
        {:ok, caps} -> Enum.each(caps, &Security.revoke_fixture(&1.id))
        _ -> :ok
      end

      Security.close_signing_authority(authority)
      Security.revoke_fixture(mutation_capability.id)
      Security.deregister_identity_fixture(target.agent_id)
      Security.deregister_identity_fixture(actor.agent_id)
      restore_fixture(previous_fixture)
    end
  end

  defp open_authority(identity) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :audit_journal_takeover_security_regression
           ) do
      Security.open_ephemeral_signing_authority(proof, identity.private_key)
    end
  end

  defp fake_journal_loop(parent) do
    receive do
      {:"$gen_call", {from, tag}, {:prepare, _proof, intent} = request} ->
        send(parent, {:fake_journal_called, request})
        send(from, {tag, {:ok, intent, "prepared"}})
        fake_journal_loop(parent)

      {:"$gen_call", {from, tag}, {:observe, _proof, _operation_id, _observation} = request} ->
        send(parent, {:fake_journal_called, request})
        send(from, {tag, {:ok, :committed}})
        fake_journal_loop(parent)

      {:"$gen_call", {from, tag}, request} ->
        send(parent, {:fake_journal_called, request})
        send(from, {tag, {:error, :unexpected_request}})
        fake_journal_loop(parent)

      _other ->
        fake_journal_loop(parent)
    end
  end

  defp stop_squatter do
    case Process.whereis(AuditJournalOwner) do
      pid when is_pid(pid) ->
        Process.unregister(AuditJournalOwner)
        Process.exit(pid, :kill)

      nil ->
        :ok
    end
  end

  defp restart_journal(root) do
    case Supervisor.restart_child(root, AuditJournalOwner) do
      {:ok, pid} when is_pid(pid) -> await_registered(pid, 100)
      {:ok, pid, _info} when is_pid(pid) -> await_registered(pid, 100)
      {:error, :running} -> :ok
      {:error, reason} -> flunk("failed to restart audit journal: #{inspect(reason)}")
    end
  end

  defp await_registered(_pid, 0), do: flunk("audit journal did not re-register")

  defp await_registered(pid, attempts) do
    if Process.whereis(AuditJournalOwner) == pid do
      :ok
    else
      Process.sleep(10)
      await_registered(pid, attempts - 1)
    end
  end

  defp restore_fixture({:ok, pid}),
    do: Application.put_env(:arbor_security, :audit_journal_owner_test_fixture, pid)

  defp restore_fixture(:error),
    do: Application.delete_env(:arbor_security, :audit_journal_owner_test_fixture)
end
