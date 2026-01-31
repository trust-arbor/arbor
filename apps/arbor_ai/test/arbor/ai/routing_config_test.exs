defmodule Arbor.AI.RoutingConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.RoutingConfig

  @moduletag :fast

  describe "get_tier_backends/1" do
    test "returns critical tier backends" do
      backends = RoutingConfig.get_tier_backends(:critical)
      assert is_list(backends)
      assert backends != []
      # Critical tier should include opus
      assert {:anthropic, :opus} in backends
    end

    test "returns complex tier backends" do
      backends = RoutingConfig.get_tier_backends(:complex)
      assert is_list(backends)
      assert {:anthropic, :sonnet} in backends
    end

    test "returns moderate tier backends" do
      backends = RoutingConfig.get_tier_backends(:moderate)
      assert is_list(backends)
      assert backends != []
    end

    test "returns simple tier backends" do
      backends = RoutingConfig.get_tier_backends(:simple)
      assert is_list(backends)
      # Simple tier should include free/cheap options
      assert {:opencode, :grok} in backends or {:qwen, :qwen_code} in backends
    end

    test "returns trivial tier backends" do
      backends = RoutingConfig.get_tier_backends(:trivial)
      assert is_list(backends)
    end
  end

  describe "get_fallback_chain/1" do
    test "returns fallback backends" do
      chain = RoutingConfig.get_fallback_chain()
      assert is_list(chain)
      assert chain != []
    end

    test "excludes specified backends" do
      chain = RoutingConfig.get_fallback_chain(exclude: [:lmstudio, :anthropic])
      refute Enum.any?(chain, fn {backend, _} -> backend == :lmstudio end)
      refute Enum.any?(chain, fn {backend, _} -> backend == :anthropic end)
    end

    test "handles empty exclude list" do
      chain = RoutingConfig.get_fallback_chain(exclude: [])
      assert is_list(chain)
      assert chain != []
    end
  end

  describe "resolve_model/1" do
    test "resolves :sonnet to current version string" do
      model = RoutingConfig.resolve_model(:sonnet)
      assert is_binary(model)
      assert model =~ "claude-sonnet"
    end

    test "resolves :opus to current version string" do
      model = RoutingConfig.resolve_model(:opus)
      assert is_binary(model)
      assert model =~ "claude-opus"
    end

    test "resolves :haiku to current version string" do
      model = RoutingConfig.resolve_model(:haiku)
      assert is_binary(model)
      assert model =~ "claude-haiku"
    end

    test "resolves :gpt5 to version string" do
      model = RoutingConfig.resolve_model(:gpt5)
      assert is_binary(model)
      assert model =~ "gpt"
    end

    test "passes through explicit strings unchanged" do
      model = RoutingConfig.resolve_model("my-custom-model-v1")
      assert model == "my-custom-model-v1"
    end

    test "converts unknown atoms to strings" do
      model = RoutingConfig.resolve_model(:unknown_model)
      assert model == "unknown_model"
    end
  end

  describe "get_embedding_providers/1" do
    test "returns embedding providers in preference order" do
      providers = RoutingConfig.get_embedding_providers()
      assert is_list(providers)
      assert providers != []

      # Check that each entry is a {backend, model} tuple
      Enum.each(providers, fn {backend, model} ->
        assert is_atom(backend)
        assert is_binary(model)
      end)
    end

    test "prefer: :local returns local providers first" do
      providers = RoutingConfig.get_embedding_providers(prefer: :local)
      assert is_list(providers)

      # First provider should be local (ollama or lmstudio)
      [{first_backend, _model} | _] = providers
      assert first_backend in [:ollama, :lmstudio]
    end

    test "prefer: :cloud returns cloud providers first" do
      providers = RoutingConfig.get_embedding_providers(prefer: :cloud)
      assert is_list(providers)

      # First provider should be cloud (openai)
      [{first_backend, _model} | _] = providers
      assert first_backend in [:openai, :anthropic, :gemini, :cohere]
    end
  end

  describe "embedding_fallback_to_cloud?/0" do
    test "returns boolean" do
      result = RoutingConfig.embedding_fallback_to_cloud?()
      assert is_boolean(result)
    end
  end

  describe "task_routing_enabled?/0" do
    test "returns boolean" do
      result = RoutingConfig.task_routing_enabled?()
      assert is_boolean(result)
    end

    test "defaults to true" do
      # Clear any config override
      original = Application.get_env(:arbor_ai, :enable_task_routing)

      try do
        Application.delete_env(:arbor_ai, :enable_task_routing)
        assert RoutingConfig.task_routing_enabled?() == true
      after
        if original != nil do
          Application.put_env(:arbor_ai, :enable_task_routing, original)
        end
      end
    end
  end

  describe "config overrides" do
    test "tier_routing config overrides defaults" do
      original = Application.get_env(:arbor_ai, :tier_routing)

      custom = %{
        critical: [{:custom, :model}],
        complex: [],
        moderate: [],
        simple: [],
        trivial: []
      }

      try do
        Application.put_env(:arbor_ai, :tier_routing, custom)
        assert RoutingConfig.get_tier_backends(:critical) == [{:custom, :model}]
        assert RoutingConfig.get_tier_backends(:complex) == []
      after
        if original != nil do
          Application.put_env(:arbor_ai, :tier_routing, original)
        else
          Application.delete_env(:arbor_ai, :tier_routing)
        end
      end
    end

    test "embedding_routing config overrides defaults" do
      original = Application.get_env(:arbor_ai, :embedding_routing)

      custom = %{
        preferred: :cloud,
        providers: [{:openai, "custom-embed"}],
        fallback_to_cloud: false
      }

      try do
        Application.put_env(:arbor_ai, :embedding_routing, custom)
        providers = RoutingConfig.get_embedding_providers()
        assert providers == [{:openai, "custom-embed"}]
        refute RoutingConfig.embedding_fallback_to_cloud?()
      after
        if original != nil do
          Application.put_env(:arbor_ai, :embedding_routing, original)
        else
          Application.delete_env(:arbor_ai, :embedding_routing)
        end
      end
    end

    test "enable_task_routing config overrides default" do
      original = Application.get_env(:arbor_ai, :enable_task_routing)

      try do
        Application.put_env(:arbor_ai, :enable_task_routing, false)
        refute RoutingConfig.task_routing_enabled?()

        Application.put_env(:arbor_ai, :enable_task_routing, true)
        assert RoutingConfig.task_routing_enabled?()
      after
        if original != nil do
          Application.put_env(:arbor_ai, :enable_task_routing, original)
        else
          Application.delete_env(:arbor_ai, :enable_task_routing)
        end
      end
    end
  end

  describe "model_versions/0" do
    test "returns map of model shorthands to version strings" do
      versions = RoutingConfig.model_versions()
      assert is_map(versions)
      assert Map.has_key?(versions, :sonnet)
      assert Map.has_key?(versions, :opus)
      assert Map.has_key?(versions, :haiku)
    end
  end
end
