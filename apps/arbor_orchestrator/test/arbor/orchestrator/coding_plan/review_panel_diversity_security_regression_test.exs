defmodule Arbor.Orchestrator.CodingPlan.ReviewPanelDiversitySecurityRegressionTest do
  @moduledoc """
  Security regression for correlated review-panel monitors
  (arxiv.org/abs/2610.29178, Exposure Check group P).

  Binding council decisions require a minimum number of distinct
  `provider:model` seats. A panel that collapses onto one model, or that is
  degraded by fallback/unresolved seats, may still vote — but those votes
  are not binding.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Orchestrator.CodingPlan.ReviewPanelCore, as: Core

  defp avail(list), do: fn p -> p in list end

  test "security regression: 3 seats on the same model fail the diversity check" do
    seats = [
      %{id: "seat_a", provider: "openai_oauth", model: "gpt-5.6-sol"},
      %{id: "seat_b", provider: "openai_oauth", model: "gpt-5.6-sol"},
      %{id: "seat_c", provider: "openai_oauth", model: "gpt-5.6-sol"}
    ]

    panel = Core.assess(seats, avail(["openai_oauth"]), %{}, [])

    assert panel.distinct_provider_models == 1
    assert panel.diversity == :insufficient
    refute panel.binding
  end

  test "security regression: a degraded panel returns non-binding" do
    seats = [
      %{id: "seat_ollama", provider: "ollama", model: "kimi-k2.7-code:cloud"},
      %{id: "seat_openai", provider: "openai_oauth", model: "gpt-5.6-sol"},
      %{id: "seat_xai", provider: "xai_oauth", model: "grok-4.6"}
    ]

    generic = [{"openai_oauth", "gpt-5.6-sol"}]

    panel = Core.assess(seats, avail(["openai_oauth"]), %{}, generic)

    assert panel.status == :degraded
    refute panel.binding
  end
end
