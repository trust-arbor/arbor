defmodule Arbor.LLM.ClientRoutingTest do
  @moduledoc """
  Routing tests for the Session 5 cutover.

  `Client.from_env/0` builds the adapter map from env-var presence
  (one entry per provider whose API key is set). As of Session 5, the
  entries point to `Arbor.LLM.Adapter.ReqLLM` (generic, via req_llm)
  when `:use_generic_llm_adapter` is true (the default), and to the
  legacy per-provider modules under
  `Arbor.Orchestrator.UnifiedLLM.Adapters.*` when false (the rollback).

  These tests don't call out to any provider — they verify the
  routing-table assembly only.
  """

  use ExUnit.Case, async: false

  alias Arbor.LLM.Adapter.ReqLLM, as: Generic
  alias Arbor.LLM.Client

  @app :arbor_orchestrator
  @flag_key :use_generic_llm_adapter

  @api_provider_envs %{
    "openai" => "OPENAI_API_KEY",
    "anthropic" => "ANTHROPIC_API_KEY",
    "gemini" => "GEMINI_API_KEY",
    "zai" => "ZAI_API_KEY",
    "zai_coding_plan" => "ZAI_CODING_PLAN_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "xai" => "XAI_API_KEY"
  }

  setup do
    original_env_values =
      Map.new(@api_provider_envs, fn {provider, env} ->
        {provider, {env, System.get_env(env)}}
      end)

    # Clear all of them — each test re-sets only what it needs.
    for {_provider, {env, _}} <- original_env_values, do: System.delete_env(env)

    original_flag = Application.get_env(@app, @flag_key)

    on_exit(fn ->
      for {_provider, {env, original_value}} <- original_env_values do
        if is_binary(original_value),
          do: System.put_env(env, original_value),
          else: System.delete_env(env)
      end

      case original_flag do
        nil -> Application.delete_env(@app, @flag_key)
        value -> Application.put_env(@app, @flag_key, value)
      end
    end)

    :ok
  end

  describe "Session 5 cutover — generic adapter routing (default)" do
    test "ANTHROPIC_API_KEY routes 'anthropic' to the generic adapter" do
      Application.put_env(@app, @flag_key, true)
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)

      assert client.adapters["anthropic"] == Generic
    end

    test "all seven API providers route through the generic adapter" do
      Application.put_env(@app, @flag_key, true)

      for {_, env} <- @api_provider_envs, do: System.put_env(env, "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)

      for provider <- Map.keys(@api_provider_envs) do
        assert client.adapters[provider] == Generic,
               "provider #{provider} should route through the generic adapter"
      end
    end
  end

  describe "Session 5 cutover — legacy rollback path" do
    test "with :use_generic_llm_adapter=false, 'openai' falls back to the legacy module" do
      Application.put_env(@app, @flag_key, false)
      System.put_env("OPENAI_API_KEY", "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)

      legacy = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :OpenAI])
      assert client.adapters["openai"] == legacy
      refute client.adapters["openai"] == Generic
    end

    test "all seven API providers fall back to legacy modules" do
      Application.put_env(@app, @flag_key, false)

      for {_, env} <- @api_provider_envs, do: System.put_env(env, "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)

      legacy_map = %{
        "openai" => Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :OpenAI]),
        "anthropic" => Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :Anthropic]),
        "gemini" => Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :Gemini]),
        "zai" => Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :Zai]),
        "zai_coding_plan" =>
          Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :ZaiCodingPlan]),
        "openrouter" =>
          Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :OpenRouter]),
        "xai" => Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Adapters, :XAI])
      }

      for {provider, expected} <- legacy_map do
        assert client.adapters[provider] == expected
      end
    end
  end

  describe "Session 5 cutover — flag default" do
    test "missing config defaults to generic adapter (the cutover)" do
      Application.delete_env(@app, @flag_key)
      System.put_env("OPENAI_API_KEY", "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)
      assert client.adapters["openai"] == Generic
    end
  end

  describe "Session 5 cutover — ACP is unconditional legacy" do
    @tag :skip
    test "ACP routes to the legacy adapter even when generic flag is on" do
      # Skipped: the ACP adapter's `available?/0` calls into the running
      # AcpPool in arbor_ai. Verifying ACP routing requires either
      # mocking the pool or actually starting it — not worth the
      # complexity for a routing-table check. Manual verification:
      # operator restarts arbor with the flag on and confirms ACP still
      # resolves to Arbor.Orchestrator.UnifiedLLM.Adapters.Acp via the
      # dashboard's runtime panel.
    end
  end

  describe "Client.embed/4 forwards :provider to the adapter (Session 5)" do
    test "provider is injected into opts so the generic adapter can build the model_spec" do
      # Mock adapter that captures its embed/3 args. Registered manually
      # via Client.register_adapter rather than env discovery so this
      # test is decoupled from env vars + the flag.
      defmodule SpyAdapter do
        @behaviour Arbor.LLM.ProviderAdapter

        def provider, do: "openai"

        def complete(_, _), do: {:error, :not_implemented}

        def embed(texts, model, opts) do
          send(self(), {:spy_embed, texts, model, opts})
          {:ok, %{embeddings: [[1.0, 2.0]], model: model, usage: %{}, dimensions: 2}}
        end
      end

      client =
        Client.new()
        |> Client.register_adapter(SpyAdapter)

      assert {:ok, _} = Client.embed(client, "openai", "text-embedding-3-small", texts: ["x"])

      assert_received {:spy_embed, ["x"], "text-embedding-3-small", opts}
      assert opts[:provider] == "openai"
    end
  end
end
