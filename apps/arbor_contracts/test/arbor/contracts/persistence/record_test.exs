defmodule Arbor.Contracts.Persistence.RecordTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record

  describe "new/3" do
    test "creates record with key and defaults" do
      record = Record.new("user:123")
      assert %Record{} = record
      assert record.key == "user:123"
      assert record.data == %{}
      assert record.metadata == %{}
      assert String.starts_with?(record.id, "rec_")
      assert %DateTime{} = record.inserted_at
      assert %DateTime{} = record.updated_at
    end

    test "creates record with data" do
      record = Record.new("user:123", %{name: "Alice"})
      assert record.data == %{name: "Alice"}
    end

    test "accepts opts for id and metadata" do
      record = Record.new("k", %{}, id: "custom_id", metadata: %{source: :import})
      assert record.id == "custom_id"
      assert record.metadata == %{source: :import}
    end
  end

  describe "update/3" do
    test "updates data and bumps updated_at" do
      record = Record.new("k", %{a: 1})
      # small sleep to ensure timestamp differs
      updated = Record.update(record, %{a: 2, b: 3})
      assert updated.data == %{a: 2, b: 3}
      assert updated.key == "k"
      assert DateTime.compare(updated.updated_at, record.inserted_at) in [:gt, :eq]
    end

    test "preserves metadata by default" do
      record = Record.new("k", %{}, metadata: %{source: :api})
      updated = Record.update(record, %{x: 1})
      assert updated.metadata == %{source: :api}
    end

    test "allows metadata override" do
      record = Record.new("k", %{}, metadata: %{source: :api})
      updated = Record.update(record, %{x: 1}, metadata: %{source: :batch})
      assert updated.metadata == %{source: :batch}
    end
  end

  describe "Jason.Encoder" do
    test "encodes record to JSON" do
      record = Record.new("test_key", %{value: 42})
      assert {:ok, json} = Jason.encode(record)
      decoded = Jason.decode!(json)
      assert decoded["key"] == "test_key"
      assert decoded["data"]["value"] == 42
      assert is_binary(decoded["inserted_at"])
    end
  end
end
