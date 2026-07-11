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
  alias Arbor.LLM.ProviderRegistry

  # Source of truth for which env var carries which provider's API key
  # lives in ProviderRegistry (which reads from req_llm's provider
  # modules). Tests derive from there so they stay correct when
  # req_llm renames variables or adds providers.
  @api_provider_envs for provider <- ProviderRegistry.list_cloud(),
                         env = ProviderRegistry.default_env_key(provider),
                         is_binary(env),
                         into: %{},
                         do: {provider, env}

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
      # No API keys set in this test's setup. Use empty `adapters`
      # observation rather than relying on from_env's
      # ConfigurationError path (which other env state — e.g.
      # UNIFIED_LLM_DEFAULT_PROVIDER — can also satisfy). This
      # asserts the actual contract: nothing got auto-registered.
      adapters =
        try do
          Client.from_env(discover_local: false, discover_acp: false).adapters
        rescue
          Arbor.LLM.ConfigurationError -> %{}
        end

      for provider <- Map.keys(@api_provider_envs) do
        refute Map.has_key?(adapters, provider),
               "provider #{provider} should not be registered with no API key"
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
          send(Keyword.fetch!(opts, :parent), {:spy_embed, texts, model, opts})
          {:ok, %{embeddings: [[1.0, 2.0]], model: model, usage: %{}, dimensions: 2}}
        end
      end

      client =
        Client.new()
        |> Client.register_adapter(SpyAdapter)

      assert {:ok, _} =
               Client.embed(client, "openai", "text-embedding-3-small",
                 texts: ["x"],
                 parent: self()
               )

      assert_received {:spy_embed, ["x"], "text-embedding-3-small", opts}
      assert opts[:provider] == "openai"
    end
  end
end
