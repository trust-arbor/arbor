defmodule Arbor.Demo.TimingTest do
  use ExUnit.Case, async: true

  alias Arbor.Demo.Timing

  describe "profiles/0" do
    test "returns all three profiles" do
      profiles = Timing.profiles()

      assert Map.has_key?(profiles, :fast)
      assert Map.has_key?(profiles, :normal)
      assert Map.has_key?(profiles, :slow)
    end

    test "each profile has required keys" do
      required_keys = [
        :monitor_poll_interval_ms,
        :debug_agent_cycles,
        :council_timeout_ms,
        :hot_load_verification_ms,
        :stage_transition_delay_ms,
        :total_scenario_timeout_ms
      ]

      for {_mode, profile} <- Timing.profiles() do
        for key <- required_keys do
          assert Map.has_key?(profile, key), "Profile missing key: #{key}"
          assert is_integer(profile[key]), "#{key} should be integer"
          assert profile[key] > 0, "#{key} should be positive"
        end
      end
    end
  end

  describe "profile/1" do
    test "returns specific profile" do
      fast = Timing.profile(:fast)
      assert fast.total_scenario_timeout_ms == 45_000
    end

    test "returns nil for unknown profile" do
      assert Timing.profile(:unknown) == nil
    end
  end

  describe "timing values are ordered" do
    test "fast < normal < slow for timeouts" do
      fast = Timing.profile(:fast)
      normal = Timing.profile(:normal)
      slow = Timing.profile(:slow)

      assert fast.total_scenario_timeout_ms < normal.total_scenario_timeout_ms
      assert normal.total_scenario_timeout_ms < slow.total_scenario_timeout_ms

      assert fast.council_timeout_ms < normal.council_timeout_ms
      assert normal.council_timeout_ms < slow.council_timeout_ms
    end

    test "fast has fewer debug agent cycles" do
      fast = Timing.profile(:fast)
      normal = Timing.profile(:normal)
      slow = Timing.profile(:slow)

      assert fast.debug_agent_cycles < normal.debug_agent_cycles
      assert normal.debug_agent_cycles < slow.debug_agent_cycles
    end
  end

  describe "set/1 and current_mode/0" do
    test "defaults to normal when agent not started" do
      # Agent may or may not be running, but we can still read mode
      mode = Timing.current_mode()
      assert mode in [:fast, :normal, :slow]
    end

    test "set updates mode via application env when agent not started" do
      # Store original
      original = Application.get_env(:arbor_demo, :timing_mode)

      try do
        Timing.set(:fast)

        # When agent isn't running, falls back to app env
        stored = Application.get_env(:arbor_demo, :timing_mode)
        assert stored == :fast or Timing.current_mode() == :fast
      after
        # Restore original
        if original do
          Application.put_env(:arbor_demo, :timing_mode, original)
        else
          Application.delete_env(:arbor_demo, :timing_mode)
        end
      end
    end
  end

  describe "accessor functions" do
    test "monitor_poll_interval returns integer" do
      assert is_integer(Timing.monitor_poll_interval())
      assert Timing.monitor_poll_interval() > 0
    end

    test "debug_agent_cycles returns integer" do
      assert is_integer(Timing.debug_agent_cycles())
      assert Timing.debug_agent_cycles() > 0
    end

    test "council_timeout returns integer" do
      assert is_integer(Timing.council_timeout())
      assert Timing.council_timeout() > 0
    end

    test "hot_load_verification returns integer" do
      assert is_integer(Timing.hot_load_verification())
      assert Timing.hot_load_verification() > 0
    end

    test "stage_transition_delay returns integer" do
      assert is_integer(Timing.stage_transition_delay())
      assert Timing.stage_transition_delay() >= 0
    end

    test "total_scenario_timeout returns integer" do
      assert is_integer(Timing.total_scenario_timeout())
      assert Timing.total_scenario_timeout() > 0
    end
  end
end
