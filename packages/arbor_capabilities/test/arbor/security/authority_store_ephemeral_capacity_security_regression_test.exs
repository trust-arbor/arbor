defmodule Arbor.Security.AuthorityStoreEphemeralCapacitySecurityRegressionTest do
  @moduledoc """
  Security regression: an ephemeral AuthorityStore's capacity bounds live
  records, not every key ever written.

  Deletes in ephemeral mode keep a tombstone in `state.entries` (CAS inserts
  read its generation), and `ensure_ephemeral_capacity/2` admitted a new key
  only while `map_size(state.entries)` was below `hydration_limit`. Tombstones
  were never pruned, so once `hydration_limit` distinct keys had ever been
  written, every new key was refused with `:inventory_limit_exceeded` until
  restart, even with no live record left.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuthorityStore

  test "security regression: deleted keys do not use up ephemeral capacity" do
    name = :"authority_ephemeral_capacity_#{System.unique_integer([:positive])}"
    start_supervised!({AuthorityStore, name: name, backend: nil, hydration_limit: 1})

    assert {:ok, _} = AuthorityStore.acknowledged_put("first", Record.new("first"), name: name)
    assert :ok = AuthorityStore.delete("first", name: name)
    assert {:error, :not_found} = AuthorityStore.authoritative_get("first", name: name)

    # No live record remains, so a new key fits under a limit of one.
    assert {:ok, _} = AuthorityStore.acknowledged_put("second", Record.new("second"), name: name)

    # The bound still holds for live records.
    assert {:error, :inventory_limit_exceeded} =
             AuthorityStore.put("third", Record.new("third"), name: name)

    # A deleted key can be written again, as before.
    assert :ok = AuthorityStore.delete("second", name: name)
    assert {:ok, _} = AuthorityStore.acknowledged_put("first", Record.new("first"), name: name)
  end
end
