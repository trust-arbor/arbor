defmodule Arbor.Consensus.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Config

  describe "new/1" do
    test "creates config with defaults" do
      config = Config.new()

      assert config.council_size == 7
      assert config.evaluation_timeout_ms == 90_000
      assert config.max_concurrent_proposals == 10
      assert config.auto_execute_approved == false
      assert is_map(config.quorum_rules)
      assert is_map(config.perspectives_for_change_type)
    end

    test "accepts custom council_size" do
      config = Config.new(council_size: 5)
      assert config.council_size == 5
    end

    test "accepts custom evaluation_timeout_ms" do
      config = Config.new(evaluation_timeout_ms: 30_000)
      assert config.evaluation_timeout_ms == 30_000
    end

    test "accepts custom max_concurrent_proposals" do
      config = Config.new(max_concurrent_proposals: 3)
      assert config.max_concurrent_proposals == 3
    end

    test "accepts auto_execute_approved flag" do
      config = Config.new(auto_execute_approved: true)
      assert config.auto_execute_approved == true
    end

    test "merges custom quorum rules with defaults" do
      config = Config.new(quorum_rules: %{code_modification: 3})
      assert config.quorum_rules[:code_modification] == 3
      # Other defaults preserved
      assert config.quorum_rules[:governance_change] == 6
    end

    test "merges custom perspectives with defaults" do
      custom = %{code_modification: [:security, :stability]}
      config = Config.new(perspectives_for_change_type: custom)
      assert config.perspectives_for_change_type[:code_modification] == [:security, :stability]
      # Other defaults preserved
      assert is_list(config.perspectives_for_change_type[:governance_change])
    end
  end

  describe "quorum_for/2" do
    test "returns governance quorum" do
      config = Config.new()
      assert Config.quorum_for(config, :governance_change) == 6
    end

    test "returns standard quorum for code modification" do
      config = Config.new()
      assert Config.quorum_for(config, :code_modification) == 5
    end

    test "returns low-risk quorum for documentation" do
      config = Config.new()
      assert Config.quorum_for(config, :documentation_change) == 4
    end

    test "returns low-risk quorum for test changes" do
      config = Config.new()
      assert Config.quorum_for(config, :test_change) == 4
    end

    test "returns standard quorum for unknown change types" do
      config = Config.new()
      assert Config.quorum_for(config, :unknown_type) == 5
    end

    test "respects custom quorum rules" do
      config = Config.new(quorum_rules: %{code_modification: 3})
      assert Config.quorum_for(config, :code_modification) == 3
    end
  end

  describe "perspectives_for/2" do
    test "returns perspectives for code modification" do
      config = Config.new()
      perspectives = Config.perspectives_for(config, :code_modification)
      assert is_list(perspectives)
      assert :security in perspectives
      assert :stability in perspectives
      assert length(perspectives) == 7
    end

    test "returns perspectives for test changes" do
      config = Config.new()
      perspectives = Config.perspectives_for(config, :test_change)
      assert :test_runner in perspectives
    end

    test "returns default perspectives for unknown types" do
      config = Config.new()
      perspectives = Config.perspectives_for(config, :unknown_type)
      assert is_list(perspectives)
      assert perspectives != []
    end
  end

  describe "requires_supermajority?/2" do
    test "governance changes require supermajority" do
      config = Config.new()
      assert Config.requires_supermajority?(config, :governance_change) == true
    end

    test "code modifications do not require supermajority" do
      config = Config.new()
      assert Config.requires_supermajority?(config, :code_modification) == false
    end

    test "documentation changes do not require supermajority" do
      config = Config.new()
      assert Config.requires_supermajority?(config, :documentation_change) == false
    end
  end
end
