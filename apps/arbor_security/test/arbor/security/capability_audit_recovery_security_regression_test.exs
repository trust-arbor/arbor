defmodule Arbor.Security.CapabilityAuditRecoverySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag security: :regression

  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore

  defmodule PostEffectFaultBackend do
    @moduledoc false
    alias Arbor.Security.AuditJournalOwner
    alias Arbor.Security.Store.JSONFile
    defdelegate put(key, value, opts), to: JSONFile
    defdelegate get(key, opts), to: JSONFile
    defdelegate delete(key, opts), to: JSONFile
    defdelegate list(opts), to: JSONFile
    defdelegate bounded_list(limit, opts), to: JSONFile
    defdelegate durability_class(opts), to: JSONFile
    defdelegate authoritative_entry(key, opts), to: JSONFile
    defdelegate compare_and_swap(key, expected, value, opts), to: JSONFile
    defdelegate compare_and_delete(key, expected, opts), to: JSONFile

    def compare_and_create(key, expected, value, opts) do
      result = JSONFile.compare_and_create(key, expected, value, opts)

      if match?({:ok, _}, result) and
           Application.get_env(:arbor_security, :audit_recovery_post_effect_fault, false) do
        Application.delete_env(:arbor_security, :audit_recovery_post_effect_fault)
        :ok = AuditJournalOwner.__test_inject__(AuditJournalOwner, :write_error, :after_store_ack)
        {:error, :lost_store_ack}
      else
        result
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "audit-recovery-#{System.unique_integer([:positive])}")
    journal_root = Path.join(root, "journal")
    File.mkdir_p!(journal_root)
    File.chmod!(journal_root, 0o700)
    store_name = :arbor_security_capabilities
    original_store = Process.whereis(store_name)
    original_journal = Process.whereis(AuditJournalOwner)
    true = Process.unregister(store_name)
    true = Process.unregister(AuditJournalOwner)
    journal_opts = [mode: :durable, root: journal_root]

    store_opts = [
      name: store_name,
      namespace: "audit-recovery",
      backend: PostEffectFaultBackend,
      backend_opts: [base_dir: Path.join(root, "authority")]
    ]

    start_owned!(AuthorityStore, store_opts)
    start_owned!(AuditJournalOwner, journal_opts)
    principal = "agent_audit_recovery_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:arbor_security, :audit_recovery_post_effect_fault)
      stop_named!(AuditJournalOwner)
      stop_named!(store_name)
      true = Process.register(original_store, store_name)
      true = Process.register(original_journal, AuditJournalOwner)
      restart_capabilities!()
      File.rm_rf!(root)
    end)

    %{principal: principal, store_opts: store_opts, journal_opts: journal_opts}
  end

  test "security regression: known real disk grant remains successful after both ACK paths fail and cold recovery observes it",
       ctx do
    Application.put_env(:arbor_security, :audit_recovery_post_effect_fault, true)

    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/recovery")

    assert {:ok, %{audit: :degraded, effect: :applied}} =
             apply(Security, :capability_mutation_audit_status, [])

    assert {:ok, [%{"status" => "prepared"}]} = Security.audit_journal_pending_operations()
    cold_restart!(ctx)
    assert {:ok, [%{id: id}]} = Security.list_capabilities(ctx.principal)
    assert id == cap.id
    assert {:ok, [%{"status" => "effect_applied"}]} = Security.audit_journal_pending_operations()
  end

  test "security regression: transient grant followed by emergency revoke remains unresolved after cold recovery",
       ctx do
    Application.put_env(:arbor_security, :audit_recovery_post_effect_fault, true)

    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/recovery")

    assert :ok = Security.revoke(cap.id)
    assert {:ok, []} = Security.list_capabilities(ctx.principal)
    cold_restart!(ctx)
    assert {:ok, []} = Security.list_capabilities(ctx.principal)
    # A later tombstone is not proof that this prepared grant never existed.
    assert {:ok, [%{"status" => "prepared", "effect_class" => "authority_increase"}]} =
             Security.audit_journal_pending_operations()
  end

  defp cold_restart!(ctx) do
    stop_named!(AuditJournalOwner)
    stop_named!(:arbor_security_capabilities)
    start_owned!(AuthorityStore, ctx.store_opts)
    start_owned!(AuditJournalOwner, ctx.journal_opts)
    restart_capabilities!()
  end

  defp restart_capabilities! do
    :ok = Supervisor.terminate_child(Security.Supervisor, CapabilityStore)
    {:ok, _} = Supervisor.restart_child(Security.Supervisor, CapabilityStore)
  end

  defp start_owned!(module, opts) do
    {:ok, pid} = module.start_link(opts)
    Process.unlink(pid)
    pid
  end

  defp stop_named!(name) do
    if pid = Process.whereis(name), do: GenServer.stop(pid)
  end
end
