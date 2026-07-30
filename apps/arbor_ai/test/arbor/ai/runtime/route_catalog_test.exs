defmodule Arbor.AI.Runtime.RouteCatalogTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Runtime.RouteCatalog
  alias Arbor.Common.ModelProfile
  alias Arbor.Contracts.LLM.ProviderEntry

  @moduletag :fast

  test "overlays gpt-5.6-sol with a single openai_oauth OAuth Arbor route" do
    base = ModelProfile.entry("gpt-5.6-sol")
    entry = RouteCatalog.entry("gpt-5.6-sol")

    assert entry.canonical_id == base.canonical_id
    assert entry.family == base.family
    assert entry.context_window == base.context_window
    assert entry.max_output_tokens == base.max_output_tokens
    assert entry.effective_window_pct == base.effective_window_pct
    assert entry.capabilities == base.capabilities
    assert entry.caveats == base.caveats

    assert [
             %ProviderEntry{
               id: :openai_oauth,
               ref: "gpt-5.6-sol",
               auth: :oauth,
               runtimes: [:arbor],
               pricing: nil
             }
           ] = entry.providers
  end

  test "overlays grok-4.5 with a single xai_oauth OAuth Arbor route" do
    base = ModelProfile.entry("grok-4.5")
    entry = RouteCatalog.entry("grok-4.5")

    assert entry.canonical_id == base.canonical_id
    assert entry.family == base.family
    assert entry.context_window == base.context_window
    assert entry.max_output_tokens == base.max_output_tokens
    assert entry.effective_window_pct == base.effective_window_pct
    assert entry.capabilities == base.capabilities
    assert entry.caveats == base.caveats

    assert [
             %ProviderEntry{
               id: :xai_oauth,
               ref: "grok-4.5",
               auth: :oauth,
               runtimes: [:arbor],
               pricing: nil
             }
           ] = entry.providers
  end

  test "lookalikes and aliases do not receive OAuth route overlays" do
    for id <- [
          "gpt-5.6",
          "gpt-5.6-sol-preview",
          "openai:gpt-5.6-sol",
          "grok-4",
          "grok-4.5-fast",
          "xai:grok-4.5"
        ] do
      base = ModelProfile.entry(id)
      entry = RouteCatalog.entry(id)
      assert entry.providers == base.providers
      refute Enum.any?(entry.providers, &(&1.id in [:openai_oauth, :xai_oauth]))
    end
  end

  test "entries/1 preserves order and count" do
    assert {:ok, [a, b, c]} =
             RouteCatalog.entries(["gpt-5.6-sol", "gpt-5.6", "grok-4.5"])

    assert length([a, b, c]) == 3
    assert a.canonical_id == "gpt-5.6-sol"
    assert hd(a.providers).id == :openai_oauth
    assert b.canonical_id == ModelProfile.entry("gpt-5.6").canonical_id
    assert b.providers == ModelProfile.entry("gpt-5.6").providers
    assert c.canonical_id == "grok-4.5"
    assert hd(c.providers).id == :xai_oauth
  end
end
