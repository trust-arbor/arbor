defmodule Arbor.AITest do
  use ExUnit.Case, async: true

  alias Arbor.AI
  alias Arbor.AI.Config
  alias Arbor.AI.Router

  describe "Config" do
    test "default_provider/0 returns configured provider" do
      # Config uses :openrouter for cost-effective operations
      assert Config.default_provider() in [:anthropic, :openrouter, :openai, :gemini]
    end

    test "default_model/0 returns configured model" do
      # Config uses free models for cost efficiency
      model = Config.default_model()
      assert is_binary(model)
      assert String.length(model) > 0
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
      assert chain != []
      assert Enum.all?(chain, &is_atom/1)
    end

    test "cli_backend_timeout/0 returns positive integer" do
      assert Config.cli_backend_timeout() > 0
    end
  end

  describe "Router" do
    test "route_task/2 accepts string prompt" do
      result = Router.route_task("Hello world")
      assert match?({:ok, {_backend, _model}}, result) or match?({:error, _}, result)
    end

    test "route_task/2 manual override bypasses routing" do
      result = Router.route_task("any prompt", model: {:anthropic, :opus})
      assert {:ok, {:anthropic, model}} = result
      assert is_binary(model)
    end

    test "route_embedding/1 returns provider or error" do
      result = Router.route_embedding()
      assert match?({:ok, {_backend, _model}}, result) or match?({:error, _}, result)
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
    @tag :llm
    test "returns structured response with text" do
      {:ok, result} =
        AI.generate_text("Say 'hello' and nothing else",
          provider: :openrouter,
          model: "arcee-ai/trinity-large-preview:free"
        )

      assert is_binary(result.text)
      assert is_map(result.usage)
      assert is_binary(result.model)
      assert is_atom(result.provider)
    end
  end

  describe "module contract" do
    test "exports generate_text function" do
      functions = AI.__info__(:functions)
      assert {:generate_text, 1} in functions or {:generate_text, 2} in functions
    end

    test "exports generate_text_with_tools function" do
      functions = AI.__info__(:functions)

      assert {:generate_text_with_tools, 1} in functions or
               {:generate_text_with_tools, 2} in functions
    end

    test "implements AI contract" do
      behaviours = Arbor.AI.__info__(:attributes)[:behaviour] || []
      assert Arbor.Contracts.API.AI in behaviours
    end
  end
end
