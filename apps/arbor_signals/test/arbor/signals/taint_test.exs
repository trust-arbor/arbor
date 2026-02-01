defmodule Arbor.Signals.TaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Signals.Taint

  @moduletag :fast

  describe "valid_level?/1" do
    test "returns true for all valid levels" do
      assert Taint.valid_level?(:trusted)
      assert Taint.valid_level?(:derived)
      assert Taint.valid_level?(:untrusted)
      assert Taint.valid_level?(:hostile)
    end

    test "returns false for invalid levels" do
      refute Taint.valid_level?(:unknown)
      refute Taint.valid_level?(:safe)
      refute Taint.valid_level?("trusted")
      refute Taint.valid_level?(nil)
    end
  end

  describe "valid_role?/1" do
    test "returns true for valid roles" do
      assert Taint.valid_role?(:control)
      assert Taint.valid_role?(:data)
    end

    test "returns false for invalid roles" do
      refute Taint.valid_role?(:unknown)
      refute Taint.valid_role?(:input)
      refute Taint.valid_role?("control")
      refute Taint.valid_role?(nil)
    end
  end

  describe "severity/1" do
    test "returns correct severity ordering" do
      assert Taint.severity(:trusted) == 0
      assert Taint.severity(:derived) == 1
      assert Taint.severity(:untrusted) == 2
      assert Taint.severity(:hostile) == 3
    end

    test "severity ordering is consistent" do
      assert Taint.severity(:trusted) < Taint.severity(:derived)
      assert Taint.severity(:derived) < Taint.severity(:untrusted)
      assert Taint.severity(:untrusted) < Taint.severity(:hostile)
    end
  end

  describe "max_taint/2" do
    test "returns the higher severity level" do
      assert Taint.max_taint(:trusted, :trusted) == :trusted
      assert Taint.max_taint(:trusted, :derived) == :derived
      assert Taint.max_taint(:trusted, :untrusted) == :untrusted
      assert Taint.max_taint(:trusted, :hostile) == :hostile
    end

    test "is symmetric" do
      assert Taint.max_taint(:trusted, :untrusted) == Taint.max_taint(:untrusted, :trusted)
      assert Taint.max_taint(:derived, :hostile) == Taint.max_taint(:hostile, :derived)
    end

    test "hostile dominates all" do
      assert Taint.max_taint(:hostile, :trusted) == :hostile
      assert Taint.max_taint(:hostile, :derived) == :hostile
      assert Taint.max_taint(:hostile, :untrusted) == :hostile
      assert Taint.max_taint(:hostile, :hostile) == :hostile
    end
  end

  describe "propagate/1" do
    test "empty list returns trusted" do
      assert Taint.propagate([]) == :trusted
    end

    test "single trusted stays trusted" do
      assert Taint.propagate([:trusted]) == :trusted
    end

    test "all trusted stays trusted" do
      assert Taint.propagate([:trusted, :trusted, :trusted]) == :trusted
    end

    test "trusted + derived = derived" do
      assert Taint.propagate([:trusted, :derived]) == :derived
    end

    test "untrusted becomes derived (not untrusted) when propagated" do
      assert Taint.propagate([:trusted, :untrusted]) == :derived
      assert Taint.propagate([:untrusted]) == :derived
    end

    test "hostile stays hostile" do
      assert Taint.propagate([:hostile]) == :hostile
      assert Taint.propagate([:trusted, :hostile]) == :hostile
      assert Taint.propagate([:untrusted, :hostile]) == :hostile
    end

    test "mixed levels propagate correctly" do
      assert Taint.propagate([:trusted, :derived, :untrusted]) == :derived
      assert Taint.propagate([:trusted, :trusted, :hostile]) == :hostile
    end
  end

  describe "can_use_as?/2 truth table" do
    test "trusted can be used as control" do
      assert Taint.can_use_as?(:trusted, :control)
    end

    test "trusted can be used as data" do
      assert Taint.can_use_as?(:trusted, :data)
    end

    test "derived can be used as control (audited, not blocked)" do
      assert Taint.can_use_as?(:derived, :control)
    end

    test "derived can be used as data" do
      assert Taint.can_use_as?(:derived, :data)
    end

    test "untrusted CANNOT be used as control" do
      refute Taint.can_use_as?(:untrusted, :control)
    end

    test "untrusted can be used as data" do
      assert Taint.can_use_as?(:untrusted, :data)
    end

    test "hostile CANNOT be used as control" do
      refute Taint.can_use_as?(:hostile, :control)
    end

    test "hostile CANNOT be used as data" do
      refute Taint.can_use_as?(:hostile, :data)
    end
  end

  describe "reduce/3" do
    test "human_review can reduce anything to trusted" do
      assert Taint.reduce(:hostile, :trusted, :human_review) == {:ok, :trusted}
      assert Taint.reduce(:untrusted, :trusted, :human_review) == {:ok, :trusted}
      assert Taint.reduce(:derived, :trusted, :human_review) == {:ok, :trusted}
    end

    test "human_review can reduce to any level" do
      assert Taint.reduce(:hostile, :derived, :human_review) == {:ok, :derived}
      assert Taint.reduce(:untrusted, :derived, :human_review) == {:ok, :derived}
    end

    test "consensus can reduce untrusted to derived" do
      assert Taint.reduce(:untrusted, :derived, :consensus) == {:ok, :derived}
    end

    test "consensus CANNOT reduce untrusted to trusted" do
      assert Taint.reduce(:untrusted, :trusted, :consensus) == {:error, :reduction_not_allowed}
    end

    test "consensus can reduce hostile to derived" do
      assert Taint.reduce(:hostile, :derived, :consensus) == {:ok, :derived}
    end

    test "consensus CANNOT reduce hostile to trusted" do
      assert Taint.reduce(:hostile, :trusted, :consensus) == {:error, :reduction_not_allowed}
    end

    test "verified_pipeline can reduce untrusted to derived" do
      assert Taint.reduce(:untrusted, :derived, :verified_pipeline) == {:ok, :derived}
    end

    test "verified_pipeline CANNOT reduce untrusted to trusted" do
      assert Taint.reduce(:untrusted, :trusted, :verified_pipeline) == {:error, :reduction_not_allowed}
    end

    test "reduction to same level always succeeds" do
      assert Taint.reduce(:trusted, :trusted, :consensus) == {:ok, :trusted}
      assert Taint.reduce(:derived, :derived, :consensus) == {:ok, :derived}
    end

    test "reduction to higher severity always succeeds" do
      assert Taint.reduce(:trusted, :derived, :consensus) == {:ok, :derived}
      assert Taint.reduce(:trusted, :untrusted, :consensus) == {:ok, :untrusted}
    end
  end

  describe "from_metadata/1" do
    test "extracts taint info from metadata" do
      metadata = %{taint: :untrusted, taint_source: "external", taint_chain: ["sig_1"]}
      result = Taint.from_metadata(metadata)

      assert result.taint == :untrusted
      assert result.taint_source == "external"
      assert result.taint_chain == ["sig_1"]
    end

    test "provides defaults for missing fields" do
      result = Taint.from_metadata(%{})

      assert result.taint == :trusted
      assert result.taint_source == nil
      assert result.taint_chain == []
    end

    test "handles partial metadata" do
      result = Taint.from_metadata(%{taint: :derived})

      assert result.taint == :derived
      assert result.taint_source == nil
      assert result.taint_chain == []
    end
  end

  describe "to_metadata/3" do
    test "builds metadata map with all fields" do
      result = Taint.to_metadata(:untrusted, "llm_output", ["sig_1", "sig_2"])

      assert result == %{
               taint: :untrusted,
               taint_source: "llm_output",
               taint_chain: ["sig_1", "sig_2"]
             }
    end

    test "defaults chain to empty list" do
      result = Taint.to_metadata(:trusted, "internal")

      assert result == %{
               taint: :trusted,
               taint_source: "internal",
               taint_chain: []
             }
    end
  end

  describe "merge_metadata/2" do
    test "merges taint fields into base metadata" do
      base = %{agent_id: "agent_001", custom: "value"}
      taint = %{taint: :untrusted, taint_source: "external"}

      result = Taint.merge_metadata(base, taint)

      assert result == %{
               agent_id: "agent_001",
               custom: "value",
               taint: :untrusted,
               taint_source: "external"
             }
    end

    test "taint fields override existing values" do
      base = %{taint: :trusted, other: "data"}
      taint = %{taint: :hostile}

      result = Taint.merge_metadata(base, taint)

      assert result.taint == :hostile
      assert result.other == "data"
    end
  end

  describe "from_metadata/to_metadata round-trip" do
    test "round-trip preserves data" do
      original = Taint.to_metadata(:untrusted, "source", ["chain_1"])
      extracted = Taint.from_metadata(original)

      assert extracted.taint == :untrusted
      assert extracted.taint_source == "source"
      assert extracted.taint_chain == ["chain_1"]
    end
  end

  describe "levels/0 and roles/0" do
    test "returns all levels in order" do
      assert Taint.levels() == [:trusted, :derived, :untrusted, :hostile]
    end

    test "returns all roles" do
      assert Taint.roles() == [:control, :data]
    end
  end
end
