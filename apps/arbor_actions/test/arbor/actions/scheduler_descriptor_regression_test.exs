defmodule Arbor.Actions.SchedulerDescriptorRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "security regression: routine listing has an admissible read descriptor" do
    assert {:ok, descriptor} =
             Arbor.Actions.runtime_descriptor(Arbor.Actions.Scheduler.ListRoutines)

    assert descriptor["effect_class"] == "read"
    assert descriptor["name"] == "scheduler_list_routines"
  end
end
