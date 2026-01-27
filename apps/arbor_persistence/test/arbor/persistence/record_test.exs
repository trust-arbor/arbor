defmodule Arbor.Persistence.RecordTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Record

  describe "new/3" do
    test "creates record with auto-generated id and timestamps" do
      record = Record.new("my_key", %{value: 1})

      assert String.starts_with?(record.id, "rec_")
      assert record.key == "my_key"
      assert record.data == %{value: 1}
      assert record.metadata == %{}
      assert %DateTime{} = record.inserted_at
      assert %DateTime{} = record.updated_at
    end

    test "creates record with custom id" do
      record = Record.new("key", %{}, id: "custom_id")
      assert record.id == "custom_id"
    end

    test "creates record with metadata" do
      record = Record.new("key", %{}, metadata: %{source: "test"})
      assert record.metadata == %{source: "test"}
    end

    test "creates record with default empty data" do
      record = Record.new("key")
      assert record.data == %{}
    end
  end

  describe "update/3" do
    test "updates data and bumps updated_at" do
      record = Record.new("key", %{old: true})
      Process.sleep(1)
      updated = Record.update(record, %{new: true})

      assert updated.data == %{new: true}
      assert updated.key == "key"
      assert DateTime.compare(updated.updated_at, record.updated_at) in [:gt, :eq]
    end

    test "can update metadata" do
      record = Record.new("key", %{})
      updated = Record.update(record, %{}, metadata: %{updated: true})
      assert updated.metadata == %{updated: true}
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      record = Record.new("key", %{value: 42})
      assert {:ok, json} = Jason.encode(record)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["key"] == "key"
      assert decoded["data"]["value"] == 42
    end
  end
end
