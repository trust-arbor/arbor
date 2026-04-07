defmodule Arbor.Dashboard.Cores.SignalsCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.SignalsCore

  @moduletag :fast

  defp sample_signal do
    %{
      id: "sig_001",
      type: :agent_started,
      category: :agent,
      timestamp: DateTime.utc_now(),
      data: %{agent_id: "agent_42", model: "claude"}
    }
  end

  describe "show_signal/1" do
    test "shapes a signal with time and data summary" do
      result = SignalsCore.show_signal(sample_signal())
      assert result.id == "sig_001"
      assert result.type == :agent_started
      assert result.category == :agent
      assert is_binary(result.time_label)
      assert is_binary(result.data_summary)
    end

    test "tolerates missing fields" do
      result = SignalsCore.show_signal(%{})
      assert result.data == %{}
      assert result.data_summary == "(empty)"
      assert result.time_label == "-"
    end
  end

  describe "time_label/1" do
    test "maps known filters" do
      assert SignalsCore.time_label(:all) == "All time"
      assert SignalsCore.time_label(:hour) == "Last hour"
      assert SignalsCore.time_label(:today) == "Today"
    end

    test "passes through unknown" do
      assert SignalsCore.time_label(:weird) == "weird"
    end
  end

  describe "matches_time?/2" do
    test ":all matches anything" do
      assert SignalsCore.matches_time?(%{timestamp: DateTime.utc_now()}, :all)
      old_signal = %{timestamp: DateTime.add(DateTime.utc_now(), -1_000_000, :second)}
      assert SignalsCore.matches_time?(old_signal, :all)
    end

    test ":hour matches signals within an hour" do
      recent = %{timestamp: DateTime.add(DateTime.utc_now(), -100, :second)}
      old = %{timestamp: DateTime.add(DateTime.utc_now(), -7200, :second)}
      assert SignalsCore.matches_time?(recent, :hour)
      refute SignalsCore.matches_time?(old, :hour)
    end

    test ":today matches signals within a day" do
      recent = %{timestamp: DateTime.add(DateTime.utc_now(), -3600, :second)}
      old = %{timestamp: DateTime.add(DateTime.utc_now(), -90_000, :second)}
      assert SignalsCore.matches_time?(recent, :today)
      refute SignalsCore.matches_time?(old, :today)
    end
  end

  describe "matches_agent?/2" do
    test "nil filter matches everything" do
      assert SignalsCore.matches_agent?(sample_signal(), nil)
    end

    test "matches substring in agent_id" do
      signal = %{data: %{agent_id: "agent_diagnostician_42"}}
      assert SignalsCore.matches_agent?(signal, "diagnostician")
    end

    test "matches string-keyed agent_id" do
      signal = %{data: %{"agent_id" => "agent_42"}}
      assert SignalsCore.matches_agent?(signal, "42")
    end

    test "returns false for non-matching" do
      signal = %{data: %{agent_id: "agent_other"}}
      refute SignalsCore.matches_agent?(signal, "missing")
    end

    test "returns false when no agent_id present" do
      refute SignalsCore.matches_agent?(%{data: %{}}, "any")
    end
  end

  describe "format_signal_data/1" do
    test "shows '(empty)' for empty map and non-map" do
      assert SignalsCore.format_signal_data(%{}) == "(empty)"
      assert SignalsCore.format_signal_data(nil) == "(empty)"
    end

    test "shows up to 3 key:value pairs" do
      result = SignalsCore.format_signal_data(%{a: 1, b: 2, c: 3, d: 4})
      assert is_binary(result)
      assert String.length(result) <= 83
    end
  end

  describe "format_signal_json/1" do
    test "encodes maps as pretty JSON" do
      result = SignalsCore.format_signal_json(%{key: "value"})
      assert result =~ "key"
      assert result =~ "value"
    end

    test "falls back to inspect for tuples" do
      result = SignalsCore.format_signal_json({:tuple, "x"})
      assert is_binary(result)
    end
  end

  describe "format_time/1" do
    test "formats DateTime as HH:MM:SS" do
      dt = ~U[2026-04-07 14:30:45Z]
      assert SignalsCore.format_time(dt) == "14:30:45"
    end

    test "formats NaiveDateTime as HH:MM:SS" do
      ndt = ~N[2026-04-07 09:15:30]
      assert SignalsCore.format_time(ndt) == "09:15:30"
    end

    test "handles nil and other input" do
      assert SignalsCore.format_time(nil) == "-"
      assert SignalsCore.format_time("garbage") == "-"
    end
  end

  describe "default_stats/0" do
    test "returns zero/false defaults" do
      stats = SignalsCore.default_stats()
      assert stats.current_count == 0
      assert stats.active_subscriptions == 0
      refute stats.healthy
    end
  end
end
