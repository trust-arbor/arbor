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

  describe "base_capabilities/0 — A1 proactive notify channel" do
    test "the universal baseline grants arbor://comms/notify/session with a rate-limit constraint" do
      caps = Config.base_capabilities()
      notify = Enum.find(caps, &(&1.resource_uri == "arbor://comms/notify/session"))

      assert notify, "baseline is missing the notify capability"
      # The anti-spam budget is applied as a :rate_limit constraint on the grant.
      assert notify.constraints[:rate_limit] == 30
    end
  end

  describe "generate_capabilities/1" do
    test "expands self-scoped URIs to the agent id" do
      caps = Config.generate_capabilities("agent_abc")
      uris = Enum.map(caps, & &1.resource_uri)

      assert "arbor://code/read/agent_abc/*" in uris
      assert Enum.all?(caps, &(&1.principal_id == "agent_abc"))
      assert Enum.all?(caps, &(&1.metadata.source == :trust_baseline))
    end
  end
end
