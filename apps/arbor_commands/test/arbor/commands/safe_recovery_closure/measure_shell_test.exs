defmodule Arbor.Commands.SafeRecoveryClosure.MeasureShellTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryClosure.MeasureShell

  @moduletag :fast

  test "fact interpreter returns the canned measurement and clears the ledger" do
    measurement = %{
      "pre_start" => %{},
      "post_start" => %{},
      "shutdown" => %{"status" => "bounded", "remaining_names" => []}
    }

    replies = %{
      :stage_source => {:ok, %{"identity" => "src"}},
      :acquire_build => {:ok, :handle},
      {:run_phase, "deps_get"} => {:ok, %{exit_code: 0, timed_out: false, killed: false}},
      :stage_native => {:ok, %{}},
      :inventory_deps => {:ok, %{}},
      {:run_phase, "compile"} => {:ok, %{exit_code: 0, timed_out: false, killed: false}},
      {:run_phase, "release"} => {:ok, %{exit_code: 0, timed_out: false, killed: false}},
      :remove_cookie => {:ok, %{}},
      :inventory_release => {:ok, %{}},
      :pin_root => {:ok, "/private/tmp/rel/arbor_trust"},
      :measure => {:ok, measurement}
    }

    assert {:ok, ^measurement} = MeasureShell.measure_from_facts_for_test(%{replies: replies})
    assert Process.get({MeasureShell, :ledger}) == nil
  end

  test "fact interpreter fails closed on a missing step" do
    assert {:error, :missing_fact} =
             MeasureShell.measure_from_facts_for_test(%{replies: %{}})
  end
end
