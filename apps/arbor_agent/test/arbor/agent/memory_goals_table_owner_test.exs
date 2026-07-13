defmodule Arbor.Agent.Test.MemoryGoalsTableOwnerTest do
  @moduledoc """
  Fixture ownership for the test-only `:arbor_memory_goals` ETS owner.

  Proves the suite-start helper leaves a usable named table without relying on
  an unsupervised forever-sleeping process.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  @table :arbor_memory_goals
  @owner Arbor.Agent.Test.MemoryGoalsTableOwner

  test "test_helper provides :arbor_memory_goals without an unsupervised sleeper" do
    assert :ets.whereis(@table) != :undefined

    case Process.whereis(@owner) do
      pid when is_pid(pid) ->
        assert Process.alive?(pid)
        # Idempotent: named GenServer cannot be double-started.
        assert {:error, {:already_started, ^pid}} = @owner.start_link([])

        # Owner is under the app supervisor — not a linked forever-sleeper.
        children = Supervisor.which_children(Arbor.Agent.AppSupervisor)

        assert Enum.any?(children, fn
                 {id, ^pid, :worker, modules} ->
                   id == @owner or modules == [@owner]

                 _ ->
                   false
               end)

      nil ->
        # Table may already be owned by a live GoalStore / other fixture.
        # Still require the named table; no orphan sleeper is required.
        assert :ets.whereis(@table) != :undefined
    end
  end
end
