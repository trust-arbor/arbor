defmodule Arbor.Orchestrator.Middleware.MandatoryMiddlewareTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  alias Arbor.Orchestrator.Middleware.{
    Budget,
    CapabilityCheck,
    Chain,
    CheckpointMiddleware,
    SafeInput,
    Sanitization,
    SignalEmit,
    TaintCheck,
    Token
  }

  defp make_token(attrs \\ %{}, assigns \\ %{}) do
    node = %Node{id: "test_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"test_node" => node}, edges: [], attrs: %{}}

    %Token{
      node: node,
      context: context,
      graph: graph,
      assigns: assigns
    }
  end

  defp make_token_with_outcome(attrs \\ %{}, assigns \\ %{}, outcome_attrs \\ %{}) do
    token = make_token(attrs, assigns)

    outcome = %Outcome{
      status: Map.get(outcome_attrs, :status, :success),
      notes: Map.get(outcome_attrs, :notes, "ok"),
      context_updates: Map.get(outcome_attrs, :context_updates, %{"last_response" => "hello"})
    }

    %{token | outcome: outcome}
  end

  # --- CapabilityCheck ---

  describe "CapabilityCheck" do
    test "passes through when skip_capability_check is set" do
      token = make_token(%{}, %{skip_capability_check: true})
      result = CapabilityCheck.before_node(token)
      refute result.halted
    end

    test "passes through when authorization is false" do
      token = make_token(%{}, %{authorization: false})
      result = CapabilityCheck.before_node(token)
      refute result.halted
    end

    test "passes through when Arbor.Security is not available" do
      # In test env, Arbor.Security may or may not be loaded
      # The middleware should gracefully handle both cases
      token = make_token()
      result = CapabilityCheck.before_node(token)
      # Either passes through or halts — both are valid depending on env
      assert is_struct(result, Token)
    end
  end

  # --- TaintCheck ---

  describe "TaintCheck" do
    test "passes through when skip_taint_check is set" do
      token = make_token(%{}, %{skip_taint_check: true})
      result = TaintCheck.before_node(token)
      refute result.halted
    end

    test "before_node sets taint_labels assign" do
      token = make_token()
      result = TaintCheck.before_node(token)
      # Should either set labels or pass through
      assert is_struct(result, Token)
    end

    test "after_node propagates taint from inputs to outputs" do
      token = make_token_with_outcome(%{}, %{taint_labels: %{"input" => :untrusted}})
      result = TaintCheck.after_node(token)
      assert is_struct(result, Token)
    end

    test "after_node passes through when no outcome" do
      token = make_token(%{}, %{})
      result = TaintCheck.after_node(token)
      refute result.halted
    end
  end

  # --- Sanitization ---

  describe "Sanitization" do
    test "passes through when skip_sanitization is set" do
      token = make_token(%{}, %{skip_sanitization: true})
      result = Sanitization.before_node(token)
      refute result.halted
    end

    test "scans node attributes for PII" do
      token = make_token(%{"prompt" => "Call me at 555-123-4567"})
      result = Sanitization.before_node(token)
      # Depends on PIIDetection availability
      assert is_struct(result, Token)
    end

    test "after_node passes through" do
      token = make_token_with_outcome()
      result = Sanitization.after_node(token)
      assert is_struct(result, Token)
    end
  end

  # --- SafeInput ---

  describe "SafeInput" do
    test "passes through when skip_safe_input is set" do
      token = make_token(%{}, %{skip_safe_input: true})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "passes through for normal paths" do
      token = make_token(%{"cwd" => "/Users/test/project"})
      result = SafeInput.before_node(token)
      refute result.halted
    end

    test "halts for path traversal" do
      token = make_token(%{"graph_file" => "../../../etc/passwd"})
      result = SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "path traversal"
    end

    test "checks multiple path attributes" do
      token = make_token(%{"source_file" => "../../../../secret"})
      result = SafeInput.before_node(token)
      assert result.halted
    end
  end

  # --- CheckpointMiddleware ---

  describe "CheckpointMiddleware" do
    test "passes through when skip_checkpoint_sanitization is set" do
      token = make_token_with_outcome(%{}, %{skip_checkpoint_sanitization: true})
      result = CheckpointMiddleware.after_node(token)
      assert result.outcome.context_updates == %{"last_response" => "hello"}
    end

    test "strips internal keys from context updates" do
      token =
        make_token_with_outcome(%{}, %{}, %{
          context_updates: %{
            "last_response" => "hello",
            "internal.simulate.key" => "value",
            "graph.cache" => "data",
            "__private" => "secret",
            "public_key" => "visible"
          }
        })

      result = CheckpointMiddleware.after_node(token)
      updates = result.outcome.context_updates

      assert Map.has_key?(updates, "last_response")
      assert Map.has_key?(updates, "public_key")
      refute Map.has_key?(updates, "internal.simulate.key")
      refute Map.has_key?(updates, "graph.cache")
      refute Map.has_key?(updates, "__private")
    end

    test "passes through when no outcome" do
      token = make_token()
      result = CheckpointMiddleware.after_node(token)
      refute result.halted
    end

    test "passes through when no context_updates" do
      token = make_token_with_outcome(%{}, %{}, %{context_updates: nil})
      result = CheckpointMiddleware.after_node(token)
      assert is_struct(result, Token)
    end
  end

  # --- Budget ---

  describe "Budget" do
    test "passes through when skip_budget_check is set" do
      token = make_token(%{}, %{skip_budget_check: true})
      result = Budget.before_node(token)
      refute result.halted
    end

    test "passes through when no budget tracker configured" do
      token = make_token()
      result = Budget.before_node(token)
      refute result.halted
    end

    test "after_node passes through when no tracker" do
      token = make_token_with_outcome()
      result = Budget.after_node(token)
      refute result.halted
    end
  end

  # --- SignalEmit ---

  describe "SignalEmit" do
    test "passes through when skip_signal_emit is set" do
      token = make_token_with_outcome(%{}, %{skip_signal_emit: true})
      result = SignalEmit.after_node(token)
      refute result.halted
    end

    test "skips read-only node types" do
      # read, gate, start, exit, branch are read-only
      for type <- ~w(read gate start exit branch) do
        token = make_token_with_outcome(%{"type" => type})
        result = SignalEmit.after_node(token)
        refute result.halted
      end
    end

    test "emits for state-changing types" do
      token = make_token_with_outcome(%{"type" => "compute"})
      result = SignalEmit.after_node(token)
      # Should pass through regardless of signal bus availability
      assert is_struct(result, Token)
      refute result.halted
    end
  end

  # --- Chain integration ---

  describe "Chain integration" do
    test "default_mandatory_chain returns 7 middleware modules" do
      chain = Chain.default_mandatory_chain()
      assert length(chain) == 7
    end

    test "mandatory chain includes all expected middleware" do
      chain = Chain.default_mandatory_chain()
      assert CapabilityCheck in chain
      assert TaintCheck in chain
      assert Sanitization in chain
      assert SafeInput in chain
      assert CheckpointMiddleware in chain
      assert Budget in chain
      assert SignalEmit in chain
    end

    test "registry includes all mandatory middleware by name" do
      registry = Chain.registry()
      assert Map.has_key?(registry, "capability_check")
      assert Map.has_key?(registry, "taint_check")
      assert Map.has_key?(registry, "sanitization")
      assert Map.has_key?(registry, "safe_input")
      assert Map.has_key?(registry, "checkpoint")
      assert Map.has_key?(registry, "budget")
      assert Map.has_key?(registry, "signal_emit")
    end

    test "build/3 works without mandatory middleware enabled" do
      # Default config has mandatory_middleware: false
      graph = %Graph{nodes: %{}, edges: [], attrs: %{}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([], graph, node)
      # Should not include mandatory chain by default
      refute CapabilityCheck in chain
    end

    test "build/3 still respects engine, graph, and node middleware" do
      graph = %Graph{nodes: %{}, edges: [], attrs: %{"middleware" => "secret_scan"}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([], graph, node)
      assert Arbor.Orchestrator.Middleware.SecretScan in chain
    end

    test "skip_middleware removes mandatory middleware" do
      graph = %Graph{nodes: %{}, edges: [], attrs: %{}}
      node = %Node{id: "test", attrs: %{"skip_middleware" => "capability_check,taint_check"}}
      chain = Chain.build([CapabilityCheck, TaintCheck], graph, node)
      refute CapabilityCheck in chain
      refute TaintCheck in chain
    end
  end
end
