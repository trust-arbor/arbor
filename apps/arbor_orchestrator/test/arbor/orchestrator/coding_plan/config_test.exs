defmodule Arbor.Orchestrator.CodingPlan.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Config

  defmodule InjectedCompiler do
  end

  defmodule InjectedArtifactStore do
  end

  @keys [:coding_plan_compiler, :coding_plan_artifact_store]

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
end
