defmodule Arbor.Orchestrator.CodingPlan.ReviewPanelTest do
  # Not async: swaps the app-env availability seam.
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.ReviewPanel

  setup do
    previous = Application.get_env(:arbor_orchestrator, :llm_provider_availability)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_orchestrator, :llm_provider_availability),
        else: Application.put_env(:arbor_orchestrator, :llm_provider_availability, previous)
    end)

    :ok
  end

  test "the reviewed council graph exposes provider-pinned seats" do
    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn _ -> true end)

    assert {:ok, panel} = ReviewPanel.observe(nil)
    assert panel.total >= 2
    assert panel.status == :passed
    assert Enum.all?(panel.seats, &is_binary(&1.id))
  end

  test "an unavailable provider degrades the panel via the host fallback table" do
    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn p ->
      p in ["openai_oauth", "xai_oauth"]
    end)

    assert {:ok, panel} = ReviewPanel.observe(nil)
    assert panel.status in [:passed, :degraded]

    # Every seat either kept its provider (available) or resolved into the
    # fallback table; only seats whose chain is empty may abstain.
    for seat <- panel.seats, seat.outcome == :fallback do
      assert elem(seat.resolved, 0) in ["openai_oauth", "xai_oauth"]
    end
  end
end
