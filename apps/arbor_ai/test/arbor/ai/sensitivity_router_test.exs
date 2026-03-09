defmodule Arbor.AI.SensitivityRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.SensitivityRouter
  alias Arbor.AI.SensitivityRouter.RoutingDecision

  @moduletag :fast

  @test_candidates [
    %{provider: :ollama, model: "llama3.2", priority: 1},
    %{provider: :anthropic, model: "claude-sonnet-4-5-20250514", priority: 2},
    %{provider: :openrouter, model: "anthropic/claude-sonnet-4-5-20250514", priority: 3}
  ]

  describe "select/2" do
    test "selects lowest-priority candidate that can handle sensitivity" do
      # :restricted — only ollama (local) can handle it
      assert {:ok, {:ollama, "llama3.2"}} =
               SensitivityRouter.select(:restricted, candidates: @test_candidates)
    end

    test "selects best candidate for confidential data" do
      # :confidential — ollama (priority 1) and anthropic (priority 2) can handle it
      assert {:ok, {:ollama, "llama3.2"}} =
               SensitivityRouter.select(:confidential, candidates: @test_candidates)
    end

    test "selects best candidate for public data" do
      # :public — all can handle it, ollama has lowest priority number
      assert {:ok, {:ollama, "llama3.2"}} =
               SensitivityRouter.select(:public, candidates: @test_candidates)
    end

    test "returns error when no candidates can handle sensitivity" do
      # Only openrouter candidates — default can only see :public
      candidates = [
        %{provider: :openrouter, model: "random/model", priority: 1}
      ]

      assert {:error, :no_candidates} =
               SensitivityRouter.select(:restricted, candidates: candidates)
    end

    test "prefers current provider if it qualifies" do
      # Both ollama and anthropic can handle :confidential,
      # but we prefer anthropic because it's the current provider
      assert {:ok, {:anthropic, "claude-sonnet-4-5-20250514"}} =
               SensitivityRouter.select(:confidential,
                 candidates: @test_candidates,
                 current_provider: :anthropic,
                 current_model: "claude-sonnet-4-5-20250514"
               )
    end

    test "falls back to best candidate when current provider can't handle sensitivity" do
      # openrouter can't handle :restricted, should fall back to ollama
      assert {:ok, {:ollama, "llama3.2"}} =
               SensitivityRouter.select(:restricted,
                 candidates: @test_candidates,
                 current_provider: :openrouter,
                 current_model: "random/model"
               )
    end

    test "handles empty candidate list" do
      assert {:error, :no_candidates} = SensitivityRouter.select(:public, candidates: [])
    end
  end

  describe "validate/3" do
    test "returns :ok when provider can handle sensitivity" do
      assert :ok = SensitivityRouter.validate(:ollama, "llama3.2", :restricted)
    end

    test "returns :ok for public data with any provider" do
      assert :ok = SensitivityRouter.validate(:openrouter, "random/model", :public)
    end

    test "returns error when provider can't handle sensitivity" do
      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:openrouter, "random/model", :restricted)
    end
  end

  describe "maybe_reroute/4" do
    test "no-op for nil sensitivity" do
      assert {:ollama, "llama3.2"} =
               SensitivityRouter.maybe_reroute(:ollama, "llama3.2", nil, [])
    end

    test "no-op for public data" do
      assert {:openrouter, "random/model"} =
               SensitivityRouter.maybe_reroute(:openrouter, "random/model", :public, [])
    end

    test "no-op when current provider can handle sensitivity" do
      assert {:ollama, "llama3.2"} =
               SensitivityRouter.maybe_reroute(:ollama, "llama3.2", :restricted,
                 candidates: @test_candidates
               )
    end

    test "reroutes when current provider can't handle sensitivity" do
      {provider, _model} =
        SensitivityRouter.maybe_reroute(:openrouter, "random/model", :restricted,
          candidates: @test_candidates
        )

      # Should reroute to ollama (only candidate that can handle :restricted)
      assert provider == :ollama
    end

    test "keeps original when no candidates available for rerouting" do
      assert {:openrouter, "random/model"} =
               SensitivityRouter.maybe_reroute(:openrouter, "random/model", :restricted,
                 candidates: []
               )
    end

    test "reroutes confidential data away from public-only provider" do
      {provider, _model} =
        SensitivityRouter.maybe_reroute(:openrouter, "random/model", :confidential,
          candidates: @test_candidates
        )

      # Should reroute to ollama (priority 1) or anthropic (priority 2) — both handle :confidential
      assert provider in [:ollama, :anthropic]
    end

    test "keeps original when mode is :block (backward compat)" do
      # :block in legacy API falls back to keeping original
      assert {:openrouter, "random/model"} =
               SensitivityRouter.maybe_reroute(:openrouter, "random/model", :restricted,
                 candidates: @test_candidates,
                 mode: :block
               )
    end
  end

  describe "decide/4" do
    test "returns :proceed for nil sensitivity" do
      decision = SensitivityRouter.decide(:ollama, "llama3.2", nil, [])
      assert %RoutingDecision{action: :proceed, original: {:ollama, "llama3.2"}} = decision
    end

    test "returns :proceed for public sensitivity" do
      decision = SensitivityRouter.decide(:openrouter, "model", :public, [])

      assert %RoutingDecision{
               action: :proceed,
               original: {:openrouter, "model"},
               sensitivity: :public
             } = decision
    end

    test "returns :proceed when provider can handle sensitivity" do
      decision =
        SensitivityRouter.decide(:ollama, "llama3.2", :restricted, candidates: @test_candidates)

      assert %RoutingDecision{action: :proceed, sensitivity: :restricted} = decision
    end

    test "returns :rerouted with mode when provider can't handle sensitivity" do
      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: @test_candidates,
          mode: :warn
        )

      assert %RoutingDecision{
               action: :rerouted,
               original: {:openrouter, "random/model"},
               alternative: {:ollama, "llama3.2"},
               sensitivity: :restricted,
               mode: :warn
             } = decision

      assert decision.reason =~ "rerouted to ollama"
    end

    test "returns :rerouted with :auto mode (no signal emitted)" do
      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: @test_candidates,
          mode: :auto
        )

      assert %RoutingDecision{action: :rerouted, mode: :auto} = decision
    end

    test "returns :rerouted with :gated mode" do
      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: @test_candidates,
          mode: :gated
        )

      assert %RoutingDecision{action: :rerouted, mode: :gated} = decision
    end

    test "returns :blocked when mode is :block" do
      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: @test_candidates,
          mode: :block
        )

      assert %RoutingDecision{
               action: :blocked,
               original: {:openrouter, "random/model"},
               sensitivity: :restricted,
               mode: :block
             } = decision

      assert decision.reason =~ "blocked by policy"
      assert decision.alternative == nil
    end

    test "returns :proceed with reason when no candidates for rerouting" do
      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: [],
          mode: :warn
        )

      assert %RoutingDecision{action: :proceed, reason: "No alternative candidates available"} =
               decision
    end

    test "selects best alternative when rerouting" do
      # Add multiple candidates that can handle restricted
      candidates = [
        %{provider: :ollama, model: "llama3.2", priority: 1},
        %{provider: :lmstudio, model: "default", priority: 2}
      ]

      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: candidates,
          mode: :auto
        )

      assert %RoutingDecision{alternative: {:ollama, "llama3.2"}} = decision
    end
  end

  describe "resolve_mode/1" do
    test "returns :warn for nil agent_id" do
      assert :warn = SensitivityRouter.resolve_mode(nil)
    end

    test "returns :warn for non-binary agent_id" do
      assert :warn = SensitivityRouter.resolve_mode(123)
    end

    test "returns :gated for unknown agent (fail closed via trust profile)" do
      # Trust system available → effective_mode returns :ask for unknown agent → :gated
      assert :gated = SensitivityRouter.resolve_mode("unknown_agent")
    end

    test "respects per-agent overrides" do
      original = Application.get_env(:arbor_ai, :sensitivity_routing_overrides, %{})

      try do
        Application.put_env(:arbor_ai, :sensitivity_routing_overrides, %{
          "blocked_agent" => :block,
          "auto_agent" => :auto
        })

        assert :block = SensitivityRouter.resolve_mode("blocked_agent")
        assert :auto = SensitivityRouter.resolve_mode("auto_agent")
        # Non-overridden agent falls through to trust profile lookup (→ :gated for unknown)
        assert :gated = SensitivityRouter.resolve_mode("normal_agent")
      after
        Application.put_env(:arbor_ai, :sensitivity_routing_overrides, original)
      end
    end

    test "ignores invalid override values" do
      original = Application.get_env(:arbor_ai, :sensitivity_routing_overrides, %{})

      try do
        Application.put_env(:arbor_ai, :sensitivity_routing_overrides, %{
          "bad_agent" => :invalid_mode
        })

        # Invalid mode falls through to trust profile lookup (→ :gated for unknown)
        assert :gated = SensitivityRouter.resolve_mode("bad_agent")
      after
        Application.put_env(:arbor_ai, :sensitivity_routing_overrides, original)
      end
    end
  end

  describe "decide/4 with per-agent mode override" do
    test "uses per-agent override when configured" do
      original = Application.get_env(:arbor_ai, :sensitivity_routing_overrides, %{})

      try do
        Application.put_env(:arbor_ai, :sensitivity_routing_overrides, %{
          "secure_agent" => :block
        })

        decision =
          SensitivityRouter.decide(:openrouter, "random/model", :restricted,
            candidates: @test_candidates,
            agent_id: "secure_agent"
          )

        assert %RoutingDecision{action: :blocked, mode: :block} = decision
      after
        Application.put_env(:arbor_ai, :sensitivity_routing_overrides, original)
      end
    end

    test "explicit :mode opt overrides agent_id resolution" do
      decision =
        SensitivityRouter.decide(:openrouter, "random/model", :restricted,
          candidates: @test_candidates,
          agent_id: "some_agent",
          mode: :auto
        )

      assert %RoutingDecision{action: :rerouted, mode: :auto} = decision
    end
  end

  describe "RoutingDecision struct" do
    test "has expected default fields" do
      decision = %RoutingDecision{}
      assert decision.action == nil
      assert decision.original == nil
      assert decision.alternative == nil
      assert decision.sensitivity == nil
      assert decision.mode == nil
      assert decision.reason == nil
    end
  end
end
