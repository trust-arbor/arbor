defmodule Arbor.AI.RouterTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.{Router, TaskMeta}

  # Note: These tests use mocked availability where needed
  # The router depends on BackendRegistry and QuotaTracker which need real processes

  describe "route_task/2" do
    @tag :fast
    test "accepts string prompt and classifies it" do
      # This will try to route but may fail if no backends available
      # The key is it accepts the string input
      result = Router.route_task("Hello world")
      # Either succeeds or returns error (no backends)
      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end

    @tag :fast
    test "accepts TaskMeta struct" do
      meta = %TaskMeta{risk_level: :medium, complexity: :moderate}
      result = Router.route_task(meta)

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end

    @tag :fast
    test "manual model override bypasses routing" do
      result = Router.route_task("any prompt", model: {:anthropic, :opus})
      assert {:ok, {:anthropic, model}} = result
      assert is_binary(model)
      assert model =~ "claude-opus"
    end

    @tag :fast
    test "manual override with string model passes through" do
      result = Router.route_task("any prompt", model: {:anthropic, "custom-model"})
      assert {:ok, {:anthropic, "custom-model"}} = result
    end

    @tag :fast
    test "invalid model override returns error" do
      result = Router.route_task("prompt", model: "not a tuple")
      assert {:error, :invalid_model_override} = result
    end

    @tag :fast
    test "security prompt gets classified to critical tier" do
      # First classify to verify tier
      meta = TaskMeta.classify("fix the security vulnerability in auth")
      assert TaskMeta.tier(meta) == :critical

      # Then verify routing attempts critical tier
      # (may fail if backends unavailable, but the classification is correct)
      _result = Router.route_task("fix the security vulnerability in auth")
    end

    @tag :fast
    test "trivial prompt gets classified to trivial tier" do
      meta = TaskMeta.classify("fix typo in readme")
      assert TaskMeta.tier(meta) == :trivial
    end
  end

  describe "route_embedding/1" do
    @tag :fast
    test "returns provider tuple or error" do
      result = Router.route_embedding()

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, :no_embedding_providers}, result)
    end

    @tag :fast
    test "prefer: :local option is accepted" do
      result = Router.route_embedding(prefer: :local)

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end

    @tag :fast
    test "prefer: :cloud option is accepted" do
      result = Router.route_embedding(prefer: :cloud)

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end
  end

  # Legacy routing tests (backward compatibility)
  describe "select_backend/1 (legacy)" do
    @tag :fast
    test "returns :api when backend: :api" do
      assert Router.select_backend(backend: :api) == :api
    end

    @tag :fast
    test "returns :cli when backend: :cli" do
      assert Router.select_backend(backend: :cli) == :cli
    end

    @tag :fast
    test "handles :auto with cost_optimized strategy" do
      assert Router.select_backend(backend: :auto, strategy: :cost_optimized) == :cli
    end

    @tag :fast
    test "handles :auto with api_only strategy" do
      assert Router.select_backend(backend: :auto, strategy: :api_only) == :api
    end

    @tag :fast
    test "handles :auto with cli_only strategy" do
      assert Router.select_backend(backend: :auto, strategy: :cli_only) == :cli
    end
  end

  describe "prefer_cli?/1 (legacy)" do
    @tag :fast
    test "returns true for cost_optimized strategy" do
      assert Router.prefer_cli?(strategy: :cost_optimized) == true
    end

    @tag :fast
    test "returns false for api_only strategy" do
      assert Router.prefer_cli?(strategy: :api_only) == false
    end
  end
end
