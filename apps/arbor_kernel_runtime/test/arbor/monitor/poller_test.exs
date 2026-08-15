defmodule Arbor.Monitor.PollerTest do
  use ExUnit.Case, async: false

  alias Arbor.Monitor.{Config, MetricsStore, Poller}

  describe "poll_now/0" do
    test "metrics appear in store after poll" do
      Poller.poll_now()

      # Check that at least beam metrics are stored
      assert {:ok, metrics, _ts} = MetricsStore.get(:beam)
      assert is_integer(metrics.process_count)
    end

    test "all enabled skills produce metrics" do
      Poller.poll_now()

      all_metrics = MetricsStore.all()
      assert Map.has_key?(all_metrics, :beam)
      assert Map.has_key?(all_metrics, :memory)
      assert Map.has_key?(all_metrics, :ets)
      assert Map.has_key?(all_metrics, :processes)
      assert Map.has_key?(all_metrics, :system)
    end
  end

  describe "periodic polling" do
    @tag timeout: 10_000
    test "polls automatically at configured interval" do
      # Clear existing metrics
      MetricsStore.clear_all()

      # Wait for at least one automatic poll cycle
      Process.sleep(Config.polling_interval() + 1_000)

      # Metrics should now be populated
      all_metrics = MetricsStore.all()
      assert map_size(all_metrics) > 0
    end
  end
end
