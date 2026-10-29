defmodule Arbor.Contracts.Security.SandboxLevelTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Security.SandboxLevel

  test "default is the most restrictive level" do
    assert SandboxLevel.default() == :strict
  end

  test "levels are ordered most→least restrictive" do
    assert SandboxLevel.levels() == [:strict, :standard, :permissive, :none]
  end

  test "valid?/1 recognizes only canonical levels" do
    for l <- [:strict, :standard, :permissive, :none], do: assert(SandboxLevel.valid?(l))
    refute SandboxLevel.valid?(:basic)
    refute SandboxLevel.valid?("strict")
    refute SandboxLevel.valid?(nil)
  end

  test "coerce/1 accepts atoms + strings, fail-safe to :strict on anything else" do
    assert SandboxLevel.coerce(:permissive) == :permissive
    assert SandboxLevel.coerce("standard") == :standard
    assert SandboxLevel.coerce("none") == :none
    assert SandboxLevel.coerce(:bogus) == :strict
    assert SandboxLevel.coerce("nonsense") == :strict
    assert SandboxLevel.coerce(nil) == :strict
  end

  test "to_shell/1 maps each canonical level to the shell vocabulary" do
    assert SandboxLevel.to_shell(:strict) == :strict
    assert SandboxLevel.to_shell(:standard) == :basic
    assert SandboxLevel.to_shell(:permissive) == :basic
    assert SandboxLevel.to_shell(:none) == :none
    # unknown degrades to the default's shell level (most restrictive)
    assert SandboxLevel.to_shell(:bogus) == :strict
  end

  test "to_code/1 maps each canonical level to the code vocabulary" do
    assert SandboxLevel.to_code(:strict) == :pure
    assert SandboxLevel.to_code(:standard) == :limited
    assert SandboxLevel.to_code(:permissive) == :full
    assert SandboxLevel.to_code(:none) == :full
    assert SandboxLevel.to_code(:bogus) == :pure
  end
end
