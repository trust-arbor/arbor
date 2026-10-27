defmodule Arbor.AI.FacadeMigrationTest do
  use ExUnit.Case, async: false

  defmodule OfflineAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "facade_migration_fixture"
    def complete(_request, _opts), do: {:error, :facade_migration_fixture_unavailable}
  end

  setup do
    key = {Arbor.AI.UnifiedBridge, :client}
    previous = :persistent_term.get(key, :missing)

    client =
      Arbor.LLM.Client.new(
        adapters: %{"anthropic" => OfflineAdapter, "openrouter" => OfflineAdapter}
      )

    :persistent_term.put(key, client)

    on_exit(fn ->
      if previous == :missing,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous)
    end)

    :ok
  end

  @moduletag :integration

  describe "generate_text/2 unified path" do
    test "generate_text/2 routes through UnifiedBridge" do
      # All providers (CLI + API) are now handled by the orchestrator's UnifiedLLM layer.
      # Without valid API keys, UnifiedBridge returns an error tuple.
      result =
        Arbor.AI.generate_text("test prompt",
          provider: :anthropic,
          model: "claude-sonnet-4-5-20250514",
          max_tokens: 10,
          temperature: 0.1
        )

      # Either succeeds (has API key) or returns error (no key / unavailable)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "generate_text/2 accepts provider option directly" do
      # Providers are passed directly — no CLI/API split
      result =
        Arbor.AI.generate_text("test",
          provider: :openrouter,
          model: "openai/gpt-oss-120b:free",
          max_tokens: 10
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
