defmodule Arbor.Monitor.Skills.SystemTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Monitor.Skills.System, as: SystemSkill

  describe "name/0" do
    test "returns :system" do
      assert SystemSkill.name() == :system
    end
  end

  describe "collect/0" do
    test "returns expected keys with valid types" do
      assert {:ok, metrics} = SystemSkill.collect()

      assert is_integer(metrics.port_count)
      assert is_integer(metrics.port_limit)
      assert is_float(metrics.port_count_ratio)
      assert is_binary(metrics.otp_release)
      assert is_binary(metrics.system_architecture)
      assert is_integer(metrics.logical_processors)
      assert is_integer(metrics.schedulers_online)
      assert is_integer(metrics.uptime_ms)
    end

    test "port_count is within limits" do
      assert {:ok, metrics} = SystemSkill.collect()
      assert metrics.port_count > 0
      assert metrics.port_count < metrics.port_limit
    end

    test "schedulers and processors are positive" do
      assert {:ok, metrics} = SystemSkill.collect()
      assert metrics.schedulers_online > 0
      assert metrics.logical_processors > 0
    end
  end

  describe "check/1" do
    test "returns :normal for healthy memory" do
      metrics = %{
        system_total_memory: 16_000_000_000,
        system_available_memory: 8_000_000_000,
        system_free_memory: 4_000_000_000
      }

      assert :normal = SystemSkill.check(metrics)
    end

    test "detects critical memory pressure" do
      metrics = %{
        system_total_memory: 16_000_000_000,
        system_available_memory: 500_000_000,
        system_free_memory: 200_000_000
      }

      assert {:anomaly, :emergency, details} = SystemSkill.check(metrics)
      assert details.metric == :system_memory_pressure
      assert details.used_ratio > 0.95
    end
  end
end
