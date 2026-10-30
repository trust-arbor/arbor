defmodule Arbor.Security.AuditRetirementLedgerCoreTest do
  @moduledoc """
  Pure retirement-ledger core (Floor-and-Ledger v3, slice 2): frame building,
  bound-tip verification and the overwritable-tail classification that decides
  which ledger bytes a retiring publication may ever overwrite.

  New API: every test here fails on the parent 52a2cc3fa only because the
  module does not exist there.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.AuditRetirementLedgerCore, as: LedgerCore
  alias Arbor.Security.Contracts.AuditJournal

  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 40,
    "committed_offset" => 100_000
  }

  describe "frame/3" do
    test "the first frame chains from genesis and names the next binding exactly" do
      retired = delivered_terminals(1..3)
      genesis = AuditJournal.ledger_genesis_binding()

      assert {:ok, framed} = LedgerCore.frame(retired, @source, genesis)
      assert framed.offset == 0

      assert framed.next_binding == %{
               "frames" => 1,
               "tip_offset" => 0,
               "tip_len" => byte_size(framed.payload),
               "tip_digest" => Base.encode16(framed.digest, case: :lower)
             }

      <<header_bytes::binary-size(72), payload::binary>> = framed.frame
      assert payload == framed.payload
      assert {:ok, header} = FileCore.decode_header(header_bytes)
      assert header.predecessor == FileCore.genesis_digest()
      assert {:ok, digest} = FileCore.verify_frame(header, payload, FileCore.genesis_digest())
      assert digest == framed.digest

      assert {:ok, batch} = LedgerCore.admit_batch_payload(payload)
      assert batch["retired"] == retired
      assert batch["source"] == @source
      assert batch["kind"] == AuditJournal.retirement_batch_kind()
      assert batch["version"] == 1

      assert :ok = LedgerCore.verify_bound_frame(framed.next_binding, framed.frame)
      assert {:ok, 72 + byte_size(payload)} == LedgerCore.bound_size(framed.next_binding)
      assert {:ok, 72 + byte_size(payload)} == AuditJournal.ledger_bound_size(framed.next_binding)
    end

    test "a later frame is written at the bound end and chains from the bound tip digest" do
      genesis = AuditJournal.ledger_genesis_binding()
      {:ok, first} = LedgerCore.frame(delivered_terminals(1..2), @source, genesis)
      {:ok, second} = LedgerCore.frame(delivered_terminals(3..5), @source, first.next_binding)

      {:ok, bound} = LedgerCore.bound_size(first.next_binding)
      assert second.offset == bound
      assert second.next_binding["frames"] == 2
      assert second.next_binding["tip_offset"] == bound
      <<_magic::binary-size(8), predecessor::binary-size(32), _rest::binary>> = second.frame
      assert predecessor == first.digest
      assert :ok = LedgerCore.verify_bound_frame(second.next_binding, second.frame)
      assert :ok = LedgerCore.verify_next_frame(first.next_binding, second.frame)
      assert {:error, _} = LedgerCore.verify_next_frame(genesis, second.frame)
    end

    test "a 4096-entry batch frames within the payload bound" do
      assert {:ok, framed} =
               LedgerCore.frame(
                 delivered_terminals(1..4096),
                 @source,
                 AuditJournal.ledger_genesis_binding()
               )

      assert byte_size(framed.payload) <= FileCore.max_payload_bytes()
    end

    test "malformed batches and bindings are refused" do
      genesis = AuditJournal.ledger_genesis_binding()
      assert {:error, :malformed} = LedgerCore.frame(%{}, @source, genesis)

      rejected = %{
        sha(:r) =>
          "effect_rejected|authority_reduce|#{sha(:i)}|prepared:#{sha(:p)}|effect_rejected:#{sha(:x)}"
      }

      assert {:error, :malformed} = LedgerCore.frame(rejected, @source, genesis)
      assert {:error, :malformed} = LedgerCore.frame(delivered_terminals(1..1), %{}, genesis)

      for bad <- [
            Map.put(genesis, "extra", 1),
            Map.put(genesis, "tip_digest", String.duplicate("0", 64)),
            Map.put(genesis, "tip_offset", 1),
            %{genesis | "frames" => 1, "tip_len" => 10, "tip_offset" => 5},
            %{genesis | "frames" => 2, "tip_len" => 10, "tip_digest" => sha(:x)},
            %{genesis | "frames" => 1, "tip_len" => 0, "tip_digest" => sha(:x)},
            Map.put(genesis, "tip_digest", String.upcase(sha(:x))),
            nil
          ] do
        assert {:error, :malformed} = LedgerCore.frame(delivered_terminals(1..1), @source, bad)
        assert {:error, :malformed} = LedgerCore.bound_size(bad)
      end
    end
  end

  describe "verify_bound_frame/2" do
    test "only the exact bound tip frame proves" do
      {:ok, framed} =
        LedgerCore.frame(
          delivered_terminals(1..2),
          @source,
          AuditJournal.ledger_genesis_binding()
        )

      binding = framed.next_binding

      assert :ok = LedgerCore.verify_bound_frame(binding, framed.frame)

      assert {:error, :size_mismatch} =
               LedgerCore.verify_bound_frame(binding, framed.frame <> "x")

      assert {:error, :size_mismatch} =
               LedgerCore.verify_bound_frame(binding, binary_part(framed.frame, 0, 100))

      last = byte_size(framed.frame) - 2

      assert {:error, :digest_mismatch} =
               LedgerCore.verify_bound_frame(binding, flip(framed.frame, last))

      other = %{binding | "tip_digest" => sha(:other)}
      assert {:error, :digest_mismatch} = LedgerCore.verify_bound_frame(other, framed.frame)

      assert :ok = LedgerCore.verify_bound_frame(AuditJournal.ledger_genesis_binding(), <<>>)

      assert {:error, :size_mismatch} =
               LedgerCore.verify_bound_frame(AuditJournal.ledger_genesis_binding(), "x")
    end

    test "the first frame must chain from genesis" do
      {:ok, payload} =
        AuditJournal.canonical_retirement_batch_bytes(%{
          "version" => 1,
          "kind" => AuditJournal.retirement_batch_kind(),
          "source" => @source,
          "retired" => delivered_terminals(1..1)
        })

      {:ok, frame, digest} = FileCore.encode_frame(payload, :crypto.hash(:sha256, "not genesis"))

      binding = %{
        "frames" => 1,
        "tip_offset" => 0,
        "tip_len" => byte_size(payload),
        "tip_digest" => Base.encode16(digest, case: :lower)
      }

      assert {:error, :predecessor_mismatch} = LedgerCore.verify_bound_frame(binding, frame)

      # A later tip's predecessor is interior-chain evidence (verified offline).
      assert :ok =
               LedgerCore.verify_bound_frame(
                 %{binding | "frames" => 2, "tip_offset" => 500},
                 frame
               )
    end
  end

  describe "classify_tail/3" do
    setup do
      {:ok, first} =
        LedgerCore.frame(
          delivered_terminals(1..2),
          @source,
          AuditJournal.ledger_genesis_binding()
        )

      binding = first.next_binding
      hot = delivered_terminals(3..6)
      {:ok, orphan} = LedgerCore.frame(delivered_terminals(3..5), @source, binding)
      %{binding: binding, hot: hot, orphan: orphan}
    end

    test "nothing beyond the bound is :bound", %{binding: binding, hot: hot} do
      assert :bound = LedgerCore.classify_tail(binding, <<>>, hot)
    end

    test "every torn prefix of a frame chained from the tip is an overwritable orphan",
         %{binding: binding, hot: hot, orphan: orphan} do
      for len <- [1, 3, 4, 7, 8, 20, 39, 40, 60, 71, 72, 73, byte_size(orphan.frame) - 1] do
        prefix = binary_part(orphan.frame, 0, len)
        assert :bound_orphan == LedgerCore.classify_tail(binding, prefix, hot), "len #{len}"
      end
    end

    test "exactly one complete frame chained from the tip over hot delivered terminals is an orphan",
         %{binding: binding, hot: hot, orphan: orphan} do
      assert :bound_orphan = LedgerCore.classify_tail(binding, orphan.frame, hot)
      # Subset, not equality: later deliveries only grow the hot set.
      assert :bound_orphan =
               LedgerCore.classify_tail(
                 binding,
                 orphan.frame,
                 Map.merge(hot, delivered_terminals(7..9))
               )
    end

    test "security invariant: anything else beyond the bound is :ahead and never overwritable",
         %{binding: binding, hot: hot, orphan: orphan} do
      # An entry that is no longer (or never was) hot.
      assert :ahead =
               LedgerCore.classify_tail(binding, orphan.frame, Map.delete(hot, sha({:op, 4})))

      # Same id, different compact string.
      changed = Map.put(hot, sha({:op, 4}), hot[sha({:op, 3})])
      assert :ahead = LedgerCore.classify_tail(binding, orphan.frame, changed)

      # One complete frame plus any further byte (a second attempt or foreign data).
      assert :ahead = LedgerCore.classify_tail(binding, orphan.frame <> "A", hot)

      {:ok, second} = LedgerCore.frame(delivered_terminals(6..6), @source, orphan.next_binding)
      assert :ahead = LedgerCore.classify_tail(binding, orphan.frame <> second.frame, hot)

      # A frame chained from somewhere else, or not a frame at all.
      {:ok, foreign} =
        LedgerCore.frame(
          delivered_terminals(3..3),
          @source,
          AuditJournal.ledger_genesis_binding()
        )

      assert :ahead = LedgerCore.classify_tail(binding, foreign.frame, hot)
      assert :ahead = LedgerCore.classify_tail(binding, binary_part(foreign.frame, 0, 50), hot)
      assert :ahead = LedgerCore.classify_tail(binding, "garbage-bytes", hot)
      assert :ahead = LedgerCore.classify_tail(binding, flip(orphan.frame, 80), hot)

      # A read longer than one maximal frame proves more than one frame.
      assert :ahead =
               LedgerCore.classify_tail(
                 binding,
                 :binary.copy(<<0>>, FileCore.max_frame_bytes() + 1),
                 hot
               )
    end

    test "a frame whose payload is not a retirement batch is :ahead", %{
      binding: binding,
      hot: hot
    } do
      {:ok, tip} = Base.decode16(binding["tip_digest"], case: :lower)
      {:ok, frame, _digest} = FileCore.encode_frame(~s({"version":1}), tip)
      assert :ahead = LedgerCore.classify_tail(binding, frame, hot)
    end

    test "malformed inputs are refused", %{hot: hot} do
      assert {:error, :malformed} = LedgerCore.classify_tail(%{}, <<>>, hot)

      assert {:error, :malformed} =
               LedgerCore.classify_tail(AuditJournal.ledger_genesis_binding(), nil, hot)
    end
  end

  test "posture helpers split retiring from paused postures" do
    for state <- [:absent, :bound, :bound_orphan] do
      assert LedgerCore.retiring_allowed?(state)
      refute LedgerCore.paused?(state)
    end

    for state <- [:mismatch, :ahead] do
      refute LedgerCore.retiring_allowed?(state)
      assert LedgerCore.paused?(state)
    end

    refute LedgerCore.retiring_allowed?(nil)
  end

  test "the ledger core contains no impure calls" do
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
      ~r/\bFile\./,
      ~r/:file\./,
      ~r/\bProcess\./,
      ~r/:crypto\.strong_rand_bytes/,
      ~r/Arbor\.Signals/,
      ~r/Historian/
    ]

    src =
      File.read!(
        Path.expand("../../../lib/arbor/security/audit_retirement_ledger_core.ex", __DIR__)
      )

    for regex <- forbidden do
      refute Regex.match?(regex, src), "matched #{inspect(regex)}"
    end
  end

  defp delivered_terminals(range) do
    Map.new(range, fn n ->
      {sha({:op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp flip(binary, index) do
    <<prefix::binary-size(index), byte, rest::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>
  end
end
