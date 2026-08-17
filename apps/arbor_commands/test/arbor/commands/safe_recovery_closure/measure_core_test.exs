defmodule Arbor.Commands.SafeRecoveryClosure.MeasureCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryClosure.MeasureCore

  @moduletag :fast

  test "walks the fixed one-build hold order then returns the measurement" do
    assert MeasureCore.steps() == [
             :stage_source,
             :acquire_build,
             {:run_phase, "deps_get"},
             :stage_native,
             :inventory_deps,
             {:run_phase, "compile"},
             {:run_phase, "release"},
             :remove_cookie,
             :inventory_release,
             :pin_root,
             :measure
           ]

    state = MeasureCore.init()
    measurement = %{"shutdown" => %{"status" => "bounded", "remaining_names" => []}}

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

    assert {:ok, ^measurement} = play(state, replies)
  end

  test "fails closed on a failed phase before measure" do
    state = MeasureCore.init()

    replies = %{
      :stage_source => {:ok, %{"identity" => "src"}},
      :acquire_build => {:ok, :handle},
      {:run_phase, "deps_get"} => {:ok, %{exit_code: 1, timed_out: false, killed: false}}
    }

    assert {:error, {:trusted_build_phase_failed, "deps_get", _}} = play(state, replies)
  end

  defp play(state, replies) do
    case MeasureCore.next(state) do
      {:done, result} ->
        result

      {:error, _} = error ->
        error

      {:effect, step, next} ->
        raw = Map.get(replies, step, {:error, :missing_fact})

        case MeasureCore.step_result(next, step, raw) do
          {:ok, state2} -> play(state2, replies)
          {:error, _} = error -> error
        end
    end
  end
end
