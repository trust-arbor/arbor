defmodule Arbor.AI.UsageStatsTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.UsageStats

  @moduletag :fast

  setup do
    # Ensure UsageStats is started
    unless UsageStats.started?() do
      {:ok, _} = UsageStats.start_link()
    end

    # Reset before each test
    UsageStats.reset()

    on_exit(fn ->
      if UsageStats.started?() do
        UsageStats.reset()
      end
    end)

    :ok
  end

  describe "record_success/2" do
    test "records success and increments counts" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        tier: :critical,
        latency_ms: 2340,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.045
      })

      # Wait for async cast
      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      assert stats.requests == 1
      assert stats.successes == 1
      assert stats.failures == 0
      assert stats.total_input_tokens == 1000
      assert stats.total_output_tokens == 500
      assert stats.total_cost_usd == 0.045
      assert stats.last_success != nil
    end

    test "accumulates multiple successes" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 500,
        output_tokens: 250,
        cost: 0.02
      })

      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 3000,
        input_tokens: 800,
        output_tokens: 400,
        cost: 0.03
      })

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      assert stats.requests == 2
      assert stats.successes == 2
      assert stats.total_input_tokens == 1300
      assert stats.total_output_tokens == 650
      assert stats.total_cost_usd == 0.05
    end

    test "tracks latency metrics" do
      Enum.each(1..10, fn i ->
        UsageStats.record_success(:anthropic, %{
          model: "claude-sonnet-4",
          latency_ms: i * 100,
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })
      end)

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-sonnet-4")
      assert stats.avg_latency_ms > 0
      assert stats.p95_latency_ms > 0
      # p95 should be high value (900 or 1000)
      assert stats.p95_latency_ms >= 900
    end
  end

  describe "record_failure/2" do
    test "records failure and increments counts" do
      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        tier: :critical,
        latency_ms: 5000,
        error: "timeout"
      })

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      assert stats.requests == 1
      assert stats.successes == 0
      assert stats.failures == 1
      assert stats.last_failure != nil
      assert stats.last_error == "timeout"
    end

    test "tracks both successes and failures" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 500,
        output_tokens: 250,
        cost: 0.02
      })

      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 5000,
        error: "rate_limit"
      })

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      assert stats.requests == 2
      assert stats.successes == 1
      assert stats.failures == 1
    end
  end

  describe "get_stats/1 (backend aggregation)" do
    test "aggregates stats across models for a backend" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      UsageStats.record_success(:anthropic, %{
        model: "claude-sonnet-4",
        latency_ms: 1500,
        input_tokens: 800,
        output_tokens: 400,
        cost: 0.02
      })

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic)
      assert stats.requests == 2
      assert stats.successes == 2
      assert stats.total_input_tokens == 1800
      assert stats.total_output_tokens == 900
      assert stats.total_cost_usd == 0.07
    end

    test "returns empty stats for unused backend" do
      stats = UsageStats.get_stats(:unused_backend)
      assert stats.requests == 0
      assert stats.successes == 0
      assert stats.failures == 0
    end
  end

  describe "get_stats/2 (backend + model)" do
    test "returns stats for specific backend and model" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      UsageStats.record_success(:anthropic, %{
        model: "claude-sonnet-4",
        latency_ms: 1500,
        input_tokens: 800,
        output_tokens: 400,
        cost: 0.02
      })

      :timer.sleep(10)

      opus_stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      assert opus_stats.requests == 1
      assert opus_stats.total_input_tokens == 1000

      sonnet_stats = UsageStats.get_stats(:anthropic, "claude-sonnet-4")
      assert sonnet_stats.requests == 1
      assert sonnet_stats.total_input_tokens == 800
    end

    test "handles atom model names" do
      UsageStats.record_success(:anthropic, %{
        model: :opus,
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, :opus)
      assert stats.requests == 1
    end
  end

  describe "all_stats/0" do
    test "returns all stats as a map" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      UsageStats.record_success(:gemini, %{
        model: "gemini-pro",
        latency_ms: 1200,
        input_tokens: 600,
        output_tokens: 300,
        cost: 0.01
      })

      :timer.sleep(10)

      all = UsageStats.all_stats()
      assert is_map(all)
      assert Map.has_key?(all, {:anthropic, "claude-opus-4"})
      assert Map.has_key?(all, {:gemini, "gemini-pro"})
    end

    test "returns empty map when no stats" do
      assert UsageStats.all_stats() == %{}
    end
  end

  describe "success_rate/1" do
    test "returns 1.0 when all successes" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 500,
        output_tokens: 250,
        cost: 0.02
      })

      :timer.sleep(10)

      rate = UsageStats.success_rate(:anthropic)
      assert rate == 1.0
    end

    test "returns 0.0 when all failures" do
      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 5000,
        error: "timeout"
      })

      :timer.sleep(10)

      rate = UsageStats.success_rate(:anthropic)
      assert rate == 0.0
    end

    test "calculates correct rate with mixed results" do
      # 3 successes, 1 failure = 0.75
      Enum.each(1..3, fn _ ->
        UsageStats.record_success(:anthropic, %{
          model: "claude-opus-4",
          latency_ms: 2000,
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })
      end)

      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 5000,
        error: "error"
      })

      :timer.sleep(10)

      rate = UsageStats.success_rate(:anthropic)
      assert rate == 0.75
    end

    test "returns 1.0 for unused backend" do
      rate = UsageStats.success_rate(:unused_backend)
      assert rate == 1.0
    end
  end

  describe "success_rate/2" do
    test "returns rate for specific backend and model" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 100,
        output_tokens: 50,
        cost: 0.01
      })

      UsageStats.record_failure(:anthropic, %{
        model: "claude-sonnet-4",
        latency_ms: 5000,
        error: "error"
      })

      :timer.sleep(10)

      opus_rate = UsageStats.success_rate(:anthropic, "claude-opus-4")
      assert opus_rate == 1.0

      sonnet_rate = UsageStats.success_rate(:anthropic, "claude-sonnet-4")
      assert sonnet_rate == 0.0
    end
  end

  describe "reliability_ranking/0" do
    test "returns backends sorted by success rate descending" do
      # Backend A: 100% success
      UsageStats.record_success(:ollama, %{
        model: "llama3",
        latency_ms: 500,
        input_tokens: 100,
        output_tokens: 50,
        cost: 0.0
      })

      # Backend B: 50% success
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 100,
        output_tokens: 50,
        cost: 0.01
      })

      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 5000,
        error: "error"
      })

      # Backend C: 0% success
      UsageStats.record_failure(:gemini, %{
        model: "gemini-pro",
        latency_ms: 3000,
        error: "error"
      })

      :timer.sleep(10)

      ranking = UsageStats.reliability_ranking()
      assert length(ranking) == 3

      # Should be sorted: ollama (1.0), anthropic (0.5), gemini (0.0)
      [{first_backend, first_rate}, {second_backend, second_rate}, {third_backend, third_rate}] =
        ranking

      assert first_backend == :ollama
      assert first_rate == 1.0

      assert second_backend == :anthropic
      assert second_rate == 0.5

      assert third_backend == :gemini
      assert third_rate == 0.0
    end

    test "returns empty list when no stats" do
      assert UsageStats.reliability_ranking() == []
    end
  end

  describe "reset/0" do
    test "clears all stats" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      :timer.sleep(10)

      # Verify there was data
      assert UsageStats.get_stats(:anthropic).requests == 1

      # Reset
      UsageStats.reset()
      :timer.sleep(10)

      # Verify cleared
      assert UsageStats.get_stats(:anthropic).requests == 0
      assert UsageStats.all_stats() == %{}
    end
  end

  describe "reset/1" do
    test "clears stats for specific backend only" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      UsageStats.record_success(:gemini, %{
        model: "gemini-pro",
        latency_ms: 1200,
        input_tokens: 600,
        output_tokens: 300,
        cost: 0.01
      })

      :timer.sleep(10)

      # Reset only anthropic
      UsageStats.reset(:anthropic)
      :timer.sleep(10)

      # Anthropic should be cleared
      assert UsageStats.get_stats(:anthropic).requests == 0

      # Gemini should remain
      assert UsageStats.get_stats(:gemini).requests == 1
    end
  end

  describe "started?/0" do
    test "returns true when running" do
      assert UsageStats.started?() == true
    end
  end

  describe "latency calculations" do
    test "avg_latency_ms is calculated correctly" do
      latencies = [100, 200, 300, 400, 500]

      Enum.each(latencies, fn latency ->
        UsageStats.record_success(:anthropic, %{
          model: "claude-opus-4",
          latency_ms: latency,
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })
      end)

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      # Average of 100, 200, 300, 400, 500 = 300
      assert stats.avg_latency_ms == 300.0
    end

    test "p95_latency_ms returns high percentile value" do
      # Create 100 samples with increasing latency
      Enum.each(1..100, fn i ->
        UsageStats.record_success(:anthropic, %{
          model: "claude-opus-4",
          latency_ms: i * 10,
          input_tokens: 100,
          output_tokens: 50,
          cost: 0.01
        })
      end)

      :timer.sleep(10)

      stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      # p95 should be around 950-1000 (top 5%)
      assert stats.p95_latency_ms >= 950
    end
  end

  describe "isolation between backends and models" do
    test "stats are isolated per backend" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      UsageStats.record_failure(:gemini, %{
        model: "gemini-pro",
        latency_ms: 3000,
        error: "error"
      })

      :timer.sleep(10)

      anthropic_stats = UsageStats.get_stats(:anthropic)
      assert anthropic_stats.successes == 1
      assert anthropic_stats.failures == 0

      gemini_stats = UsageStats.get_stats(:gemini)
      assert gemini_stats.successes == 0
      assert gemini_stats.failures == 1
    end

    test "stats are isolated per model within a backend" do
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        latency_ms: 2000,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.05
      })

      UsageStats.record_failure(:anthropic, %{
        model: "claude-sonnet-4",
        latency_ms: 3000,
        error: "error"
      })

      :timer.sleep(10)

      opus_stats = UsageStats.get_stats(:anthropic, "claude-opus-4")
      assert opus_stats.successes == 1
      assert opus_stats.failures == 0

      sonnet_stats = UsageStats.get_stats(:anthropic, "claude-sonnet-4")
      assert sonnet_stats.successes == 0
      assert sonnet_stats.failures == 1
    end
  end
end
