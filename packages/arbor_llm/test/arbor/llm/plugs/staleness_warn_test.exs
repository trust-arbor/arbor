defmodule Arbor.LLM.Plugs.StalenessWarnTest do
  @moduledoc """
  Tests for `Plugs.StalenessWarn`. The plug:

    * Warns when a replayed fixture is older than the configured
      `:fixture_max_age_days` (default 90).
    * Stays silent for fresh fixtures.
    * Stays silent for non-replayed calls (live LLM hits don't
      have `replayed_from` metadata).
    * Never modifies the call.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  import ExUnit.CaptureLog

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.StalenessWarn

  setup do
    original = Application.get_env(:arbor_llm, :fixture_max_age_days)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:arbor_llm, :fixture_max_age_days)
        v -> Application.put_env(:arbor_llm, :fixture_max_age_days, v)
      end
    end)

    :ok
  end

  describe "StalenessWarn.call/1 — replayed fixture older than max age" do
    test "emits a Logger.warning that names the path and age" do
      Application.put_env(:arbor_llm, :fixture_max_age_days, 10)

      old_ts = DateTime.add(DateTime.utc_now(), -50, :day)

      call =
        :complete
        |> Call.new({})
        |> Call.put_metadata(%{replayed_from: "/tmp/x.json", recorded_at: old_ts})

      log =
        capture_log(fn ->
          StalenessWarn.call(call)
        end)

      assert log =~ "LLM fixture is"
      assert log =~ "50 days old"
      assert log =~ "max: 10"
      assert log =~ "/tmp/x.json"
    end

    test "returns the call unchanged" do
      Application.put_env(:arbor_llm, :fixture_max_age_days, 10)

      old_ts = DateTime.add(DateTime.utc_now(), -50, :day)

      call =
        :complete
        |> Call.new({})
        |> Call.put_metadata(%{replayed_from: "/tmp/x.json", recorded_at: old_ts})
        |> Call.assign(:tag, "preserved")

      result =
        capture_log(fn ->
          send(self(), {:result, StalenessWarn.call(call)})
        end)

      _ = result
      assert_received {:result, returned}
      assert returned.assigns.tag == "preserved"
      assert returned.metadata.replayed_from == "/tmp/x.json"
    end
  end

  describe "StalenessWarn.call/1 — fresh replayed fixture" do
    test "stays silent" do
      Application.put_env(:arbor_llm, :fixture_max_age_days, 90)

      recent_ts = DateTime.add(DateTime.utc_now(), -3, :day)

      call =
        :complete
        |> Call.new({})
        |> Call.put_metadata(%{replayed_from: "/tmp/x.json", recorded_at: recent_ts})

      log = capture_log(fn -> StalenessWarn.call(call) end)
      refute log =~ "LLM fixture is"
    end
  end

  describe "StalenessWarn.call/1 — no replay metadata (live call)" do
    test "stays silent" do
      call = Call.new(:complete, {})
      log = capture_log(fn -> StalenessWarn.call(call) end)
      refute log =~ "LLM fixture"
    end
  end

  describe "StalenessWarn.call/1 — halted call" do
    test "STILL fires on halted calls — observability is the point" do
      # StalenessWarn is the canonical observability plug. Replay halts
      # the pipeline after loading a fixture, but the staleness warning
      # is precisely what we want to emit at that point. So no halted
      # short-circuit here.
      Application.put_env(:arbor_llm, :fixture_max_age_days, 10)
      old_ts = DateTime.add(DateTime.utc_now(), -50, :day)

      call =
        :complete
        |> Call.new({})
        |> Call.put_metadata(%{replayed_from: "/tmp/x.json", recorded_at: old_ts})
        |> Call.halt()

      log = capture_log(fn -> StalenessWarn.call(call) end)
      assert log =~ "LLM fixture is"
      assert log =~ "50 days old"
    end
  end
end
