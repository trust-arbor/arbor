defmodule Arbor.Security.CapabilityMutationAuditRetirementFacadeTest do
  @moduledoc """
  Terminal-identity retirement (Floor-and-Ledger v3, slice 3) through the
  capability mutation facade: the path `Security.grant/1` and
  `Security.revoke/1` take (`CapabilityStore` -> `CapabilityMutationAudit` ->
  journal owner), not the owner's test arities.

  - Cutover continuity: a v2 grant pending at cutover is continued by the same
    capability's v3 retry. The facade executes and observes with the returned
    v2 original, so one identity exists; it is later delivered and retired.
  - Section 4.5 rows: a grant whose identity is already terminal is refused
    with reason class `:identity`; a revoke whose identity is already terminal
    executes degraded (exact CAD) with reason `:identity`; under a paused
    ledger at the 4096-retained endpoint a revoke executes degraded with
    reason `:capacity`.

  New-API tests: on the parent 52a2cc3fa they fail by absence (no v3
  producer, no reason class, no retirement).

  `async: false`: the registered journal owner is swapped, and the test
  process registers as the authority audit consumer through Application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security
  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityAuditCore
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.Contracts.AuditJournal
  alias Arbor.Security.SystemAuthority

  @store :arbor_security_capabilities
  @time "2026-09-28T12:00:00Z"
  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 40,
    "committed_offset" => 100_000
  }
  @degraded [:arbor, :security, :audit_journal, :degraded_reduction]
  @refused [:arbor, :security, :audit_journal, :refused]
  @retired [:arbor, :security, :audit_journal, :retired]

  setup do
    original = Process.whereis(Owner)
    principal = "agent_retire_facade_#{System.unique_integer([:positive])}"
    handler = "cma-retire-facade-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [@degraded, @refused, @retired],
        &__MODULE__.forward_event/4,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      current = Process.whereis(Owner)

      if current != original do
        if current, do: Process.unregister(Owner)
        Process.register(original, Owner)
      end

      case Security.list_capabilities(principal) do
        {:ok, caps} -> Enum.each(caps, &Security.revoke(&1.id))
        _ -> :ok
      end
    end)

    %{principal: principal}
  end

  @doc false
  def forward_event(event, measurements, metadata, pid),
    do: send(pid, {:audit_event, event, measurements, metadata})

  test "cutover continuity: a v2 grant pending at cutover is continued by the same capability's retry",
       ctx do
    register_consumer!()
    cap = signed_capability(ctx.principal, "arbor://memory/read/cutover")
    v3 = grant_intent(cap)
    v2 = v2_twin(v3)
    refute v2["operation_id"] == v3["operation_id"]

    # The journal the pre-cutover producer left: 3070 kept terminals and the
    # capability's v2 grant prepared but never applied.
    root = unique_root()
    write_v2_journal(root, rejected_terminals(3070), [prepared_record(v2)])
    swap_owner!(root)
    # T1 cut the v2 snapshot over (nothing delivered to retire) and kept the
    # pending v2 operation.
    assert [{%{count: 0}, %{trigger: :boot}}] = drain(@retired)
    assert status!()["retirement"]["floor"] == 3

    # The capability store's retry of the same capability (what Security.grant
    # does with a freshly signed one) continues the v2 operation.
    assert {:ok, :stored} = CapabilityStore.put(cap)
    assert {:ok, stored} = AuthorityStore.authoritative_entry(cap.id, name: @store)
    assert %Record{} = stored

    assert {:ok, pending} = Security.audit_journal_pending_operations()
    assert [%{"operation_id" => id, "status" => "effect_applied"}] = pending
    assert id == v2["operation_id"]
    assert {:ok, %{operation: :grant, effect: :applied, audit: :recorded}} = audit_status()
    assert {:ok, %{operation_id: ^id}} = audit_status()

    # Delivered by the consumer, then retired by the next capacity relief.
    assert {:ok, [item]} = Owner.delivery_batch()
    assert item["operation_id"] == id
    assert {:ok, :committed} = Owner.acknowledge_delivery(id, item["intent_sha256"])

    assert {:ok, _} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/cutover/1")

    assert [] = drain(@retired)

    assert {:ok, _} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/cutover/2")

    assert [{%{count: 1}, %{trigger: :capacity}}] = drain(@retired)
    status = status!()
    assert status["capacity"]["retired_operation_total"] == 1
    assert status["retirement"]["ledger_state"] == "bound"
  end

  test "a grant whose identity is already terminal is refused with reason class :identity", ctx do
    register_consumer!()
    swap_owner!(unique_root())
    cap = signed_capability(ctx.principal, "arbor://memory/read/terminal")
    intent = grant_intent(cap)
    deliver!(intent)
    drain(@refused)

    # The authority store never saw the capability; the journal already holds
    # the identical grant as delivered.
    capture_log([level: :warning], fn ->
      assert {:error, :audit_unavailable} = CapabilityStore.put(cap)
    end)

    assert [{%{count: 1}, %{operation: :grant, reason: :identity}}] = drain(@refused)

    assert {:ok, %{operation: :grant, effect: :not_applied, audit: :refused, reason: :identity}} =
             audit_status()

    assert status!()["last_refusal"] == "operation_terminal"
    assert {:ok, :absent} = AuthorityStore.authoritative_entry(cap.id, name: @store)
  end

  test "a revoke whose identity is already terminal executes degraded with reason :identity",
       ctx do
    register_consumer!()
    swap_owner!(unique_root())

    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/revoked")

    assert {:ok, %Record{} = before} = AuthorityStore.authoritative_entry(cap.id, name: @store)

    {:ok, revoke} =
      CapabilityAuditCore.intent(
        :revoke,
        before,
        {:tombstone, before.generation},
        before.data,
        @time
      )

    deliver!(revoke)
    drain(@degraded)

    log = capture_log([level: :warning], fn -> assert :ok = Security.revoke(cap.id) end)

    assert [{%{count: 1}, %{reason: :identity}}] = drain(@degraded)
    assert {:ok, status} = audit_status()
    assert %{operation: :revoke, effect: :applied, audit: :degraded, reason: :identity} = status

    if status.degraded_reductions <= 10 or rem(status.degraded_reductions, 100) == 0,
      do: assert(log =~ "reason identity")

    assert status!()["last_refusal"] == "operation_terminal"
    assert {:ok, []} = Security.list_capabilities(ctx.principal)
  end

  test "under a paused ledger the 4096-retained endpoint degrades reductions with the warning",
       ctx do
    swap_owner!(unique_root())

    assert {:ok, cap} =
             Security.grant(principal: ctx.principal, resource: "arbor://memory/read/paused")

    # 3585 kept terminals plus 511 delivered ones a healthy ledger would retire.
    root = unique_root()
    write_journal(root, v3_snapshot(rejected_terminals(3585), delivered_terminals(511)))
    plant_ledger(root, "stale ledger bytes")

    log =
      capture_log([level: :warning], fn ->
        swap_owner!(root)
        assert :ok = Security.revoke(cap.id)
      end)

    assert log =~ "retirement ledger is ahead"
    assert [{%{count: 1}, %{reason: :capacity}}] = drain(@degraded)
    assert [] = drain(@retired)
    assert {:ok, status} = audit_status()
    assert %{operation: :revoke, effect: :applied, audit: :degraded, reason: :capacity} = status

    if status.degraded_reductions <= 10 or rem(status.degraded_reductions, 100) == 0,
      do: assert(log =~ "reason capacity")

    journal = status!()
    assert journal["retirement"]["ledger_state"] == "ahead"
    assert journal["admission_open"] == false
    assert journal["last_refusal"] == "capacity_exhausted"
    assert journal["capacity"]["retirable_operation_count"] == 511
    assert {:ok, []} = Security.list_capabilities(ctx.principal)
  end

  # ---------------------------------------------------------------------------

  defp status! do
    assert {:ok, status} = Security.audit_journal_status()
    status
  end

  defp audit_status, do: Security.capability_mutation_audit_status()

  # Drive `intent` to delivered on the registered owner as the consumer.
  defp deliver!(intent) do
    assert {:ok, _, "prepared"} = Owner.prepare(intent)
    assert {:ok, :committed} = Owner.observe(intent["operation_id"], :applied)
    assert {:ok, batch} = Owner.delivery_batch()
    item = Enum.find(batch, &(&1["operation_id"] == intent["operation_id"]))

    assert {:ok, :committed} =
             Owner.acknowledge_delivery(item["operation_id"], item["intent_sha256"])
  end

  defp signed_capability(principal, resource) do
    {:ok, cap} = Capability.new(resource_uri: resource, principal_id: principal)
    {:ok, signed} = SystemAuthority.sign_capability(cap)
    signed
  end

  # Exactly the intent CapabilityMutationAudit.put/2 derives for a new
  # capability (before :absent); prepared_at is not part of the identity.
  defp grant_intent(cap) do
    assert {:ok, :absent} = AuthorityStore.authoritative_entry(cap.id, name: @store)
    data = Serializer.serialize(cap)
    after_entry = CapabilityAuditCore.replacement(Record.new(cap.id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, after_entry, data, @time)
    assert intent["version"] == 3
    intent
  end

  # The identity the pre-cutover (v2) producer derived for the same facts.
  defp v2_twin(v3) do
    {:ok, v2} =
      v3
      |> Map.drop(["operation_id"])
      |> Map.merge(%{"version" => 2, "kind" => AuditJournal.intent_kind(2)})
      |> AuditJournal.admit_intent()

    assert {:ok, v2["operation_id"]} == AuditJournal.legacy_alias_operation_id(v3)
    v2
  end

  defp prepared_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp register_consumer! do
    name = :"cma_retire_consumer_#{System.unique_integer([:positive])}"
    true = Process.register(self(), name)
    previous = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)
    Application.put_env(:arbor_security, :authority_audit_consumer_name, name)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_name, value)

        :error ->
          Application.delete_env(:arbor_security, :authority_audit_consumer_name)
      end
    end)

    name
  end

  # Replace whichever owner is registered (the application's original is
  # restored on exit) with a durable operational owner on `root`.
  defp swap_owner!(root) do
    current = Process.whereis(Owner)
    true = Process.unregister(Owner)

    {:ok, journal} =
      Owner.start_link(mode: :durable, root: root, capacity_profile: :operational)

    Process.unlink(journal)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
    end)

    if current && Process.get({__MODULE__, :swapped, current}),
      do: GenServer.stop(current)

    Process.put({__MODULE__, :swapped, journal}, true)
    journal
  end

  defp drain(event, acc \\ []) do
    receive do
      {:audit_event, ^event, measurements, metadata} ->
        drain(event, [{measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Journal fixtures

  defp journal_path(root), do: Path.join(root, "audit_journal.v1.log")
  defp ledger_path(root), do: Path.join(root, "audit_journal.v1.retirement.v1.log")

  defp write_journal(root, snapshot, pending \\ []) do
    {:ok, bytes, _replay} = FileCore.encode_compacted(snapshot, pending)
    File.write!(journal_path(root), bytes)
    File.chmod!(journal_path(root), 0o600)
  end

  defp write_v2_journal(root, terminals, records) do
    {:ok, empty} = Core.new(:operational)

    state =
      Enum.reduce(records, empty, fn record, acc ->
        {:ok, next} = Core.append(acc, record)
        next
      end)

    {:ok, _compacted, v3, pending} = Core.compact(state, @source)

    v2 =
      v3
      |> Map.delete("retirement")
      |> Map.merge(%{
        "version" => 2,
        "kind" => AuditJournal.operational_snapshot_kind(),
        "terminals" => Map.merge(v3["terminals"], terminals)
      })

    write_journal(root, v2, pending)
  end

  defp plant_ledger(root, bytes) do
    File.write!(ledger_path(root), bytes)
    File.chmod!(ledger_path(root), 0o600)
  end

  defp v3_snapshot(rejected, delivered) do
    %{
      "version" => 3,
      "kind" => AuditJournal.snapshot_kind(3),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => Map.merge(rejected, delivered),
      "capacity_profile" => "operational",
      "retirement" => %{"retired_total" => 0, "ledger" => AuditJournal.ledger_genesis_binding()}
    }
  end

  defp delivered_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp rejected_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:rejected_op, n}),
       "effect_rejected|authority_increase|#{sha({:ri, n})}|prepared:#{sha({:rp, n})}|" <>
         "effect_rejected:#{sha({:rr, n})}"}
    end)
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp unique_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cma-retire-facade-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
