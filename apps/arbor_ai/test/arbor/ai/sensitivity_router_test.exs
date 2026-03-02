defmodule Arbor.AI.SensitivityRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.SensitivityRouter

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
  end
end
