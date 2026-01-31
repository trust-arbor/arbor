defmodule Arbor.AI.TaskMetaTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.TaskMeta

  @tag :fast
  describe "classify/1" do
    test "security keywords result in critical risk and security domain" do
      meta = TaskMeta.classify("Fix the security vulnerability in authentication")
      assert meta.risk_level == :critical
      assert meta.domain == :security
      assert meta.min_trust_level == :high
    end

    test "trivial keywords result in trivial complexity" do
      meta = TaskMeta.classify("fix typo in readme")
      assert meta.complexity == :trivial
      assert meta.risk_level == :trivial
    end

    test "refactoring results in complex complexity and repo-wide scope" do
      meta = TaskMeta.classify("refactor the auth system architecture")
      assert meta.complexity == :complex
      assert meta.scope == :repo_wide
      assert meta.risk_level == :high
    end

    test "database keywords result in database domain" do
      meta = TaskMeta.classify("add migration for users table")
      assert meta.domain == :database
    end

    test "test keywords result in tests domain" do
      meta = TaskMeta.classify("write unit tests for the parser")
      assert meta.domain == :tests
    end

    test "explain keyword triggers requires_reasoning" do
      meta = TaskMeta.classify("explain why this function fails")
      assert meta.requires_reasoning == true
    end

    test "run keyword triggers requires_tools" do
      meta = TaskMeta.classify("run the test suite and fix failures")
      assert meta.requires_tools == true
    end

    test "handles empty string gracefully" do
      meta = TaskMeta.classify("")
      assert meta.risk_level == :medium
      assert meta.complexity == :moderate
    end

    test "handles very long string" do
      long_prompt = String.duplicate("test ", 10_000)
      meta = TaskMeta.classify(long_prompt)
      assert meta.domain == :tests
    end

    test "case insensitive matching" do
      meta = TaskMeta.classify("SECURITY VULNERABILITY")
      assert meta.domain == :security
      assert meta.risk_level == :critical
    end
  end

  @tag :fast
  describe "classify/2 with overrides" do
    test "overrides risk_level" do
      meta = TaskMeta.classify("hello world", risk_level: :critical)
      assert meta.risk_level == :critical
    end

    test "overrides speed_preference" do
      meta = TaskMeta.classify("hello", speed_preference: :fast)
      assert meta.speed_preference == :fast
    end

    test "overrides min_trust_level" do
      meta = TaskMeta.classify("hello", min_trust_level: :highest)
      assert meta.min_trust_level == :highest
    end

    test "heuristic detection still runs, then override applies" do
      meta = TaskMeta.classify("fix security bug", risk_level: :low)
      # Security domain detected by heuristics
      assert meta.domain == :security
      # But risk level overridden
      assert meta.risk_level == :low
    end

    test "ignores unknown options" do
      meta = TaskMeta.classify("hello", unknown_option: :value)
      assert meta.risk_level == :medium
    end
  end

  @tag :fast
  describe "tier/1" do
    test "critical risk maps to critical tier" do
      meta = %TaskMeta{risk_level: :critical}
      assert TaskMeta.tier(meta) == :critical
    end

    test "security domain maps to critical tier" do
      meta = %TaskMeta{risk_level: :medium, domain: :security}
      assert TaskMeta.tier(meta) == :critical
    end

    test "complex complexity maps to complex tier" do
      meta = %TaskMeta{complexity: :complex}
      assert TaskMeta.tier(meta) == :complex
    end

    test "repo_wide scope maps to complex tier" do
      meta = %TaskMeta{scope: :repo_wide}
      assert TaskMeta.tier(meta) == :complex
    end

    test "high risk maps to complex tier" do
      meta = %TaskMeta{risk_level: :high}
      assert TaskMeta.tier(meta) == :complex
    end

    test "moderate complexity maps to moderate tier" do
      meta = %TaskMeta{complexity: :moderate}
      assert TaskMeta.tier(meta) == :moderate
    end

    test "multi_file scope maps to moderate tier" do
      meta = %TaskMeta{scope: :multi_file, complexity: :simple}
      assert TaskMeta.tier(meta) == :moderate
    end

    test "simple complexity with low risk maps to simple tier" do
      meta = %TaskMeta{complexity: :simple, risk_level: :low}
      assert TaskMeta.tier(meta) == :simple
    end

    test "trivial complexity and single_file scope maps to trivial tier" do
      meta = %TaskMeta{complexity: :trivial, scope: :single_file, risk_level: :trivial}
      assert TaskMeta.tier(meta) == :trivial
    end

    test "default struct maps to moderate tier" do
      meta = %TaskMeta{}
      assert TaskMeta.tier(meta) == :moderate
    end
  end

  @tag :fast
  describe "struct defaults" do
    test "has expected default values" do
      meta = %TaskMeta{}
      assert meta.risk_level == :medium
      assert meta.complexity == :moderate
      assert meta.scope == :single_file
      assert meta.domain == nil
      assert meta.requires_reasoning == false
      assert meta.requires_tools == false
      assert meta.speed_preference == :balanced
      assert meta.min_trust_level == :any
    end
  end
end
