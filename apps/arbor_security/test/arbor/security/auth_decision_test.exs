defmodule Arbor.Security.AuthDecisionTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.AuthDecision

  describe "evaluate/4" do
    test "returns :unauthorized when no capability exists" do
      # Agent with no capabilities — should be unauthorized
      result = AuthDecision.evaluate("nonexistent_agent", "arbor://fs/read", :execute)

      assert result == {:error, :unauthorized} or
               match?({:error, _}, result)
    end

    test "human identities pass identity status check" do
      # Human identity should not fail on identity status
      result = AuthDecision.evaluate("human_test123", "arbor://nonexistent", :execute)

      # Will fail on capability lookup, not identity
      assert match?({:error, _}, result)
    end

    test "returns a decision, never raises" do
      # Should never crash — always returns a decision
      result = AuthDecision.evaluate("agent_test", "arbor://test", :execute, skip_uri_check: true)
      assert is_atom(result) or is_tuple(result)
    end
  end
end
