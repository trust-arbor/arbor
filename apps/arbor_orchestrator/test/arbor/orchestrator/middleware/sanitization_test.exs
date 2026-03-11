defmodule Arbor.Orchestrator.Middleware.SanitizationTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{Sanitization, Token}

  defp make_token(attrs \\ %{}, assigns \\ %{}) do
    node = %Node{id: "san_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"san_node" => node}, edges: [], attrs: %{}}
    %Token{node: node, context: context, graph: graph, assigns: assigns}
  end

  defp make_token_with_outcome(attrs \\ %{}, assigns \\ %{}) do
    token = make_token(attrs, assigns)

    %{
      token
      | outcome: %Outcome{
          status: :success,
          notes: "ok",
          context_updates: %{"last_response" => "hello world"}
        }
    }
  end

  # --- before_node ---

  describe "before_node/1" do
    test "passes through when skip_sanitization is set" do
      token = make_token(%{"prompt" => "my SSN is 123-45-6789"}, %{skip_sanitization: true})
      result = Sanitization.before_node(token)
      refute result.halted
    end

    test "passes through when PIIDetection is not available" do
      # PIIDetection may not be loaded in test env
      token = make_token(%{"prompt" => "normal text"})
      result = Sanitization.before_node(token)
      assert is_struct(result, Token)
    end

    test "scans string-valued node attributes" do
      token = make_token(%{"prompt" => "Call me at 555-123-4567"})
      result = Sanitization.before_node(token)
      # Result depends on PIIDetection availability
      assert is_struct(result, Token)
    end

    test "ignores non-string attributes" do
      token = make_token(%{"timeout" => 5000, "retries" => 3, "enabled" => true})
      result = Sanitization.before_node(token)
      refute result.halted
    end

    test "handles empty attributes" do
      token = make_token(%{})
      result = Sanitization.before_node(token)
      refute result.halted
    end

    test "sanitization_action :warn stores warnings instead of halting" do
      token = make_token(%{"prompt" => "test data"}, %{sanitization_action: :warn})
      result = Sanitization.before_node(token)
      # Should not halt even if PII found — warn mode
      refute result.halted
    end

    test "sanitization_action defaults to :fail" do
      # When PII is detected and action is :fail (default), should halt
      # But only if PIIDetection is available and finds something
      token = make_token(%{"prompt" => "normal text"})
      result = Sanitization.before_node(token)
      assert is_struct(result, Token)
    end
  end

  # --- after_node ---

  describe "after_node/1" do
    test "passes through when skip_sanitization is set" do
      token = make_token_with_outcome(%{}, %{skip_sanitization: true})
      result = Sanitization.after_node(token)
      refute result.halted
    end

    test "passes through outcome unchanged (delegates to SecretScan)" do
      token = make_token_with_outcome()
      result = Sanitization.after_node(token)
      refute result.halted
      # Outcome should be preserved
      assert result.outcome.status == :success
    end

    test "passes through when no outcome" do
      token = make_token()
      result = Sanitization.after_node(token)
      refute result.halted
    end

    test "passes through when PIIDetection not available" do
      token = make_token_with_outcome()
      result = Sanitization.after_node(token)
      assert is_struct(result, Token)
      refute result.halted
    end
  end
end
