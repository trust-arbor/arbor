defmodule Arbor.Orchestrator.HeartbeatRefresherTest do
  @moduledoc """
  Tests `HeartbeatRefresher.with_heartbeat_refresh/3` — the wrapper
  that keeps a pipeline's heartbeat fresh during long-blocking calls
  (long reasoning LLMs, HITL approval waits, etc.).

  Exercises `PipelineStatus.touch_heartbeat/1` through the refresher.
  Journal/ticker failures are swallowed so the wrapped fun still returns.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.HeartbeatRefresher

  describe "with_heartbeat_refresh/3" do
    test "no-op when run_id is nil — fun runs directly, returns its result" do
      result = HeartbeatRefresher.with_heartbeat_refresh(nil, fn -> :the_return end)
      assert result == :the_return
    end

    test "returns fun's result unchanged when run_id is set" do
      result =
        HeartbeatRefresher.with_heartbeat_refresh(
          "test_run_x",
          fn -> {:ok, "hi"} end,
          interval_ms: 10_000
        )

      assert result == {:ok, "hi"}
    end

    test "exception from fun propagates; ticker is cleaned up via after" do
      # Capture ticker pid via a side channel — the test process sees
      # the spawn message under :trace. Use a small fixture instead.
      assert_raise RuntimeError, "boom", fn ->
        HeartbeatRefresher.with_heartbeat_refresh(
          "test_run_explosion",
          fn -> raise "boom" end,
          # Long enough that the ticker doesn't actually fire — we're
          # only validating the after-clause cleanup
          interval_ms: 60_000
        )
      end

      # Brief settle window for ticker process to exit
      Process.sleep(50)

      # Find any orphan ticker processes by enumerating running
      # processes still in tick_loop — we don't expect any.

      orphans =
        Process.list()
        |> Enum.filter(fn pid ->
          case Process.info(pid, [:current_function, :initial_call]) do
            nil ->
              false

            info ->
              info[:current_function] ==
                {Arbor.Orchestrator.HeartbeatRefresher, :tick_loop, 2}
          end
        end)

      assert orphans == [], "orphan ticker(s) survived after exception: #{inspect(orphans)}"
    end

    test "fun returns even when touch_heartbeat errors are swallowed" do
      # The ticker rescues + catches errors from PipelineStatus.touch_heartbeat.
      # Ticks should silently fail if the journal is unavailable; fun still returns.
      result =
        HeartbeatRefresher.with_heartbeat_refresh(
          "test_run_no_registry",
          fn ->
            Process.sleep(80)
            :ok
          end,
          # Force at least one tick during the 80ms sleep
          interval_ms: 30
        )

      assert result == :ok
    end
  end
end
