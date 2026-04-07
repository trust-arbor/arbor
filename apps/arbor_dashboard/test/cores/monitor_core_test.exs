defmodule Arbor.Dashboard.Cores.MonitorCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.MonitorCore

  @moduletag :fast

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp sample_metrics do
    %{
      memory: %{total_mb: 1024, processes_mb: 256, system_mb: 512},
      processes: %{count: 437},
      ets: %{table_count: 89},
      scheduler: %{total_utilization: 12},
      gc: %{total_collections: 50_000}
    }
  end

  defp sample_anomalies do
    [
      %{
        severity: :warning,
        metric: "memory.total_mb",
        value: 8000,
        baseline: 4000,
        deviation: 2.5,
        detected_at: ~U[2026-04-07 12:00:00Z]
      }
    ]
  end

  defp sample_status do
    %{
      status: :healthy,
      anomaly_count: 1,
      skills: [:memory, :processes, :ets, :scheduler, :gc],
      metrics_available: [:memory, :processes, :ets, :scheduler, :gc]
    }
  end

  # ── Construct ────────────────────────────────────────────────────────

  describe "new/3" do
    test "builds initial state from raw monitor data" do
      state = MonitorCore.new(sample_metrics(), sample_anomalies(), sample_status())

      assert state.metrics == sample_metrics()
      assert state.anomalies == sample_anomalies()
      assert state.status.status == :healthy
      assert state.selected_skill == nil
      assert state.history == %{}
    end

    test "tolerates nil inputs" do
      state = MonitorCore.new(nil, nil, nil)

      assert state.metrics == %{}
      assert state.anomalies == []
      assert state.status.status == :unknown
      assert state.status.skills == []
    end
  end

  # ── Reduce ───────────────────────────────────────────────────────────

  describe "select_skill/2" do
    test "selects a skill when nothing is selected" do
      state = MonitorCore.new(sample_metrics(), [], sample_status())
      assert MonitorCore.select_skill(state, :memory).selected_skill == :memory
    end

    test "toggles off when selecting the same skill twice" do
      state =
        sample_metrics()
        |> MonitorCore.new([], sample_status())
        |> MonitorCore.select_skill(:memory)
        |> MonitorCore.select_skill(:memory)

      assert state.selected_skill == nil
    end

    test "switches selection when given a different skill" do
      state =
        sample_metrics()
        |> MonitorCore.new([], sample_status())
        |> MonitorCore.select_skill(:memory)
        |> MonitorCore.select_skill(:processes)

      assert state.selected_skill == :processes
    end
  end

  describe "append_history/2" do
    test "appends primary values per skill" do
      state =
        MonitorCore.new(%{}, [], sample_status())
        |> MonitorCore.append_history(sample_metrics())

      assert state.history.memory == [1024]
      assert state.history.processes == [437]
      assert state.history.ets == [89]
    end

    test "bounds history at 20 entries per skill" do
      state =
        Enum.reduce(1..30, MonitorCore.new(%{}, [], sample_status()), fn n, acc ->
          MonitorCore.append_history(acc, %{memory: %{total_mb: n}})
        end)

      assert length(state.history.memory) == 20
      # Most recent value first (30, 29, 28, ... 11)
      assert hd(state.history.memory) == 30
      assert List.last(state.history.memory) == 11
    end
  end

  describe "update_data/4" do
    test "replaces data while preserving selection and accumulating history" do
      state =
        sample_metrics()
        |> MonitorCore.new([], sample_status())
        |> MonitorCore.select_skill(:memory)

      new_metrics = %{memory: %{total_mb: 2048}, processes: %{count: 500}}
      updated = MonitorCore.update_data(state, new_metrics, [], sample_status())

      assert updated.selected_skill == :memory
      assert updated.metrics == new_metrics
      assert updated.history.memory == [2048]
      assert updated.history.processes == [500]
    end
  end

  # ── Convert ──────────────────────────────────────────────────────────

  describe "show_dashboard/1" do
    test "produces all expected sections" do
      result =
        sample_metrics()
        |> MonitorCore.new(sample_anomalies(), sample_status())
        |> MonitorCore.show_dashboard()

      assert is_map(result.status_card)
      assert is_list(result.skill_cards)
      assert is_list(result.anomaly_cards)
      assert result.selected_skill_detail == nil
    end

    test "selected skill detail is populated when a skill is selected" do
      result =
        sample_metrics()
        |> MonitorCore.new(sample_anomalies(), sample_status())
        |> MonitorCore.select_skill(:memory)
        |> MonitorCore.show_dashboard()

      detail = result.selected_skill_detail
      assert detail.key == :memory
      assert detail.name == "Memory"
      assert detail.data == sample_metrics().memory
      assert is_list(detail.flat_metrics)
    end
  end

  describe "show_status/1" do
    test "formats status code, label, anomaly count, skill count" do
      result = MonitorCore.show_status(sample_status())

      assert result.status_code == :healthy
      assert result.status_label == "Healthy"
      assert result.anomaly_count == 1
      assert result.skill_count == 5
    end
  end

  describe "show_skill_cards/1" do
    test "produces one card per skill in status" do
      cards =
        sample_metrics()
        |> MonitorCore.new([], sample_status())
        |> MonitorCore.show_skill_cards()

      assert length(cards) == 5

      memory_card = Enum.find(cards, &(&1.key == :memory))
      assert memory_card.icon == "💾"
      assert memory_card.name == "Memory"
      assert memory_card.summary == "1024MB used"
      assert memory_card.primary_value == 1024
      refute memory_card.selected
    end

    test "marks selected card" do
      cards =
        sample_metrics()
        |> MonitorCore.new([], sample_status())
        |> MonitorCore.select_skill(:processes)
        |> MonitorCore.show_skill_cards()

      processes_card = Enum.find(cards, &(&1.key == :processes))
      assert processes_card.selected
      refute Enum.find(cards, &(&1.key == :memory)).selected
    end
  end

  describe "show_anomaly/1" do
    test "formats severity, metric, value, baseline, deviation" do
      [anomaly] = sample_anomalies()
      result = MonitorCore.show_anomaly(anomaly)

      assert result.severity == :warning
      assert result.severity_icon == "⚠️"
      assert result.metric == "memory.total_mb"
      assert result.value == "8000"
      assert result.baseline == "4000"
      assert result.deviation == "2.5 stddev"
      assert result.detected_at == ~U[2026-04-07 12:00:00Z]
    end

    test "tolerates missing fields with defaults" do
      result = MonitorCore.show_anomaly(%{})
      assert result.severity == :info
      assert result.metric == "unknown"
      assert result.value == "—"
      assert result.deviation == nil
    end
  end

  # ── Pure Helpers ─────────────────────────────────────────────────────

  describe "primary_value/2" do
    test "extracts canonical primary metric per skill" do
      assert MonitorCore.primary_value(:memory, %{total_mb: 1024}) == 1024
      assert MonitorCore.primary_value(:processes, %{count: 437}) == 437
      assert MonitorCore.primary_value(:ets, %{table_count: 89}) == 89
      assert MonitorCore.primary_value(:scheduler, %{total_utilization: 12}) == 12
      assert MonitorCore.primary_value(:gc, %{total_collections: 50_000}) == 50_000
    end

    test "falls back to map_size for unknown skills" do
      assert MonitorCore.primary_value(:unknown, %{a: 1, b: 2}) == 2
    end

    test "returns nil for non-map data" do
      assert MonitorCore.primary_value(:foo, nil) == nil
    end
  end

  describe "format_status/1" do
    test "maps known statuses" do
      assert MonitorCore.format_status(:healthy) == "Healthy"
      assert MonitorCore.format_status(:warning) == "Warning"
      assert MonitorCore.format_status(:critical) == "Critical"
      assert MonitorCore.format_status(:emergency) == "Emergency"
    end

    test "unknown statuses become 'Unknown'" do
      assert MonitorCore.format_status(:weird) == "Unknown"
    end
  end

  describe "flatten_metrics/1" do
    test "flattens nested maps with dotted paths" do
      result = MonitorCore.flatten_metrics(%{memory: %{total_mb: 100, free_mb: 50}})
      assert {"memory.free_mb", 50} in result
      assert {"memory.total_mb", 100} in result
    end

    test "passes through flat maps" do
      result = MonitorCore.flatten_metrics(%{count: 5})
      assert result == [{"count", 5}]
    end

    test "tolerates non-map input" do
      assert MonitorCore.flatten_metrics(nil) == []
    end
  end

  describe "format_value/1" do
    test "handles common types" do
      assert MonitorCore.format_value(nil) == "—"
      assert MonitorCore.format_value(42) == "42"
      assert MonitorCore.format_value(3.14159) == "3.14"
    end
  end
end
