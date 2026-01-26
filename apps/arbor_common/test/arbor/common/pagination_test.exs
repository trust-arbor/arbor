defmodule Arbor.Common.PaginationTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Pagination

  @sample_timestamp ~U[2026-01-26 17:00:00.000Z]
  @sample_timestamp_ms 1_769_446_800_000

  describe "generate_cursor/1" do
    test "generates cursor from record with DateTime timestamp" do
      record = %{timestamp: @sample_timestamp, id: "evt_123"}
      cursor = Pagination.generate_cursor(record)

      assert cursor == "#{@sample_timestamp_ms}:evt_123"
    end

    test "generates cursor from record with integer timestamp" do
      record = %{timestamp: @sample_timestamp_ms, id: "evt_123"}
      cursor = Pagination.generate_cursor(record)

      assert cursor == "#{@sample_timestamp_ms}:evt_123"
    end

    test "returns nil for nil input" do
      assert Pagination.generate_cursor(nil) == nil
    end

    test "returns nil for invalid input" do
      assert Pagination.generate_cursor(%{}) == nil
      assert Pagination.generate_cursor(%{timestamp: nil}) == nil
      assert Pagination.generate_cursor(%{id: "test"}) == nil
    end
  end

  describe "parse_cursor/1" do
    test "parses valid cursor" do
      cursor = "#{@sample_timestamp_ms}:evt_123"
      assert {:ok, {timestamp, id}} = Pagination.parse_cursor(cursor)

      assert timestamp == @sample_timestamp
      assert id == "evt_123"
    end

    test "handles cursor with colons in id" do
      cursor = "#{@sample_timestamp_ms}:evt:with:colons"
      assert {:ok, {_timestamp, id}} = Pagination.parse_cursor(cursor)

      assert id == "evt:with:colons"
    end

    test "returns error for invalid cursor" do
      assert Pagination.parse_cursor("invalid") == :error
      assert Pagination.parse_cursor("not:a:valid:timestamp") == :error
      assert Pagination.parse_cursor("12345:") == :error
      assert Pagination.parse_cursor(":id") == :error
    end

    test "returns error for nil" do
      assert Pagination.parse_cursor(nil) == :error
    end
  end

  describe "parse_cursor!/1" do
    test "returns components for valid cursor" do
      cursor = "#{@sample_timestamp_ms}:evt_123"
      assert {timestamp, id} = Pagination.parse_cursor!(cursor)

      assert timestamp == @sample_timestamp
      assert id == "evt_123"
    end

    test "returns nil tuple for invalid cursor" do
      assert Pagination.parse_cursor!("invalid") == {nil, nil}
      assert Pagination.parse_cursor!(nil) == {nil, nil}
    end
  end

  describe "filter_after_cursor/3" do
    setup do
      t1 = ~U[2026-01-26 17:00:00Z]
      t2 = ~U[2026-01-26 17:01:00Z]
      t3 = ~U[2026-01-26 17:02:00Z]

      items_desc = [
        %{timestamp: t3, id: "3"},
        %{timestamp: t2, id: "2"},
        %{timestamp: t1, id: "1"}
      ]

      items_asc = [
        %{timestamp: t1, id: "1"},
        %{timestamp: t2, id: "2"},
        %{timestamp: t3, id: "3"}
      ]

      %{items_desc: items_desc, items_asc: items_asc, t1: t1, t2: t2, t3: t3}
    end

    test "returns all items when cursor is nil", %{items_desc: items} do
      assert Pagination.filter_after_cursor(items, nil, :desc) == items
    end

    test "filters items after cursor in descending order", %{items_desc: items, t2: t2} do
      cursor = Pagination.generate_cursor(%{timestamp: t2, id: "2"})
      filtered = Pagination.filter_after_cursor(items, cursor, :desc)

      assert length(filtered) == 1
      assert hd(filtered).id == "1"
    end

    test "filters items after cursor in ascending order", %{items_asc: items, t2: t2} do
      cursor = Pagination.generate_cursor(%{timestamp: t2, id: "2"})
      filtered = Pagination.filter_after_cursor(items, cursor, :asc)

      assert length(filtered) == 1
      assert hd(filtered).id == "3"
    end

    test "returns all items for invalid cursor", %{items_desc: items} do
      assert Pagination.filter_after_cursor(items, "invalid", :desc) == items
    end
  end

  describe "build_response/2" do
    setup do
      t1 = ~U[2026-01-26 17:00:00Z]
      t2 = ~U[2026-01-26 17:01:00Z]
      t3 = ~U[2026-01-26 17:02:00Z]

      items = [
        %{timestamp: t1, id: "1"},
        %{timestamp: t2, id: "2"},
        %{timestamp: t3, id: "3"}
      ]

      %{items: items}
    end

    test "returns paginated response with has_more true", %{items: items} do
      response = Pagination.build_response(items, 2)

      assert length(response.items) == 2
      assert response.has_more == true
      assert response.next_cursor != nil
    end

    test "returns response with has_more false when at end", %{items: items} do
      response = Pagination.build_response(items, 5)

      assert length(response.items) == 3
      assert response.has_more == false
      assert response.next_cursor == nil
    end

    test "returns response with exact limit", %{items: items} do
      response = Pagination.build_response(items, 3)

      assert length(response.items) == 3
      assert response.has_more == false
    end
  end

  describe "build_response/3 with custom key" do
    test "uses custom key for items" do
      items = [%{timestamp: ~U[2026-01-26 17:00:00Z], id: "1"}]
      response = Pagination.build_response(items, 10, :events)

      assert Map.has_key?(response, :events)
      refute Map.has_key?(response, :items)
      assert response.events == items
    end
  end
end
