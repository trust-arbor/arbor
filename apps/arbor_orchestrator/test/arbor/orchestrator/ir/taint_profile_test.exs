defmodule Arbor.Orchestrator.IR.TaintProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.IR.TaintProfile

  describe "pessimistic/0" do
    test "returns maximally restrictive profile" do
      profile = TaintProfile.pessimistic()
      assert profile.sensitivity == :restricted
      assert profile.wipes_sanitizations == true
      assert profile.provider_constraint == :can_see_restricted
      assert profile.min_confidence == :unverified
      assert profile.required_sanitizations == 0
      assert profile.output_sanitizations == 0
    end
  end

  describe "satisfies?/2" do
    test "zero required is always satisfied" do
      assert TaintProfile.satisfies?(0, 0)
      assert TaintProfile.satisfies?(0xFF, 0)
    end

    test "exact match satisfies" do
      assert TaintProfile.satisfies?(0b00001100, 0b00001100)
    end

    test "superset satisfies" do
      # provided has both command_injection + path_traversal + xss
      assert TaintProfile.satisfies?(0b00001101, 0b00001100)
    end

    test "subset does not satisfy" do
      # only has command_injection, needs path_traversal too
      refute TaintProfile.satisfies?(0b00000100, 0b00001100)
    end

    test "disjoint does not satisfy" do
      refute TaintProfile.satisfies?(0b00000001, 0b00000010)
    end
  end

  describe "missing_sanitizations/2" do
    test "returns empty list when all satisfied" do
      assert TaintProfile.missing_sanitizations(0b00001100, 0b00001100) == []
    end

    test "returns empty list when zero required" do
      assert TaintProfile.missing_sanitizations(0, 0) == []
    end

    test "returns missing sanitization names" do
      # provided: xss (0b01), required: xss+sqli (0b11)
      missing = TaintProfile.missing_sanitizations(0b00000001, 0b00000011)
      assert :sqli in missing
      refute :xss in missing
    end

    test "returns all required when nothing provided" do
      missing = TaintProfile.missing_sanitizations(0, 0b00001100)
      assert :command_injection in missing
      assert :path_traversal in missing
      assert length(missing) == 2
    end
  end

  describe "confidence_rank/1" do
    test "returns correct ordering" do
      assert TaintProfile.confidence_rank(:unverified) == 0
      assert TaintProfile.confidence_rank(:plausible) == 1
      assert TaintProfile.confidence_rank(:corroborated) == 2
      assert TaintProfile.confidence_rank(:verified) == 3
    end
  end

  describe "parse_sanitization_names/1" do
    test "parses comma-separated names into bitmask" do
      mask = TaintProfile.parse_sanitization_names("command_injection,path_traversal")
      # command_injection = 0b00000100, path_traversal = 0b00001000
      assert mask == 0b00001100
    end

    test "handles single name" do
      mask = TaintProfile.parse_sanitization_names("xss")
      assert mask == 0b00000001
    end

    test "handles whitespace" do
      mask = TaintProfile.parse_sanitization_names(" xss , sqli ")
      assert mask == 0b00000011
    end

    test "ignores unknown names" do
      mask = TaintProfile.parse_sanitization_names("xss,unknown_thing")
      assert mask == 0b00000001
    end

    test "returns 0 for nil" do
      assert TaintProfile.parse_sanitization_names(nil) == 0
    end

    test "returns 0 for empty string" do
      mask = TaintProfile.parse_sanitization_names("")
      assert mask == 0
    end
  end
end
