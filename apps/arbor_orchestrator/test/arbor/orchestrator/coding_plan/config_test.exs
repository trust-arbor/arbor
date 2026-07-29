defmodule Arbor.Orchestrator.CodingPlan.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Config

  defmodule InjectedCompiler do
  end

  defmodule InjectedArtifactStore do
  end

  @keys [
    :coding_plan_compiler,
    :coding_plan_artifact_store,
    :coding_reconciliation_observer_module,
    :coding_reconciliation_clock,
    :coding_reconciliation_shell_facade,
    :coding_approval_timeout_ms
  ]

  setup do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:arbor_orchestrator, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_orchestrator, key, value)
        {key, :error} -> Application.delete_env(:arbor_orchestrator, key)
      end)
    end)

    Enum.each(@keys, &Application.delete_env(:arbor_orchestrator, &1))

    :ok
  end

  test "coding plan modules use trusted production defaults" do
    assert Config.coding_plan_compiler() == Arbor.Orchestrator.CodingPlan.Compiler

    assert Config.coding_plan_artifact_store() ==
             Arbor.Orchestrator.CodingPlan.ArtifactStore
  end

  test "coding plan modules support trusted Application config injection" do
    Application.put_env(:arbor_orchestrator, :coding_plan_compiler, InjectedCompiler)

    Application.put_env(
      :arbor_orchestrator,
      :coding_plan_artifact_store,
      InjectedArtifactStore
    )

    assert Config.coding_plan_compiler() == InjectedCompiler
    assert Config.coding_plan_artifact_store() == InjectedArtifactStore
  end

  test "reconciliation observation and clock seams are not public data options" do
    refute is_map(Config.coding_reconciliation_observer_module())
    assert Config.coding_reconciliation_clock() == nil
    assert Config.coding_reconciliation_shell_facade() == Arbor.Shell
  end

  describe "coding_interaction_wait_ms/1" do
    test "absent operator config uses the full effective wall with no five-minute ceiling" do
      assert Config.coding_approval_operator_timeout_ms() == :none
      assert Config.coding_interaction_wait_ms(900_000) == 900_000
      assert Config.coding_interaction_wait_ms(20) == 20
    end

    test "invalid operator config is ignored and does not impose a five-minute ceiling" do
      for invalid <- [0, -1, "fast", :fast, 1.5, nil] do
        Application.put_env(:arbor_orchestrator, :coding_approval_timeout_ms, invalid)
        assert Config.coding_approval_operator_timeout_ms() == :none
        assert Config.coding_interaction_wait_ms(900_000) == 900_000
      end
    end

    test "explicit positive operator config shortens but cannot widen beyond the wall" do
      Application.put_env(:arbor_orchestrator, :coding_approval_timeout_ms, 60_000)
      assert Config.coding_approval_operator_timeout_ms() == {:ok, 60_000}
      assert Config.coding_interaction_wait_ms(900_000) == 60_000
      assert Config.coding_interaction_wait_ms(20_000) == 20_000

      Application.put_env(:arbor_orchestrator, :coding_approval_timeout_ms, 2_000_000)
      assert Config.coding_interaction_wait_ms(900_000) == 900_000
    end
  end
end
