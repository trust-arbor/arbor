defmodule Arbor.Security.AuditJournalFileCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @t1 "2026-08-20T12:00:01Z"
  @magic <<"AJL1">>

  describe "limits and empty consume" do
    test "exposes frozen frame bounds" do
      assert FileCore.header_size() == 72
      assert FileCore.max_payload_bytes() == 32_768
      assert FileCore.max_frame_bytes() == 32_840
      assert FileCore.max_committed_frames() == 48
      assert FileCore.max_file_bytes() == 1_609_159
      assert byte_size(FileCore.genesis_digest()) == 32
    end

    test "empty consume folds to the empty AuditJournalCore projection" do
      assert {:ok, state} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(state, <<>>)
      shown = FileCore.show(replayed)

      assert shown.projection == %{
               "version" => 1,
               "entry_count" => 0,
               "byte_count" => 0,
               "operations" => []
             }

      assert shown.evidence.committed_offset == 0
      assert shown.evidence.committed_digest == FileCore.genesis_digest()
      assert shown.evidence.committed_frames == 0
      assert shown.evidence.torn_tail == nil
    end
  end

  describe "encode/consume roundtrip" do
    test "one frame matches Core.fold projection" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, bytes} = AuditJournal.canonical_record_bytes(prepared)
      {:ok, frame, digest} = FileCore.encode_frame(bytes, FileCore.genesis_digest())

      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, frame)
      assert {:ok, folded} = AuditJournalCore.fold([prepared])

      shown = FileCore.show(replayed)
      assert shown.projection == AuditJournalCore.show(folded)
      assert shown.evidence.committed_frames == 1
      assert shown.evidence.committed_digest == digest
      assert shown.evidence.committed_offset == byte_size(frame)
      assert shown.evidence.torn_tail == nil
    end

    test "two frames match Core.fold projection" do
      {prepared, applied, _delivered} = grant_lifecycle()
      {:ok, log} = encode_records([prepared, applied])

      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, log)
      assert {:ok, folded} = AuditJournalCore.fold([prepared, applied])
      assert FileCore.show(replayed).projection == AuditJournalCore.show(folded)
      assert FileCore.show(replayed).evidence.committed_frames == 2
    end
  end

  describe "integrity chain" do
    test "identical consecutive payloads remain chained; deleting the interior copy mismatches" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, payload} = AuditJournal.canonical_record_bytes(prepared)

      {:ok, frame1, d1} = FileCore.encode_frame(payload, FileCore.genesis_digest())
      {:ok, frame2, d2} = FileCore.encode_frame(payload, d1)
      {:ok, frame3, _d3} = FileCore.encode_frame(payload, d2)

      assert {:ok, empty} = FileCore.new()
      assert {:ok, all} = FileCore.consume(empty, frame1 <> frame2 <> frame3)
      assert FileCore.show(all).evidence.committed_frames == 3
      assert FileCore.show(all).projection["entry_count"] == 1

      assert {:error, :predecessor_mismatch} = FileCore.consume(empty, frame1 <> frame3)
    end

    test "swapping two non-identical frames is predecessor_mismatch" do
      {prepared, applied, _delivered} = grant_lifecycle()
      {:ok, p1} = AuditJournal.canonical_record_bytes(prepared)
      {:ok, p2} = AuditJournal.canonical_record_bytes(applied)
      {:ok, frame1, d1} = FileCore.encode_frame(p1, FileCore.genesis_digest())
      {:ok, frame2, _d2} = FileCore.encode_frame(p2, d1)

      assert {:ok, empty} = FileCore.new()
      assert {:error, :predecessor_mismatch} = FileCore.consume(empty, frame2 <> frame1)
    end

    test "flipped frame_digest on a complete middle frame is digest_mismatch" do
      {prepared, applied, _delivered} = grant_lifecycle()
      {:ok, log} = encode_records([prepared, applied])
      {:ok, first, _d1} = encode_one(prepared)
      flipped = flip_byte(log, byte_size(first) + 40)

      assert {:ok, empty} = FileCore.new()
      assert {:error, :digest_mismatch} = FileCore.consume(empty, flipped)
    end
  end

  describe "oversized declared length" do
    test "header payload_len=1_000_000 on a 72-byte binary is oversized_frame without a payload" do
      header = oversized_header(1_000_000)
      assert byte_size(header) == 72
      assert FileCore.decode_header(header) == {:error, :oversized_frame}

      assert {:ok, empty} = FileCore.new()
      assert {:error, :oversized_frame} = FileCore.consume(empty, header)

      assert FileCore.classify_suffix(header, FileCore.genesis_digest()) ==
               {:error, :oversized_frame}
    end

    test "payload_len=32769 header is oversized_frame" do
      suffix = @magic <> <<32_769::32-big>>

      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) ==
               {:error, :oversized_frame}
    end
  end

  describe "incomplete length prefix" do
    test "impossible 7-byte length prefix is oversized_frame not torn" do
      suffix = @magic <> <<0, 0, 0x81>>
      assert byte_size(suffix) == 7

      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) ==
               {:error, :oversized_frame}

      assert {:ok, empty} = FileCore.new()
      assert {:error, :oversized_frame} = FileCore.consume(empty, suffix)
    end

    test "impossible 5-byte and 6-byte length prefixes are oversized_frame" do
      five = @magic <> <<1>>
      six = @magic <> <<0, 1>>

      assert FileCore.classify_suffix(five, FileCore.genesis_digest()) ==
               {:error, :oversized_frame}

      assert FileCore.classify_suffix(six, FileCore.genesis_digest()) ==
               {:error, :oversized_frame}
    end

    test "7-byte prefix that can complete to 32768 is torn_tail" do
      suffix = @magic <> <<0, 0, 0x80>>

      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) == :torn_tail

      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, suffix)
      assert FileCore.show(replayed).evidence.torn_tail == %{offset: 0, byte_size: 7}
    end

    test "7-byte zero length prefix that can complete to 1..255 is torn_tail" do
      suffix = @magic <> <<0, 0, 0>>

      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) == :torn_tail
    end
  end

  describe "torn tail versus corruption" do
    test "3-byte AJL suffix after a good frame is torn_tail with prefix projection" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, frame, _digest} = encode_one(prepared)

      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, frame <> "AJL")
      shown = FileCore.show(replayed)
      assert {:ok, folded} = AuditJournalCore.fold([prepared])
      assert shown.projection == AuditJournalCore.show(folded)
      assert shown.evidence.torn_tail == %{offset: byte_size(frame), byte_size: 3}
    end

    test "4-byte non-magic suffix is malformed_header not torn" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, frame, _digest} = encode_one(prepared)

      assert {:ok, empty} = FileCore.new()
      assert {:error, :malformed_header} = FileCore.consume(empty, frame <> "XXXX")
    end

    test "8-byte AJL1 plus len=0 is malformed_header" do
      suffix = @magic <> <<0::32-big>>

      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) ==
               {:error, :malformed_header}
    end

    test "40-byte good magic+len+wrong predecessor is predecessor_mismatch not torn" do
      suffix = @magic <> <<100::32-big>> <> :binary.copy(<<0xFF>>, 32)
      assert byte_size(suffix) == 40

      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) ==
               {:error, :predecessor_mismatch}
    end

    test "72-byte header with matching pred and truncated payload is torn_tail" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, frame, _digest} = encode_one(prepared)
      truncated = binary_part(frame, 0, 72 + 10)

      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, truncated)
      shown = FileCore.show(replayed)
      assert shown.projection["entry_count"] == 0
      assert shown.evidence.torn_tail == %{offset: 0, byte_size: byte_size(truncated)}
    end

    test "offset beyond binary size is malformed" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, frame, _digest} = encode_one(prepared)

      assert {:ok, empty} = FileCore.new()
      assert {:ok, committed} = FileCore.consume(empty, frame)
      assert committed.offset == byte_size(frame)
      assert {:error, :malformed} = FileCore.consume(committed, <<>>)

      truncated = binary_part(frame, 0, div(byte_size(frame), 2))
      assert {:error, :malformed} = FileCore.consume(committed, truncated)
    end

    test "extended binary that completes a torn frame clears torn_tail" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, frame, _digest} = encode_one(prepared)
      truncated = binary_part(frame, 0, 20)

      assert {:ok, empty} = FileCore.new()
      assert {:ok, torn} = FileCore.consume(empty, truncated)
      assert FileCore.show(torn).evidence.torn_tail == %{offset: 0, byte_size: 20}

      assert {:ok, completed} = FileCore.consume(torn, frame)
      shown = FileCore.show(completed)
      assert {:ok, folded} = AuditJournalCore.fold([prepared])
      assert shown.projection == AuditJournalCore.show(folded)
      assert shown.evidence.torn_tail == nil
      assert shown.evidence.committed_frames == 1
      assert shown.evidence.committed_offset == byte_size(frame)
    end

    test "72-byte header with wrong pred and truncated payload is predecessor_mismatch not torn" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, frame, _digest} = encode_one(prepared)
      wrong_pred = :binary.copy(<<0x11>>, 32)

      corrupted =
        binary_part(frame, 0, 8) <> wrong_pred <> binary_part(frame, 40, 32 + 10)

      assert {:ok, empty} = FileCore.new()
      assert {:error, :predecessor_mismatch} = FileCore.consume(empty, corrupted)
    end
  end

  describe "canonical and schema admission" do
    test "whitespace-variant JSON is non_canonical and reducer state is unchanged" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, canonical} = AuditJournal.canonical_record_bytes(prepared)
      variant = canonical <> " "
      {:ok, frame, _digest} = FileCore.encode_frame(variant, FileCore.genesis_digest())

      assert {:ok, empty} = FileCore.new()
      snapshot = FileCore.show(empty)
      assert {:error, :non_canonical} = FileCore.consume(empty, frame)
      assert FileCore.show(empty) == snapshot
    end

    test "schema-invalid JSON after a good prefix does not fold the bad record" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, good, digest} = encode_one(prepared)
      {:ok, bad_frame, _d} = FileCore.encode_frame(~s({"nope":true}), digest)

      assert {:ok, empty} = FileCore.new()
      assert {:error, :malformed} = FileCore.consume(empty, good <> bad_frame)

      assert {:ok, prefix_only} = FileCore.consume(empty, good)
      assert FileCore.show(prefix_only).projection["entry_count"] == 1
    end

    test "duplicate canonical frame is idempotent at Core" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, payload} = AuditJournal.canonical_record_bytes(prepared)
      {:ok, frame1, d1} = FileCore.encode_frame(payload, FileCore.genesis_digest())
      {:ok, frame2, _d2} = FileCore.encode_frame(payload, d1)

      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, frame1 <> frame2)
      assert FileCore.show(replayed).projection["entry_count"] == 1
      assert FileCore.show(replayed).evidence.committed_frames == 2
    end

    test "conflicting same-type bytes are operation_conflict" do
      {prepared, applied, _delivered} = grant_lifecycle()
      other = Map.put(applied, "occurred_at", "2026-08-20T12:00:09Z")
      {:ok, log} = encode_records([prepared, applied, other])

      assert {:ok, empty} = FileCore.new()
      assert {:error, :operation_conflict} = FileCore.consume(empty, log)
    end

    test "soft and hard capacity bounds fail closed" do
      grants =
        Enum.map(1..32, fn n ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          prepared_record(intent)
        end)

      {:ok, grant_log} = encode_records(grants)
      assert {:ok, empty} = FileCore.new()
      assert {:ok, at_soft} = FileCore.consume(empty, grant_log)

      {:ok, extra_intent} = AuditJournal.admit_intent(grant_facts(33))
      {:ok, extra, _} = encode_one(prepared_record(extra_intent), at_soft.digest)
      assert {:error, :soft_capacity_exhausted} = FileCore.consume(empty, grant_log <> extra)

      revokes =
        Enum.map(1..16, fn n ->
          {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
          prepared_record(intent)
        end)

      {:ok, mixed} = encode_records(grants ++ revokes)
      assert {:ok, at_hard} = FileCore.consume(empty, mixed)
      assert FileCore.show(at_hard).evidence.committed_frames == 48

      {:ok, overflow_intent} = AuditJournal.admit_intent(revoke_facts(99))
      {:ok, overflow, _} = encode_one(prepared_record(overflow_intent), at_hard.digest)
      assert {:error, :capacity_exhausted} = FileCore.consume(empty, mixed <> overflow)
    end
  end

  describe "purity" do
    test "file core contains no impure calls" do
      forbidden = [
        ~r/DateTime\.utc_now/,
        ~r/System\.(monotonic|os|system)_time/,
        ~r/:rand\./,
        ~r/:erlang\.unique_integer/,
        ~r/\bmake_ref\s*\(/,
        ~r/Application\.get_env/,
        ~r/GenServer\.(call|cast|start)/,
        ~r/\bRepo\./,
        ~r/:ets\./,
        ~r/\bLogger\./,
        ~r/\bFile\.(read|write|open|rm|ls)/,
        ~r/:file\./,
        ~r/\bProcess\.(get|put|send)/,
        ~r/Arbor\.Signals/,
        ~r/Historian/,
        ~r/Arbor\.Security\.(grant|revoke)\b/
      ]

      src =
        File.read!(Path.expand("../../../lib/arbor/security/audit_journal_file_core.ex", __DIR__))

      for regex <- forbidden do
        refute Regex.match?(regex, src), "matched #{inspect(regex)}"
      end
    end
  end

  describe "snapshot-first replay" do
    test "empty snapshot-only log restores occupancy 1 from genesis" do
      {:ok, empty} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      assert {:ok, compacted, snapshot, []} = AuditJournalCore.compact(empty, source)
      assert {:ok, bytes, encoded} = FileCore.encode_compacted(snapshot, [])
      assert {:ok, start} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(start, bytes)
      assert FileCore.core_match?(replayed.core, compacted)
      assert FileCore.core_match?(encoded.core, compacted)
      assert replayed.frames == 1
      assert replayed.torn_tail == nil
      assert replayed.digest == encoded.digest
      assert FileCore.show(replayed).projection["entry_count"] == 1
    end

    test "effect_applied pending prefix restores prepared then applied in manifest order" do
      {prepared, applied, _delivered} = grant_lifecycle()
      assert {:ok, state} = AuditJournalCore.fold([prepared, applied])
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 2, 40)
      assert {:ok, compacted, snapshot, pending} = AuditJournalCore.compact(state, source)
      assert Enum.map(pending, & &1["record_type"]) == ["prepared", "effect_applied"]
      assert {:ok, bytes, encoded} = FileCore.encode_compacted(snapshot, pending)
      assert FileCore.core_match?(encoded.core, compacted)
      assert {:ok, start} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(start, bytes)
      assert FileCore.core_match?(replayed.core, compacted)
      assert replayed.frames == 3
      assert replayed.pending_needed == []
    end

    test "snapshot plus exact pending then later record matches restore then append" do
      {prepared, applied, delivered} = grant_lifecycle()
      {:ok, intent2} = AuditJournal.admit_intent(grant_facts(2))
      pending_prepared = prepared_record(intent2)

      assert {:ok, state} =
               AuditJournalCore.fold([prepared, applied, delivered, pending_prepared])

      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 4, 99)
      assert {:ok, compacted, snapshot, pending} = AuditJournalCore.compact(state, source)
      assert length(pending) == 1
      assert {:ok, prefix, encoded} = FileCore.encode_compacted(snapshot, pending)
      assert FileCore.core_match?(encoded.core, compacted)

      {:ok, extra_intent} = AuditJournal.admit_intent(revoke_facts(1))
      extra = prepared_record(extra_intent)
      {:ok, extra_bytes} = AuditJournal.canonical_record_bytes(extra)
      {:ok, extra_frame, _} = FileCore.encode_frame(extra_bytes, encoded.digest)

      assert {:ok, start} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(start, prefix <> extra_frame)
      assert {:ok, expected} = AuditJournalCore.append(compacted, extra)
      assert FileCore.core_match?(replayed.core, expected)
      assert replayed.frames == encoded.frames + 1
    end

    test "legacy record-only consume is unchanged beside extra replay keys" do
      {prepared, applied, _delivered} = grant_lifecycle()
      {:ok, log} = encode_records([prepared, applied])
      assert {:ok, empty} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(empty, log)
      assert {:ok, folded} = AuditJournalCore.fold([prepared, applied])
      assert FileCore.show(replayed).projection == AuditJournalCore.show(folded)
      assert replayed.snapshot == nil
      assert replayed.pending_needed == []
    end

    test "snapshot after frame one is snapshot_not_first" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, record_frame, pred} = encode_one(prepared)
      {:ok, empty_core} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      {:ok, _compacted, snapshot, []} = AuditJournalCore.compact(empty_core, source)
      {:ok, snap_bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
      {:ok, snap_frame, _} = FileCore.encode_frame(snap_bytes, pred)
      assert {:ok, start} = FileCore.new()
      assert {:error, :snapshot_not_first} = FileCore.consume(start, record_frame <> snap_frame)
    end

    test "missing pending prefix is pending_mismatch" do
      {prepared, applied, delivered} = grant_lifecycle()
      {:ok, intent2} = AuditJournal.admit_intent(grant_facts(2))
      pending_prepared = prepared_record(intent2)

      assert {:ok, state} =
               AuditJournalCore.fold([prepared, applied, delivered, pending_prepared])

      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 4, 1)
      assert {:ok, _compacted, snapshot, pending} = AuditJournalCore.compact(state, source)
      assert pending != []
      {:ok, snap_bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
      {:ok, snap_frame, _} = FileCore.encode_frame(snap_bytes, FileCore.genesis_digest())
      assert {:ok, start} = FileCore.new()
      assert {:error, :pending_mismatch} = FileCore.consume(start, snap_frame)
    end

    test "reordered pending prefix is pending_mismatch or cross_operation" do
      {prepared, applied, delivered} = grant_lifecycle()
      {:ok, intent2} = AuditJournal.admit_intent(grant_facts(2))
      {:ok, intent3} = AuditJournal.admit_intent(revoke_facts(1))
      p2 = prepared_record(intent2)
      p3 = prepared_record(intent3)
      assert {:ok, state} = AuditJournalCore.fold([prepared, applied, delivered, p2, p3])
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 5, 1)
      assert {:ok, _compacted, snapshot, pending} = AuditJournalCore.compact(state, source)
      assert length(pending) >= 2
      reversed = Enum.reverse(pending)
      bytes = encode_snapshot_frames(snapshot, reversed)
      assert {:ok, start} = FileCore.new()
      assert {:error, reason} = FileCore.consume(start, bytes)
      assert reason in [:pending_mismatch, :cross_operation]
    end

    test "substituted pending fingerprint is pending_mismatch" do
      {prepared, applied, _delivered} = grant_lifecycle()
      assert {:ok, state} = AuditJournalCore.fold([prepared, applied])
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 2, 1)
      assert {:ok, _compacted, snapshot, pending} = AuditJournalCore.compact(state, source)
      assert Enum.map(pending, & &1["record_type"]) == ["prepared", "effect_applied"]
      [prepared_pending, applied_pending] = pending
      substituted = Map.put(applied_pending, "occurred_at", "2026-08-20T12:00:09Z")
      {:ok, admitted} = AuditJournal.admit_record(substituted)
      assert admitted["operation_id"] == applied_pending["operation_id"]
      assert admitted["record_type"] == "effect_applied"
      bytes = encode_snapshot_frames(snapshot, [prepared_pending, substituted])
      assert {:ok, start} = FileCore.new()
      assert {:error, :pending_mismatch} = FileCore.consume(start, bytes)
    end

    test "non-canonical snapshot is non_canonical" do
      {:ok, empty_core} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      {:ok, _compacted, snapshot, []} = AuditJournalCore.compact(empty_core, source)
      {:ok, canonical} = AuditJournal.canonical_snapshot_bytes(snapshot)
      {:ok, frame, _} = FileCore.encode_frame(canonical <> " ", FileCore.genesis_digest())
      assert {:ok, start} = FileCore.new()
      assert {:error, :non_canonical} = FileCore.consume(start, frame)
    end

    test "non-canonical record after snapshot is non_canonical" do
      {prepared, applied, delivered} = grant_lifecycle()
      {:ok, intent2} = AuditJournal.admit_intent(grant_facts(2))
      pending_prepared = prepared_record(intent2)

      assert {:ok, state} =
               AuditJournalCore.fold([prepared, applied, delivered, pending_prepared])

      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 4, 1)
      assert {:ok, _compacted, snapshot, [pending]} = AuditJournalCore.compact(state, source)
      {:ok, snap_bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
      {:ok, snap_frame, digest} = FileCore.encode_frame(snap_bytes, FileCore.genesis_digest())
      {:ok, rec_bytes} = AuditJournal.canonical_record_bytes(pending)
      {:ok, rec_frame, _} = FileCore.encode_frame(rec_bytes <> " ", digest)
      assert {:ok, start} = FileCore.new()
      assert {:error, :non_canonical} = FileCore.consume(start, snap_frame <> rec_frame)
    end

    test "predecessor corruption on snapshot-first log is predecessor_mismatch" do
      {:ok, empty_core} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      {:ok, _compacted, snapshot, []} = AuditJournalCore.compact(empty_core, source)
      {:ok, bytes, _} = FileCore.encode_compacted(snapshot, [])
      pred = :binary.copy(<<0x11>>, 32)
      rest = binary_part(bytes, 40, byte_size(bytes) - 40)
      corrupted = binary_part(bytes, 0, 8) <> pred <> rest
      assert {:ok, start} = FileCore.new()
      assert {:error, :predecessor_mismatch} = FileCore.consume(start, corrupted)
    end

    test "digest corruption on snapshot-first log is digest_mismatch" do
      {:ok, empty_core} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      {:ok, _compacted, snapshot, []} = AuditJournalCore.compact(empty_core, source)
      {:ok, bytes, _} = FileCore.encode_compacted(snapshot, [])
      flipped = flip_byte(bytes, 40)
      assert {:ok, start} = FileCore.new()
      assert {:error, :digest_mismatch} = FileCore.consume(start, flipped)
    end

    test "torn tail during pending prefix is pending_mismatch" do
      {prepared, applied, delivered} = grant_lifecycle()
      {:ok, intent2} = AuditJournal.admit_intent(grant_facts(2))
      pending_prepared = prepared_record(intent2)

      assert {:ok, state} =
               AuditJournalCore.fold([prepared, applied, delivered, pending_prepared])

      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 4, 1)
      assert {:ok, _compacted, snapshot, pending} = AuditJournalCore.compact(state, source)
      {:ok, bytes, _} = FileCore.encode_compacted(snapshot, pending)
      truncated = binary_part(bytes, 0, byte_size(bytes) - 3)
      assert {:ok, start} = FileCore.new()
      assert {:error, :pending_mismatch} = FileCore.consume(start, truncated)
    end

    test "torn tail after restore remains torn_tail" do
      {:ok, empty_core} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      {:ok, _compacted, snapshot, []} = AuditJournalCore.compact(empty_core, source)
      {:ok, prefix, encoded} = FileCore.encode_compacted(snapshot, [])
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, rec_bytes} = AuditJournal.canonical_record_bytes(prepared)
      {:ok, rec_frame, _} = FileCore.encode_frame(rec_bytes, encoded.digest)
      torn = prefix <> binary_part(rec_frame, 0, 3)
      assert {:ok, start} = FileCore.new()
      assert {:ok, replayed} = FileCore.consume(start, torn)
      assert replayed.torn_tail == %{offset: encoded.offset, byte_size: 3}
    end
  end

  describe "publication helpers" do
    test "source_binding is 64 lowercase hex" do
      digest = FileCore.genesis_digest()
      assert {:ok, source} = FileCore.source_binding(digest, 3, 12)
      assert byte_size(source["committed_digest"]) == 64
      assert source["committed_digest"] == Base.encode16(digest, case: :lower)
      assert source["committed_digest"] =~ ~r/\A[0-9a-f]{64}\z/
      assert source["committed_frames"] == 3
      assert source["committed_offset"] == 12
      assert {:error, :malformed} = FileCore.source_binding(<<1, 2, 3>>, 0, 0)
    end

    test "core_match? requires full reducer equality not show/1" do
      {:ok, empty} = AuditJournalCore.new()
      {:ok, source} = FileCore.source_binding(FileCore.genesis_digest(), 0, 0)
      assert {:ok, compacted, _snapshot, []} = AuditJournalCore.compact(empty, source)
      tweaked = Map.put(compacted, "snapshot_bytes", compacted["snapshot_bytes"] + 1)
      assert AuditJournalCore.show(compacted) == AuditJournalCore.show(tweaked)
      refute FileCore.core_match?(compacted, tweaked)
      assert FileCore.core_match?(compacted, compacted)
    end

    test "source_tip_match? requires digest frames and offset" do
      {:ok, empty} = FileCore.new()
      {:ok, source} = FileCore.source_binding(empty.digest, empty.frames, empty.offset)
      assert FileCore.source_tip_match?(empty, source)
      refute FileCore.source_tip_match?(empty, Map.put(source, "committed_frames", 1))
    end

    test "candidate_basename is a single hidden compact segment" do
      assert {:ok, ".audit_journal.v1.log.compact"} =
               FileCore.candidate_basename("audit_journal.v1.log")

      assert {:error, :malformed} = FileCore.candidate_basename("")
      assert {:error, :malformed} = FileCore.candidate_basename(".")
      assert {:error, :malformed} = FileCore.candidate_basename("..")
      assert {:error, :malformed} = FileCore.candidate_basename("a/b")
    end

    test "leftover_action admits only regular 0600 single-link" do
      assert :unlink = FileCore.leftover_action(%{type: :regular, mode: 0o100600, links: 1})

      assert {:error, :symlink_rejected} =
               FileCore.leftover_action(%{type: :symlink, mode: 0o120777, links: 1})

      assert {:error, :hardlink_rejected} =
               FileCore.leftover_action(%{type: :regular, mode: 0o100600, links: 2})

      assert {:error, :insecure_mode} =
               FileCore.leftover_action(%{type: :regular, mode: 0o100644, links: 1})

      assert {:error, :not_regular} =
               FileCore.leftover_action(%{type: :directory, mode: 0o40700, links: 2})
    end

    test "classify_dir_sync known-unsupported is ok" do
      assert :ok = FileCore.classify_dir_sync(:ok)
      assert :ok = FileCore.classify_dir_sync({:error, :enotsup})
      assert :ok = FileCore.classify_dir_sync({:error, :eisdir})
      assert {:error, :eio} = FileCore.classify_dir_sync({:error, :eio})
    end

    test "classify_rename_outcome splits not_published from uncertain" do
      assert :continue = FileCore.classify_rename_outcome(%{rename: :ok})

      assert {:not_published, :write_failed} =
               FileCore.classify_rename_outcome(%{
                 rename: {:error, :eio},
                 candidate_present?: true,
                 target_identity_match?: true
               })

      assert {:publish_uncertain, :rename_ambiguous} =
               FileCore.classify_rename_outcome(%{
                 rename: {:error, :eio},
                 candidate_present?: false,
                 target_identity_match?: true
               })

      refute :continue ==
               FileCore.classify_rename_outcome(%{
                 rename: {:error, :eio},
                 candidate_present?: true,
                 target_identity_match?: true
               })
    end

    test "classify_publish_phase splits pre-rename from post-rename" do
      for phase <- [
            :admit,
            :cleanup,
            :create,
            :write,
            :sync,
            :candidate_proof,
            :candidate_reproof,
            :source_tip_proof
          ] do
        assert {:not_published, :sync_failed} =
                 FileCore.classify_publish_phase(phase, :sync_failed)
      end

      for phase <- [:dir_finalize, :reopen, :published_replay] do
        assert {:publish_uncertain, :reopen_failed} =
                 FileCore.classify_publish_phase(phase, :reopen_failed)
      end

      assert {:error, :malformed} = FileCore.classify_publish_phase(:rename, :eio)
      assert {:error, :malformed} = FileCore.classify_publish_phase(:sync, "eio")
    end

    test "encode_compacted returns malformed for snapshots through canonical_snapshot_bytes" do
      deep = Enum.reduce(1..6, "x", fn _i, acc -> %{"k" => acc} end)

      assert {:error, :malformed} = AuditJournal.canonical_snapshot_bytes(deep)
      assert {:error, :malformed} = FileCore.encode_compacted(deep, [])
      assert {:error, :malformed} = FileCore.encode_compacted(self(), [])
      assert FileCore.encode_compacted(nil, []) == {:error, :malformed}
    end
  end

  defp encode_snapshot_frames(snapshot, pending) do
    {:ok, snap_bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
    {:ok, frame, digest} = FileCore.encode_frame(snap_bytes, FileCore.genesis_digest())

    Enum.reduce(pending, {frame, digest}, fn record, {acc, pred} ->
      {:ok, rec_bytes} = AuditJournal.canonical_record_bytes(record)
      {:ok, rec_frame, next} = FileCore.encode_frame(rec_bytes, pred)
      {acc <> rec_frame, next}
    end)
    |> elem(0)
  end

  defp grant_lifecycle do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    {prepared_record(intent), applied_record(intent, @t1), delivered_record(intent, @t1)}
  end

  defp encode_records(records) do
    Enum.reduce_while(
      records,
      {:ok, <<>>, FileCore.genesis_digest()},
      fn record, {:ok, acc, pred} ->
        case encode_one(record, pred) do
          {:ok, frame, digest} -> {:cont, {:ok, acc <> frame, digest}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
    |> case do
      {:ok, log, _digest} -> {:ok, log}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_one(record, pred \\ FileCore.genesis_digest()) do
    with {:ok, bytes} <- AuditJournal.canonical_record_bytes(record) do
      FileCore.encode_frame(bytes, pred)
    end
  end

  defp oversized_header(len) do
    @magic <> <<len::32-big>> <> FileCore.genesis_digest() <> FileCore.genesis_digest()
  end

  defp flip_byte(binary, index) do
    <<prefix::binary-size(index), byte, rest::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>
  end

  defp grant_facts(n) do
    cap_id = cap_id(n)

    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => cap_id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => live_fp(1),
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp revoke_facts(n) do
    cap_id = cap_id(1000 + n)

    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_revoke",
      "effect_class" => "authority_reduce",
      "authority_namespace" => "capability",
      "authority_key" => cap_id,
      "before_fence" => live_fp(3),
      "after_fingerprint" => %{"kind" => "tombstone", "generation" => 3},
      "audit" => %{
        "event_type" => "capability_revoked",
        "data" => %{
          "capability_id" => cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp live_fp(generation) do
    %{
      "kind" => "live",
      "record_id" => "rec_1",
      "generation" => generation,
      "revision" => 1,
      "capability_digest" => @digest
    }
  end

  defp cap_id(n) do
    hex =
      n
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")

    "cap_" <> hex
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

  defp applied_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => %{
        "kind" => "applied",
        "after_fingerprint" => intent["after_fingerprint"]
      }
    }
  end

  defp delivered_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "delivered",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at
    }
  end
end
