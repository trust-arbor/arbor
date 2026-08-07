defmodule Arbor.Actions.SessionMemoryBackgroundChecksTest do
  @moduledoc """
  Guards the memory learning producer and, in particular, the telemetry →
  `ActionPatterns.action()` adapter.

  Audit finding F1: `heartbeat.dot` called `background_checks_run`, which
  resolved to a Claude Code harness diagnostic of the same name, while
  `Arbor.Memory.BackgroundChecks.run/2` — the actual learning producer — had
  zero non-test callers. So `:learning`, `:insight` and `:preconscious`
  proposals were never produced at runtime.

  Wiring the checks alone would not have been enough: `check_action_patterns/2`
  needs `:action_history` and returns nothing below five entries, so it would
  have been a producer that produces nothing. These tests pin the shape
  conversion that makes the history usable.
  """

  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.SessionMemory.BackgroundChecks

  @moduletag :fast

  defp event(tool, result, timestamp) do
    %{
      id: "tevt_#{System.unique_integer([:positive])}",
      agent_id: "a",
      event_type: "tool_call",
      timestamp: timestamp,
      data: %{"tool_name" => tool, "result" => result, "duration_ms" => 5}
    }
  end

  describe "telemetry -> ActionPatterns.action/0 adapter" do
    test "renames tool_name and produces the three required keys" do
      [action] =
        BackgroundChecks.to_action_history([event("fs.read", "ok", ~N[2026-08-06 12:00:00])])

      assert %{tool: "fs.read", status: :success, timestamp: %DateTime{}} = action
      assert Map.keys(action) |> Enum.sort() == [:status, :timestamp, :tool]
    end

    test "NaiveDateTime is converted — ActionPatterns calls DateTime.diff/3" do
      # telemetry_events rows come back naive; DateTime.diff/3 raises on those,
      # so a missing conversion would blow up inside pattern detection rather
      # than return no patterns.
      [%{timestamp: ts}] =
        BackgroundChecks.to_action_history([event("x", "ok", ~N[2026-08-06 12:00:00])])

      assert %DateTime{} = ts
      assert ts.time_zone == "Etc/UTC"
      assert DateTime.diff(ts, ts, :second) == 0
    end

    test "an existing DateTime passes through unchanged" do
      dt = ~U[2026-08-06 12:00:00Z]
      assert [%{timestamp: ^dt}] = BackgroundChecks.to_action_history([event("x", "ok", dt)])
    end

    test "record_tool's :ok maps to :success, not passed through" do
      # ActionPatterns matches on :success | :error. Leaving :ok in place would
      # make every call look like a failure to detect_failure_then_success/1.
      for ok <- ["ok", :ok, "success", :success] do
        assert [%{status: :success}] =
                 BackgroundChecks.to_action_history([event("t", ok, ~N[2026-08-06 12:00:00])])
      end
    end

    test "errors and gated calls are both failures" do
      for bad <- ["error", :error, "gated", :gated] do
        assert [%{status: :error}] =
                 BackgroundChecks.to_action_history([event("t", bad, ~N[2026-08-06 12:00:00])])
      end
    end

    test "unusable events are dropped rather than crashing the beat" do
      events = [
        event("good", "ok", ~N[2026-08-06 12:00:00]),
        %{data: %{"result" => "ok"}, timestamp: ~N[2026-08-06 12:00:01]},
        %{data: %{"tool_name" => "no_ts"}, timestamp: nil},
        %{not_an_event: true},
        "garbage"
      ]

      assert [%{tool: "good"}] = BackgroundChecks.to_action_history(events)
    end

    test "order is preserved — sequence detection depends on it" do
      tools =
        BackgroundChecks.to_action_history([
          event("a", "ok", ~N[2026-08-06 12:00:00]),
          event("b", "ok", ~N[2026-08-06 12:00:01]),
          event("c", "ok", ~N[2026-08-06 12:00:02])
        ])
        |> Enum.map(& &1.tool)

      assert tools == ["a", "b", "c"]
    end
  end

  describe "run/2" do
    test "returns the context keys the heartbeat node publishes" do
      agent_id = "bgchecks_#{System.unique_integer([:positive])}"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)

      assert {:ok, out} = BackgroundChecks.run(%{agent_id: agent_id}, %{})

      assert Map.has_key?(out, :background_suggestions)
      assert Map.has_key?(out, :background_warnings)
      assert Map.has_key?(out, :background_actions)
      assert is_integer(out.action_history_count)
    end

    test "reads the session.-prefixed key the DOT node supplies" do
      agent_id = "bgchecks_ctx_#{System.unique_integer([:positive])}"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)

      assert {:ok, out} = BackgroundChecks.run(%{"session.agent_id" => agent_id}, %{})
      assert is_list(out.background_suggestions)
    end

    test "a missing agent_id is an explicit error" do
      assert {:error, :missing_agent_id} = BackgroundChecks.run(%{}, %{})
    end

    test "an unavailable telemetry store degrades to an empty history, not a crash" do
      # query_events/2 now returns {:error, :repo_unavailable} rather than an
      # empty list; the beat must still complete.
      agent_id = "bgchecks_notelem_#{System.unique_integer([:positive])}"
      {:ok, _} = Arbor.Memory.init_for_agent(agent_id)
      on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)

      assert {:ok, out} = BackgroundChecks.run(%{agent_id: agent_id}, %{})
      assert out.action_history_count >= 0
    end
  end
end
