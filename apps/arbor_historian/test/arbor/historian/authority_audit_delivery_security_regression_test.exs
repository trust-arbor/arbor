defmodule Arbor.Historian.AuthorityAuditDeliverySecurityRegressionTest do
  use Arbor.Persistence.DatabaseCase, async: false

  @moduletag :database
  @moduletag :integration
  @moduletag security: :regression

  alias Arbor.Historian
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore

  defmodule LostAckBackend do
    @moduledoc false
    alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
    def durability_class(opts), do: EctoEventLog.durability_class(opts)
    def read_stream(stream, opts), do: EctoEventLog.read_stream(stream, opts)

    def append(stream, events, opts) do
      {:ok, _} = EctoEventLog.append(stream, events, opts)
      {:error, :lost_ack}
    end
  end

  defmodule JournalOutageBackend do
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

      if match?({:ok, _}, result) do
        :ok = AuditJournalOwner.__test_inject__(AuditJournalOwner, :write_error, :after_store_ack)
      end

      result
    end
  end

  setup ctx do
    :ok = Security.TestBootstrap.start!()
    original = Process.whereis(AuditJournalOwner)
    true = Process.unregister(AuditJournalOwner)
    root = Path.join(System.tmp_dir!(), "historian-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {:ok, journal} = AuditJournalOwner.start_link(mode: :durable, root: root)
    Process.unlink(journal)
    original_store = install_journal_outage_store(ctx, root)
    old_target = Application.fetch_env(:arbor_historian, :durable_event_log_target)
    Application.put_env(:arbor_historian, :durable_event_log_target, target(EctoEventLog))
    principal = "agent_delivery_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = Process.whereis(Arbor.Historian.AuthorityAuditPuller), do: GenServer.stop(pid)
      {:ok, caps} = Security.list_capabilities(principal)
      Enum.each(caps, &Security.revoke(&1.id))
      GenServer.stop(Process.whereis(AuditJournalOwner))
      true = Process.register(original, AuditJournalOwner)
      restore_authority_store(original_store)

      case old_target do
        {:ok, value} -> Application.put_env(:arbor_historian, :durable_event_log_target, value)
        :error -> Application.delete_env(:arbor_historian, :durable_event_log_target)
      end

      File.rm_rf!(root)
    end)

    {:ok, cap} = Security.grant(principal: principal, resource: "arbor://memory/read/delivery")
    {:ok, [pending]} = Security.audit_journal_pending_operations()
    %{id: pending["operation_id"], cap: cap, journal: journal, root: root}
  end

  test "security regression: real SQL content acknowledgement drains a public grant exactly once",
       ctx do
    start_puller!()
    assert {:ok, %{delivered: 1, pending: 0}} = apply(Historian, :flush_authority_audit, [])
    assert {:ok, []} = Security.audit_journal_pending_operations()
    assert {:ok, status} = Security.audit_journal_status()
    assert status["capacity"]["retained_operation_count"] == 1
    assert {:ok, [event]} = read(ctx.id)
    assert event.id == ctx.id
    assert event.data["intent"]["audit"]["data"]["capability_id"] == ctx.cap.id
    assert event.data["effect"] == "applied"
    assert event.event_number == 1

    assert Persistence.canonical_event_fingerprint(event.stream_id, event) ==
             event.operation_fingerprint

    assert {:ok, %{delivered: 0, pending: 0}} = apply(Historian, :flush_authority_audit, [])
    assert {:ok, [^event]} = read(ctx.id)
  end

  test "security regression: lost append ACK is reconciled from actual SQL content without a duplicate",
       ctx do
    Application.put_env(:arbor_historian, :durable_event_log_target, target(LostAckBackend))
    start_puller!()
    assert {:ok, %{delivered: 1, pending: 0}} = apply(Historian, :flush_authority_audit, [])
    assert {:ok, [_event]} = read(ctx.id)
    assert {:ok, []} = Security.audit_journal_pending_operations()
  end

  @tag journal_restart: true
  test "security regression: journal-only restart recovers a known disk effect and delivers once while CapabilityStore stays alive",
       ctx do
    capabilities = Process.whereis(CapabilityStore)

    assert {:ok, %{audit: :degraded, effect: :applied}} =
             apply(Security, :capability_mutation_audit_status, [])

    assert {:ok, [%{"status" => "prepared"}]} = Security.audit_journal_pending_operations()
    assert {:ok, []} = read(ctx.id)
    GenServer.stop(ctx.journal)
    {:ok, journal} = AuditJournalOwner.start_link(mode: :durable, root: ctx.root)
    Process.unlink(journal)

    assert {:ok, [%{"status" => "prepared"}]} = Security.audit_journal_pending_operations()
    start_puller!()
    assert {:ok, %{delivered: 1, pending: 0}} = apply(Historian, :flush_authority_audit, [])
    assert Process.whereis(CapabilityStore) == capabilities
    assert Process.alive?(capabilities)
    assert {:ok, [%{id: id}]} = Security.list_capabilities(ctx.cap.principal_id)
    assert id == ctx.cap.id
    assert {:ok, []} = Security.audit_journal_pending_operations()
    assert {:ok, [event]} = read(ctx.id)
    assert event.id == ctx.id
    assert event.data["intent"]["audit"]["data"]["capability_id"] == ctx.cap.id
    assert {:ok, %{delivered: 0, pending: 0}} = apply(Historian, :flush_authority_audit, [])
    assert {:ok, [^event]} = read(ctx.id)

    assert {:error, :unauthorized_audit_consumer} =
             apply(Security, :reconcile_authority_audit, [])
  end

  test "security regression: conflicting SQL payload never acknowledges the journal", ctx do
    stream = stream(ctx.id)
    bad = Event.new(stream, "capability_granted", %{"wrong" => "body"}, id: ctx.id)

    assert {:ok, [_]} =
             Persistence.append(:historian_durable_event_log, EctoEventLog, stream, bad,
               repo: Repo
             )

    start_puller!()
    assert {:ok, %{delivered: 0, pending: 1}} = apply(Historian, :flush_authority_audit, [])

    assert {:ok, [%{"operation_id" => id, "status" => "effect_applied"}]} =
             Security.audit_journal_pending_operations()

    assert id == ctx.id
    assert {:ok, [%{data: %{"wrong" => "body"}}]} = read(ctx.id)
  end

  test "security regression: a volatile target or forged caller ACK cannot erase pending audit",
       ctx do
    name = :authority_audit_volatile_test
    start_supervised!({ETS, name: name})

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: name,
      backend: ETS,
      opts: []
    })

    start_puller!()
    assert {:ok, %{delivered: 0, pending: 1}} = apply(Historian, :flush_authority_audit, [])

    assert {:error, :unauthorized_audit_consumer} =
             apply(Security, :acknowledge_authority_audit, [ctx.id, String.duplicate("0", 64)])

    assert {:error, :unauthorized_audit_consumer} =
             apply(Security, :authority_audit_delivery_batch, [])

    assert {:ok, []} = Persistence.read_stream(name, ETS, stream(ctx.id))
    assert {:ok, [_]} = Security.audit_journal_pending_operations()
  end

  defp start_puller! do
    # Manual flush is executed by the real registered production consumer.
    start_supervised!({Arbor.Historian.AuthorityAuditPuller, poll_interval_ms: 60_000})
  end

  defp install_journal_outage_store(%{journal_restart: true}, root) do
    name = :arbor_security_capabilities
    original = Process.whereis(name)
    true = Process.unregister(name)

    {:ok, store} =
      AuthorityStore.start_link(
        name: name,
        namespace: "historian-journal-recovery",
        backend: JournalOutageBackend,
        backend_opts: [base_dir: Path.join(root, "authority")]
      )

    Process.unlink(store)
    original
  end

  defp install_journal_outage_store(_ctx, _root), do: nil

  defp restore_authority_store(nil), do: :ok

  defp restore_authority_store(original) do
    name = :arbor_security_capabilities
    GenServer.stop(Process.whereis(name))
    true = Process.register(original, name)
    :ok = Supervisor.terminate_child(Security.Supervisor, CapabilityStore)
    {:ok, _} = Supervisor.restart_child(Security.Supervisor, CapabilityStore)
  end

  defp target(backend),
    do: %{name: :historian_durable_event_log, backend: backend, opts: [repo: Repo]}

  defp stream(id), do: "security:authority_mutation:" <> id

  defp read(id),
    do:
      Persistence.read_stream(:historian_durable_event_log, EctoEventLog, stream(id), repo: Repo)
end
