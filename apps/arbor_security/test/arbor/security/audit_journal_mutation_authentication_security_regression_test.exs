defmodule Arbor.Security.AuditJournalMutationAuthenticationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-011"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.CapabilityAuditCore
  alias Arbor.Security.CapabilityStore

  @principal "agent_" <> String.duplicate("a", 64)
  @prepared_at "2026-10-07T12:00:00Z"

  setup do
    original = Process.whereis(Owner)
    assert is_pid(original)
    assert Process.unregister(Owner)

    assert {:ok, journal} =
             Owner.start_link(mode: :ephemeral, name: Owner, capacity_profile: :operational)

    Process.unlink(journal)
    :ok = Owner.install_test_fixture(journal)

    on_exit(fn ->
      :ok = Owner.clear_test_fixture()
      if Process.alive?(journal), do: GenServer.stop(journal)

      if Process.whereis(Owner) == nil and Process.alive?(original),
        do: Process.register(original, Owner)
    end)

    :ok
  end

  @tag spec: "SSEC-011"
  test "security regression: an arbitrary pid cannot reserve journal quota" do
    intent = grant_intent(1)
    assert {:ok, before} = Owner.status()

    attacker = Task.async(fn -> Owner.prepare(intent) end)

    assert {:error, :audit_mutation_unauthorized} = Task.await(attacker)
    assert {:ok, after_attempt} = Owner.status()
    assert after_attempt["entry_count"] == before["entry_count"]
    assert after_attempt["pending_count"] == before["pending_count"]

    assert after_attempt["capacity"]["used_entries"] ==
             before["capacity"]["used_entries"]

    assert after_attempt["capacity"]["reserved_entries"] ==
             before["capacity"]["reserved_entries"]

    assert {:ok, []} = Owner.pending_intents()
  end

  test "security regression: a forged raw GenServer append cannot impersonate CapabilityStore" do
    intent = grant_intent(3)
    assert {:ok, before} = Owner.status()
    capability_store = Process.whereis(CapabilityStore)
    assert is_pid(capability_store)

    assert {:error, :audit_mutation_unauthorized} =
             forged_call(capability_store, {:append, prepared_record(intent)})

    assert {:ok, after_attempt} = Owner.status()
    assert after_attempt["entry_count"] == before["entry_count"]
    assert after_attempt["pending_count"] == before["pending_count"]

    assert after_attempt["capacity"]["reserved_entries"] ==
             before["capacity"]["reserved_entries"]

    assert {:ok, []} = Owner.pending_intents()
  end

  test "security regression: an arbitrary pid cannot terminalize a guessed operation id" do
    intent = grant_intent(2)
    assert {:ok, admitted, "prepared"} = Owner.prepare(Owner, intent)
    assert admitted["operation_id"] == intent["operation_id"]
    assert {:ok, before} = Owner.status()

    attacker = Task.async(fn -> Owner.observe(intent["operation_id"], :applied) end)

    assert {:error, :audit_mutation_unauthorized} = Task.await(attacker)
    assert {:ok, after_attempt} = Owner.status()
    assert after_attempt["entry_count"] == before["entry_count"]
    assert after_attempt["pending_count"] == before["pending_count"]

    assert {:ok, pending} = Owner.pending_intents()

    assert %{"status" => "prepared", "intent" => ^intent} =
             Enum.find(pending, &(&1["intent"]["operation_id"] == intent["operation_id"]))
  end

  test "the CapabilityStore owner remains the authenticated journal writer" do
    principal = "agent_audit_writer_#{System.unique_integer([:positive])}"
    resource = "arbor://memory/read/audit-writer-#{System.unique_integer([:positive])}"

    assert {:ok, cap} = Security.grant_fixture(principal: principal, resource: resource)
    assert {:ok, pending} = Owner.pending_intents()

    assert %{"status" => "effect_applied"} =
             Enum.find(pending, &(&1["intent"]["authority_key"] == cap.id))

    assert :ok = Security.revoke_fixture(cap.id)
  end

  defp grant_intent(n) do
    capability_id = "cap_" <> String.pad_leading(Integer.to_string(n), 32, "0")

    data = %{
      "id" => capability_id,
      "principal_id" => @principal,
      "resource_uri" => "arbor://memory/read/audit-mutation-authentication"
    }

    replacement = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, replacement, data, @prepared_at)
    intent
  end

  defp prepared_record(intent) do
    %{
      "version" => 1,
      "kind" => "arbor.security.authority_mutation_record.v1",
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp forged_call(victim, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(Owner, {:"$gen_call", {victim, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged audit-journal call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end
end
