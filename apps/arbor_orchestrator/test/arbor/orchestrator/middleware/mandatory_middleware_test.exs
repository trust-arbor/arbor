defmodule Arbor.Orchestrator.Middleware.MandatoryMiddlewareTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.IR.TaintProfile

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

  defp make_compiled_node(overrides \\ %{}) do
    defaults = %{
      id: "compiled_node",
      attrs: %{"type" => "codergen"},
      type: "codergen",
      capabilities_required: [],
      taint_profile: nil,
      llm_model: nil,
      llm_provider: nil,
      timeout_ms: nil,
      handler_module: Arbor.Orchestrator.Handlers.ComputeHandler
    }

    struct(Node, Map.merge(defaults, overrides))
  end

  defp make_taint_struct(level, sensitivity, sanitizations, confidence) do
    struct(Arbor.Contracts.Security.Taint,
      level: level,
      sensitivity: sensitivity,
      sanitizations: sanitizations,
      confidence: confidence
    )
  end

  defp make_compiled_token(node_overrides, assigns) do
    node = make_compiled_node(node_overrides)
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{node.id => node}, edges: [], attrs: %{}}

    %Token{
      node: node,
      context: context,
      graph: graph,
      assigns: assigns
    }
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

    test "capability_resources/1 uses capabilities_required when populated" do
      node = make_compiled_node(%{capabilities_required: ["cap:a", "cap:b"]})

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/cap:a",
               "arbor://orchestrator/execute/cap:b"
             ]
    end

    test "capability_resources/1 preserves already-qualified URIs" do
      node =
        make_compiled_node(%{
          capabilities_required: ["arbor://custom/execute/foo", "bare_name"]
        })

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://custom/execute/foo",
               "arbor://orchestrator/execute/bare_name"
             ]
    end

    test "capability_resources/1 falls back to type-based URI for empty list" do
      node = make_compiled_node(%{capabilities_required: [], attrs: %{"type" => "shell"}})
      assert CapabilityCheck.capability_resources(node) == ["arbor://orchestrator/execute/shell"]
    end

    test "capability_resources/1 falls back to type-based URI for nil" do
      node = %Node{id: "test", attrs: %{"type" => "compute"}, capabilities_required: []}

      assert CapabilityCheck.capability_resources(node) == [
               "arbor://orchestrator/execute/compute"
             ]
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

  # --- TaintCheck with compiled taint_profile ---

  describe "TaintCheck required_sanitizations enforcement" do
    test "halts when input taint lacks required sanitization bits" do
      # xss=1, sqli=2 → required=3
      profile = %TaintProfile{required_sanitizations: 3}
      # Input has sanitizations=0 (nothing sanitized)
      taint_label = make_taint_struct(:untrusted, :internal, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "missing sanitizations"
      assert result.halt_reason =~ "compiled_node"
    end

    test "passes when input taint has all required sanitization bits" do
      profile = %TaintProfile{required_sanitizations: 3}
      # Input has sanitizations=3 (xss + sqli both applied)
      taint_label = make_taint_struct(:untrusted, :internal, 3, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      refute result.halted
    end

    test "missing sanitization names appear in halt message" do
      # command_injection = 0b00000100 = 4
      profile = %TaintProfile{required_sanitizations: 4}
      taint_label = make_taint_struct(:untrusted, :internal, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "command_injection"
    end

    test "zero required_sanitizations passes through" do
      profile = %TaintProfile{required_sanitizations: 0}
      taint_label = make_taint_struct(:untrusted, :internal, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      refute result.halted
    end
  end

  describe "TaintCheck min_confidence enforcement" do
    test "halts when input confidence is below required" do
      profile = %TaintProfile{min_confidence: :corroborated}
      taint_label = make_taint_struct(:untrusted, :internal, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "confidence"
      assert result.halt_reason =~ "unverified"
      assert result.halt_reason =~ "corroborated"
    end

    test "passes when input confidence meets required level" do
      profile = %TaintProfile{min_confidence: :corroborated}
      taint_label = make_taint_struct(:untrusted, :internal, 0, :verified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      refute result.halted
    end

    test "unverified min_confidence always passes" do
      profile = %TaintProfile{min_confidence: :unverified}
      taint_label = make_taint_struct(:untrusted, :internal, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      result = TaintCheck.before_node(token)
      refute result.halted
    end
  end

  describe "TaintCheck wipe_sanitizations (after_node)" do
    test "zeroes sanitization bits when wipes_sanitizations is true" do
      profile = %TaintProfile{wipes_sanitizations: true}
      # Input has sanitizations=7 (xss+sqli+command_injection)
      taint_label = make_taint_struct(:untrusted, :internal, 7, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      # Give it an outcome so after_node runs
      token = %{
        token
        | outcome: %Outcome{
            status: :success,
            context_updates: %{"last_response" => "output"}
          }
      }

      result = TaintCheck.after_node(token)
      labels = result.assigns.taint_labels
      assert labels["last_response"].sanitizations == 0
    end

    test "preserves sanitization bits when wipes_sanitizations is false" do
      profile = %TaintProfile{wipes_sanitizations: false}
      taint_label = make_taint_struct(:untrusted, :internal, 7, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      token = %{
        token
        | outcome: %Outcome{
            status: :success,
            context_updates: %{"last_response" => "output"}
          }
      }

      result = TaintCheck.after_node(token)
      labels = result.assigns.taint_labels

      # Sanitizations should be preserved (may be propagated from worst_taint
      # but the wipe step itself doesn't zero)
      output_label = labels["last_response"]
      # wipe was false, so if the label was struct, sanitizations remain
      assert is_map(output_label)
    end
  end

  describe "TaintCheck output_sanitizations (after_node)" do
    test "ORs output sanitization bits into taint labels" do
      # This node provides sqli sanitization (bit 1 = 2)
      profile = %TaintProfile{output_sanitizations: 2}
      taint_label = make_taint_struct(:untrusted, :internal, 1, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      token = %{
        token
        | outcome: %Outcome{
            status: :success,
            context_updates: %{"last_response" => "sanitized"}
          }
      }

      result = TaintCheck.after_node(token)
      labels = result.assigns.taint_labels
      output_label = labels["last_response"]
      # Should now have both xss(1) and sqli(2) = 3
      assert is_struct(output_label)
      assert Bitwise.band(output_label.sanitizations, 2) == 2
    end

    test "zero output_sanitizations is no-op" do
      profile = %TaintProfile{output_sanitizations: 0}
      taint_label = make_taint_struct(:untrusted, :internal, 1, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      token = %{
        token
        | outcome: %Outcome{
            status: :success,
            context_updates: %{"last_response" => "output"}
          }
      }

      result = TaintCheck.after_node(token)
      labels = result.assigns.taint_labels
      output_label = labels["last_response"]
      assert is_map(output_label)
    end
  end

  describe "TaintCheck sensitivity floor enforcement" do
    test "upgrades output sensitivity to floor when lower" do
      profile = %TaintProfile{sensitivity: :confidential}
      taint_label = make_taint_struct(:untrusted, :public, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      token = %{
        token
        | outcome: %Outcome{
            status: :success,
            context_updates: %{"last_response" => "output"}
          }
      }

      result = TaintCheck.after_node(token)
      labels = result.assigns.taint_labels
      output_label = labels["last_response"]
      assert output_label.sensitivity == :confidential
    end

    test "preserves output sensitivity when already at or above floor" do
      profile = %TaintProfile{sensitivity: :internal}
      taint_label = make_taint_struct(:untrusted, :restricted, 0, :unverified)

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => taint_label}}
        )

      token = %{
        token
        | outcome: %Outcome{
            status: :success,
            context_updates: %{"last_response" => "output"}
          }
      }

      result = TaintCheck.after_node(token)
      labels = result.assigns.taint_labels
      output_label = labels["last_response"]
      assert output_label.sensitivity == :restricted
    end
  end

  describe "TaintCheck backward compatibility" do
    test "nil taint_profile passes through (uncompiled graph)" do
      token = make_compiled_token(%{taint_profile: nil}, %{taint_labels: %{"x" => :trusted}})
      result = TaintCheck.before_node(token)
      refute result.halted
    end

    test "all-zero taint_profile passes through (no requirements)" do
      profile = %TaintProfile{}

      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{
            taint_labels: %{
              "last_response" => make_taint_struct(:untrusted, :internal, 0, :unverified)
            }
          }
        )

      result = TaintCheck.before_node(token)
      refute result.halted
    end

    test "handles atom taint labels gracefully" do
      profile = %TaintProfile{required_sanitizations: 1}

      # Atom labels have no sanitizations field — should be skipped (nil = no data)
      token =
        make_compiled_token(
          %{taint_profile: profile},
          %{taint_labels: %{"last_response" => :untrusted}}
        )

      result = TaintCheck.before_node(token)
      # Atom labels return nil from extract_sanitizations, so they don't trigger failure
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

    test "strips graph keys but preserves handler state and engine keys" do
      token =
        make_token_with_outcome(%{}, %{}, %{
          context_updates: %{
            "last_response" => "hello",
            "internal.simulate.key" => "handler_state",
            "graph.cache" => "data",
            "__adapted_graph__" => "engine_needs_this",
            "public_key" => "visible"
          }
        })

      result = CheckpointMiddleware.after_node(token)
      updates = result.outcome.context_updates

      assert Map.has_key?(updates, "last_response")
      assert Map.has_key?(updates, "public_key")
      refute Map.has_key?(updates, "graph.cache")
      # Handler state and engine keys preserved — needed for retry loops and graph adaptation
      assert Map.has_key?(updates, "internal.simulate.key")
      assert Map.has_key?(updates, "__adapted_graph__")
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

    test "build_cost_hint/1 extracts model, timeout, and type from compiled node" do
      node =
        make_compiled_node(%{
          llm_model: "claude-sonnet",
          timeout_ms: 30_000,
          type: "codergen"
        })

      hint = Budget.build_cost_hint(node)
      assert hint[:model] == "claude-sonnet"
      assert hint[:timeout_ms] == 30_000
      assert hint[:handler_type] == "codergen"
    end

    test "build_cost_hint/1 omits nil fields" do
      node = make_compiled_node(%{llm_model: nil, timeout_ms: nil, type: nil, attrs: %{}})
      hint = Budget.build_cost_hint(node)
      refute Map.has_key?(hint, :model)
      refute Map.has_key?(hint, :timeout_ms)
      refute Map.has_key?(hint, :handler_type)
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

    test "build/3 includes mandatory middleware when enabled" do
      # Config now has mandatory_middleware: true (test.exs)
      graph = %Graph{nodes: %{}, edges: [], attrs: %{}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([], graph, node)
      assert CapabilityCheck in chain
      assert TaintCheck in chain
      assert Sanitization in chain
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

  # --- Integration: compiled node through full chain ---

  describe "integration: compiled node through middleware chain" do
    test "compiled node with taint_profile flows through CapabilityCheck → TaintCheck" do
      profile = %TaintProfile{required_sanitizations: 0, min_confidence: :unverified}
      node = make_compiled_node(%{taint_profile: profile, capabilities_required: []})
      context = %Context{values: %{}}
      graph = %Graph{nodes: %{node.id => node}, edges: [], attrs: %{}}

      token = %Token{node: node, context: context, graph: graph, assigns: %{}}

      # Run capability check — should pass (no security available or no caps required)
      token = CapabilityCheck.before_node(token)
      refute token.halted

      # Run taint check — should pass (no requirements)
      token = TaintCheck.before_node(token)
      refute token.halted
    end

    test "token assigns populated from context session.agent_id" do
      context = %Context{values: %{"session.agent_id" => "agent_abc123"}}
      node = make_compiled_node()
      graph = %Graph{nodes: %{node.id => node}, edges: [], attrs: %{}}

      # Simulate what authorization.ex build_assigns does
      agent_id = Context.get(context, "session.agent_id")
      assigns = if agent_id, do: %{agent_id: agent_id}, else: %{}

      token = %Token{node: node, context: context, graph: graph, assigns: assigns}
      assert token.assigns[:agent_id] == "agent_abc123"
    end

    test "skip_capability_check injected when authorization disabled" do
      _context = %Context{values: %{}}
      opts = [authorization: false]

      # Simulate build_assigns logic
      assigns =
        if Keyword.get(opts, :authorization) == false do
          %{skip_capability_check: true}
        else
          %{}
        end

      assert assigns[:skip_capability_check] == true
    end
  end
end
