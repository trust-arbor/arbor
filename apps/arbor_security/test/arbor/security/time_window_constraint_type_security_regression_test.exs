defmodule Arbor.Security.TimeWindowConstraintTypeSecurityRegressionTest do
  @moduledoc """
  Security regression: a `time_window` constraint whose hours are not integers
  must deny, not allow.

  `evaluate_time_window/1` compared the current hour with `start_hour` and
  `end_hour` without checking their types. Under Erlang term order every
  integer sorts below every binary, so `%{start_hour: "22", end_hour: "06"}`
  took the midnight-wrapping branch and `current_hour < "06"` was always true:
  the window allowed every hour. A grant built from string input therefore
  carried a time restriction that never applied.
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Security.Constraint

  @principal "agent_time_window_type_regression"
  @resource "arbor://fs/read/project/src/main.ex"

  test "security regression: string hours in a wrapping window deny at every hour" do
    constraints = %{time_window: %{start_hour: "22", end_hour: "06"}}

    assert {:error, {:constraint_violated, :time_window, context}} =
             Constraint.enforce(constraints, @principal, @resource)

    assert context.reason == :invalid_time_window
  end

  test "security regression: non-integer or out-of-range hours deny" do
    for window <- [
          %{start_hour: "09", end_hour: "17"},
          %{start_hour: 9.0, end_hour: 17},
          %{start_hour: 0, end_hour: :end_of_day},
          %{start_hour: -1, end_hour: 6},
          %{start_hour: 22, end_hour: 25}
        ] do
      assert {:error, {:constraint_violated, :time_window, %{reason: :invalid_time_window}}} =
               Constraint.enforce(%{time_window: window}, @principal, @resource),
             "expected #{inspect(window)} to be refused"
    end
  end

  test "integer windows keep their meaning" do
    assert :ok =
             Constraint.enforce(
               %{time_window: %{start_hour: 0, end_hour: 24}},
               @principal,
               @resource
             )

    hour = DateTime.utc_now().hour
    closed = %{start_hour: rem(hour + 1, 24), end_hour: rem(hour + 2, 24)}

    if closed.start_hour < closed.end_hour do
      assert {:error, {:constraint_violated, :time_window, _}} =
               Constraint.enforce(%{time_window: closed}, @principal, @resource)
    end
  end
end
