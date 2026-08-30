defmodule Arbor.Orchestrator.CodingPlan.SteeringEligibilityCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.SteeringEligibilityCore

  @targets [nil, "design", "implement", "validate", "review", "unknown"]

  test "unknown phase holds every admitted target including nil and design" do
    for target <- @targets do
      assert SteeringEligibilityCore.decide(target, :unknown) == :ineligible
      assert SteeringEligibilityCore.decide(target, :bogus) == :ineligible
    end
  end

  test "design phase allows only nil and exact design refinement" do
    assert SteeringEligibilityCore.decide(nil, :design) == :eligible
    assert SteeringEligibilityCore.decide("design", :design) == :eligible

    for target <- ["implement", "validate", "review", "unknown"] do
      assert SteeringEligibilityCore.decide(target, :design) == :ineligible
    end
  end

  test "implement phase admits every well-formed target" do
    for target <- @targets do
      assert SteeringEligibilityCore.decide(target, :implement) == :eligible
    end
  end
end
