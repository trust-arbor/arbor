defmodule Arbor.Trust.CapabilitySyncTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.CapabilitySync
  alias Arbor.Trust.CapabilityTemplates

  @moduletag :fast

  describe "start_link/1" do
    test "starts with enabled: false" do
      {:ok, pid} = CapabilitySync.start_link(enabled: false)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "init/1" do
    test "initializes with enabled: true and schedules subscription" do
      # Test that init returns {:ok, state, {:continue, ...}} when enabled
      assert {:ok, %CapabilitySync{enabled: true, subscribed: false},
              {:continue, :subscribe_to_pubsub}} =
               CapabilitySync.init(enabled: true)
    end

    test "initializes with enabled: false without scheduling subscription" do
      assert {:ok, %CapabilitySync{enabled: false, subscribed: false}} =
               CapabilitySync.init(enabled: false)
    end

    test "defaults to enabled: true" do
      assert {:ok, %CapabilitySync{enabled: true}, {:continue, :subscribe_to_pubsub}} =
               CapabilitySync.init([])
    end

    test "retry_count starts at 0" do
      {:ok, state, _} = CapabilitySync.init([])
      assert state.retry_count == 0
    end
  end

  describe "handle_continue/2 - PubSub subscription" do
    test "handles missing PubSub gracefully (retry scheduling)" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 0}

      # PubSub is not running, so attempt_subscribe will fail
      # handle_continue should schedule a retry and return noreply
      assert {:noreply, %CapabilitySync{subscribed: false}} =
               CapabilitySync.handle_continue(:subscribe_to_pubsub, state)
    end
  end

  describe "handle_info/2 - retry_subscribe" do
    test "retries subscription and increments retry count when PubSub unavailable" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 0}

      # PubSub not running, so subscription will fail and retry will be scheduled
      assert {:noreply, %CapabilitySync{retry_count: 1, subscribed: false}} =
               CapabilitySync.handle_info(:retry_subscribe, state)
    end

    test "stops retrying after max retries (10)" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 10}

      # At max retries, should stop retrying and stay in standalone mode
      assert {:noreply, %CapabilitySync{retry_count: 10}} =
               CapabilitySync.handle_info(:retry_subscribe, state)
    end

    test "incrementally increases retry count" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 3}

      assert {:noreply, %CapabilitySync{retry_count: 4}} =
               CapabilitySync.handle_info(:retry_subscribe, state)
    end

    test "retry at count 9 still retries (under max)" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 9}

      # 9 < 10, so should still try
      {:noreply, result_state} = CapabilitySync.handle_info(:retry_subscribe, state)
      # Either succeeds (subscribed: true) or fails (retry_count: 10)
      # Since PubSub is not available, it fails
      assert result_state.retry_count == 10
    end
  end

  describe "handle_info/2 - trust events when disabled" do
    test "ignores tier_changed event when disabled" do
      state = %CapabilitySync{enabled: false, subscribed: false, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :tier_changed,
                  %{old_tier: :untrusted, new_tier: :probationary}},
                 state
               )
    end

    test "ignores trust_frozen event when disabled" do
      state = %CapabilitySync{enabled: false, subscribed: false, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :trust_frozen,
                  %{reason: :security_violation}},
                 state
               )
    end

    test "ignores trust_unfrozen event when disabled" do
      state = %CapabilitySync{enabled: false, subscribed: false, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :trust_unfrozen, %{}},
                 state
               )
    end

    test "ignores profile_created event when disabled" do
      state = %CapabilitySync{enabled: false, subscribed: false, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :profile_created, %{tier: :untrusted}},
                 state
               )
    end

    test "ignores unknown event types when disabled" do
      state = %CapabilitySync{enabled: false, subscribed: false, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :some_other_event,
                  %{previous_tier: :untrusted, new_tier: :probationary}},
                 state
               )
    end
  end

  describe "handle_info/2 - trust events when enabled (without external services)" do
    # These tests verify that enabled trust events attempt to call external
    # services (Arbor.Security facade, Manager). Since those services
    # are not running in unit tests, the handler catches the exits gracefully
    # and returns {:noreply, state}. This confirms the event dispatch logic
    # is working correctly and is resilient to missing services.

    test "tier_changed event handles missing service gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # tier_changed with promotion calls grant_tier_upgrade_capabilities
      # which calls Arbor.Security.grant (CapabilityStore not running)
      # The handler catches the exit and returns noreply
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :tier_changed,
                  %{old_tier: :untrusted, new_tier: :probationary}},
                 state
               )
    end

    test "trust_frozen event handles missing service gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # trust_frozen calls revoke_modifiable_capabilities
      # which calls Arbor.Security.list_capabilities (CapabilityStore not running)
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :trust_frozen,
                  %{reason: :security_violation}},
                 state
               )
    end

    test "trust_unfrozen event handles missing service gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # trust_unfrozen calls do_sync_capabilities which calls Manager.get_trust_profile
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :trust_unfrozen, %{}},
                 state
               )
    end

    test "profile_created event handles missing service gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # profile_created calls grant_tier_capabilities(:untrusted)
      # which calls CapabilityStore.list_capabilities (not running)
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :profile_created, %{tier: :untrusted}},
                 state
               )
    end

    test "unknown event with tier change metadata handles missing service gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # Unknown event with previous_tier/new_tier triggers handle_tier_change
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :some_other_event,
                  %{previous_tier: :untrusted, new_tier: :probationary}},
                 state
               )
    end

    test "unknown event without tier metadata is a no-op" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # Unknown event without tier change metadata does nothing
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :some_event, %{data: "no tiers"}},
                 state
               )
    end

    test "unknown event with same old and new tier is a no-op" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # Same tier means no tier change, so check_tier_change does nothing
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_test", :some_event,
                  %{previous_tier: :trusted, new_tier: :trusted}},
                 state
               )
    end
  end

  describe "handle_info/2 - unknown messages" do
    test "handles unknown messages without crashing" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(:unknown_message, state)

      assert {:noreply, ^state} =
               CapabilitySync.handle_info({:random, :tuple}, state)

      assert {:noreply, ^state} =
               CapabilitySync.handle_info("string_message", state)
    end
  end

  describe "handle_call/3 - sync_capabilities" do
    test "sync_capabilities calls Manager (exits without service)" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # do_sync_capabilities calls Manager.get_trust_profile which is not running
      assert catch_exit(
               CapabilitySync.handle_call({:sync_capabilities, "agent_test"}, self(), state)
             )
    end
  end

  describe "expected_capabilities/1 - without Manager running" do
    test "exits when Manager is not running" do
      # Manager is not started in this test, so expected_capabilities
      # calls Manager.get_trust_profile which is a GenServer.call to a non-existent process
      assert catch_exit(CapabilitySync.expected_capabilities("nonexistent_agent"))
    end
  end

  describe "struct" do
    test "has expected fields" do
      sync = %CapabilitySync{}
      assert Map.has_key?(sync, :enabled)
      assert Map.has_key?(sync, :subscribed)
      assert Map.has_key?(sync, :retry_count)
    end

    test "defaults are nil" do
      sync = %CapabilitySync{}
      assert sync.enabled == nil
      assert sync.subscribed == nil
      assert sync.retry_count == nil
    end
  end

  describe "ensure_agent_prefix logic (tested via generate_capabilities)" do
    test "agent IDs with prefix are preserved in generated capabilities" do
      caps = CapabilityTemplates.generate_capabilities("agent_foo", :untrusted)

      for cap <- caps do
        assert cap.principal_id == "agent_foo"
        assert String.contains?(cap.resource_uri, "agent_foo")
      end
    end

    test "agent IDs without prefix still work in generated capabilities" do
      caps = CapabilityTemplates.generate_capabilities("raw_id", :untrusted)

      for cap <- caps do
        assert cap.principal_id == "raw_id"
        assert String.contains?(cap.resource_uri, "raw_id")
      end
    end
  end
end
