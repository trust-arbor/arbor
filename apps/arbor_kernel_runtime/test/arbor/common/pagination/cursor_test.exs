defmodule Arbor.Common.Pagination.CursorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Pagination.Cursor

  describe "parse/1" do
    test "parses valid cursor string" do
      assert {:ok, {1_705_123_456_789, "evt_123"}} = Cursor.parse("1705123456789:evt_123")
    end

    test "handles id with colons" do
      assert {:ok, {1_705_123_456_789, "id:with:colons"}} =
               Cursor.parse("1705123456789:id:with:colons")
    end

    test "returns error for non-numeric timestamp" do
      assert :error = Cursor.parse("abc:evt_123")
    end

    test "returns error for no separator" do
      assert :error = Cursor.parse("invalid")
    end

    test "returns error for non-binary input" do
      assert :error = Cursor.parse(123)
    end

    test "returns error for timestamp with trailing chars" do
      assert :error = Cursor.parse("123abc:evt_1")
    end
  end

  describe "parse_datetime/2" do
    test "parses with millisecond precision" do
      {:ok, {datetime, id}} = Cursor.parse_datetime("1705123456789:evt_123")

      assert id == "evt_123"
      assert %DateTime{} = datetime
      assert DateTime.to_unix(datetime, :millisecond) == 1_705_123_456_789
    end

    test "parses with microsecond precision" do
      {:ok, {datetime, id}} =
        Cursor.parse_datetime("1705123456789000:evt_123", precision: :microsecond)

      assert id == "evt_123"
      assert %DateTime{} = datetime
    end

    test "returns error for invalid cursor" do
      assert :error = Cursor.parse_datetime("invalid")
    end

    test "returns error for non-numeric timestamp" do
      assert :error = Cursor.parse_datetime("abc:id")
    end
  end

  describe "generate/2" do
    test "generates cursor from DateTime" do
      datetime = ~U[2024-01-13 12:00:00Z]
      cursor = Cursor.generate(datetime, "evt_123")

      expected_ms = DateTime.to_unix(datetime, :millisecond)
      assert cursor == "#{expected_ms}:evt_123"
    end

    test "generates cursor from integer timestamp" do
      assert Cursor.generate(1_705_147_200_000, "evt_456") == "1705147200000:evt_456"
    end

    test "roundtrips correctly" do
      datetime = ~U[2024-06-15 08:30:00.123Z]
      cursor = Cursor.generate(datetime, "sig_abc")
      {:ok, {ts_ms, id}} = Cursor.parse(cursor)

      assert id == "sig_abc"
      assert ts_ms == DateTime.to_unix(datetime, :millisecond)
    end
  end

  describe "passes_filter?/5" do
    test "desc order: earlier record passes" do
      assert Cursor.passes_filter?(1000, "a", 2000, "b", :desc)
    end

    test "desc order: later record does not pass" do
      refute Cursor.passes_filter?(3000, "a", 2000, "b", :desc)
    end

    test "asc order: later record passes" do
      assert Cursor.passes_filter?(3000, "a", 2000, "b", :asc)
    end

    test "asc order: earlier record does not pass" do
      refute Cursor.passes_filter?(1000, "a", 2000, "b", :asc)
    end

    test "same timestamp desc: smaller ID passes" do
      assert Cursor.passes_filter?(2000, "a", 2000, "b", :desc)
      refute Cursor.passes_filter?(2000, "c", 2000, "b", :desc)
    end

    test "same timestamp asc: larger ID passes" do
      assert Cursor.passes_filter?(2000, "c", 2000, "b", :asc)
      refute Cursor.passes_filter?(2000, "a", 2000, "b", :asc)
    end
  end

  describe "filter_records/4" do
    setup do
      records = [
        %{timestamp: ~U[2024-01-01 10:00:00Z], id: "1", value: :a},
        %{timestamp: ~U[2024-01-01 11:00:00Z], id: "2", value: :b},
        %{timestamp: ~U[2024-01-01 12:00:00Z], id: "3", value: :c}
      ]

      opts = [timestamp_fn: & &1.timestamp, id_fn: & &1.id]
      {:ok, records: records, opts: opts}
    end

    test "nil cursor returns all records", %{records: records, opts: opts} do
      assert Cursor.filter_records(records, nil, :desc, opts) == records
    end

    test "invalid cursor returns all records", %{records: records, opts: opts} do
      assert Cursor.filter_records(records, "invalid", :desc, opts) == records
    end

    test "filters desc from middle cursor", %{records: records, opts: opts} do
      # Cursor at record 2's timestamp — desc means return records before it
      cursor = Cursor.generate(~U[2024-01-01 11:00:00Z], "2")
      filtered = Cursor.filter_records(records, cursor, :desc, opts)

      assert length(filtered) == 1
      assert hd(filtered).id == "1"
    end

    test "filters asc from middle cursor", %{records: records, opts: opts} do
      cursor = Cursor.generate(~U[2024-01-01 11:00:00Z], "2")
      filtered = Cursor.filter_records(records, cursor, :asc, opts)

      assert length(filtered) == 1
      assert hd(filtered).id == "3"
    end
  end

  describe "filter_records_datetime/4" do
    setup do
      records = [
        %{timestamp: ~U[2024-01-01 10:00:00Z], id: "1"},
        %{timestamp: ~U[2024-01-01 11:00:00Z], id: "2"},
        %{timestamp: ~U[2024-01-01 12:00:00Z], id: "3"}
      ]

      opts = [timestamp_fn: & &1.timestamp, id_fn: & &1.id]
      {:ok, records: records, opts: opts}
    end

    test "nil cursor returns all records", %{records: records, opts: opts} do
      assert Cursor.filter_records_datetime(records, nil, :desc, opts) == records
    end

    test "invalid cursor returns all records", %{records: records, opts: opts} do
      assert Cursor.filter_records_datetime(records, "invalid", :desc, opts) == records
    end

    test "filters desc from cursor", %{records: records, opts: opts} do
      cursor = Cursor.generate(~U[2024-01-01 11:00:00Z], "2")
      filtered = Cursor.filter_records_datetime(records, cursor, :desc, opts)

      assert length(filtered) == 1
      assert hd(filtered).id == "1"
    end

    test "filters asc from cursor", %{records: records, opts: opts} do
      cursor = Cursor.generate(~U[2024-01-01 11:00:00Z], "2")
      filtered = Cursor.filter_records_datetime(records, cursor, :asc, opts)

      assert length(filtered) == 1
      assert hd(filtered).id == "3"
    end

    test "same timestamp uses ID comparison", %{opts: opts} do
      records = [
        %{timestamp: ~U[2024-01-01 11:00:00Z], id: "a"},
        %{timestamp: ~U[2024-01-01 11:00:00Z], id: "b"},
        %{timestamp: ~U[2024-01-01 11:00:00Z], id: "c"}
      ]

      cursor = Cursor.generate(~U[2024-01-01 11:00:00Z], "b")
      desc_filtered = Cursor.filter_records_datetime(records, cursor, :desc, opts)
      asc_filtered = Cursor.filter_records_datetime(records, cursor, :asc, opts)

      assert Enum.map(desc_filtered, & &1.id) == ["a"]
      assert Enum.map(asc_filtered, & &1.id) == ["c"]
    end
  end
end
