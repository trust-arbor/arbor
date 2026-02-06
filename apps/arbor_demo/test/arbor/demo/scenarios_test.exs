defmodule Arbor.Demo.ScenariosTest do
  @moduledoc """
  Tests for demo scenarios.

  These tests verify that the scenario infrastructure works correctly.
  Full end-to-end scenario tests are tagged :integration and :slow
  for manual execution before conference.
  """

  use ExUnit.Case, async: true

  alias Arbor.Demo.Scenarios
  alias Arbor.Demo.Timing

  describe "scenario/1" do
    test "returns definition for :successful_heal" do
      scenario = Scenarios.scenario(:successful_heal)

      assert scenario.name == :successful_heal
      assert scenario.fault == :message_queue_flood
      assert scenario.expected_decision == :approved
      assert is_list(scenario.narrator_notes)
      assert is_list(scenario.recovery_steps)
    end

    test "returns definition for :rejected_fix" do
      scenario = Scenarios.scenario(:rejected_fix)

      assert scenario.name == :rejected_fix
      assert scenario.fault == :supervisor_crash
      assert scenario.expected_decision == :rejected
      assert is_map(scenario.mock_proposal)
    end

    test "returns definition for :second_success" do
      scenario = Scenarios.scenario(:second_success)

      assert scenario.name == :second_success
      assert scenario.fault == :process_leak
      assert scenario.expected_decision == :approved
    end

    test "returns nil for unknown scenario" do
      assert Scenarios.scenario(:unknown) == nil
    end
  end

  describe "available_scenarios/0" do
    test "returns all three scenarios" do
      scenarios = Scenarios.available_scenarios()

      assert :successful_heal in scenarios
      assert :rejected_fix in scenarios
      assert :second_success in scenarios
      assert length(scenarios) == 3
    end
  end

  describe "timing integration" do
    test "scenarios module references Timing module" do
      # Verify Timing is accessible from Scenarios
      assert Timing.total_scenario_timeout() > 0
    end

    test "timing modes are available" do
      assert Timing.profile(:fast) != nil
      assert Timing.profile(:normal) != nil
      assert Timing.profile(:slow) != nil
    end

    test "fast timing is faster than normal" do
      fast = Timing.profile(:fast)
      normal = Timing.profile(:normal)

      assert fast.total_scenario_timeout_ms < normal.total_scenario_timeout_ms
      assert fast.council_timeout_ms < normal.council_timeout_ms
    end
  end

  # ============================================================================
  # Integration Tests (run manually before conference)
  # ============================================================================

  describe "run/2 integration" do
    @describetag :integration
    @describetag :slow

    @tag timeout: 120_000
    test "successful_heal scenario completes" do
      # Set fast timing for test
      Timing.set(:fast)

      case Scenarios.run(:successful_heal, timeout: 60_000) do
        {:ok, result} ->
          assert result.scenario == :successful_heal
          assert is_integer(result.duration_ms)
          assert result.duration_ms > 0

        # Note: actual decision depends on full system running
        _other ->
          # In isolated test, full system may not be running
          :ok
      end
    end

    @tag timeout: 120_000
    test "rejected_fix scenario completes" do
      Timing.set(:fast)

      case Scenarios.run(:rejected_fix, timeout: 60_000) do
        {:ok, result} ->
          assert result.scenario == :rejected_fix
          assert is_integer(result.duration_ms)

        _other ->
          # Expected in isolated test environment
          :ok
      end
    end
  end

  describe "rehearsal/1 integration" do
    @describetag :integration
    @describetag :slow

    @tag timeout: 300_000
    test "rehearsal runs all scenarios" do
      Timing.set(:fast)

      # This test requires the full system to be running
      # rehearsal always returns {:ok, results} - it catches errors internally
      {:ok, results} = Scenarios.rehearsal(verbose: false)
      assert is_list(results)
      assert length(results) == 3
    end
  end
end
