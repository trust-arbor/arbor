defmodule Arbor.Contracts.Persistence.RevisionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Persistence.Revision

  describe "key agreement" do
    test "key_mismatch?/2 is false for non-Record values" do
      refute Revision.key_mismatch?("k", "plain")
      refute Revision.key_mismatch?("k", %{not: :record})
      refute Revision.key_mismatch?("k", 42)
    end

    test "key_mismatch?/2 compares Record.key to the physical store key" do
      matching = Record.new("k", %{"n" => 1})
      mismatched = Record.new("other", %{"n" => 1})

      refute Revision.key_mismatch?("k", matching)
      assert Revision.key_mismatch?("k", mismatched)
    end

    test "cas_operands_key_mismatch?/3 checks replacement and expected {:value, record}" do
      clean = Record.new("k", %{"n" => 1})
      wrong = Record.new("other", %{"n" => 1})

      refute Revision.cas_operands_key_mismatch?("k", :not_found, clean)
      refute Revision.cas_operands_key_mismatch?("k", {:value, clean}, clean)

      assert Revision.cas_operands_key_mismatch?("k", :not_found, wrong)
      assert Revision.cas_operands_key_mismatch?("k", {:value, wrong}, clean)
      assert Revision.cas_operands_key_mismatch?("k", {:value, clean}, wrong)
    end
  end

  describe "put advancement" do
    test "absent + Record starts generation 1 revision 1" do
      before = DateTime.utc_now()
      record = Record.new("k", %{"n" => 1}, generation: 0, revision: 0)

      assert {:ok, stored} = Revision.apply_put(:absent, record)
      assert stored.generation == 1
      assert stored.revision == 1
      assert DateTime.compare(stored.updated_at, before) in [:gt, :eq]
    end

    test "tombstone + Record advances generation and resets revision" do
      record = Record.new("k", %{"n" => 2})

      assert {:ok, stored} = Revision.apply_put({:tombstone, 3}, record)
      assert stored.generation == 4
      assert stored.revision == 1
    end

    test "live Record same key preserves id/key/generation and advances revision" do
      inserted_at = ~U[2026-01-01 00:00:00Z]

      current =
        Record.new("k", %{"n" => 1},
          id: "rec_logical_a",
          generation: 2,
          revision: 5,
          inserted_at: inserted_at
        )

      replacement =
        Record.new("k", %{"n" => 2},
          id: "rec_other",
          generation: 0,
          revision: 0
        )

      before = DateTime.utc_now()
      assert {:ok, stored} = Revision.apply_put(current, replacement)

      assert stored.id == "rec_logical_a"
      assert stored.key == "k"
      assert stored.generation == 2
      assert stored.revision == 6
      assert stored.data == %{"n" => 2}
      assert stored.inserted_at == inserted_at
      assert DateTime.compare(stored.updated_at, before) in [:gt, :eq]
    end

    test "live Record key mismatch returns :key_mismatch" do
      current = Record.new("k", %{"n" => 1}, generation: 1, revision: 1)
      replacement = Record.new("other", %{"n" => 2})

      assert {:error, :key_mismatch} = Revision.apply_put(current, replacement)
    end

    test "plain value put over absent/tombstone/live stores the plain value" do
      assert {:ok, "v"} = Revision.apply_put(:absent, "v")
      assert {:ok, "v"} = Revision.apply_put({:tombstone, 1}, "v")
      assert {:ok, "v"} = Revision.apply_put(Record.new("k", %{}), "v")
      assert {:ok, "v2"} = Revision.apply_put("v1", "v2")
    end

    test "Record replacing a plain value starts a fresh structured incarnation" do
      record = Record.new("k", %{"n" => 1}, generation: 9, revision: 9)

      assert {:ok, stored} = Revision.apply_put("plain", record)
      assert stored.generation == 1
      assert stored.revision == 1
    end
  end

  describe "CAS insert/update/match" do
    test "advance_cas_insert/1 sets generation and revision for Records" do
      record = Record.new("k", %{"n" => 1}, generation: 0, revision: 0)
      before = DateTime.utc_now()

      stored = Revision.advance_cas_insert(record)
      assert stored.generation == 1
      assert stored.revision == 1
      assert DateTime.compare(stored.updated_at, before) in [:gt, :eq]

      assert Revision.advance_cas_insert("plain") == "plain"
    end

    test "advance_cas_insert_from_tombstone/2 reuses previous generation + 1" do
      record = Record.new("k", %{"n" => 1})
      stored = Revision.advance_cas_insert_from_tombstone(4, record)

      assert stored.generation == 5
      assert stored.revision == 1
      assert Revision.advance_cas_insert_from_tombstone(4, "plain") == "plain"
    end

    test "advance_cas_update/2 preserves identity tokens and advances revision" do
      inserted_at = ~U[2026-02-01 12:00:00Z]

      current =
        Record.new("k", %{"n" => 1},
          id: "rec_keep",
          generation: 3,
          revision: 7,
          inserted_at: inserted_at
        )

      replacement =
        Record.new("k", %{"n" => 2},
          id: "rec_replace",
          generation: 1,
          revision: 1
        )

      assert {:ok, stored} = Revision.advance_cas_update(current, replacement)
      assert stored.id == "rec_keep"
      assert stored.key == "k"
      assert stored.generation == 3
      assert stored.revision == 8
      assert stored.inserted_at == inserted_at
      assert stored.data == %{"n" => 2}
    end

    test "advance_cas_update/2 rejects key mismatch and non-Record pairs" do
      current = Record.new("k", %{"n" => 1}, generation: 1, revision: 1)
      wrong_key = Record.new("other", %{"n" => 2})

      assert {:error, :key_mismatch} = Revision.advance_cas_update(current, wrong_key)
      assert {:error, :conflict} = Revision.advance_cas_update(current, "plain")
      assert {:error, :conflict} = Revision.advance_cas_update("plain", current)
    end

    test "cas_matches?/2 compares generation+revision for Records" do
      current = Record.new("k", %{}, generation: 2, revision: 5)
      same = Record.new("k", %{}, generation: 2, revision: 5)
      gen_only = Record.new("k", %{}, generation: 2, revision: 4)
      rev_only = Record.new("k", %{}, generation: 1, revision: 5)

      assert Revision.cas_matches?(current, same)
      refute Revision.cas_matches?(current, gen_only)
      refute Revision.cas_matches?(current, rev_only)
      refute Revision.cas_matches?({:tombstone, 2}, same)
      assert Revision.cas_matches?("plain", "plain")
      refute Revision.cas_matches?("plain", "other")
    end

    test "absent_for_cas?/1 treats absent and tombstones as insertable" do
      assert Revision.absent_for_cas?(:absent)
      assert Revision.absent_for_cas?({:tombstone, 1})
      refute Revision.absent_for_cas?(Record.new("k", %{}))
      refute Revision.absent_for_cas?("plain")
    end

    test "advance_ephemeral_insert/1 sets positive generation and revision 1" do
      record = Record.new("k", %{"n" => 1})
      stored = Revision.advance_ephemeral_insert(record)

      assert is_integer(stored.generation) and stored.generation > 0
      assert stored.revision == 1
      assert Revision.advance_ephemeral_insert("plain") == "plain"
    end
  end

  describe "tombstones and ABA" do
    test "to_tombstone/1 keeps Record generation and leaves plain values absent" do
      record = Record.new("k", %{}, generation: 7, revision: 3)

      assert Revision.to_tombstone(record) == {:tombstone, 7}
      assert Revision.to_tombstone({:tombstone, 7}) == {:tombstone, 7}
      assert Revision.to_tombstone("plain") == :absent
    end

    test "live_value/1 and polarity helpers" do
      record = Record.new("k", %{})

      assert Revision.live_value(:absent) == :not_found
      assert Revision.live_value({:tombstone, 1}) == :not_found
      assert Revision.live_value(record) == {:ok, record}
      assert Revision.live_value("plain") == {:ok, "plain"}

      assert Revision.live_record?(record)
      refute Revision.live_record?({:tombstone, 1})
      refute Revision.live_record?("plain")

      assert Revision.tombstone?({:tombstone, 1})
      refute Revision.tombstone?(record)
      refute Revision.tombstone?("plain")
    end

    test "pure ABA sequence: delete/reinsert invalidates stale generation+revision" do
      live =
        Record.new("k", %{"n" => 1},
          id: "rec_a",
          generation: 1,
          revision: 1
        )

      tombstone = Revision.to_tombstone(live)
      assert tombstone == {:tombstone, 1}

      reinserted =
        Revision.advance_cas_insert_from_tombstone(1, Record.new("k", %{"n" => 2}, id: "rec_b"))

      assert reinserted.generation == 2
      assert reinserted.revision == 1

      stale = %{live | data: %{"n" => 99}}
      refute Revision.cas_matches?(reinserted, stale)
      assert Revision.cas_matches?(reinserted, %{reinserted | data: %{"ignored" => true}})
    end
  end

  describe "logical-id preservation" do
    test "live apply_put and advance_cas_update keep stored logical id" do
      current =
        Record.new("k", %{"n" => 1},
          id: "rec_original",
          generation: 4,
          revision: 2
        )

      replacement =
        Record.new("k", %{"n" => 2},
          id: "rec_attacker",
          generation: 99,
          revision: 99
        )

      assert {:ok, put_stored} = Revision.apply_put(current, replacement)
      assert put_stored.id == "rec_original"
      assert put_stored.generation == 4

      assert {:ok, cas_stored} = Revision.advance_cas_update(current, replacement)
      assert cas_stored.id == "rec_original"
      assert cas_stored.generation == 4
      assert cas_stored.revision == 3
    end
  end

  describe "authoritative inventory limits" do
    test "missing opt returns nil limit" do
      assert {:ok, nil} = Revision.authoritative_list_limit([])
      assert {:ok, nil} = Revision.authoritative_list_limit(other: 1)
    end

    test "accepts positive integers up to 10_001" do
      assert {:ok, 1} = Revision.authoritative_list_limit(authoritative_limit: 1)
      assert {:ok, 10_000} = Revision.authoritative_list_limit(authoritative_limit: 10_000)
      assert {:ok, 10_001} = Revision.authoritative_list_limit(authoritative_limit: 10_001)
    end

    test "rejects invalid limits and non-keyword opts" do
      assert {:error, :invalid_authoritative_limit} =
               Revision.authoritative_list_limit(authoritative_limit: 0)

      assert {:error, :invalid_authoritative_limit} =
               Revision.authoritative_list_limit(authoritative_limit: -1)

      assert {:error, :invalid_authoritative_limit} =
               Revision.authoritative_list_limit(authoritative_limit: 10_002)

      assert {:error, :invalid_authoritative_limit} =
               Revision.authoritative_list_limit(authoritative_limit: "10")

      assert {:error, :invalid_authoritative_limit} =
               Revision.authoritative_list_limit(%{authoritative_limit: 1})
    end
  end
end
