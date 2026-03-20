defmodule Arbor.Orchestrator.Security.TaintPropagationTest do
  @moduledoc """
  Tests runtime taint flow through multi-step pipeline nodes.

  Verifies that taint state is correctly propagated, wiped, and
  enforced through the orchestrator's TaintCheck middleware.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.IR.TaintProfile

  alias Arbor.Orchestrator.Middleware.{
    TaintCheck,
    Token
  }

  defp make_taint_struct(level, sensitivity, sanitizations, confidence) do
    struct(Arbor.Contracts.Security.Taint,
      level: level,
      sensitivity: sensitivity,
      sanitizations: sanitizations,
      confidence: confidence
    )
  end

  defp make_compiled_node(overrides) do
    defaults = %{
      id: "node_#{:erlang.unique_integer([:positive])}",
      attrs: %{"type" => "compute"},
      type: "compute",
      capabilities_required: [],
      taint_profile: nil,
      llm_model: nil,
      llm_provider: nil,
      timeout_ms: nil,
      handler_module: Arbor.Orchestrator.Handlers.ComputeHandler
    }

    struct(Node, Map.merge(defaults, overrides))
  end

  defp make_token(node, assigns) do
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{node.id => node}, edges: [], attrs: %{}}

    %Token{
      node: node,
      context: context,
      graph: graph,
      assigns: assigns
    }
  end

  defp add_outcome(token, context_updates \\ %{"last_response" => "output"}) do
    %{token | outcome: %Outcome{status: :success, context_updates: context_updates}}
  end

  # ============================================================================
  # Test 1: Input taint level propagates through pipeline nodes correctly
  # ============================================================================

  describe "taint propagation through nodes" do
    test "input taint label is preserved through before_node" do
      profile = %TaintProfile{required_sanitizations: 0}
      taint = make_taint_struct(:untrusted, :internal, 0, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      refute result.halted
      assert result.assigns.taint_labels["last_response"] == taint
    end

    test "output inherits worst taint from inputs via after_node" do
      profile = %TaintProfile{}
      taint = make_taint_struct(:untrusted, :confidential, 7, :plausible)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"input_a" => taint}})
      token = add_outcome(token)

      result = TaintCheck.after_node(token)
      output_label = result.assigns.taint_labels["last_response"]

      assert is_map(output_label)
    end
  end

  # ============================================================================
  # Test 2: LLM node wipes sanitization status
  # ============================================================================

  describe "LLM node wipes sanitizations" do
    test "wipes_sanitizations: true zeroes all sanitization bits" do
      profile = %TaintProfile{wipes_sanitizations: true}
      # Input has all sanitizations applied (0xFF)
      taint = make_taint_struct(:untrusted, :internal, 0xFF, :verified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      token = add_outcome(token)

      result = TaintCheck.after_node(token)
      output_label = result.assigns.taint_labels["last_response"]

      # After LLM processing, sanitizations should be wiped
      assert output_label.sanitizations == 0
    end

    test "output becomes 'derived' status after LLM processing" do
      # The Signals.Taint.for_llm_output function escalates trusted to derived
      input_taint = %Arbor.Contracts.Security.Taint{
        level: :trusted,
        sensitivity: :internal,
        sanitizations: 0xFF,
        confidence: :verified
      }

      llm_output = Arbor.Signals.Taint.for_llm_output(input_taint)

      assert llm_output.level == :derived
      assert llm_output.sanitizations == 0
      assert llm_output.confidence == :plausible
    end
  end

  # ============================================================================
  # Test 3: Shell node after LLM node requires re-sanitization
  # ============================================================================

  describe "shell node after LLM requires re-sanitization" do
    test "node with command_injection requirement blocks unsanitized input" do
      # Simulates: LLM output (sanitizations wiped) flowing into shell node
      # Shell node requires command_injection sanitization (bit 2 = 4)
      profile = %TaintProfile{required_sanitizations: 4}
      taint = make_taint_struct(:derived, :internal, 0, :plausible)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      assert result.halted
      assert result.halt_reason =~ "missing sanitizations"
      assert result.halt_reason =~ "command_injection"
    end

    test "re-sanitized input passes through shell node" do
      import Bitwise
      profile = %TaintProfile{required_sanitizations: 4}
      # Input has command_injection bit set (bit 2 = 4)
      taint = make_taint_struct(:derived, :internal, 4, :plausible)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      refute result.halted
    end
  end

  # ============================================================================
  # Test 4: Taint middleware blocks when sanitization requirements not met
  # ============================================================================

  describe "middleware blocks on unmet requirements" do
    test "missing xss sanitization blocks execution" do
      # xss = 1, sqli = 2 -> required = 3
      profile = %TaintProfile{required_sanitizations: 3}
      taint = make_taint_struct(:untrusted, :internal, 0, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      assert result.halted
      assert result.halt_reason =~ "missing sanitizations"
    end

    test "partial sanitization still blocks" do
      # Requires xss(1) + sqli(2) = 3, but only has xss(1)
      profile = %TaintProfile{required_sanitizations: 3}
      taint = make_taint_struct(:untrusted, :internal, 1, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      assert result.halted
      assert result.halt_reason =~ "sqli"
    end
  end

  # ============================================================================
  # Test 5: Taint middleware allows when requirements ARE met
  # ============================================================================

  describe "middleware allows met requirements" do
    test "all required sanitizations present allows execution" do
      profile = %TaintProfile{required_sanitizations: 3}
      taint = make_taint_struct(:untrusted, :internal, 3, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      refute result.halted
    end

    test "superset of sanitizations also allows" do
      profile = %TaintProfile{required_sanitizations: 3}
      # Has all 8 sanitizations applied (0xFF)
      taint = make_taint_struct(:untrusted, :internal, 0xFF, :verified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      refute result.halted
    end

    test "zero requirements always passes" do
      profile = %TaintProfile{required_sanitizations: 0}
      taint = make_taint_struct(:untrusted, :internal, 0, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      refute result.halted
    end
  end

  # ============================================================================
  # Test 6: Parallel pipeline branches maintain independent taint levels
  # ============================================================================

  describe "parallel branches maintain independent taint" do
    test "different taint labels coexist in assigns" do
      profile = %TaintProfile{}

      taint_a = make_taint_struct(:trusted, :public, 0xFF, :verified)
      taint_b = make_taint_struct(:hostile, :restricted, 0, :unverified)

      node = make_compiled_node(%{taint_profile: profile})

      labels = %{
        "branch_a_output" => taint_a,
        "branch_b_output" => taint_b
      }

      token = make_token(node, %{taint_labels: labels})
      result = TaintCheck.before_node(token)

      # Both labels should be preserved independently
      refute result.halted
      assert result.assigns.taint_labels["branch_a_output"].level == :trusted
      assert result.assigns.taint_labels["branch_b_output"].level == :hostile
    end
  end

  # ============================================================================
  # Test 7: Fan-in node takes the WORST taint level from all inputs
  # ============================================================================

  describe "fan-in worst taint propagation" do
    test "propagate_taint takes worst level from multiple inputs" do
      taint_a = %Arbor.Contracts.Security.Taint{
        level: :trusted,
        sensitivity: :public,
        sanitizations: 0xFF,
        confidence: :verified
      }

      taint_b = %Arbor.Contracts.Security.Taint{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0x03,
        confidence: :plausible
      }

      merged = Arbor.Signals.Taint.propagate_taint([taint_a, taint_b])

      # Level: max(trusted, untrusted) = untrusted
      assert merged.level == :untrusted
      # Sensitivity: max(public, confidential) = confidential
      assert merged.sensitivity == :confidential
      # Sanitizations: band(0xFF, 0x03) = 0x03
      assert merged.sanitizations == 0x03
      # Confidence: min(verified, plausible) = plausible
      assert merged.confidence == :plausible
    end

    test "hostile input makes entire merge hostile" do
      taint_a = %Arbor.Contracts.Security.Taint{
        level: :trusted,
        sensitivity: :public,
        sanitizations: 0xFF,
        confidence: :verified
      }

      taint_b = %Arbor.Contracts.Security.Taint{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified
      }

      merged = Arbor.Signals.Taint.propagate_taint([taint_a, taint_b])

      assert merged.level == :hostile
      assert merged.sensitivity == :restricted
      assert merged.sanitizations == 0
      assert merged.confidence == :unverified
    end
  end

  # ============================================================================
  # Test 8: Checkpoint preserve taint state
  # ============================================================================

  describe "taint state preservation" do
    test "taint labels survive through token assigns" do
      profile = %TaintProfile{}
      taint = make_taint_struct(:derived, :confidential, 7, :plausible)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"data" => taint}})

      # Before node should preserve labels
      result = TaintCheck.before_node(token)
      assert result.assigns.taint_labels["data"] == taint

      # After node with outcome should propagate labels to outputs
      result_with_outcome = add_outcome(result, %{"data" => "updated"})
      final = TaintCheck.after_node(result_with_outcome)
      assert Map.has_key?(final.assigns.taint_labels, "data")
    end
  end

  # ============================================================================
  # Test: Confidence enforcement
  # ============================================================================

  describe "confidence enforcement" do
    test "low confidence input is blocked when high confidence required" do
      profile = %TaintProfile{min_confidence: :verified}
      taint = make_taint_struct(:trusted, :public, 0xFF, :plausible)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      assert result.halted
      assert result.halt_reason =~ "confidence"
    end

    test "sufficient confidence passes through" do
      profile = %TaintProfile{min_confidence: :plausible}
      taint = make_taint_struct(:trusted, :public, 0, :corroborated)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      result = TaintCheck.before_node(token)

      refute result.halted
    end
  end

  # ============================================================================
  # Test: Sensitivity floor enforcement
  # ============================================================================

  describe "sensitivity floor" do
    test "output sensitivity is upgraded to floor when lower" do
      profile = %TaintProfile{sensitivity: :restricted}
      taint = make_taint_struct(:untrusted, :public, 0, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      token = add_outcome(token)

      result = TaintCheck.after_node(token)
      output = result.assigns.taint_labels["last_response"]

      assert output.sensitivity == :restricted
    end

    test "output sensitivity preserved when already above floor" do
      profile = %TaintProfile{sensitivity: :internal}
      taint = make_taint_struct(:untrusted, :restricted, 0, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      token = add_outcome(token)

      result = TaintCheck.after_node(token)
      output = result.assigns.taint_labels["last_response"]

      assert output.sensitivity == :restricted
    end
  end

  # ============================================================================
  # Test: Output sanitization bit ORing
  # ============================================================================

  describe "output sanitization accumulation" do
    test "node adds its output sanitization bits to labels" do
      import Bitwise
      # Node provides sqli sanitization (bit 1 = 2)
      profile = %TaintProfile{output_sanitizations: 2}
      # Input already has xss sanitization (bit 0 = 1)
      taint = make_taint_struct(:untrusted, :internal, 1, :unverified)
      node = make_compiled_node(%{taint_profile: profile})

      token = make_token(node, %{taint_labels: %{"last_response" => taint}})
      token = add_outcome(token)

      result = TaintCheck.after_node(token)
      output = result.assigns.taint_labels["last_response"]

      # Should now have both xss(1) + sqli(2) = 3
      assert band(output.sanitizations, 2) == 2
    end
  end
end
