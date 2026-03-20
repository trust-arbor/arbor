defmodule Arbor.AI.Security.SensitivityRoutingTest do
  @moduledoc """
  Integration tests for sensitivity classification affecting provider selection.

  Verifies that data sensitivity levels are correctly enforced in
  LLM provider routing decisions — restricted data stays local,
  confidential data avoids untrusted providers, etc.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  alias Arbor.AI.BackendTrust
  alias Arbor.AI.SensitivityRouter
  alias Arbor.AI.SensitivityRouter.RoutingDecision

  @local_and_cloud_candidates [
    %{provider: :ollama, model: "llama3.2", priority: 1},
    %{provider: :lmstudio, model: "qwen2.5-coder", priority: 2},
    %{provider: :anthropic, model: "claude-sonnet-4-5-20250514", priority: 3},
    %{provider: :openai, model: "gpt-4o", priority: 4},
    %{provider: :openrouter, model: "anthropic/claude-sonnet-4-5-20250514", priority: 5}
  ]

  @cloud_only_candidates [
    %{provider: :anthropic, model: "claude-sonnet-4-5-20250514", priority: 1},
    %{provider: :openai, model: "gpt-4o", priority: 2},
    %{provider: :openrouter, model: "anthropic/claude-sonnet-4-5-20250514", priority: 3}
  ]

  # ============================================================================
  # Test 1: :restricted data only routes to local providers
  # ============================================================================

  describe "restricted data routing" do
    test "restricted data selects local provider (ollama)" do
      {:ok, {provider, _model}} =
        SensitivityRouter.select(:restricted, candidates: @local_and_cloud_candidates)

      assert provider in [:ollama, :lmstudio],
             "Restricted data must route to local provider, got: #{provider}"
    end

    test "restricted data does NOT select anthropic" do
      {:ok, {provider, _model}} =
        SensitivityRouter.select(:restricted, candidates: @local_and_cloud_candidates)

      refute provider == :anthropic
      refute provider == :openai
      refute provider == :openrouter
    end

    test "restricted data validation fails for cloud providers" do
      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:anthropic, "claude-sonnet-4-5-20250514", :restricted)

      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:openai, "gpt-4o", :restricted)

      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:openrouter, "anything", :restricted)
    end

    test "restricted data validation passes for local providers" do
      assert :ok = SensitivityRouter.validate(:ollama, "llama3.2", :restricted)
      assert :ok = SensitivityRouter.validate(:lmstudio, "any-model", :restricted)
    end

    test "BackendTrust confirms local providers can see restricted" do
      assert BackendTrust.can_see?(:ollama, :restricted)
      assert BackendTrust.can_see?(:lmstudio, :restricted)
    end

    test "BackendTrust confirms cloud providers cannot see restricted" do
      refute BackendTrust.can_see?(:anthropic, :restricted)
      refute BackendTrust.can_see?(:openai, :restricted)
      refute BackendTrust.can_see?(:openrouter, :restricted)
    end
  end

  # ============================================================================
  # Test 2: :confidential data routes to Anthropic or local (not OpenRouter/OpenAI)
  # ============================================================================

  describe "confidential data routing" do
    test "confidential data selects local or anthropic" do
      {:ok, {provider, _model}} =
        SensitivityRouter.select(:confidential, candidates: @local_and_cloud_candidates)

      assert provider in [:ollama, :lmstudio, :anthropic, :opencode],
             "Confidential data must route to local or high-trust provider, got: #{provider}"
    end

    test "confidential data does NOT select openrouter" do
      {:ok, {provider, _model}} =
        SensitivityRouter.select(:confidential, candidates: @local_and_cloud_candidates)

      refute provider == :openrouter
    end

    test "confidential data validation fails for low-trust providers" do
      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:openrouter, "any-model", :confidential)

      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:qwen, "any-model", :confidential)
    end

    test "confidential data validation passes for high-trust providers" do
      assert :ok = SensitivityRouter.validate(:anthropic, "claude-sonnet-4-5-20250514", :confidential)
      assert :ok = SensitivityRouter.validate(:ollama, "llama3.2", :confidential)
    end

    test "BackendTrust confirms capability boundaries" do
      assert BackendTrust.can_see?(:anthropic, :confidential)
      assert BackendTrust.can_see?(:ollama, :confidential)
      refute BackendTrust.can_see?(:openrouter, :confidential)
      refute BackendTrust.can_see?(:qwen, :confidential)
    end
  end

  # ============================================================================
  # Test 3: :internal data excludes only the most open providers
  # ============================================================================

  describe "internal data routing" do
    test "internal data excludes lowest trust providers" do
      {:ok, {provider, _model}} =
        SensitivityRouter.select(:internal, candidates: @local_and_cloud_candidates)

      # Qwen and openrouter (low trust) cannot see internal
      refute provider == :qwen
    end

    test "internal data includes anthropic and openai" do
      assert BackendTrust.can_see?(:anthropic, :internal)
      assert BackendTrust.can_see?(:openai, :internal)
    end

    test "internal data excludes lowest trust" do
      refute BackendTrust.can_see?(:qwen, :internal)
    end
  end

  # ============================================================================
  # Test 4: :public data has no restrictions
  # ============================================================================

  describe "public data routing" do
    test "public data passes validation for all providers" do
      for provider <- [:ollama, :lmstudio, :anthropic, :openai, :openrouter, :qwen] do
        assert BackendTrust.can_see?(provider, :public),
               "#{provider} should be able to see :public data"
      end
    end

    test "public sensitivity is no-op for routing" do
      decision = SensitivityRouter.decide(:openrouter, "any-model", :public, [])

      assert %RoutingDecision{action: :proceed} = decision
    end

    test "nil sensitivity is no-op for routing" do
      decision = SensitivityRouter.decide(:openrouter, "any-model", nil, [])

      assert %RoutingDecision{action: :proceed} = decision
    end
  end

  # ============================================================================
  # Test 5: When no local provider available, :restricted query returns error
  # ============================================================================

  describe "no local provider fallback" do
    test "restricted data with only cloud candidates returns error" do
      result = SensitivityRouter.select(:restricted, candidates: @cloud_only_candidates)

      assert {:error, :no_candidates} = result
    end

    test "restricted data with empty candidates returns error" do
      result = SensitivityRouter.select(:restricted, candidates: [])

      assert {:error, :no_candidates} = result
    end

    test "decide returns :blocked when mode is :block and no local available" do
      decision =
        SensitivityRouter.decide(:anthropic, "claude-sonnet-4-5-20250514", :restricted,
          candidates: @cloud_only_candidates,
          mode: :block
        )

      assert %RoutingDecision{action: :blocked, mode: :block} = decision
      assert decision.reason =~ "blocked by policy"
    end

    test "decide returns :proceed with reason when no alternatives (non-block mode)" do
      decision =
        SensitivityRouter.decide(:anthropic, "claude-sonnet-4-5-20250514", :restricted,
          candidates: [],
          mode: :warn
        )

      assert %RoutingDecision{action: :proceed} = decision
      assert decision.reason =~ "No alternative candidates available"
    end
  end

  # ============================================================================
  # Test 6: Mixed sensitivity in a batch — each item routed independently
  # ============================================================================

  describe "independent routing per sensitivity level" do
    test "each sensitivity level selects appropriate provider independently" do
      sensitivities = [:public, :internal, :confidential, :restricted]

      results =
        Enum.map(sensitivities, fn sensitivity ->
          SensitivityRouter.select(sensitivity, candidates: @local_and_cloud_candidates)
        end)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Extract providers
      providers = Enum.map(results, fn {:ok, {p, _m}} -> p end)

      # Restricted must be local
      restricted_provider = Enum.at(providers, 3)
      assert restricted_provider in [:ollama, :lmstudio]

      # Public can be anything (lowest priority wins)
      public_provider = Enum.at(providers, 0)
      assert public_provider in [:ollama, :lmstudio, :anthropic, :openai, :openrouter]
    end

    test "batch of decide calls produces independent decisions" do
      configs = [
        {:openrouter, "model", :public},
        {:openrouter, "model", :restricted},
        {:ollama, "llama3.2", :restricted}
      ]

      decisions =
        Enum.map(configs, fn {provider, model, sensitivity} ->
          SensitivityRouter.decide(provider, model, sensitivity,
            candidates: @local_and_cloud_candidates,
            mode: :warn
          )
        end)

      # Public on openrouter -> proceed
      assert %RoutingDecision{action: :proceed} = Enum.at(decisions, 0)

      # Restricted on openrouter -> rerouted
      assert %RoutingDecision{action: :rerouted} = Enum.at(decisions, 1)

      # Restricted on ollama -> proceed (local can handle restricted)
      assert %RoutingDecision{action: :proceed} = Enum.at(decisions, 2)
    end
  end

  # ============================================================================
  # Test 7: Sensitivity classification is checked BEFORE the LLM call
  # ============================================================================

  describe "sensitivity checked before LLM call" do
    test "validate/3 is a pure function that can be called pre-flight" do
      # validate returns immediately without making any LLM call
      assert :ok = SensitivityRouter.validate(:ollama, "llama3.2", :restricted)

      assert {:error, :insufficient_clearance} =
               SensitivityRouter.validate(:openrouter, "model", :restricted)
    end

    test "decide/4 returns decision without making LLM call" do
      # decide is also a pure function — no network calls
      decision =
        SensitivityRouter.decide(:openrouter, "model", :restricted,
          candidates: @local_and_cloud_candidates,
          mode: :block
        )

      assert %RoutingDecision{action: :blocked} = decision
      # The blocked decision means the LLM call would NOT proceed
    end

    test "maybe_reroute/4 selects alternative before any LLM call" do
      {provider, _model} =
        SensitivityRouter.maybe_reroute(:openrouter, "model", :restricted,
          candidates: @local_and_cloud_candidates
        )

      # Rerouted to local provider — this happens before any LLM call
      assert provider in [:ollama, :lmstudio]
    end
  end

  # ============================================================================
  # Test: Trust level ordering is correct
  # ============================================================================

  describe "trust level ordering" do
    test "local providers have highest trust" do
      assert BackendTrust.level(:ollama) == :highest
      assert BackendTrust.level(:lmstudio) == :highest
    end

    test "anthropic has high trust" do
      assert BackendTrust.level(:anthropic) == :high
    end

    test "openai has medium trust" do
      assert BackendTrust.level(:openai) == :medium
    end

    test "openrouter has low trust" do
      assert BackendTrust.level(:openrouter) == :low
    end

    test "unknown backends default to low trust" do
      assert BackendTrust.level(:unknown_provider) == :low
    end
  end
end
