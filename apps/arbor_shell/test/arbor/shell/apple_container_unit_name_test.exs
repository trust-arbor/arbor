defmodule Arbor.Shell.AppleContainerUnitNameTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerUnitJournalCore, as: Journal
  alias Arbor.Shell.AppleContainerUnitName
  alias Arbor.Shell.AppleContainerUnitRecoveryCore, as: Recovery

  @moduletag :fast

  test "generated unit names satisfy the durable journal and recovery contract" do
    entropy = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>

    assert {:ok, name} = AppleContainerUnitName.from_entropy(entropy)
    assert name == "arbor-v1-000102030405060708090a0b0c0d0e0f"
    assert {:ok, ^name} = AppleContainerUnitName.validate(name)

    assert {:ok, journal} = Journal.new()

    assert {:ok, _journal, [{:persist_snapshot, _snapshot}]} =
             Journal.reserve(journal, %{
               unit_name: name,
               execution_id: "exec-unit-name-contract",
               token: String.duplicate("a", 64),
               reserved_at_ms: 1
             })

    assert {:ok, %{unit_name: ^name}, _effects} = Recovery.new(name)
  end

  test "rejects non-128-bit entropy and near-miss names" do
    assert {:error, :invalid_unit_name_entropy} =
             AppleContainerUnitName.from_entropy(<<0::120>>)

    for name <- [
          "a" <> String.duplicate("0", 32),
          "arbor-v1-" <> String.duplicate("0", 31),
          "arbor-v1-" <> String.duplicate("A", 32),
          "arbor-v2-" <> String.duplicate("0", 32)
        ] do
      assert {:error, :invalid_unit_name} = AppleContainerUnitName.validate(name)
    end
  end
end
