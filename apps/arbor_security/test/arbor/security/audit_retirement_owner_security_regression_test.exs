defmodule Arbor.Security.AuditRetirementOwnerSecurityRegressionTest do
  @moduledoc """
  Exact-parent security regressions for the journal owner's terminal-identity
  retirement (Floor-and-Ledger v3, slice 3).

  Written to run unchanged against the parent 52a2cc3fa: only APIs that exist
  on both commits are used (the owner's GenServer message protocol, the arity-0
  facade functions, `AuditJournalFileCore.encode_compacted/2` and
  `CapabilityAuditCore.intent/6`, which emits a v2 intent on the parent and a
  v3 intent on the candidate). Each test fails on the parent for the bug's
  reason: the live exhausted journal refuses every new prepare with
  `:capacity_exhausted`, and a delivered terminal is answered as a live
  `"delivered"` prepare instead of an identity refusal.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag security: :regression

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.CapabilityAuditCore
  alias Arbor.Security.Contracts.AuditJournal

  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 40,
    "committed_offset" => 100_000
  }
  @now "2026-09-28T12:00:00Z"
  @later "2026-09-28T12:05:00Z"

  test "security regression: 4096 delivered identities no longer refuse the 4097th prepared" do
    root = unique_root()
    # The live exhausted shape (runbook: one v2 operational snapshot, 4096
    # delivered terminals, nothing pending), written with an encoder that exists
    # on both commits.
    terminals = delivered_terminals(4096)
    write_journal(root, v2_snapshot(terminals))
    swap_registered_owner!(mode: :durable, root: root, capacity_profile: :operational)

    intent = grant_intent("cap_" <> String.duplicate("7", 32), @now)
    result = AuditJournalOwner.prepare(AuditJournalOwner, intent)

    # Parent 52a2cc3fa: {:error, :capacity_exhausted}. 4096 delivered
    # identities are a lifetime quota there: retained 4097 > 4096 refuses every
    # prepare and no compaction can reclaim a terminal.
    assert {:ok, admitted, "prepared"} = result
    assert admitted["operation_id"] == intent["operation_id"]

    assert {:ok, status} = AuditJournalOwner.status()
    assert status["capacity"]["retained_operation_count"] == 1
    assert status["capacity"]["retired_operation_total"] == 4096
    assert status["retirement"]["floor"] == 3
    assert status["retirement"]["ledger_frames"] == 1
    assert status["retirement"]["ledger_state"] == "bound"
    assert status["committed_frames"] == 2
    assert status["serving"] == true

    # Nothing was lost: the one cold ledger frame holds exactly the 4096
    # compact strings that left the hot snapshot.
    assert ledger_entries(root) == terminals
    assert File.stat!(ledger_path(root)).mode |> Bitwise.band(0o777) == 0o600

    # The public boundary grants again on the formerly exhausted journal.
    principal = "agent_retire_live_#{System.unique_integer([:positive])}"
    on_exit(fn -> revoke_all(principal) end)

    assert {:ok, _cap} =
             Security.grant_fixture(
               principal: principal,
               resource: "arbor://memory/read/retirement"
             )
  end

  test "security regression: prepare on a delivered terminal answers :operation_terminal before and after compaction" do
    root = unique_root()
    name = :"audit_retire_terminal_#{System.unique_integer([:positive])}"
    register_consumer!()
    # The small profile never retires, so a compaction keeps the delivered
    # identity hot as fingerprints (the "after compaction" case).
    {:ok, pid} = AuditJournalOwner.start_link(mode: :durable, root: root, name: name)
    Process.unlink(pid)
    on_exit(fn -> stop(pid) end)

    target = grant_intent("cap_" <> String.duplicate("1", 32), @now)
    deliver!(name, target)
    assert {:ok, delivered_status} = AuditJournalOwner.status(name)

    # Same facts, a later observation time: the same operation identity.
    retry = grant_intent("cap_" <> String.duplicate("1", 32), @later)
    assert retry["operation_id"] == target["operation_id"]

    # Parent 52a2cc3fa: {:ok, target, "delivered"} — an uncompacted delivered
    # identity was answered like a live prepare (the facade then refused the
    # reduction as :audit_unavailable), while the same identity compacted was
    # :operation_terminal.
    assert {:error, :operation_terminal} = AuditJournalOwner.prepare(name, retry)
    assert {:error, :operation_terminal} = AuditJournalOwner.prepare(name, target)
    assert {:ok, after_refusal} = AuditJournalOwner.status(name)
    assert after_refusal["committed_frames"] == delivered_status["committed_frames"]

    # Fill the small journal until a capacity refusal publishes a compaction.
    compact_by_capacity!(name)
    assert {:ok, compacted} = AuditJournalOwner.status(name) |> drop_refusal()
    # The compacted terminal is still hot (small never retires).
    assert Enum.any?(
             :sys.get_state(pid).core["operations"],
             fn {id, op} -> id == target["operation_id"] and Map.has_key?(op, "fingerprints") end
           )

    assert {:error, :operation_terminal} = AuditJournalOwner.prepare(name, retry)
    assert {:error, :operation_terminal} = AuditJournalOwner.prepare(name, target)
    assert {:ok, ^compacted} = AuditJournalOwner.status(name) |> drop_refusal()
  end

  test "security regression: an unknown v2 prepare after cutover is refused :retired_version through the owner and never publishes" do
    root = unique_root()
    name = :"audit_retire_floor_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      AuditJournalOwner.start_link(
        mode: :durable,
        root: root,
        name: name,
        capacity_profile: :operational
      )

    Process.unlink(pid)
    on_exit(fn -> stop(pid) end)
    assert {:ok, before} = AuditJournalOwner.status(name)

    {:ok, v2} =
      AuditJournal.admit_intent(%{
        "version" => 2,
        "kind" => "arbor.security.authority_mutation_intent.v2",
        "operation" => "capability_grant",
        "effect_class" => "authority_increase",
        "authority_namespace" => "capability",
        "authority_key" => "cap_" <> String.duplicate("2", 32),
        "before_fence" => %{"kind" => "absent"},
        "after_fingerprint" => %{
          "kind" => "live",
          "record_id" => "record-v2",
          "generation" => 1,
          "revision" => 1,
          "capability_digest" => String.duplicate("ab", 32)
        },
        "audit" => %{
          "event_type" => "capability_granted",
          "data" => %{
            "capability_id" => "cap_" <> String.duplicate("2", 32),
            "principal_id" => "agent_retirement_fixture",
            "resource_uri" => "arbor://memory/read/retirement"
          }
        },
        "prepared_at" => @now
      })

    # Parent 52a2cc3fa: {:ok, v2, "prepared"} — no admission floor; the v2
    # identity of a retired operation would be admitted as brand new.
    assert {:error, :retired_version} = AuditJournalOwner.prepare(name, v2)
    assert {:ok, after_refusal} = AuditJournalOwner.status(name) |> drop_refusal()
    assert after_refusal == elem(drop_refusal({:ok, before}), 1)
    refute File.exists?(ledger_path(root))
  end

  # ---------------------------------------------------------------------------

  # `last_refusal` does not exist on the parent; every other field must be
  # unchanged by a refusal.
  defp drop_refusal({:ok, status}), do: {:ok, Map.delete(status, "last_refusal")}

  defp deliver!(name, intent) do
    assert {:ok, _, "prepared"} = AuditJournalOwner.prepare(name, intent)

    assert {:ok, :committed} =
             AuditJournalOwner.observe(name, intent["operation_id"], :applied)

    assert {:ok, batch} = AuditJournalOwner.delivery_batch(name)
    item = Enum.find(batch, &(&1["operation_id"] == intent["operation_id"]))

    assert {:ok, :committed} =
             AuditJournalOwner.acknowledge_delivery(
               name,
               item["operation_id"],
               item["intent_sha256"]
             )
  end

  # Full lifecycles until a prepare is refused and relieved by one compaction
  # (the frame count drops to the snapshot plus the retried record).
  defp compact_by_capacity!(name) do
    Enum.reduce_while(2..40, nil, fn n, _acc ->
      assert {:ok, before} = AuditJournalOwner.status(name)

      deliver!(
        name,
        grant_intent("cap_" <> String.pad_leading(Integer.to_string(n), 32, "0"), @now)
      )

      assert {:ok, now} = AuditJournalOwner.status(name)

      if now["committed_frames"] < before["committed_frames"],
        do: {:halt, :ok},
        else: {:cont, nil}
    end)
    |> case do
      :ok -> :ok
      nil -> flunk("no compaction happened")
    end
  end

  defp grant_intent(capability_id, now) do
    data = %{
      "id" => capability_id,
      "principal_id" => "agent_retirement_fixture",
      "resource_uri" => "arbor://memory/read/retirement"
    }

    after_entry = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, after_entry, data, now)
    intent
  end

  defp v2_snapshot(terminals) do
    %{
      "version" => 2,
      "kind" => AuditJournal.operational_snapshot_kind(),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => terminals,
      "capacity_profile" => "operational"
    }
  end

  defp delivered_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp write_journal(root, snapshot) do
    {:ok, bytes, _replay} = FileCore.encode_compacted(snapshot, [])
    path = Path.join(root, "audit_journal.v1.log")
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
  end

  defp ledger_path(root), do: Path.join(root, "audit_journal.v1.retirement.v1.log")

  defp ledger_entries(root) do
    bytes = File.read!(ledger_path(root))
    header_size = FileCore.header_size()
    {:ok, header} = FileCore.decode_header(binary_part(bytes, 0, header_size))
    assert byte_size(bytes) == header_size + header.payload_len
    payload = binary_part(bytes, header_size, header.payload_len)
    Jason.decode!(payload)["retired"]
  end

  # Swap the registered journal owner (as the capability wiring regressions
  # do) so the arity-0 facade and CapabilityStore reach this journal.
  defp swap_registered_owner!(opts) do
    original = Process.whereis(AuditJournalOwner)
    true = Process.unregister(AuditJournalOwner)
    {:ok, journal} = AuditJournalOwner.start_link(opts)
    Process.unlink(journal)
    :ok = AuditJournalOwner.install_test_fixture(journal)

    on_exit(fn ->
      :ok = AuditJournalOwner.clear_test_fixture()
      if Process.alive?(journal), do: GenServer.stop(journal)

      if Process.whereis(AuditJournalOwner) == nil,
        do: Process.register(original, AuditJournalOwner)
    end)

    journal
  end

  defp register_consumer! do
    name = :"audit_retire_consumer_#{System.unique_integer([:positive])}"
    true = Process.register(self(), name)
    previous = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)

    previous_application =
      Application.fetch_env(:arbor_security, :authority_audit_consumer_application)

    Application.put_env(:arbor_security, :authority_audit_consumer_name, name)
    Application.put_env(:arbor_security, :authority_audit_consumer_application, :test)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_name, value)

        :error ->
          Application.delete_env(:arbor_security, :authority_audit_consumer_name)
      end

      case previous_application do
        {:ok, value} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_application, value)

        :error ->
          Application.delete_env(:arbor_security, :authority_audit_consumer_application)
      end
    end)

    name
  end

  defp revoke_all(principal) do
    case Security.list_capabilities(principal) do
      {:ok, caps} -> Enum.each(caps, &Security.revoke_fixture(&1.id))
      _ -> :ok
    end
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp unique_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "audit-retire-owner-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
