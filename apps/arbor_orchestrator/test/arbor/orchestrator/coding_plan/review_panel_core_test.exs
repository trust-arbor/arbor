defmodule Arbor.Orchestrator.CodingPlan.ReviewPanelCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.ReviewPanelCore, as: Core

  @generic [{"openai_oauth", "gpt-5.6-sol"}, {"xai_oauth", "grok-4.6"}]
  @seats [
    %{id: "seat_ollama_a", provider: "ollama", model: "kimi-k2.7-code:cloud"},
    %{id: "seat_ollama_b", provider: "ollama", model: "glm-5.2:cloud"},
    %{id: "seat_openai", provider: "openai_oauth", model: "gpt-5.6-sol"},
    %{id: "seat_xai", provider: "xai_oauth", model: "grok-4.6"}
  ]

  defp avail(list), do: fn p -> p in list end

  test "passes when every seat runs on its preferred provider" do
    panel = Core.assess(@seats, avail(["ollama", "openai_oauth", "xai_oauth"]), %{}, @generic)

    assert panel.status == :passed
    assert panel.total == 4 and panel.preferred == 4
    assert panel.distinct_providers == 3
    assert Core.message(panel) =~ "All 4 review seats"
  end

  test "degrades with fallback seats when a provider is missing but a fallback exists" do
    panel = Core.assess(@seats, avail(["openai_oauth", "xai_oauth"]), %{}, @generic)

    assert panel.status == :degraded
    assert panel.fallback == 2 and panel.unresolved == 0
    assert panel.distinct_providers == 2

    assert Enum.find(panel.seats, &(&1.id == "seat_ollama_a")).resolved ==
             {"openai_oauth", "gpt-5.6-sol"}

    assert Core.message(panel) =~ "2 fall back (seat_ollama_a, seat_ollama_b)"
    assert Core.remedy(panel) =~ "preferred providers"
  end

  test "degrades with abstaining seats when nothing in the chain is available" do
    panel = Core.assess(@seats, avail(["xai_oauth"]), %{}, [])

    assert panel.status == :degraded
    assert panel.unresolved == 3 and panel.preferred == 1
    assert panel.distinct_providers == 1
    assert Core.message(panel) =~ "3 will abstain"
    assert Core.message(panel) =~ "1 distinct provider(s) will vote"
    assert Core.remedy(panel) =~ "llm_fallback_providers"
  end

  test "a graph with no seats is degraded, never passed" do
    panel = Core.assess([], avail(["xai_oauth"]), %{}, @generic)
    assert panel.status == :degraded and panel.total == 0
    assert Core.message(panel) =~ "declares no seats"
  end

  test "malformed seats are ignored rather than raised" do
    seats = [%{id: "", provider: "ollama"}, %{id: "x", provider: nil}, :junk | @seats]
    panel = Core.assess(seats, avail(["ollama", "openai_oauth", "xai_oauth"]), %{}, @generic)
    assert panel.total == 4
  end
end
