defmodule Arbor.AI.Runtime.SelectorTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.Runtime.Selector
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

  # Build a ModelEntry directly (avoids any llm_db dependency in tests) —
  # the selector is pure, so what matters is the provider/runtime shape,
  # not where the entry came from.
  defp entry(canonical_id, providers, opts \\ []) do
    {:ok, e} =
      ModelEntry.new(%{
        canonical_id: canonical_id,
        family: Keyword.get(opts, :family, :claude),
        context_window: 200_000,
        max_output_tokens: 32_000,
        providers: providers
      })

    e
  end

  defp provider(id, runtimes) do
    %{id: id, ref: "ref-#{id}", auth: :api_key, runtimes: runtimes}
  end

  describe "choose/2 — defaults" do
    test "default :arbor is selected when no policy is supplied" do
      e =
        entry("claude-opus-4-6", [
          provider(:anthropic, [:arbor]),
          provider(:openrouter, [:arbor])
        ])

      assert {:ok, %{provider: %ProviderEntry{id: :anthropic}, runtime: :arbor}} =
               Selector.choose(e)
    end

    test "auto-claim walks providers in declared order until one supports runtime" do
      e =
        entry("claude-opus-4-6", [
          # First provider only supports :acp (no :arbor)
          provider(:claude_subscription_acp_only, [:acp]),
          provider(:anthropic, [:arbor])
        ])

      assert {:ok, %{provider: %ProviderEntry{id: :anthropic}, runtime: :arbor}} =
               Selector.choose(e)
    end

    test "policy.default_runtime overrides the :arbor default" do
      e =
        entry("claude-opus-4-6", [
          provider(:claude_subscription, [:arbor, :acp])
        ])

      assert {:ok, %{provider: %ProviderEntry{id: :claude_subscription}, runtime: :acp}} =
               Selector.choose(e, %{default_runtime: :acp})
    end
  end

  describe "choose/2 — per-turn override (highest priority)" do
    test "policy.runtime overrides everything below it" do
      e =
        entry("claude-opus-4-6", [
          provider(:claude_subscription, [:arbor, :acp])
        ])

      assert {:ok, %{runtime: :acp}} = Selector.choose(e, %{runtime: :acp})
    end

    test "policy.runtime errors if no provider supports it" do
      e = entry("claude-opus-4-6", [provider(:anthropic, [:arbor])])

      assert {:error, {:no_provider_supports_runtime, :acp}} =
               Selector.choose(e, %{runtime: :acp})
    end

    test "policy.provider + policy.runtime pin a specific path" do
      e =
        entry("claude-opus-4-6", [
          provider(:anthropic, [:arbor]),
          provider(:claude_subscription, [:arbor, :acp])
        ])

      assert {:ok, %{provider: %ProviderEntry{id: :claude_subscription}, runtime: :acp}} =
               Selector.choose(e, %{provider: :claude_subscription, runtime: :acp})
    end

    test "pinned provider that doesn't support the runtime errors" do
      e =
        entry("claude-opus-4-6", [
          provider(:anthropic, [:arbor])
        ])

      assert {:error, {:requested_runtime_not_supported, :acp}} =
               Selector.choose(e, %{provider: :anthropic, runtime: :acp})
    end

    test "pinned provider not in the model's list errors" do
      e =
        entry("claude-opus-4-6", [
          provider(:anthropic, [:arbor])
        ])

      assert {:error, {:requested_provider_not_available, :bedrock}} =
               Selector.choose(e, %{provider: :bedrock})
    end
  end

  describe "choose/2 — model-scoped pins" do
    test "model_runtime_pins[canonical_id] takes precedence over default_runtime" do
      e =
        entry("claude-opus-4-6", [
          provider(:claude_subscription, [:arbor, :acp])
        ])

      assert {:ok, %{runtime: :acp}} =
               Selector.choose(e, %{
                 model_runtime_pins: %{"claude-opus-4-6" => :acp},
                 default_runtime: :arbor
               })
    end

    test "per-turn override beats model_runtime_pins" do
      e =
        entry("claude-opus-4-6", [
          provider(:claude_subscription, [:arbor, :acp])
        ])

      assert {:ok, %{runtime: :arbor}} =
               Selector.choose(e, %{
                 runtime: :arbor,
                 model_runtime_pins: %{"claude-opus-4-6" => :acp}
               })
    end

    test "model_runtime_pins for a different canonical_id is ignored" do
      e =
        entry("claude-opus-4-6", [
          provider(:anthropic, [:arbor])
        ])

      assert {:ok, %{runtime: :arbor}} =
               Selector.choose(e, %{model_runtime_pins: %{"claude-sonnet-4-6" => :acp}})
    end
  end

  describe "choose/2 — provider-scoped pins" do
    test "provider_runtime_pins[id] applies only when that provider is pinned" do
      e =
        entry("claude-opus-4-6", [
          provider(:claude_subscription, [:arbor, :acp])
        ])

      # provider is pinned + provider_runtime_pins has an entry for it.
      assert {:ok, %{runtime: :acp}} =
               Selector.choose(e, %{
                 provider: :claude_subscription,
                 provider_runtime_pins: %{claude_subscription: :acp}
               })
    end

    test "provider_runtime_pins is NOT consulted when no provider is pinned (auto-claim path)" do
      # Without a pinned provider, provider_runtime_pins doesn't fire —
      # the selector falls through to default_runtime then auto-claims a
      # provider. This is intentional: provider_runtime_pins is keyed by
      # provider, so it requires the caller to commit to a provider before
      # the pin can apply.
      e =
        entry("claude-opus-4-6", [
          provider(:claude_subscription, [:arbor, :acp])
        ])

      assert {:ok, %{runtime: :arbor}} =
               Selector.choose(e, %{
                 provider_runtime_pins: %{claude_subscription: :acp}
               })
    end
  end

  describe "choose/2 — error edges" do
    test "ModelEntry with empty providers list errors" do
      e = %ModelEntry{
        canonical_id: "x",
        providers: [],
        family: :unknown,
        context_window: 1,
        max_output_tokens: 1,
        effective_window_pct: 0.75,
        capabilities: [],
        caveats: []
      }

      assert {:error, :no_providers} = Selector.choose(e)
    end
  end
end
