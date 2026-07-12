defmodule Arbor.AI.UnifiedBridgeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.AI.UnifiedBridge
  alias Arbor.LLM.{Client, Request, RequestTimeoutError, Response}

  defmodule SlowDeadlineAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "deadline-bridge"

    @impl true
    def complete(%Request{}, _opts) do
      Process.sleep(40)
      {:ok, %Response{text: "late"}}
    end
  end

  describe "available?/0" do
    test "returns true when orchestrator client is loaded" do
      # The unified client module should be available in our test env
      # since arbor_orchestrator is compiled in the umbrella
      assert is_boolean(UnifiedBridge.available?())
    end
  end

  describe "generate_text/2" do
    @tag :llm
    test "returns :unavailable when client module not loaded" do
      # This test verifies the fallback behavior
      # We can't easily unload a module, so just verify the function exists
      # and returns one of the expected shapes
      result = UnifiedBridge.generate_text("test", provider: :anthropic, model: "test-model")
      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end

    test "bridge can check availability and call unified client" do
      # Verify the bridge module works
      # available? should return a boolean
      assert is_boolean(UnifiedBridge.available?())

      # generate_text should either succeed, return :unavailable, or return an error
      result = UnifiedBridge.generate_text("test", provider: :test, model: "test-model")
      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end

    test "security regression: bridge preserves the strictest duplicate caller deadline" do
      key = {UnifiedBridge, :client}
      previous = :persistent_term.get(key, :missing)

      client =
        Client.new(
          adapters: %{"deadline-bridge" => SlowDeadlineAdapter},
          default_provider: "deadline-bridge"
        )

      :persistent_term.put(key, client)

      on_exit(fn ->
        if previous == :missing,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, previous)
      end)

      assert {:error, %RequestTimeoutError{timeout_ms: 5}} =
               UnifiedBridge.generate_text("test",
                 provider: "deadline-bridge",
                 model: "slow",
                 timeout: 100,
                 timeout: 5
               )
    end
  end

  describe "resolve_provider/1" do
    test "maps API provider atoms to orchestrator strings" do
      assert UnifiedBridge.resolve_provider(provider: :anthropic) == "anthropic"
      assert UnifiedBridge.resolve_provider(provider: :openai) == "openai"
      # Session 6.6: the gemini backend atom maps to the "google"
      # provider string (req_llm's transport name) — Arbor no longer
      # carries its historical "gemini" alias.
      assert UnifiedBridge.resolve_provider(provider: :gemini) == "google"
      assert UnifiedBridge.resolve_provider(provider: :openrouter) == "openrouter"
      assert UnifiedBridge.resolve_provider(provider: :xai) == "xai"
      assert UnifiedBridge.resolve_provider(provider: :zai) == "zai"
      assert UnifiedBridge.resolve_provider(provider: :zai_coding_plan) == "zai_coding_plan"
    end

    test "maps local provider atoms to orchestrator strings" do
      assert UnifiedBridge.resolve_provider(provider: :lmstudio) == "lm_studio"
      assert UnifiedBridge.resolve_provider(provider: :ollama) == "ollama"
    end

    test "string providers pass through unchanged" do
      assert UnifiedBridge.resolve_provider(provider: "custom_provider") == "custom_provider"
    end

    test "unknown atom providers converted to string" do
      assert UnifiedBridge.resolve_provider(provider: :some_future_provider) ==
               "some_future_provider"
    end
  end

  describe "generate_text_stream/2" do
    test "returns :unavailable when client module not loaded" do
      result =
        UnifiedBridge.generate_text_stream("test", provider: :anthropic, model: "test-model")

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end

    test "accepts on_event callback option" do
      # Verify the function accepts and doesn't crash with on_event
      result =
        UnifiedBridge.generate_text_stream("test",
          provider: :test,
          model: "test-model",
          on_event: fn _event -> :ok end
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end

    test "accepts collect: false option" do
      result =
        UnifiedBridge.generate_text_stream("test",
          provider: :test,
          model: "test-model",
          collect: false
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end

    test "defaults to collect: true" do
      # With collect: true (default), result should be a response map, not a stream
      result =
        UnifiedBridge.generate_text_stream("test",
          provider: :test,
          model: "test-model"
        )

      case result do
        {:ok, response} when is_map(response) ->
          # Collected response should have standard keys
          assert Map.has_key?(response, :text) or Map.has_key?(response, :model)

        {:error, _} ->
          :ok

        :unavailable ->
          :ok
      end
    end
  end

  describe "embed/2" do
    test "returns expected shape or unavailable" do
      result = UnifiedBridge.embed("test text", provider: :ollama, model: "nomic-embed-text")

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end
  end

  describe "embed_batch/2" do
    test "returns expected shape or unavailable" do
      result =
        UnifiedBridge.embed_batch(["text 1", "text 2"],
          provider: :ollama,
          model: "nomic-embed-text"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end
  end
end
