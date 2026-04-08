defmodule Arbor.Dashboard.Cores.EventsCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.EventsCore

  @moduletag :fast

  defp sample_event do
    %{
      id: "evt_001",
      type: :agent_started,
      category: :agent,
      stream_id: "agents",
      timestamp: ~U[2026-04-07 12:00:00Z],
      data: %{agent_id: "agent_42", name: "Diagnostician", model: "claude"}
    }
  end

  describe "show_event/1" do
    test "shapes an event with subtitle and data summary" do
      result = EventsCore.show_event(sample_event())
      assert result.id == "evt_001"
      assert result.type == :agent_started
      assert result.category == :agent
      assert result.stream_id == "agents"
      assert is_binary(result.subtitle)
      assert is_binary(result.data_summary)
    end

    test "tolerates missing fields" do
      result = EventsCore.show_event(%{})
      assert result.id == nil
      assert result.data == %{}
      assert result.data_summary == "(empty)"
    end
  end

  describe "format_event_subtitle/1" do
    test "joins agent, stream, and data summary with pipes" do
      result = EventsCore.format_event_subtitle(sample_event())
      assert result =~ "agent: agent_42"
      assert result =~ "stream: agents"
      assert result =~ "agent_id"
    end

    test "skips agent when missing" do
      event = %{stream_id: "x", data: %{foo: "bar"}}
      result = EventsCore.format_event_subtitle(event)
      refute result =~ "agent:"
      assert result =~ "stream: x"
    end

    test "skips stream when 'unknown'" do
      event = %{stream_id: "unknown", data: %{foo: "bar"}}
      result = EventsCore.format_event_subtitle(event)
      refute result =~ "stream:"
    end

    test "tolerates missing data" do
      result = EventsCore.format_event_subtitle(%{})
      assert result == "(empty)"
    end
  end

  describe "format_data_summary/1" do
    test "shows '(empty)' for empty map" do
      assert EventsCore.format_data_summary(%{}) == "(empty)"
    end

    test "shows up to 3 key:value pairs, truncated" do
      data = %{a: 1, b: 2, c: 3, d: 4, e: 5}
      result = EventsCore.format_data_summary(data)
      assert is_binary(result)
      assert String.length(result) <= 63
    end

    test "tolerates non-map" do
      assert EventsCore.format_data_summary(nil) == "(empty)"
      assert EventsCore.format_data_summary("string") == "(empty)"
    end
  end

  describe "format_json/1" do
    test "encodes data as pretty JSON" do
      result = EventsCore.format_json(%{key: "value"})
      assert is_binary(result)
      assert result =~ "key"
      assert result =~ "value"
    end

    test "falls back to inspect for non-JSON-encodable data" do
      result = EventsCore.format_json({:tuple, "value"})
      assert is_binary(result)
    end
  end

  describe "time_label/1" do
    test "maps known time filters" do
      assert EventsCore.time_label(:all) == "All time"
      assert EventsCore.time_label(:hour) == "Last hour"
      assert EventsCore.time_label(:today) == "Today"
    end

    test "passes through unknown values" do
      assert EventsCore.time_label(:weird) == "weird"
    end
  end

  describe "matches_agent?/2" do
    test "matches event with agent_id substring" do
      event = %{data: %{agent_id: "agent_diagnostician_42"}}
      assert EventsCore.matches_agent?(event, "diagnostician")
    end

    test "matches string-keyed agent_id" do
      event = %{data: %{"agent_id" => "agent_42"}}
      assert EventsCore.matches_agent?(event, "42")
    end

    test "returns false when no agent_id" do
      assert EventsCore.matches_agent?(%{data: %{}}, "any")
             |> Kernel.==(false)
    end

    test "returns false for non-matching substring" do
      event = %{data: %{agent_id: "agent_other"}}
      refute EventsCore.matches_agent?(event, "missing")
    end
  end

  describe "default_stats/0" do
    test "returns zero stream_count and total_events" do
      assert EventsCore.default_stats() == %{stream_count: 0, total_events: 0}
    end
  end
end
