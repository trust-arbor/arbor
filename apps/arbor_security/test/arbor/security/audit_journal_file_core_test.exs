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
      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) == {:error, :oversized_frame}
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
      assert FileCore.classify_suffix(suffix, FileCore.genesis_digest()) == {:error, :malformed_header}
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
        File.read!(
          Path.expand("../../../lib/arbor/security/audit_journal_file_core.ex", __DIR__)
        )

      for regex <- forbidden do
        refute Regex.match?(regex, src), "matched #{inspect(regex)}"
      end
    end
  end

  defp grant_lifecycle do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    {prepared_record(intent), applied_record(intent, @t1), delivered_record(intent, @t1)}
  end

  defp encode_records(records) do
    Enum.reduce_while(records, {:ok, <<>>, FileCore.genesis_digest()}, fn record, {:ok, acc, pred} ->
      case encode_one(record, pred) do
        {:ok, frame, digest} -> {:cont, {:ok, acc <> frame, digest}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
