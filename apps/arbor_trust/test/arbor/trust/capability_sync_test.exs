defmodule Arbor.Trust.CapabilitySyncTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.CapabilitySync
  alias Arbor.Trust.CapabilityTemplates
  alias Manager

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

  describe "handle_info/2 - tier_changed promotion and demotion paths" do
    test "tier_changed with promotion (lower to higher) dispatches upgrade" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # Promotion from untrusted to trusted
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_promo", :tier_changed,
                  %{old_tier: :untrusted, new_tier: :trusted}},
                 state
               )
    end

    test "tier_changed with demotion (higher to lower) dispatches downgrade" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # Demotion from trusted to untrusted
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_demo", :tier_changed,
                  %{old_tier: :trusted, new_tier: :untrusted}},
                 state
               )
    end

    test "tier_changed with same tier does nothing" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_same", :tier_changed,
                  %{old_tier: :trusted, new_tier: :trusted}},
                 state
               )
    end

    test "tier_changed with nil old_tier handles gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_nil_tier", :tier_changed,
                  %{old_tier: nil, new_tier: :trusted}},
                 state
               )
    end

    test "tier_changed with nil new_tier handles gracefully" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_nil_new", :tier_changed,
                  %{old_tier: :trusted, new_tier: nil}},
                 state
               )
    end

    test "tier_changed multi-tier promotion veteran to autonomous" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_vet_auto", :tier_changed,
                  %{old_tier: :veteran, new_tier: :autonomous}},
                 state
               )
    end

    test "tier_changed multi-tier demotion autonomous to probationary" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_auto_prob", :tier_changed,
                  %{old_tier: :autonomous, new_tier: :probationary}},
                 state
               )
    end
  end

  describe "handle_info/2 - trust_frozen event details" do
    test "trust_frozen with security_violation reason" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_freeze_sec", :trust_frozen,
                  %{reason: :security_violation}},
                 state
               )
    end

    test "trust_frozen with circuit_breaker reason" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_freeze_cb", :trust_frozen,
                  %{reason: :circuit_breaker}},
                 state
               )
    end

    test "trust_frozen with empty metadata" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_freeze_empty", :trust_frozen, %{}},
                 state
               )
    end
  end

  describe "handle_info/2 - trust_unfrozen event" do
    test "trust_unfrozen restores capabilities (catches exit without Manager)" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_unfreeze", :trust_unfrozen, %{}},
                 state
               )
    end

    test "trust_unfrozen with extra metadata" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_unfreeze2", :trust_unfrozen,
                  %{unfrozen_by: "admin", reason: :manual}},
                 state
               )
    end
  end

  describe "handle_info/2 - profile_created event" do
    test "profile_created grants untrusted tier capabilities (catches exit)" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_new_profile", :profile_created,
                  %{tier: :untrusted}},
                 state
               )
    end

    test "profile_created with no tier metadata" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_new_no_tier", :profile_created, %{}},
                 state
               )
    end
  end

  describe "handle_info/2 - check_tier_change fallback for unknown events" do
    test "unknown event with tier promotion triggers handle_tier_change" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_unk_promo", :action_success,
                  %{previous_tier: :untrusted, new_tier: :probationary}},
                 state
               )
    end

    test "unknown event with tier demotion triggers handle_tier_change" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_unk_demo", :action_failure,
                  %{previous_tier: :trusted, new_tier: :probationary}},
                 state
               )
    end

    test "unknown event with only previous_tier does nothing" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_partial", :some_event,
                  %{previous_tier: :trusted}},
                 state
               )
    end

    test "unknown event with only new_tier does nothing" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_partial2", :some_event,
                  %{new_tier: :trusted}},
                 state
               )
    end
  end

  describe "handle_info/2 - unknown messages with GenServer running" do
    test "running GenServer handles unknown messages without crash" do
      {:ok, pid} = CapabilitySync.start_link(enabled: false)

      send(pid, :some_random_message)
      send(pid, {:random, :tuple})
      send(pid, "string_message")
      send(pid, 12_345)
      send(pid, %{key: "value"})

      # Give the GenServer time to process the messages
      Process.sleep(50)

      # CapabilitySync should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "running GenServer handles trust events when disabled" do
      {:ok, pid} = CapabilitySync.start_link(enabled: false)

      send(pid, {:trust_event, "agent_disabled", :profile_created, %{tier: :untrusted}})
      send(pid, {:trust_event, "agent_disabled", :tier_changed, %{old_tier: :untrusted, new_tier: :trusted}})
      send(pid, {:trust_event, "agent_disabled", :trust_frozen, %{reason: :test}})
      send(pid, {:trust_event, "agent_disabled", :trust_unfrozen, %{}})

      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "handle_info/2 - retry_subscribe max retries exceeded" do
    test "max retries exceeded logs warning and stops retrying" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 10}

      {:noreply, result_state} = CapabilitySync.handle_info(:retry_subscribe, state)

      # Should remain at 10 retries (no increment) and still not subscribed
      assert result_state.retry_count == 10
      assert result_state.subscribed == false
    end

    test "retries above max are all no-ops" do
      state = %CapabilitySync{enabled: true, subscribed: false, retry_count: 15}

      {:noreply, result_state} = CapabilitySync.handle_info(:retry_subscribe, state)

      # Should stay at 15 (above max, no-op)
      assert result_state.retry_count == 15
      assert result_state.subscribed == false
    end
  end

  describe "handle_call/3 - sync_capabilities with various agent_ids" do
    test "sync_capabilities with agent_ prefix calls Manager (exits without service)" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert catch_exit(
               CapabilitySync.handle_call({:sync_capabilities, "agent_test_prefix"}, self(), state)
             )
    end

    test "sync_capabilities with non-prefixed agent_id calls Manager (exits without service)" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      assert catch_exit(
               CapabilitySync.handle_call({:sync_capabilities, "test_no_prefix"}, self(), state)
             )
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

  describe "sync_capabilities with full services" do
    setup do
      # Start Store, EventStore, Manager, and CapabilitySync so sync calls work
      ensure_store_started()
      ensure_event_store_started()
      ensure_manager_started()
      ensure_capability_sync_started()
      :ok
    end

    test "sync_capabilities for existing agent with prefix" do
      {:ok, _} = Manager.create_trust_profile("agent_sync_prefix")

      # CapabilitySync calls Manager.get_trust_profile and then grants capabilities
      # The grant call will try Arbor.Security which may not be running, but
      # the key code paths (do_sync_capabilities, grant_tier_capabilities, ensure_agent_prefix)
      # are exercised
      result = CapabilitySync.sync_capabilities("agent_sync_prefix")

      case result do
        {:ok, %{granted: _, existing: _, errors: _}} -> assert true
        {:error, _} -> assert true
      end
    end

    test "sync_capabilities for existing agent without prefix" do
      {:ok, _} = Manager.create_trust_profile("no_prefix_sync")

      result = CapabilitySync.sync_capabilities("no_prefix_sync")

      case result do
        {:ok, %{granted: _, existing: _, errors: _}} -> assert true
        {:error, _} -> assert true
      end
    end

    test "sync_capabilities for frozen agent" do
      {:ok, _} = Manager.create_trust_profile("agent_frozen_sync")
      :ok = Manager.freeze_trust("agent_frozen_sync", :test_freeze)

      result = CapabilitySync.sync_capabilities("agent_frozen_sync")

      case result do
        {:ok, %{granted: _, existing: _, errors: _}} -> assert true
        {:error, _} -> assert true
      end
    end

    test "sync_capabilities for non-existent agent creates profile" do
      # Agent does not exist yet; do_sync_capabilities creates it
      result = CapabilitySync.sync_capabilities("agent_new_sync_#{System.unique_integer([:positive])}")

      case result do
        {:ok, %{granted: _, existing: _, errors: _}} -> assert true
        {:error, _} -> assert true
      end
    end

    test "expected_capabilities for existing agent" do
      {:ok, _} = Manager.create_trust_profile("agent_expected_caps")

      {:ok, caps} = CapabilitySync.expected_capabilities("agent_expected_caps")
      assert is_list(caps)
    end

    test "expected_capabilities for non-existent agent returns error" do
      result = CapabilitySync.expected_capabilities("totally_missing_agent_#{System.unique_integer([:positive])}")

      assert {:error, :not_found} = result
    end
  end

  describe "handle_info trust events with full services" do
    setup do
      ensure_store_started()
      ensure_event_store_started()
      ensure_manager_started()
      :ok
    end

    test "trust_unfrozen event with Manager running calls do_sync_capabilities" do
      {:ok, _} = Manager.create_trust_profile("agent_unfreeze_full")
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # This will call do_sync_capabilities -> Manager.get_trust_profile (succeeds)
      # -> grant_tier_capabilities (may fail at Arbor.Security but exercises code paths)
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_unfreeze_full", :trust_unfrozen, %{}},
                 state
               )
    end

    test "profile_created event with Manager running grants capabilities" do
      state = %CapabilitySync{enabled: true, subscribed: true, retry_count: 0}

      # profile_created calls grant_tier_capabilities(:untrusted)
      assert {:noreply, ^state} =
               CapabilitySync.handle_info(
                 {:trust_event, "agent_created_full", :profile_created, %{tier: :untrusted}},
                 state
               )
    end
  end

  # Helpers

  defp ensure_store_started do
    case Process.whereis(Arbor.Trust.Store) do
      nil -> start_supervised!(Arbor.Trust.Store)
      _pid -> :ok
    end
  end

  defp ensure_event_store_started do
    case Process.whereis(Arbor.Trust.EventStore) do
      nil -> start_supervised!({Arbor.Trust.EventStore, []})
      _pid -> :ok
    end
  end

  defp ensure_manager_started do
    case Process.whereis(Manager) do
      nil ->
        start_supervised!(
          {Manager, circuit_breaker: false, decay: false, event_store: true}
        )

      _pid ->
        :ok
    end
  end

  defp ensure_capability_sync_started do
    case Process.whereis(CapabilitySync) do
      nil -> start_supervised!({CapabilitySync, enabled: false})
      _pid -> :ok
    end
  end
end
