defmodule Arbor.Common.Extension.RegistryCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Extension.RegistryCore
  alias Arbor.Contracts.Extension.Envelope

  test "staged handles are invisible until publish" do
    state = RegistryCore.new()
    transaction = Envelope.fixture(:activation_transaction)
    handle = Envelope.fixture(:provider_handle)

    {:ok, staged} =
      RegistryCore.stage(state, transaction, handle, "owner.1", "2026-08-16T00:00:00Z")

    assert {:error, "no_compatible_provider"} =
             RegistryCore.resolve(staged, handle["protocol_id"], "2026-08-16T00:00:00Z")

    receipt = %{
      Envelope.fixture(:activation_receipt)
      | "transaction_id" => transaction["transaction_id"]
    }

    {:ok, published} = RegistryCore.publish(staged, receipt, "2026-08-16T00:00:00Z")
    assert {:ok, entry} = RegistryCore.resolve(published, "vector.store", "2026-08-16T00:00:00Z")
    refute Map.has_key?(entry["handle"], "module")
    assert entry["handle"]["handle_id"] == handle["handle_id"]
  end

  test "core lock blocks overwrite and rollback leaves no residue" do
    transaction = Envelope.fixture(:activation_transaction)
    handle = Envelope.fixture(:provider_handle)

    receipt = %{
      Envelope.fixture(:activation_receipt)
      | "transaction_id" => transaction["transaction_id"]
    }

    {:ok, state} = RegistryCore.mark_core(RegistryCore.new(), "vector.store")
    state = RegistryCore.lock_core(state)

    {:ok, staged} =
      RegistryCore.stage(state, transaction, handle, "owner.1", "2026-08-16T00:00:00Z")

    {:ok, published} = RegistryCore.publish(staged, receipt, "2026-08-16T00:00:00Z")

    assert {:error, "commit_conflict"} =
             RegistryCore.stage(published, transaction, handle, "owner.1", "2026-08-16T00:00:00Z")

    {:ok, again} =
      RegistryCore.stage(
        RegistryCore.new(),
        transaction,
        handle,
        "owner.1",
        "2026-08-16T00:00:00Z"
      )

    {:ok, rolled} = RegistryCore.rollback(again)

    assert {:error, "no_compatible_provider"} =
             RegistryCore.resolve(rolled, "vector.store", "2026-08-16T00:00:00Z")
  end

  test "expired leases and dead owners are cleaned" do
    transaction = Envelope.fixture(:activation_transaction)
    handle = Envelope.fixture(:provider_handle)

    receipt = %{
      Envelope.fixture(:activation_receipt)
      | "transaction_id" => transaction["transaction_id"]
    }

    {:ok, staged} =
      RegistryCore.stage(
        RegistryCore.new(),
        transaction,
        handle,
        "owner.1",
        "2026-08-16T00:00:00Z"
      )

    {:ok, published} = RegistryCore.publish(staged, receipt, "2026-08-16T00:00:00Z")

    assert {:error, "expired_lease"} =
             RegistryCore.resolve(published, "vector.store", "2026-08-18T00:00:00Z")

    cleaned = RegistryCore.cleanup(published, "2026-08-16T00:00:00Z", dead_owner_id: "owner.1")

    assert {:error, "no_compatible_provider"} =
             RegistryCore.resolve(cleaned, "vector.store", "2026-08-16T00:00:00Z")
  end

  test "handles with executable identity are rejected" do
    transaction = Envelope.fixture(:activation_transaction)
    handle = Map.put(Envelope.fixture(:provider_handle), "module", "Elixir.Foo")

    assert {:error, "malformed"} =
             RegistryCore.stage(
               RegistryCore.new(),
               transaction,
               handle,
               "owner.1",
               "2026-08-16T00:00:00Z"
             )
  end
end
