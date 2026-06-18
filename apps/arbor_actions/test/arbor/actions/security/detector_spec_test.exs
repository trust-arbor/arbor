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

  describe "build/1 — S3 shape (tree-wide pattern)" do
    test "infers :s3 from an S3 category and builds a literal pattern" do
      assert {:ok, %DetectorSpec{} = spec} =
               DetectorSpec.build(%{
                 category: :capability_overmatch,
                 invariant: "No over-broad capability match.",
                 match_pattern: %{kind: :literal, literal: "arbor://**"}
               })

      assert spec.shape == :s3
      assert spec.category == :capability_overmatch
      assert spec.match_pattern == %{kind: :literal, literal: "arbor://**"}
      assert spec.name == "synthesized_capability_overmatch"
    end

    test "builds a :call pattern for serialization_drop" do
      assert {:ok, %DetectorSpec{shape: :s3} = spec} =
               DetectorSpec.build(%{
                 category: :serialization_drop,
                 invariant: "Signed struct must not drop a field on serialize.",
                 match_pattern: %{kind: :call, call: "String.to_atom"}
               })

      assert spec.match_pattern == %{kind: :call, call: "String.to_atom"}
    end

    test "rejects an S3 category with a missing match_pattern" do
      assert {:error, :invalid_match_pattern} =
               DetectorSpec.build(%{
                 category: :capability_overmatch,
                 invariant: "x"
               })
    end

    test "rejects an S3 category with an unknown match_pattern kind" do
      assert {:error, :invalid_match_pattern} =
               DetectorSpec.build(%{
                 category: :capability_overmatch,
                 match_pattern: %{kind: :bogus, literal: "x"}
               })
    end

    test "accepts string-keyed params + string shape/kind (atom category)" do
      # build/1 expects an atom category value (JSON→atom coercion is upstream in
      # SynthesizeDetector); string KEYS and a string shape/kind are supported.
      assert {:ok, %DetectorSpec{shape: :s3}} =
               DetectorSpec.build(%{
                 "shape" => "s3",
                 "category" => :capability_overmatch,
                 "invariant" => "x",
                 "match_pattern" => %{"kind" => "literal", "literal" => "arbor://**"}
               })
    end

    test "an explicit shape that disagrees with the category is unsupported" do
      # :fail_open_authz is S1; asking for :s3 is a mismatch.
      assert {:error, {:unsupported_shape, :fail_open_authz}} =
               DetectorSpec.build(%{
                 shape: :s3,
                 category: :fail_open_authz,
                 match_pattern: %{kind: :literal, literal: "x"}
               })
    end

    test "a bespoke/correlation category (crypto_weakness) is rejected as unsupported" do
      # SignedFieldCoverage's transitive-closure shape is NOT expressible as a
      # tree-wide pattern → it stays hand-authored.
      assert {:error, {:unsupported_shape, :crypto_weakness}} =
               DetectorSpec.build(%{
                 category: :crypto_weakness,
                 match_pattern: %{kind: :literal, literal: "x"}
               })
    end
  end

  describe "shape_for_category/1 + s3_category?/1" do
    test "S1 categories map to :s1, S3 to :s3, others to :error" do
      assert DetectorSpec.shape_for_category(:fail_open_authz) == {:ok, :s1}
      assert DetectorSpec.shape_for_category(:capability_overmatch) == {:ok, :s3}
      assert DetectorSpec.shape_for_category(:serialization_drop) == {:ok, :s3}
      assert DetectorSpec.shape_for_category(:crypto_weakness) == :error
      assert DetectorSpec.shape_for_category(:other) == :error
    end

    test "s3_category?/1" do
      assert DetectorSpec.s3_category?(:capability_overmatch)
      assert DetectorSpec.s3_category?(:serialization_drop)
      refute DetectorSpec.s3_category?(:fail_open_authz)
    end
  end
end
