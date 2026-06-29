defmodule Arbor.Trust.ConfigTest do
  # async: false because these tests modify shared Application config keys
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.Config

  describe "pubsub/0" do
    test "returns default PubSub module when no app env set" do
      original = Application.get_env(:arbor_trust, :pubsub)
      Application.delete_env(:arbor_trust, :pubsub)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :pubsub, original),
          else: Application.delete_env(:arbor_trust, :pubsub)
      end)

      assert Config.pubsub() == Arbor.Core.PubSub
    end

    test "returns overridden PubSub module from app env" do
      original = Application.get_env(:arbor_trust, :pubsub)
      Application.put_env(:arbor_trust, :pubsub, MyApp.CustomPubSub)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :pubsub, original),
          else: Application.delete_env(:arbor_trust, :pubsub)
      end)

      assert Config.pubsub() == MyApp.CustomPubSub
    end
  end

  describe "tiers/0" do
    test "returns default tier list when no app env set" do
      original = Application.get_env(:arbor_trust, :tiers)
      Application.delete_env(:arbor_trust, :tiers)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tiers, original),
          else: Application.delete_env(:arbor_trust, :tiers)
      end)

      assert Config.tiers() == [:untrusted, :probationary, :trusted, :veteran, :autonomous]
    end

    test "returns overridden tier list from app env" do
      original = Application.get_env(:arbor_trust, :tiers)
      custom_tiers = [:low, :medium, :high]
      Application.put_env(:arbor_trust, :tiers, custom_tiers)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tiers, original),
          else: Application.delete_env(:arbor_trust, :tiers)
      end)

      assert Config.tiers() == custom_tiers
    end
  end

  describe "tier_thresholds/0" do
    test "returns default tier thresholds when no app env set" do
      original = Application.get_env(:arbor_trust, :tier_thresholds)
      Application.delete_env(:arbor_trust, :tier_thresholds)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_thresholds, original),
          else: Application.delete_env(:arbor_trust, :tier_thresholds)
      end)

      expected = %{
        untrusted: 0,
        probationary: 20,
        trusted: 50,
        veteran: 75,
        autonomous: 90
      }

      assert Config.tier_thresholds() == expected
    end

    test "returns overridden tier thresholds from app env" do
      original = Application.get_env(:arbor_trust, :tier_thresholds)
      custom = %{low: 0, medium: 30, high: 70}
      Application.put_env(:arbor_trust, :tier_thresholds, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_thresholds, original),
          else: Application.delete_env(:arbor_trust, :tier_thresholds)
      end)

      assert Config.tier_thresholds() == custom
    end
  end

  describe "capability_templates/0" do
    test "returns empty map as default when no app env set" do
      original = Application.get_env(:arbor_trust, :capability_templates)
      Application.delete_env(:arbor_trust, :capability_templates)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :capability_templates, original),
          else: Application.delete_env(:arbor_trust, :capability_templates)
      end)

      assert Config.capability_templates() == %{}
    end

    test "returns overridden capability templates from app env" do
      original = Application.get_env(:arbor_trust, :capability_templates)
      custom = %{trusted: [:read, :write], autonomous: [:read, :write, :admin]}
      Application.put_env(:arbor_trust, :capability_templates, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :capability_templates, original),
          else: Application.delete_env(:arbor_trust, :capability_templates)
      end)

      assert Config.capability_templates() == custom
    end
  end

  describe "circuit_breaker_config/0" do
    test "returns default circuit breaker config when no app env set" do
      original = Application.get_env(:arbor_trust, :circuit_breaker)
      Application.delete_env(:arbor_trust, :circuit_breaker)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :circuit_breaker, original),
          else: Application.delete_env(:arbor_trust, :circuit_breaker)
      end)

      expected = %{
        rapid_failure_threshold: 5,
        rapid_failure_window_seconds: 60,
        security_violation_threshold: 3,
        security_violation_window_seconds: 3600,
        rollback_threshold: 3,
        rollback_window_seconds: 3600,
        test_failure_threshold: 5,
        test_failure_window_seconds: 300,
        freeze_duration_seconds: 86_400,
        half_open_duration_seconds: 3600
      }

      assert Config.circuit_breaker_config() == expected
    end

    test "returns overridden circuit breaker config from app env" do
      original = Application.get_env(:arbor_trust, :circuit_breaker)

      custom = %{
        rapid_failure_threshold: 10,
        rapid_failure_window_seconds: 120,
        security_violation_threshold: 5,
        security_violation_window_seconds: 7200,
        rollback_threshold: 5,
        rollback_window_seconds: 7200,
        test_failure_threshold: 10,
        test_failure_window_seconds: 600,
        freeze_duration_seconds: 172_800,
        half_open_duration_seconds: 7200
      }

      Application.put_env(:arbor_trust, :circuit_breaker, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :circuit_breaker, original),
          else: Application.delete_env(:arbor_trust, :circuit_breaker)
      end)

      assert Config.circuit_breaker_config() == custom
    end
  end

  describe "tier_definitions/0" do
    test "returns default tier definitions when no app env set" do
      original = Application.get_env(:arbor_trust, :tier_definitions)
      Application.delete_env(:arbor_trust, :tier_definitions)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_definitions, original),
          else: Application.delete_env(:arbor_trust, :tier_definitions)
      end)

      definitions = Config.tier_definitions()
      assert is_map(definitions)
      assert Map.has_key?(definitions, :untrusted)
      assert Map.has_key?(definitions, :autonomous)

      # Check structure of one tier
      untrusted = definitions[:untrusted]
      assert untrusted.display_name == "New"
      assert untrusted.description == "Just getting started together"
      assert untrusted.sandbox == :strict
      assert untrusted.actions == [:read, :search, :think]
    end

    test "returns overridden tier definitions from app env" do
      original = Application.get_env(:arbor_trust, :tier_definitions)

      custom = %{
        low: %{display_name: "Low Trust", sandbox: :strict, actions: [:read]}
      }

      Application.put_env(:arbor_trust, :tier_definitions, custom)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_definitions, original),
          else: Application.delete_env(:arbor_trust, :tier_definitions)
      end)

      assert Config.tier_definitions() == custom
    end
  end

  describe "display_name/1" do
    test "returns display name from default config" do
      original = Application.get_env(:arbor_trust, :tier_definitions)
      Application.delete_env(:arbor_trust, :tier_definitions)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_definitions, original),
          else: Application.delete_env(:arbor_trust, :tier_definitions)
      end)

      assert Config.display_name(:untrusted) == "New"
      assert Config.display_name(:probationary) == "Guided"
      assert Config.display_name(:trusted) == "Established"
      assert Config.display_name(:veteran) == "Trusted Partner"
      assert Config.display_name(:autonomous) == "Full Partner"
    end

    test "falls back to capitalized atom for unknown tier" do
      assert Config.display_name(:unknown_tier) == "Unknown_tier"
    end
  end

  describe "tier_description/1" do
    test "returns description from default config" do
      original = Application.get_env(:arbor_trust, :tier_definitions)
      Application.delete_env(:arbor_trust, :tier_definitions)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_definitions, original),
          else: Application.delete_env(:arbor_trust, :tier_definitions)
      end)

      assert Config.tier_description(:untrusted) == "Just getting started together"
      assert Config.tier_description(:autonomous) == "Complete partnership"
    end

    test "returns nil for unknown tier" do
      assert Config.tier_description(:unknown_tier) == nil
    end
  end

  describe "actions_for_tier/1" do
    test "returns actions from default config" do
      original = Application.get_env(:arbor_trust, :tier_definitions)
      Application.delete_env(:arbor_trust, :tier_definitions)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arbor_trust, :tier_definitions, original),
          else: Application.delete_env(:arbor_trust, :tier_definitions)
      end)

      assert Config.actions_for_tier(:untrusted) == [:read, :search, :think]
      assert Config.actions_for_tier(:autonomous) == :all
    end

    test "falls back to basic actions for unknown tier" do
      assert Config.actions_for_tier(:unknown_tier) == [:read, :search, :think]
    end
  end

  describe "capabilities_for_tier/1 — A1 proactive notify channel (Phase 3b)" do
    test "every tier is granted arbor://comms/notify/session with a rate-limit constraint" do
      for tier <- [:untrusted, :probationary, :trusted, :veteran, :autonomous] do
        caps = Config.capabilities_for_tier(tier)
        notify = Enum.find(caps, &(&1.resource_uri == "arbor://comms/notify/session"))

        assert notify, "tier #{tier} is missing the notify capability"
        # The anti-spam budget is applied as a :rate_limit constraint on the grant
        # (Phase 3b: makes the Phase-2 declared budget actually enforced).
        assert notify.constraints[:rate_limit] == 30
      end
    end
  end
end
