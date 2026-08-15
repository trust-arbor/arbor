defmodule Arbor.Contracts.Consensus.InvariantsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.Invariants

  describe "council constants" do
    test "council_size is 7" do
      assert Invariants.council_size() == 7
    end

    test "standard_quorum is 5" do
      assert Invariants.standard_quorum() == 5
    end

    test "meta_quorum is 6" do
      assert Invariants.meta_quorum() == 6
    end

    test "low_risk_quorum is 4" do
      assert Invariants.low_risk_quorum() == 4
    end
  end

  describe "quorum_for_change_type/1" do
    test "governance_change requires meta quorum" do
      assert Invariants.quorum_for_change_type(:governance_change) == 6
    end

    test "topic_governance requires meta quorum" do
      assert Invariants.quorum_for_change_type(:topic_governance) == 6
    end

    test "documentation_change requires low risk quorum" do
      assert Invariants.quorum_for_change_type(:documentation_change) == 4
    end

    test "test_change requires low risk quorum" do
      assert Invariants.quorum_for_change_type(:test_change) == 4
    end

    test "code_modification requires standard quorum" do
      assert Invariants.quorum_for_change_type(:code_modification) == 5
    end

    test "unknown change type requires standard quorum" do
      assert Invariants.quorum_for_change_type(:something_else) == 5
    end
  end

  describe "meets_quorum?/2" do
    test "5 approvals meets standard quorum" do
      assert Invariants.meets_quorum?(5, :code_modification) == true
    end

    test "4 approvals does not meet standard quorum" do
      assert Invariants.meets_quorum?(4, :code_modification) == false
    end

    test "6 approvals meets meta quorum" do
      assert Invariants.meets_quorum?(6, :governance_change) == true
    end

    test "4 approvals meets low-risk quorum" do
      assert Invariants.meets_quorum?(4, :documentation_change) == true
    end
  end

  describe "meta_change?/1" do
    test "true for governance_change" do
      assert Invariants.meta_change?(:governance_change) == true
    end

    test "true for topic_governance" do
      assert Invariants.meta_change?(:topic_governance) == true
    end

    test "false for other types" do
      assert Invariants.meta_change?(:code_modification) == false
    end
  end

  describe "low_risk_change?/1" do
    test "true for documentation_change" do
      assert Invariants.low_risk_change?(:documentation_change) == true
    end

    test "true for test_change" do
      assert Invariants.low_risk_change?(:test_change) == true
    end

    test "false for other types" do
      assert Invariants.low_risk_change?(:code_modification) == false
    end
  end

  describe "immutable_invariants/0" do
    test "returns 5 invariants" do
      invariants = Invariants.immutable_invariants()
      assert length(invariants) == 5
      assert :consensus_requires_quorum in invariants
      assert :evaluators_are_independent in invariants
      assert :containment_boundary_exists in invariants
      assert :audit_log_append_only in invariants
      assert :layer_hierarchy_enforced in invariants
    end
  end

  describe "violation_patterns/0" do
    test "returns list of violation strings" do
      patterns = Invariants.violation_patterns()
      assert is_list(patterns)
      assert patterns != []
      assert "quorum = 0" in patterns
      assert "bypass_boundary" in patterns
    end
  end
end
