defmodule Arbor.Contracts.Persistence.StoreCASTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Store

  describe "Store optional CAS contract surface" do
    test "behaviour declares optional compare_and_swap/4 and durability_class/1" do
      optional = Store.behaviour_info(:optional_callbacks)

      assert {:compare_and_swap, 4} in optional
      assert {:durability_class, 1} in optional
    end

    test "required callbacks remain put/get/delete/list" do
      callbacks = Store.behaviour_info(:callbacks)

      assert {:put, 3} in callbacks
      assert {:get, 2} in callbacks
      assert {:delete, 2} in callbacks
      assert {:list, 1} in callbacks
    end
  end
end
