defmodule Arbor.Actions.Security.DetectorSpecTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.DetectorSpec

  describe "build/1 — S1 scope boundary" do
    test "builds a valid fail_open_authz spec" do
      assert {:ok, %DetectorSpec{} = spec} =
               DetectorSpec.build(%{
                 category: :fail_open_authz,
                 invariant: "Auth must fail closed.",
                 name_match: ["authoriz", :can?],
                 target_literals: [:ok, true, {:ok, :_}],
                 exclusions: [{:ok, :verified}],
                 clause_position: :rescue_or_catch_all
               })

      assert spec.category == :fail_open_authz
      assert spec.name == "synthesized_fail_open_authz"
      assert :can? in spec.name_match
    end

    test "rejects a non-S1 category with {:unsupported_shape, category}" do
      assert {:error, {:unsupported_shape, :crypto_weakness}} =
               DetectorSpec.build(%{
                 category: :crypto_weakness,
                 name_match: ["verif"],
                 target_literals: [true]
               })
    end

    test "rejects an unknown clause_position" do
      assert {:error, {:invalid_clause_position, :bogus}} =
               DetectorSpec.build(%{
                 category: :unsafe_atom,
                 name_match: ["foo"],
                 target_literals: [:ok],
                 clause_position: :bogus
               })
    end

    test "rejects an empty name_match (matches nothing)" do
      assert {:error, :empty_name_match} =
               DetectorSpec.build(%{category: :path_traversal, target_literals: [:ok]})
    end

    test "rejects empty target_literals (nothing to flag)" do
      assert {:error, :empty_target_literals} =
               DetectorSpec.build(%{category: :config_fail_open, name_match: ["foo"]})
    end
  end

  describe "s1_category?/1" do
    test "the four known S1 categories are accepted" do
      for c <- [:fail_open_authz, :unsafe_atom, :path_traversal, :config_fail_open] do
        assert DetectorSpec.s1_category?(c)
      end
    end

    test "other categories are not S1" do
      refute DetectorSpec.s1_category?(:crypto_weakness)
      refute DetectorSpec.s1_category?(:other)
    end
  end
end
