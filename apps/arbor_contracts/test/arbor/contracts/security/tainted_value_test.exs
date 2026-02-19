defmodule Arbor.Contracts.Security.TaintedValueTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintedValue}

  @moduletag :fast

  describe "wrap/2" do
    test "wraps a value with taint" do
      taint = %Taint{level: :untrusted, sensitivity: :confidential}
      tv = TaintedValue.wrap("secret data", taint)
      assert tv.value == "secret data"
      assert tv.taint == taint
    end

    test "works with any value type" do
      taint = %Taint{}
      assert %TaintedValue{value: 42} = TaintedValue.wrap(42, taint)
      assert %TaintedValue{value: [1, 2]} = TaintedValue.wrap([1, 2], taint)
      assert %TaintedValue{value: %{a: 1}} = TaintedValue.wrap(%{a: 1}, taint)
    end
  end

  describe "unwrap!/1" do
    test "extracts the raw value" do
      tv = TaintedValue.wrap("data", %Taint{level: :hostile})
      assert TaintedValue.unwrap!(tv) == "data"
    end
  end

  describe "trusted/1" do
    test "creates a trusted public value" do
      tv = TaintedValue.trusted("safe data")
      assert tv.value == "safe data"
      assert tv.taint.level == :trusted
      assert tv.taint.sensitivity == :public
      assert tv.taint.confidence == :verified
    end
  end

  describe "unknown/1" do
    test "creates a value with conservative defaults" do
      tv = TaintedValue.unknown("mystery data")
      assert tv.value == "mystery data"
      assert tv.taint.level == :trusted
      assert tv.taint.sensitivity == :internal
      assert tv.taint.confidence == :unverified
    end
  end

  describe "level?/2" do
    test "returns true when level matches" do
      tv = TaintedValue.wrap("x", %Taint{level: :hostile})
      assert TaintedValue.level?(tv, :hostile)
    end

    test "returns false when level does not match" do
      tv = TaintedValue.wrap("x", %Taint{level: :trusted})
      refute TaintedValue.level?(tv, :hostile)
    end
  end

  describe "sensitivity_at_most?/2" do
    test "public is at most public" do
      tv = TaintedValue.trusted("x")
      assert TaintedValue.sensitivity_at_most?(tv, :public)
    end

    test "public is at most internal" do
      tv = TaintedValue.trusted("x")
      assert TaintedValue.sensitivity_at_most?(tv, :internal)
    end

    test "confidential is NOT at most internal" do
      tv = TaintedValue.wrap("x", %Taint{sensitivity: :confidential})
      refute TaintedValue.sensitivity_at_most?(tv, :internal)
    end

    test "restricted is only at most restricted" do
      tv = TaintedValue.wrap("x", %Taint{sensitivity: :restricted})
      refute TaintedValue.sensitivity_at_most?(tv, :confidential)
      assert TaintedValue.sensitivity_at_most?(tv, :restricted)
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      tv = TaintedValue.trusted("test")
      assert {:ok, _json} = Jason.encode(tv)
    end
  end
end
