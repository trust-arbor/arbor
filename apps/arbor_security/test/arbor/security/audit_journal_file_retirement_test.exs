defmodule Arbor.Security.AuditJournalFileRetirementTest do
  @moduledoc """
  File-layer retirement of delivered terminals into the cold retirement ledger
  (Floor-and-Ledger v3, slice 2): the `:ledger_append` publication phase, the
  ledger postures at open (`:absent | :bound | :bound_orphan | :mismatch |
  :ahead`), the crash boundaries of a retiring publication, mixed v1/v2/v3
  snapshots, boot-time retirement (`ensure_retirement_current/1`, T1) and open
  determinism.

  Parent 52a2cc3fa: `AuditJournalFile.compact/2`, `ensure_retirement_current/1`,
  `ledger_state/1` and the ledger modules do not exist, and operational
  publications emit v2 snapshots that keep every delivered terminal hot. These
  tests therefore fail on the parent by absence of the retirement API; the
  "security invariant:" tests pin the evidence-preservation and fail-closed
  rules of the new publication phase. The exact-parent live-shape regression
  through the owner is slice 3.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.AuditRetirementLedgerCore, as: LedgerCore
  alias Arbor.Security.Contracts.AuditJournal

  @time "2026-09-28T12:00:00Z"
  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 40,
    "committed_offset" => 100_000
  }
  @journal_name "audit_journal.v1.log"
  @ledger_name "audit_journal.v1.retirement.v1.log"

  setup do
    AuditJournalFile.__test_inject__(:clear)
    on_exit(fn -> AuditJournalFile.__test_inject__(:clear) end)
    %{root: unique_root()}
  end

  describe "retiring publication" do
    test "security invariant: a retiring publication writes the retired compact strings to one 0600 ledger frame and binds it",
         %{root: root} do
      {handle, batch} = retiring_fixture(root)
      assert AuditJournalFile.ledger_state(handle) == :absent
      assert ledger_binding(handle) == AuditJournal.ledger_genesis_binding()
      refute File.exists?(ledger_path(root))

      assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)

      stat = File.lstat!(ledger_path(root))
      assert stat.type == :regular
      assert Bitwise.band(stat.mode, 0o777) == 0o600
      assert stat.links == 1

      assert [frame] = decode_ledger(root)
      snapshot = published.core["snapshot"]
      assert frame.batch["retired"] == batch
      assert frame.batch["source"] == snapshot["source"]
      assert stat.size == 72 + frame.len

      assert snapshot["version"] == 3
      assert snapshot["retirement"]["retired_total"] == 3

      assert snapshot["retirement"]["ledger"] == %{
               "frames" => 1,
               "tip_offset" => 0,
               "tip_len" => frame.len,
               "tip_digest" => hex(frame.digest)
             }

      for id <- Map.keys(batch), do: refute(Map.has_key?(published.core["operations"], id))
      assert Core.retirable_count(published.core) == 0
      # The pending prepared and the rejected terminal stay hot.
      assert map_size(published.core["operations"]) == 2
      assert map_size(snapshot["terminals"]) == 1
      assert Core.admission_floor(published.core) == 3
      assert AuditJournalFile.ledger_state(published) == :bound

      assert :ok = AuditJournalFile.close(published)
      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :bound
      assert FileCore.core_match?(reopened.core, published.core)
      assert :ok = AuditJournalFile.close(reopened)
    end

    test "a non-retiring publication carries the binding unchanged; the next retiring one appends frame 2 at the bound",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      bound = ledger_binding(first)
      ledger_bytes = File.read!(ledger_path(root))

      first = deliver(first, 3, 4..5)
      assert {:ok, carried} = AuditJournalFile.compact(first)
      assert ledger_binding(carried) == bound
      assert retired_total(carried) == 3
      assert Core.retirable_count(carried.core) == 2
      assert File.read!(ledger_path(root)) == ledger_bytes
      assert AuditJournalFile.ledger_state(carried) == :bound

      {:ok, second_batch} = Core.retirement_batch(carried.core)
      assert {:ok, second} = AuditJournalFile.compact(carried, retire: true)
      assert [first_frame, second_frame] = decode_ledger(root)
      {:ok, bound_size} = AuditJournal.ledger_bound_size(bound)
      assert first_frame.offset == 0
      assert second_frame.offset == bound_size
      assert second_frame.batch["retired"] == second_batch

      assert ledger_binding(second) == %{
               "frames" => 2,
               "tip_offset" => bound_size,
               "tip_len" => second_frame.len,
               "tip_digest" => hex(second_frame.digest)
             }

      assert retired_total(second) == 5
      assert AuditJournalFile.ledger_state(second) == :bound
      assert :ok = AuditJournalFile.close(second)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :bound
      assert :ok = AuditJournalFile.close(reopened)
    end

    test "a retiring publication with nothing delivered writes no ledger", %{root: root} do
      handle = operational(root) |> append_all([record(intent(3, 1), "prepared")])
      assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)
      refute File.exists?(ledger_path(root))
      assert ledger_binding(published) == AuditJournal.ledger_genesis_binding()
      assert AuditJournalFile.ledger_state(published) == :absent
    end

    test "compact/1 and compact(retire: false) never retire", %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, kept} = AuditJournalFile.compact(handle)
      assert Core.retirable_count(kept.core) == 3
      assert {:ok, kept} = AuditJournalFile.compact(kept, retire: false)
      assert Core.retirable_count(kept.core) == 3
      assert retired_total(kept) == 0
      refute File.exists?(ledger_path(root))
    end

    test "retire: true on the small profile never retires and touches no ledger", %{root: root} do
      {:ok, small} = AuditJournalFile.open(root: root)
      small = deliver(small, 3, 1..2)
      assert {:ok, compacted} = AuditJournalFile.compact(small, retire: true)
      assert compacted.core["snapshot"]["version"] == 1
      assert map_size(compacted.core["snapshot"]["terminals"]) == 2
      refute File.exists?(ledger_path(root))
    end

    test "unknown or non-boolean compact options are refused before any IO", %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      before = File.read!(journal_path(root))

      for opts <- [[retire: :yes], [unknown: true], [{"retire", true}], :retire] do
        assert {:error, {:not_published, :malformed}} = AuditJournalFile.compact(handle, opts)
      end

      assert File.read!(journal_path(root)) == before
      refute File.exists?(ledger_path(root))
    end

    test "an explicit :path journal gets its own ledger derived from its basename", %{root: root} do
      path = Path.join(root, "custom.log")
      {:ok, handle} = AuditJournalFile.open(root: root, path: path)
      {:ok, handle} = AuditJournalFile.ensure_capacity_profile(handle, :operational)
      handle = deliver(handle, 3, 1..2)
      assert {:ok, _published} = AuditJournalFile.compact(handle, retire: true)
      assert File.exists?(Path.join(root, "custom.retirement.v1.log"))
      refute File.exists?(ledger_path(root))
    end

    test "security invariant: promotion keeps every delivered terminal hot and never touches the ledger",
         %{root: root} do
      {:ok, small} = AuditJournalFile.open(root: root)
      small = deliver(small, 3, 1..2)
      assert :ok = AuditJournalFile.close(small)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert Core.profile(reopened.core) == :small
      assert {:ok, promoted} = AuditJournalFile.ensure_capacity_profile(reopened, :operational)

      snapshot = promoted.core["snapshot"]
      assert snapshot["version"] == 3
      assert map_size(snapshot["terminals"]) == 2

      assert snapshot["retirement"] == %{
               "retired_total" => 0,
               "ledger" => AuditJournal.ledger_genesis_binding()
             }

      assert Core.retirable_count(promoted.core) == 2
      assert Core.admission_floor(promoted.core) == 3
      refute File.exists?(ledger_path(root))
      assert AuditJournalFile.ledger_state(promoted) == :absent
    end

    test "security invariant: promotion under a stale foreign ledger keeps terminals hot and leaves the ledger untouched",
         %{root: root} do
      {:ok, small} = AuditJournalFile.open(root: root)
      small = deliver(small, 3, 1..2)
      assert :ok = AuditJournalFile.close(small)
      plant_ledger(root, "not a retirement ledger")

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :ahead
      assert {:ok, promoted} = AuditJournalFile.ensure_capacity_profile(reopened, :operational)
      assert map_size(promoted.core["snapshot"]["terminals"]) == 2
      assert AuditJournalFile.ledger_state(promoted) == :ahead
      assert File.read!(ledger_path(root)) == "not a retirement ledger"
    end
  end

  describe "crash boundaries of a retiring publication" do
    for {inject, reason} <- [
          compact_sync_error: :sync_failed,
          compact_after_sync_error: :candidate_proof_failed
        ] do
      test "#{inject} before the ledger phase leaves no ledger bytes and the hot set unchanged",
           %{root: root} do
        {handle, batch} = retiring_fixture(root)
        before = File.read!(journal_path(root))

        AuditJournalFile.__test_inject__(unquote(inject), :eio)

        assert {:error, {:not_published, unquote(reason)}} =
                 AuditJournalFile.compact(handle, retire: true)

        AuditJournalFile.__test_inject__(:clear)

        refute File.exists?(ledger_path(root))
        assert File.read!(journal_path(root)) == before
        refute_candidate(root)
        assert Core.retirable_count(handle.core) == 3

        # The live handle retires normally once the fault clears.
        assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)
        assert_retired(published, root, batch)
      end
    end

    test "security invariant: a crash between the ledger frame and the rename leaves exactly one overwritable orphan",
         %{root: root} do
      {handle, batch} = retiring_fixture(root)
      before = File.read!(journal_path(root))

      AuditJournalFile.__test_inject__(:compact_rename_before_effect)

      assert {:error, {:not_published, :write_failed}} =
               AuditJournalFile.compact(handle, retire: true)

      AuditJournalFile.__test_inject__(:clear)

      assert File.read!(journal_path(root)) == before
      assert [orphan] = decode_ledger(root)
      assert orphan.batch["retired"] == batch
      # The in-memory tip is never advanced by a write.
      assert ledger_binding(handle) == AuditJournal.ledger_genesis_binding()
      assert :ok = AuditJournalFile.close(handle)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :bound_orphan
      assert Core.retirable_count(reopened.core) == 3
      assert ledger_binding(reopened) == AuditJournal.ledger_genesis_binding()

      reopened = deliver(reopened, 3, 4..4)
      {:ok, superset} = Core.retirement_batch(reopened.core)
      assert map_size(superset) == 4
      assert Map.take(superset, Map.keys(batch)) == batch

      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert [frame] = decode_ledger(root)
      assert frame.batch["retired"] == superset
      assert File.stat!(ledger_path(root)).size == 72 + frame.len
      assert AuditJournalFile.ledger_state(published) == :bound
      assert retired_total(published) == 4
    end

    test "the live handle overwrites its own orphan on its next retiring publication", %{
      root: root
    } do
      {handle, batch} = retiring_fixture(root)
      AuditJournalFile.__test_inject__(:compact_rename_before_effect)

      assert {:error, {:not_published, :write_failed}} =
               AuditJournalFile.compact(handle, retire: true)

      AuditJournalFile.__test_inject__(:clear)
      assert [_orphan] = decode_ledger(root)

      assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)
      assert_retired(published, root, batch)
    end

    test "a rename that lands before an ambiguous error is publish_uncertain and reopens v3 and bound",
         %{root: root} do
      {handle, batch} = retiring_fixture(root)
      AuditJournalFile.__test_inject__(:compact_rename_after_effect)

      assert {:error, {:publish_uncertain, :rename_ambiguous}} =
               AuditJournalFile.compact(handle, retire: true)

      AuditJournalFile.__test_inject__(:clear)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert_retired(reopened, root, batch)
      assert :ok = AuditJournalFile.close(reopened)
    end

    for {inject, reason} <- [
          compact_dir_sync: :dir_sync_failed,
          compact_reopen_error: :reopen_failed,
          compact_replay_error: :replay_mismatch
        ] do
      test "#{inject} after the rename is publish_uncertain and reopens v3 and bound", %{
        root: root
      } do
        {handle, batch} = retiring_fixture(root)
        AuditJournalFile.__test_inject__(unquote(inject), :eio)

        assert {:error, {:publish_uncertain, unquote(reason)}} =
                 AuditJournalFile.compact(handle, retire: true)

        AuditJournalFile.__test_inject__(:clear)

        assert {:ok, reopened} = AuditJournalFile.open(root: root)
        assert_retired(reopened, root, batch)
        assert :ok = AuditJournalFile.close(reopened)
      end
    end

    test "security invariant: a ledger write failure is not_published with nothing retired", %{
      root: root
    } do
      {handle, batch} = retiring_fixture(root)
      before = File.read!(journal_path(root))

      AuditJournalFile.__test_inject__(:ledger_write_error, :eio)

      assert {:error, {:not_published, :ledger_write_failed}} =
               AuditJournalFile.compact(handle, retire: true)

      AuditJournalFile.__test_inject__(:clear)

      refute_candidate(root)
      assert File.read!(journal_path(root)) == before
      assert decode_ledger(root) == []
      assert Core.retirable_count(handle.core) == 3

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert FileCore.core_match?(reopened.core, handle.core)
      # An empty ledger file at genesis binds nothing beyond its (empty) bound.
      assert AuditJournalFile.ledger_state(reopened) == :bound
      assert :ok = AuditJournalFile.close(reopened)

      assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)
      assert_retired(published, root, batch)
    end

    test "a failed directory fsync when the first frame is written is not_published and writes no frame",
         %{root: root} do
      {handle, batch} = retiring_fixture(root)
      AuditJournalFile.__test_inject__(:ledger_dir_sync, :eio)

      assert {:error, {:not_published, :ledger_write_failed}} =
               AuditJournalFile.compact(handle, retire: true)

      AuditJournalFile.__test_inject__(:clear)
      assert decode_ledger(root) == []
      assert Core.retirable_count(handle.core) == 3

      # Known-unsupported directory fsync keeps the journal's classification.
      AuditJournalFile.__test_inject__(:ledger_dir_sync, :enotsup)
      assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)
      AuditJournalFile.__test_inject__(:clear)
      assert_retired(published, root, batch)

      # The directory entry is fsynced only for the first frame.
      published = deliver(published, 3, 4..4)
      AuditJournalFile.__test_inject__(:ledger_dir_sync, :eio)
      assert {:ok, second} = AuditJournalFile.compact(published, retire: true)
      AuditJournalFile.__test_inject__(:clear)
      assert ledger_binding(second)["frames"] == 2
    end

    test "security invariant: a ledger shorter than its binding pauses retirement; publications still run, non-retiring",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      bound = ledger_binding(first)
      {:ok, bound_size} = AuditJournal.ledger_bound_size(bound)
      first = deliver(first, 3, 4..5)

      AuditJournalFile.__test_inject__(:ledger_truncate_below_bound)

      assert {:error, {:not_published, :ledger_write_failed}} =
               AuditJournalFile.compact(first, retire: true)

      AuditJournalFile.__test_inject__(:clear)
      assert File.stat!(ledger_path(root)).size == bound_size - 1
      short = File.read!(ledger_path(root))
      assert :ok = AuditJournalFile.close(first)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :mismatch
      assert Core.retirable_count(reopened.core) == 2

      # Never refused for posture: the publication runs, non-retiring.
      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert ledger_binding(published) == bound
      assert retired_total(published) == 3
      assert Core.retirable_count(published.core) == 2
      assert map_size(published.core["snapshot"]["terminals"]) == 3
      assert AuditJournalFile.ledger_state(published) == :mismatch
      assert File.read!(ledger_path(root)) == short

      # T1 has nothing it may do on a paused, current v3 journal.
      assert {:ok, ^published} = AuditJournalFile.ensure_retirement_current(published)
    end

    test "security invariant: frames beyond the bound are :ahead, never truncated, and publications run non-retiring",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      bound = ledger_binding(first)
      {:ok, second} = LedgerCore.frame(delivered_terminals(1..2), @source, bound)
      {:ok, third} = LedgerCore.frame(delivered_terminals(3..3), @source, second.next_binding)
      File.write!(ledger_path(root), second.frame <> third.frame, [:append])
      ahead = File.read!(ledger_path(root))
      first = deliver(first, 3, 4..5)
      assert :ok = AuditJournalFile.close(first)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :ahead
      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert ledger_binding(published) == bound
      assert Core.retirable_count(published.core) == 2
      assert AuditJournalFile.ledger_state(published) == :ahead
      assert File.read!(ledger_path(root)) == ahead
    end

    test "security invariant: one complete frame beyond the bound over non-hot entries is :ahead",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      {:ok, foreign} = LedgerCore.frame(delivered_terminals(1..1), @source, ledger_binding(first))
      File.write!(ledger_path(root), foreign.frame, [:append])
      ahead = File.read!(ledger_path(root))
      first = deliver(first, 3, 4..4)
      assert :ok = AuditJournalFile.close(first)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :ahead
      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert Core.retirable_count(published.core) == 1
      assert File.read!(ledger_path(root)) == ahead
    end

    test "security invariant: a live handle refuses to overwrite foreign bytes that appear beyond the bound",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      first = deliver(first, 3, 4..4)
      {:ok, foreign} = LedgerCore.frame(delivered_terminals(1..1), @source, ledger_binding(first))
      File.write!(ledger_path(root), foreign.frame, [:append])
      ahead = File.read!(ledger_path(root))

      assert {:error, {:not_published, :ledger_write_failed}} =
               AuditJournalFile.compact(first, retire: true)

      assert File.read!(ledger_path(root)) == ahead
      assert Core.retirable_count(first.core) == 1
    end

    test "security invariant: a binding naming frames with the ledger absent is :mismatch and the ledger is never re-created",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      first = deliver(first, 3, 4..5)
      assert :ok = AuditJournalFile.close(first)
      aside = ledger_path(root) <> ".moved"
      File.rename!(ledger_path(root), aside)
      moved = File.read!(aside)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :mismatch
      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert Core.retirable_count(published.core) == 2
      assert ledger_binding(published) == ledger_binding(first)
      refute File.exists?(ledger_path(root))
      assert File.read!(aside) == moved
    end

    test "security invariant: a bound tip frame that no longer recomputes to the bound digest is :mismatch",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      first = deliver(first, 3, 4..4)
      assert :ok = AuditJournalFile.close(first)
      path = ledger_path(root)
      bytes = File.read!(path)
      <<head::binary-size(100), byte, rest::binary>> = bytes
      tampered = <<head::binary, Bitwise.bxor(byte, 0x01), rest::binary>>
      File.write!(path, tampered)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :mismatch
      assert reopened.ledger.detail == :digest_mismatch
      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert Core.retirable_count(published.core) == 1
      assert File.read!(path) == tampered
    end

    test "security invariant: a paused posture changes only by restart, never by a later publication",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      first = deliver(first, 3, 4..4)
      assert :ok = AuditJournalFile.close(first)
      File.chmod!(ledger_path(root), 0o644)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :mismatch

      # The pair is "repaired" while the handle is live: still paused.
      File.chmod!(ledger_path(root), 0o600)
      assert {:ok, published} = AuditJournalFile.compact(reopened, retire: true)
      assert AuditJournalFile.ledger_state(published) == :mismatch
      assert {:ok, again} = AuditJournalFile.compact(published, retire: true)
      assert AuditJournalFile.ledger_state(again) == :mismatch
      assert Core.retirable_count(again.core) == 1
      assert :ok = AuditJournalFile.close(again)

      assert {:ok, restarted} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(restarted) == :bound
      assert {:ok, retired} = AuditJournalFile.compact(restarted, retire: true)
      assert Core.retirable_count(retired.core) == 0
      assert ledger_binding(retired)["frames"] == 2
    end

    test "security invariant: a ledger that fails the journal's file rules pauses retirement and is never written",
         %{root: root} do
      {handle, _batch} = retiring_fixture(root)
      assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
      first = deliver(first, 3, 4..4)
      assert :ok = AuditJournalFile.close(first)
      path = ledger_path(root)
      bytes = File.read!(path)

      File.chmod!(path, 0o644)
      assert_paused_open(root, :insecure_mode)
      File.chmod!(path, 0o600)

      link = Path.join(root, "ledger.hardlink")
      File.ln!(path, link)
      assert_paused_open(root, :hardlink_rejected)
      File.rm!(link)

      real = Path.join(root, "ledger.real")
      File.rename!(path, real)
      File.ln_s!(real, path)
      assert_paused_open(root, :symlink_rejected)
      File.rm!(path)
      File.rename!(real, path)

      assert File.read!(path) == bytes
      assert {:ok, restored} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(restored) == :bound
      assert :ok = AuditJournalFile.close(restored)
    end
  end

  describe "mixed snapshots" do
    test "security invariant: a promoted v1 small snapshot retires its v1 delivered terminals only when publishing retiring, then floors v1",
         %{root: root} do
      pending = intent(1, 3)
      {:ok, small} = AuditJournalFile.open(root: root)
      small = small |> deliver(1, 1..2) |> append_all([record(pending, "prepared")])
      assert {:ok, compacted} = AuditJournalFile.compact(small)
      assert compacted.core["snapshot"]["version"] == 1
      assert :ok = AuditJournalFile.close(compacted)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert {:ok, promoted} = AuditJournalFile.ensure_capacity_profile(reopened, :operational)
      snapshot = promoted.core["snapshot"]
      assert snapshot["version"] == 3
      assert map_size(snapshot["terminals"]) == 2
      assert map_size(snapshot["pending_manifest"]) == 1
      assert Core.retirable_count(promoted.core) == 2
      refute File.exists?(ledger_path(root))

      {:ok, v1_batch} = Core.retirement_batch(promoted.core)
      assert {:ok, retired} = AuditJournalFile.compact(promoted, retire: true)
      assert [frame] = decode_ledger(root)
      assert frame.batch["retired"] == v1_batch
      assert retired_total(retired) == 2

      # Exact re-append of the retained pending v1 prepared stays idempotent.
      assert {:ok, _same, :idempotent} =
               AuditJournalFile.append(retired, record(pending, "prepared"))

      # The pending v1 operation completes by id.
      retired =
        append_all(retired, [record(pending, "effect_applied"), record(pending, "delivered")])

      # A new v1 identity and a retired v1 identity are refused below the floor.
      assert {:error, :retired_version} =
               AuditJournalFile.append(retired, record(intent(1, 4), "prepared"))

      assert {:error, :retired_version} =
               AuditJournalFile.append(retired, record(intent(1, 1), "prepared"))

      assert {:ok, _admitted} = AuditJournalFile.append(retired, record(intent(3, 5), "prepared"))
    end

    test "security invariant: a v2 snapshot's pending v2 operations stay in the manifest through the retiring cutover and complete by id",
         %{root: root} do
      applied = intent(2, 5)
      prepared = intent(2, 6)

      write_v2_journal(
        root,
        Enum.flat_map(1..3, &lifecycle(intent(2, &1))) ++
          [
            record(applied, "prepared"),
            record(applied, "effect_applied"),
            record(prepared, "prepared")
          ]
      )

      assert {:ok, handle} = AuditJournalFile.open(root: root)
      assert handle.core["snapshot"]["version"] == 2
      assert Core.admission_floor(handle.core) == 1
      assert AuditJournalFile.ledger_state(handle) == :absent
      {:ok, batch} = Core.retirement_batch(handle.core)
      assert map_size(batch) == 3

      assert {:ok, cut} = AuditJournalFile.ensure_retirement_current(handle)
      snapshot = cut.core["snapshot"]
      assert snapshot["version"] == 3
      assert snapshot["terminals"] == %{}

      assert Enum.sort(Map.keys(snapshot["pending_manifest"])) ==
               Enum.sort([applied["operation_id"], prepared["operation_id"]])

      assert [frame] = decode_ledger(root)
      assert frame.batch["retired"] == batch
      assert Core.admission_floor(cut.core) == 3

      cut =
        append_all(cut, [
          record(applied, "delivered"),
          record(prepared, "effect_applied"),
          record(prepared, "delivered")
        ])

      {:ok, later} = Core.retirement_batch(cut.core)

      assert Enum.sort(Map.keys(later)) ==
               Enum.sort([applied["operation_id"], prepared["operation_id"]])

      assert {:ok, done} = AuditJournalFile.compact(cut, retire: true)
      assert [_first, second] = decode_ledger(root)
      assert second.batch["retired"] == later
      assert done.core["snapshot"]["pending_manifest"] == %{}
      assert retired_total(done) == 5

      assert {:error, :retired_version} =
               AuditJournalFile.append(done, record(intent(2, 9), "prepared"))
    end

    test "security invariant: the live exhausted shape (v2, 4096 delivered, nothing pending) retires into ledger frame 1 at T1",
         %{root: root} do
      terminals = delivered_terminals(1..4096)
      write_journal(root, v2_snapshot(terminals), [])

      assert {:ok, handle} = AuditJournalFile.open(root: root)
      assert Core.capacity(handle.core)["retained_operation_count"] == 4096

      assert {:error, refused} =
               AuditJournalFile.append(handle, record(intent(3, 1), "prepared"))

      assert refused in [:capacity_exhausted, :soft_capacity_exhausted]

      assert {:ok, cut} = AuditJournalFile.ensure_retirement_current(handle)
      assert retired_total(cut) == 4096
      assert cut.core["operations"] == %{}
      assert Core.admission_floor(cut.core) == 3
      assert ledger_binding(cut)["frames"] == 1
      assert [frame] = decode_ledger(root)
      assert frame.batch["retired"] == terminals
      assert :ok = AuditJournalFile.close(cut)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(reopened) == :bound
      assert retired_total(reopened) == 4096
      assert FileCore.core_match?(reopened.core, cut.core)

      assert {:ok, admitted} =
               AuditJournalFile.append(reopened, record(intent(3, 1), "prepared"))

      assert {:error, :retired_version} =
               AuditJournalFile.append(admitted, record(intent(2, 2), "prepared"))
    end
  end

  describe "ensure_retirement_current/1 (T1)" do
    test "does nothing on a current v3 journal with fewer than retire_batch retirable terminals",
         %{root: root} do
      handle = root |> operational() |> deliver(3, 1..2)
      assert {:ok, ^handle} = AuditJournalFile.ensure_retirement_current(handle)
      refute File.exists?(ledger_path(root))
    end

    test "publishes on a v3 journal once retire_batch delivered terminals are retirable", %{
      root: root
    } do
      write_journal(root, v3_snapshot(delivered_terminals(1..511)), [])
      assert {:ok, handle} = AuditJournalFile.open(root: root)
      assert AuditJournal.limits(:operational).retire_batch == 512
      assert {:ok, ^handle} = AuditJournalFile.ensure_retirement_current(handle)
      refute File.exists?(ledger_path(root))

      handle = deliver(handle, 3, 1..1)
      assert {:ok, published} = AuditJournalFile.ensure_retirement_current(handle)
      assert retired_total(published) == 512
      assert AuditJournalFile.ledger_state(published) == :bound
    end

    test "skips a torn-tail journal", %{root: root} do
      bytes = write_journal(root, v2_snapshot(delivered_terminals(1..3)), [])
      File.write!(journal_path(root), "AJL", [:append])

      assert {:ok, handle} = AuditJournalFile.open(root: root)
      assert handle.torn_tail != nil
      assert {:ok, ^handle} = AuditJournalFile.ensure_retirement_current(handle)
      assert File.read!(journal_path(root)) == bytes <> "AJL"
      refute File.exists?(ledger_path(root))
    end

    test "returns not_published with the original live handle", %{root: root} do
      write_journal(root, v2_snapshot(delivered_terminals(1..3)), [])
      assert {:ok, handle} = AuditJournalFile.open(root: root)

      AuditJournalFile.__test_inject__(:ledger_write_error, :eio)

      assert {:not_published, :ledger_write_failed, ^handle} =
               AuditJournalFile.ensure_retirement_current(handle)

      AuditJournalFile.__test_inject__(:clear)

      assert {:ok, _next} = AuditJournalFile.append(handle, record(intent(3, 1), "prepared"))
    end

    test "returns uncertain after an ambiguous post-rename fault", %{root: root} do
      terminals = delivered_terminals(1..3)
      write_journal(root, v2_snapshot(terminals), [])
      assert {:ok, handle} = AuditJournalFile.open(root: root)

      AuditJournalFile.__test_inject__(:compact_dir_sync, :eio)

      assert {:uncertain, {:publish_uncertain, :dir_sync_failed}} =
               AuditJournalFile.ensure_retirement_current(handle)

      AuditJournalFile.__test_inject__(:clear)

      assert {:ok, reopened} = AuditJournalFile.open(root: root)
      assert_retired(reopened, root, terminals)
      assert {:uncertain, :closed} = AuditJournalFile.ensure_retirement_current(:not_a_handle)
    end

    test "under a paused ledger a pre-v3 snapshot still becomes v3 with every terminal kept", %{
      root: root
    } do
      write_journal(root, v2_snapshot(delivered_terminals(1..3)), [])
      plant_ledger(root, "stale ledger bytes")

      assert {:ok, handle} = AuditJournalFile.open(root: root)
      assert AuditJournalFile.ledger_state(handle) == :ahead
      assert {:ok, published} = AuditJournalFile.ensure_retirement_current(handle)
      assert published.core["snapshot"]["version"] == 3
      assert Core.admission_floor(published.core) == 3
      assert map_size(published.core["snapshot"]["terminals"]) == 3
      assert retired_total(published) == 0
      assert File.read!(ledger_path(root)) == "stale ledger bytes"
    end
  end

  test "opening the same root twice yields an identical handle status", %{root: root} do
    {handle, _batch} = retiring_fixture(root)
    assert {:ok, first} = AuditJournalFile.compact(handle, retire: true)
    first = deliver(first, 3, 4..5)
    AuditJournalFile.__test_inject__(:compact_rename_before_effect)

    assert {:error, {:not_published, :write_failed}} =
             AuditJournalFile.compact(first, retire: true)

    AuditJournalFile.__test_inject__(:clear)
    assert :ok = AuditJournalFile.close(first)

    assert {:ok, a} = AuditJournalFile.open(root: root)
    status_a = status(a)
    assert :ok = AuditJournalFile.close(a)

    assert {:ok, b} = AuditJournalFile.open(root: root)
    status_b = status(b)
    assert :ok = AuditJournalFile.close(b)

    assert status_a == status_b
    assert status_a.ledger_state == :bound_orphan
  end

  # ---------------------------------------------------------------------------

  defp retiring_fixture(root) do
    rejected = revoke_intent(3, 50)

    handle =
      root
      |> operational()
      |> deliver(3, 1..3)
      |> append_all([
        record(intent(3, 10), "prepared"),
        record(rejected, "prepared"),
        rejected_record(rejected)
      ])

    {:ok, batch} = Core.retirement_batch(handle.core)
    assert map_size(batch) == 3
    {handle, batch}
  end

  defp assert_retired(handle, root, batch) do
    snapshot = handle.core["snapshot"]
    assert snapshot["version"] == 3
    assert snapshot["retirement"]["retired_total"] == map_size(batch)
    for id <- Map.keys(batch), do: refute(Map.has_key?(handle.core["operations"], id))
    assert AuditJournalFile.ledger_state(handle) == :bound
    assert [frame] = decode_ledger(root)
    assert frame.batch["retired"] == batch
    assert snapshot["retirement"]["ledger"]["tip_digest"] == hex(frame.digest)
  end

  defp assert_paused_open(root, detail) do
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert AuditJournalFile.ledger_state(handle) == :mismatch
    assert handle.ledger.detail == detail
    before = File.read!(ledger_path(root))
    assert {:ok, published} = AuditJournalFile.compact(handle, retire: true)
    assert Core.retirable_count(published.core) == Core.retirable_count(handle.core)
    assert File.read!(ledger_path(root)) == before
    assert :ok = AuditJournalFile.close(published)
  end

  defp status(handle) do
    %{
      evidence: AuditJournalFile.evidence(handle),
      core: handle.core,
      capacity: Core.capacity(handle.core, paused: false),
      pending: Core.pending_summary(handle.core, @time),
      ledger_state: AuditJournalFile.ledger_state(handle),
      ledger: Map.take(handle.ledger, [:path, :binding, :identity, :state, :detail])
    }
  end

  defp operational(root) do
    {:ok, handle} = AuditJournalFile.open(root: root)
    {:ok, handle} = AuditJournalFile.ensure_capacity_profile(handle, :operational)
    handle
  end

  defp deliver(handle, version, range) do
    append_all(handle, Enum.flat_map(range, &lifecycle(intent(version, &1))))
  end

  defp append_all(handle, records) do
    Enum.reduce(records, handle, fn record, acc ->
      case AuditJournalFile.append(acc, record) do
        {:ok, next} -> next
        {:ok, next, :idempotent} -> next
        other -> flunk("append failed: #{inspect(other)} for #{record["record_type"]}")
      end
    end)
  end

  defp ledger_binding(handle),
    do: AuditJournal.snapshot_retirement(handle.core["snapshot"])["ledger"]

  defp retired_total(handle),
    do: AuditJournal.snapshot_retirement(handle.core["snapshot"])["retired_total"]

  defp journal_path(root), do: Path.join(root, @journal_name)
  defp ledger_path(root), do: Path.join(root, @ledger_name)

  defp refute_candidate(root) do
    {:ok, name} = FileCore.candidate_basename(@journal_name)
    refute File.exists?(Path.join(root, name))
  end

  defp plant_ledger(root, bytes) do
    File.write!(ledger_path(root), bytes)
    File.chmod!(ledger_path(root), 0o600)
  end

  defp write_journal(root, snapshot, pending) do
    {:ok, bytes, _replay} = FileCore.encode_compacted(snapshot, pending)
    File.write!(journal_path(root), bytes)
    File.chmod!(journal_path(root), 0o600)
    bytes
  end

  # A legacy v2 operational snapshot (what the parent emits) over `records`.
  defp write_v2_journal(root, records) do
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
      |> Map.merge(%{"version" => 2, "kind" => AuditJournal.operational_snapshot_kind()})

    write_journal(root, v2, pending)
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

  defp v3_snapshot(terminals) do
    %{
      "version" => 3,
      "kind" => AuditJournal.snapshot_kind(3),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => terminals,
      "capacity_profile" => "operational",
      "retirement" => %{
        "retired_total" => 0,
        "ledger" => AuditJournal.ledger_genesis_binding()
      }
    }
  end

  defp delivered_terminals(range) do
    Map.new(range, fn n ->
      {sha({:op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp decode_ledger(root) do
    case File.read(ledger_path(root)) do
      {:ok, bytes} -> decode_frames(bytes, 0, FileCore.genesis_digest(), [])
      {:error, :enoent} -> flunk("ledger file is absent")
    end
  end

  defp decode_frames(bytes, offset, _predecessor, acc) when offset == byte_size(bytes),
    do: Enum.reverse(acc)

  defp decode_frames(bytes, offset, predecessor, acc) do
    {:ok, header} = FileCore.decode_header(binary_part(bytes, offset, 72))
    payload = binary_part(bytes, offset + 72, header.payload_len)
    assert header.predecessor == predecessor
    {:ok, digest} = FileCore.verify_frame(header, payload, predecessor)
    {:ok, batch} = LedgerCore.admit_batch_payload(payload)
    entry = %{offset: offset, len: header.payload_len, digest: digest, batch: batch}
    decode_frames(bytes, offset + 72 + header.payload_len, digest, [entry | acc])
  end

  defp hex(digest), do: Base.encode16(digest, case: :lower)

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp lifecycle(intent) do
    [record(intent, "prepared"), record(intent, "effect_applied"), record(intent, "delivered")]
  end

  defp intent(version, n) do
    {:ok, intent} = AuditJournal.admit_intent(facts(version, n))
    intent
  end

  defp revoke_intent(version, n) do
    grant = facts(version, n)

    {:ok, intent} =
      grant
      |> Map.put("operation", "capability_revoke")
      |> Map.put("effect_class", "authority_reduce")
      |> Map.put("before_fence", grant["after_fingerprint"])
      |> Map.put("after_fingerprint", %{"kind" => "tombstone", "generation" => 1})
      |> put_in(["audit", "event_type"], "capability_revoked")
      |> AuditJournal.admit_intent()

    intent
  end

  defp facts(version, n) do
    id = "cap_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")

    %{
      "version" => version,
      "kind" => "arbor.security.authority_mutation_intent.v#{version}",
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => %{
        "kind" => "live",
        "record_id" => "record-#{n}",
        "generation" => 1,
        "revision" => 1,
        "capability_digest" => String.duplicate("ab", 32)
      },
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => id,
          "principal_id" => "agent_fixture",
          "resource_uri" => "arbor://memory/read"
        }
      },
      "prepared_at" => @time
    }
  end

  defp record(intent, type) do
    base = %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => type,
      "operation_id" => intent["operation_id"],
      "occurred_at" => @time
    }

    case type do
      "prepared" ->
        Map.merge(base, %{"intent" => intent, "occurred_at" => intent["prepared_at"]})

      "effect_applied" ->
        Map.put(base, "observation", %{
          "kind" => "applied",
          "after_fingerprint" => intent["after_fingerprint"]
        })

      "delivered" ->
        base
    end
  end

  defp rejected_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_rejected",
      "operation_id" => intent["operation_id"],
      "occurred_at" => @time,
      "observation" => %{"kind" => "rejected", "reason" => "before_mismatch"}
    }
  end

  defp unique_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ajf-retire-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
