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

  describe "application-level config" do
    test "deterministic_evaluator_timeout/0 returns default" do
      assert Config.deterministic_evaluator_timeout() == 60_000
    end

    test "deterministic_evaluator_sandbox/0 returns default" do
      assert Config.deterministic_evaluator_sandbox() == :strict
    end

    test "deterministic_evaluator_default_cwd/0 returns default" do
      assert Config.deterministic_evaluator_default_cwd() == nil
    end
  end

  describe "quota config" do
    test "max_proposals_per_agent/0 returns default" do
      assert is_integer(Config.max_proposals_per_agent())
    end

    test "proposal_quota_enabled?/0 returns boolean" do
      assert is_boolean(Config.proposal_quota_enabled?())
    end
  end

  describe "LLM evaluator config" do
    test "llm_evaluator_timeout/0 returns default" do
      assert Config.llm_evaluator_timeout() == 180_000
    end

    test "llm_evaluator_ai_module/0 returns default module" do
      assert Config.llm_evaluator_ai_module() == Arbor.AI
    end

    test "llm_evaluators_enabled?/0 returns boolean" do
      assert is_boolean(Config.llm_evaluators_enabled?())
    end

    test "llm_perspectives/0 returns list of atoms" do
      perspectives = Config.llm_perspectives()
      assert is_list(perspectives)
      assert :security_llm in perspectives
      assert :architecture_llm in perspectives
      assert :code_quality_llm in perspectives
      assert :performance_llm in perspectives
    end
  end

  describe "event sourcing config" do
    test "event_log/0 returns configured or nil" do
      # Default is nil
      result = Config.event_log()
      # Could be nil or a tuple depending on test config
      assert is_nil(result) or is_tuple(result)
    end

    test "event_stream/0 returns stream name" do
      assert Config.event_stream() == "arbor:consensus"
    end

    test "recovery_strategy/0 returns atom" do
      strategy = Config.recovery_strategy()
      assert strategy in [:deadlock, :resume, :restart]
    end

    test "emit_recovery_events?/0 returns boolean" do
      assert is_boolean(Config.emit_recovery_events?())
    end
  end
end
