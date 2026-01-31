defmodule Arbor.AI.BackendTrustTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.BackendTrust

  @tag :fast
  describe "level/1" do
    test "returns :highest for lmstudio" do
      assert BackendTrust.level(:lmstudio) == :highest
    end

    test "returns :highest for ollama" do
      assert BackendTrust.level(:ollama) == :highest
    end

    test "returns :high for anthropic" do
      assert BackendTrust.level(:anthropic) == :high
    end

    test "returns :high for opencode" do
      assert BackendTrust.level(:opencode) == :high
    end

    test "returns :medium for openai" do
      assert BackendTrust.level(:openai) == :medium
    end

    test "returns :medium for gemini" do
      assert BackendTrust.level(:gemini) == :medium
    end

    test "returns :low for qwen" do
      assert BackendTrust.level(:qwen) == :low
    end

    test "returns :low for openrouter" do
      assert BackendTrust.level(:openrouter) == :low
    end

    test "returns :low for unknown backends (conservative default)" do
      assert BackendTrust.level(:unknown_backend) == :low
    end
  end

  @tag :fast
  describe "meets_minimum?/2" do
    test ":any matches all backends" do
      assert BackendTrust.meets_minimum?(:qwen, :any) == true
      assert BackendTrust.meets_minimum?(:lmstudio, :any) == true
    end

    test "highest backend meets :highest minimum" do
      assert BackendTrust.meets_minimum?(:lmstudio, :highest) == true
    end

    test "highest backend meets :high minimum" do
      assert BackendTrust.meets_minimum?(:lmstudio, :high) == true
    end

    test "high backend does not meet :highest minimum" do
      assert BackendTrust.meets_minimum?(:anthropic, :highest) == false
    end

    test "high backend meets :high minimum" do
      assert BackendTrust.meets_minimum?(:anthropic, :high) == true
    end

    test "medium backend does not meet :high minimum" do
      assert BackendTrust.meets_minimum?(:openai, :high) == false
    end

    test "medium backend meets :medium minimum" do
      assert BackendTrust.meets_minimum?(:openai, :medium) == true
    end

    test "low backend meets :low minimum" do
      assert BackendTrust.meets_minimum?(:qwen, :low) == true
    end

    test "low backend does not meet :medium minimum" do
      assert BackendTrust.meets_minimum?(:qwen, :medium) == false
    end
  end

  @tag :fast
  describe "sort_by_trust/1" do
    test "sorts backends by trust level (highest first)" do
      backends = [{:openai, "gpt-4"}, {:anthropic, "claude"}, {:lmstudio, "local"}]
      sorted = BackendTrust.sort_by_trust(backends)
      assert sorted == [{:lmstudio, "local"}, {:anthropic, "claude"}, {:openai, "gpt-4"}]
    end

    test "preserves order within same trust level" do
      backends = [{:openai, "gpt-4"}, {:gemini, "pro"}]
      sorted = BackendTrust.sort_by_trust(backends)
      # Both are :medium, should preserve original order
      assert sorted == [{:openai, "gpt-4"}, {:gemini, "pro"}]
    end

    test "handles empty list" do
      assert BackendTrust.sort_by_trust([]) == []
    end

    test "handles single item" do
      assert BackendTrust.sort_by_trust([{:anthropic, "claude"}]) == [{:anthropic, "claude"}]
    end
  end

  @tag :fast
  describe "compare/2" do
    test "highest is greater than high" do
      assert BackendTrust.compare(:highest, :high) == :gt
    end

    test "high is greater than medium" do
      assert BackendTrust.compare(:high, :medium) == :gt
    end

    test "medium is greater than low" do
      assert BackendTrust.compare(:medium, :low) == :gt
    end

    test "same levels are equal" do
      assert BackendTrust.compare(:high, :high) == :eq
      assert BackendTrust.compare(:medium, :medium) == :eq
    end

    test "low is less than medium" do
      assert BackendTrust.compare(:low, :medium) == :lt
    end

    test "medium is less than high" do
      assert BackendTrust.compare(:medium, :high) == :lt
    end
  end

  @tag :fast
  describe "trust_levels/0" do
    test "returns map of all default trust levels" do
      levels = BackendTrust.trust_levels()
      assert is_map(levels)
      assert levels[:lmstudio] == :highest
      assert levels[:anthropic] == :high
      assert levels[:openai] == :medium
      assert levels[:qwen] == :low
    end
  end

  @tag :fast
  describe "trust_order/0" do
    test "returns trust levels in descending order" do
      assert BackendTrust.trust_order() == [:highest, :high, :medium, :low]
    end
  end
end
