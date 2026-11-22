defmodule Arbor.LLM.ProviderRouteTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  # Regression: the first provider-fallback implementation rerouted any
  # provider the catalog did not list — including caller-registered adapters
  # — so a working custom adapter was replaced by an unrelated fallback that
  # then failed with `{:unknown_provider, ...}`. Unknown routes must be
  # `:unknown`, never `:unavailable`.
  test "a name the catalog has never heard of is :unknown, not :unavailable" do
    assert Arbor.LLM.provider_route("llm_usage_context_capture") == :unknown
    assert Arbor.LLM.provider_route("") == :unknown
    assert Arbor.LLM.provider_route(nil) == :unknown
  end

  test "OAuth routes are always known: available only when the login is ready" do
    for route <- ["openai_oauth", "xai_oauth"] do
      assert Arbor.LLM.provider_route(route) in [:available, :unavailable]
    end
  end

  test "provider_available? agrees with provider_route" do
    for route <- ["openai_oauth", "xai_oauth", "ollama", "openai", "nope"] do
      assert Arbor.LLM.provider_available?(route) ==
               (Arbor.LLM.provider_route(route) == :available)
    end
  end
end
