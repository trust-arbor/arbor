defmodule Arbor.AITest do
  use ExUnit.Case, async: true

  alias Arbor.AI
  alias Arbor.AI.Config
  alias Arbor.AI.Router

  describe "Config" do
    test "default_provider/0 returns anthropic" do
      assert Config.default_provider() == :anthropic
    end

    test "default_model/0 returns claude model" do
      assert Config.default_model() =~ "claude"
    end

    test "timeout/0 returns positive integer" do
      assert Config.timeout() > 0
    end

    test "default_backend/0 returns valid backend option" do
      assert Config.default_backend() in [:api, :cli, :auto]
    end

    test "routing_strategy/0 returns valid strategy" do
      assert Config.routing_strategy() in [
               :cost_optimized,
               :quality_first,
               :cli_only,
               :api_only
             ]
    end

    test "cli_fallback_chain/0 returns list of providers" do
      chain = Config.cli_fallback_chain()
      assert is_list(chain)
      assert length(chain) > 0
      assert Enum.all?(chain, &is_atom/1)
    end

    test "cli_backend_timeout/0 returns positive integer" do
      assert Config.cli_backend_timeout() > 0
    end
  end

  describe "Router" do
    test "select_backend/1 returns :api when backend: :api" do
      assert Router.select_backend(backend: :api) == :api
    end

    test "select_backend/1 returns :cli when backend: :cli" do
      assert Router.select_backend(backend: :cli) == :cli
    end

    test "select_backend/1 handles :auto with cost_optimized strategy" do
      # Default strategy is cost_optimized, which prefers CLI
      assert Router.select_backend(backend: :auto, strategy: :cost_optimized) == :cli
    end

    test "select_backend/1 handles :auto with api_only strategy" do
      assert Router.select_backend(backend: :auto, strategy: :api_only) == :api
    end

    test "select_backend/1 handles :auto with cli_only strategy" do
      assert Router.select_backend(backend: :auto, strategy: :cli_only) == :cli
    end

    test "prefer_cli?/1 returns true for cost_optimized" do
      assert Router.prefer_cli?(strategy: :cost_optimized) == true
    end

    test "prefer_cli?/1 returns false for api_only" do
      assert Router.prefer_cli?(strategy: :api_only) == false
    end
  end

  describe "CliImpl" do
    alias Arbor.AI.CliImpl

    test "fallback_chain/0 returns configured chain" do
      chain = CliImpl.fallback_chain()
      assert is_list(chain)
      assert length(chain) > 0
    end

    test "available_providers/0 returns list of providers" do
      providers = CliImpl.available_providers()
      assert :anthropic in providers
      assert :openai in providers
      assert :gemini in providers
      assert :lmstudio in providers
    end

    test "backend_module/1 returns module for valid provider" do
      assert CliImpl.backend_module(:anthropic) == Arbor.AI.Backends.ClaudeCli
      assert CliImpl.backend_module(:openai) == Arbor.AI.Backends.CodexCli
      assert CliImpl.backend_module(:gemini) == Arbor.AI.Backends.GeminiCli
      assert CliImpl.backend_module(:lmstudio) == Arbor.AI.Backends.LMStudio
    end

    test "backend_module/1 returns nil for invalid provider" do
      assert CliImpl.backend_module(:nonexistent) == nil
    end
  end

  describe "Response" do
    alias Arbor.AI.Response

    test "new/1 creates response struct" do
      response = Response.new(text: "Hello", provider: :anthropic)
      assert response.text == "Hello"
      assert response.provider == :anthropic
    end

    test "from_map/1 normalizes map to struct" do
      map = %{
        "text" => "Hello",
        "provider" => "anthropic",
        "model" => "claude-sonnet-4",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      response = Response.from_map(map)
      assert response.text == "Hello"
      assert response.provider == :anthropic
      assert response.model == "claude-sonnet-4"
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 20
    end
  end

  describe "generate_text/2" do
    @tag :external
    @tag :skip
    test "returns structured response with text" do
      # This test requires a valid API key and makes real API calls
      {:ok, result} = AI.generate_text("Say 'hello' and nothing else")

      assert is_binary(result.text)
      assert is_map(result.usage)
      assert is_binary(result.model)
      assert is_atom(result.provider)
    end
  end

  describe "module contract" do
    test "exports generate_text function" do
      # Check module info for the function
      functions = AI.__info__(:functions)
      assert {:generate_text, 1} in functions or {:generate_text, 2} in functions
    end

    test "exports generate_text_via_cli function" do
      functions = AI.__info__(:functions)
      assert {:generate_text_via_cli, 1} in functions or {:generate_text_via_cli, 2} in functions
    end

    test "exports generate_text_via_api function" do
      functions = AI.__info__(:functions)
      assert {:generate_text_via_api, 1} in functions or {:generate_text_via_api, 2} in functions
    end

    test "implements AI contract" do
      behaviours = Arbor.AI.__info__(:attributes)[:behaviour] || []
      assert Arbor.Contracts.API.AI in behaviours
    end
  end
end
