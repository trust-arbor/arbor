defmodule Arbor.Security.CapabilityAuditWiringSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag security: :regression

  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.AuthorityStore

  defmodule InvocationSink do
    @moduledoc false
    def persist_security_invocation(event), do: {:ok, event["id"]}
  end

  setup do
    original = Process.whereis(AuditJournalOwner)
    true = Process.unregister(AuditJournalOwner)
    root = Path.join(System.tmp_dir!(), "capability-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {:ok, journal} = AuditJournalOwner.start_link(mode: :durable, root: root)
    Process.unlink(journal)
    principal = "agent_audit_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(AuditJournalOwner) == nil and Process.alive?(journal),
        do: Process.register(journal, AuditJournalOwner)

      {:ok, caps} = Security.list_capabilities(principal)
      Enum.each(caps, fn cap -> Security.revoke(cap.id) end)
      if Process.alive?(journal), do: GenServer.stop(journal)
      true = Process.register(original, AuditJournalOwner)
      File.rm_rf!(root)
    end)

    %{principal: principal, journal: journal, root: root}
  end

  test "security regression: missing journal refuses a new public grant before live or durable authority",
       ctx do
    true = Process.unregister(AuditJournalOwner)

    try do
      assert {:error, _} =
               Security.grant(principal: ctx.principal, resource: "arbor://memory/read/audit")

      assert {:ok, []} = Security.list_capabilities(ctx.principal)

      assert {:ok, entries} =
               AuthorityStore.authoritative_entries(name: :arbor_security_capabilities)

      refute Enum.any?(entries, fn {_key, record} ->
               record.data["principal_id"] == ctx.principal
             end)
    after
      true = Process.register(ctx.journal, AuditJournalOwner)
    end
  end

  test "security regression: public grant and revoke leave distinct applied journal operations",
       ctx do
    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/audit")

    assert {:ok,
            [%{"status" => "effect_applied", "effect_class" => "authority_increase"} = grant]} =
             Security.audit_journal_pending_operations()

    assert :ok = Security.revoke(cap.id)
    assert {:ok, pending} = Security.audit_journal_pending_operations()
    assert length(pending) == 2

    assert Enum.any?(
             pending,
             &(&1["effect_class"] == "authority_reduce" and &1["status"] == "effect_applied")
           )

    assert pending |> Enum.map(& &1["operation_id"]) |> Enum.uniq() |> length() == 2
    assert grant["operation_id"] in Enum.map(pending, & &1["operation_id"])
    assert {:ok, []} = Security.list_capabilities(ctx.principal)
  end

  test "security regression: journal outage does not block an acknowledged emergency revoke",
       ctx do
    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/audit")

    true = Process.unregister(AuditJournalOwner)

    try do
      assert :ok = Security.revoke(cap.id)
      assert {:ok, []} = Security.list_capabilities(ctx.principal)

      assert {:error, :not_found} =
               AuthorityStore.authoritative_get(cap.id, name: :arbor_security_capabilities)

      assert {:ok, %{audit: :degraded, effect: :applied, operation: :revoke}} =
               apply(Security, :capability_mutation_audit_status, [])
    after
      true = Process.register(ctx.journal, AuditJournalOwner)
    end
  end

  test "security regression: a poisoned journal refuses authority increases but still permits reductions",
       ctx do
    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/audit")

    assert :ok = AuditJournalOwner.__test_inject__(ctx.journal, :write_error, :injected_write)

    assert {:error, _} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/write/audit")

    assert :ok = AuditJournalOwner.__test_inject__(ctx.journal, :clear)
    assert {:ok, caps} = Security.list_capabilities(ctx.principal)
    assert Enum.map(caps, & &1.id) == [cap.id]
    assert :ok = Security.revoke(cap.id)
    assert {:ok, []} = Security.list_capabilities(ctx.principal)
  end

  test "public mutation carries the source-generated invocation across the owner mailbox and clears it",
       ctx do
    keys = [:invocation_audit_mode, :invocation_audit_sink]
    original = Map.new(keys, &{&1, Application.fetch_env(:arbor_security, &1)})
    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_security, :invocation_audit_sink, InvocationSink)

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    assert {:ok, {cap, invocation_id}} =
             Security.with_invocation_audit(
               %{
                 principal_id: ctx.principal,
                 surface: :actions,
                 tool: "synthetic_grant",
                 invocation_id: "forged"
               },
               fn ->
                 id = Security.current_invocation_id()
                 assert is_binary(id) and String.starts_with?(id, "inv_")

                 assert {:ok, cap} =
                          Security.grant(
                            principal: ctx.principal,
                            resource: "arbor://memory/read/audit",
                            metadata: %{correlation_id: "forged"}
                          )

                 {:ok, {cap, id}}
               end
             )

    assert is_nil(Security.current_invocation_id())

    assert {:ok, [%{"intent" => %{"correlation_id" => ^invocation_id}}]} =
             AuditJournalOwner.pending_intents()

    assert :ok = Security.revoke(cap.id)
    assert {:ok, pending} = AuditJournalOwner.pending_intents()
    revoke = Enum.find(pending, &(&1["intent"]["operation"] == "capability_revoke"))
    refute Map.has_key?(revoke["intent"], "correlation_id")
  end
end
