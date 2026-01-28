defmodule Arbor.AITest do
  use ExUnit.Case, async: true

  alias Arbor.AI
  alias Arbor.AI.Config

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

    test "implements AI contract" do
      behaviours = Arbor.AI.__info__(:attributes)[:behaviour] || []
      assert Arbor.Contracts.API.AI in behaviours
    end
  end
end
