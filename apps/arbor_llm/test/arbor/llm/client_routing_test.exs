defmodule Arbor.LLM.ClientRoutingTest do
  @moduledoc """
  Routing tests for `Client.from_env/0`'s adapter map assembly.

  Every env-discovered API + local-LM provider routes through
  `Arbor.LLM.Adapter.ReqLLM`. ACP routes through `Arbor.AI.LLM.Adapter.Acp`
  (subprocess runtime, not an LLM transport). The Session 5
  `use_generic_llm_adapter` rollback flag was removed in Session 6
  after live-traffic soak confirmed the cutover.

  These tests don't call out to any provider — they verify the
  routing-table assembly only.
  """

  use ExUnit.Case, async: false

  alias Arbor.LLM.Adapter.ReqLLM, as: Generic
  alias Arbor.LLM.Client

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

    for {_provider, {env, _}} <- original_env_values, do: System.delete_env(env)

    on_exit(fn ->
      for {_provider, {env, original_value}} <- original_env_values do
        if is_binary(original_value),
          do: System.put_env(env, original_value),
          else: System.delete_env(env)
      end
    end)

    :ok
  end

  describe "env-discovered API providers route to the generic adapter" do
    test "ANTHROPIC_API_KEY routes 'anthropic' to the generic adapter" do
      System.put_env("ANTHROPIC_API_KEY", "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)

      assert client.adapters["anthropic"] == Generic
    end

    test "all seven API providers route through the generic adapter" do
      for {_, env} <- @api_provider_envs, do: System.put_env(env, "test-key")

      client = Client.from_env(discover_local: false, discover_acp: false)

      for provider <- Map.keys(@api_provider_envs) do
        assert client.adapters[provider] == Generic,
               "provider #{provider} should route through the generic adapter"
      end
    end

    test "absent API key → provider absent from routing table" do
      # No API keys set in this test's setup, and we explicitly skip
      # local + ACP discovery — so the adapter map should be empty and
      # `from_env` raises (no provider configured).
      assert_raise Arbor.LLM.ConfigurationError, fn ->
        Client.from_env(discover_local: false, discover_acp: false)
      end
    end
  end

  describe "Client.embed/4 forwards :provider to the adapter" do
    test "provider is injected into opts so the generic adapter can build the model_spec" do
      # Mock adapter that captures its embed/3 args. Registered manually
      # via Client.register_adapter rather than env discovery so this
      # test is decoupled from env vars.
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
