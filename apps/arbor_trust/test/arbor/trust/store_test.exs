defmodule Arbor.Trust.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Store

  defmodule DurableBackend do
    @state_key {__MODULE__, :state}

    def reset do
      :persistent_term.put(@state_key, %{records: %{}, fail_writes?: false})
    end

    def fail_writes?(value) do
      update(&Map.put(&1, :fail_writes?, value))
    end

    def put(key, record, _opts) do
      if state().fail_writes? do
        {:error, :simulated_backend_failure}
      else
        update(fn state -> put_in(state.records[key], record) end)
        :ok
      end
    end

    def get(key, _opts) do
      case Map.fetch(state().records, key) do
        {:ok, record} -> {:ok, record}
        :error -> {:error, :not_found}
      end
    end

    def list(_opts), do: {:ok, state().records |> Map.keys() |> Enum.sort()}

    defp state, do: :persistent_term.get(@state_key, %{records: %{}, fail_writes?: false})
    defp update(update), do: :persistent_term.put(@state_key, update.(state()))
  end

  setup do
    # Stop the Store if it was already running from a previous test
    case GenServer.whereis(Store) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    # Also clean up named ETS table if it lingers
    if :ets.info(:trust_profile_cache) != :undefined do
      :ets.delete(:trust_profile_cache)
    end

    {:ok, pid} = Store.start_link([])

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    {:ok, profile} = Profile.new("agent_test_1")
    {:ok, pid: pid, profile: profile}
  end

  describe "start_link/1 and stopping" do
    test "starts the store GenServer", %{pid: pid} do
      assert Process.alive?(pid)
      assert GenServer.whereis(Store) == pid
    end

    test "creates ETS table on start" do
      assert :ets.info(:trust_profile_cache) != :undefined
    end

    test "stops cleanly and cleans up ETS table", %{pid: pid} do
      GenServer.stop(pid, :normal)
      # ETS table is cleaned up in terminate/2
      assert :ets.info(:trust_profile_cache) == :undefined
    end
  end

  describe "store_profile/1 and get_profile/1" do
    test "stores and retrieves a profile", %{profile: profile} do
      assert :ok = Store.store_profile(profile)
      assert {:ok, retrieved} = Store.get_profile(profile.agent_id)
      assert retrieved.agent_id == profile.agent_id
      assert retrieved.baseline == profile.baseline
    end

    test "returns {:error, :not_found} for missing profile" do
      assert {:error, :not_found} = Store.get_profile("nonexistent_agent")
    end

    test "overwrites an existing profile", %{profile: profile} do
      :ok = Store.store_profile(profile)

      # Create an updated version of the same profile
      updated_profile = %{profile | baseline: :allow}
      :ok = Store.store_profile(updated_profile)

      {:ok, retrieved} = Store.get_profile(profile.agent_id)
      assert retrieved.baseline == :allow
    end

    test "stores multiple different profiles" do
      {:ok, profile_a} = Profile.new("agent_a")
      {:ok, profile_b} = Profile.new("agent_b")

      :ok = Store.store_profile(profile_a)
      :ok = Store.store_profile(profile_b)

      {:ok, retrieved_a} = Store.get_profile("agent_a")
      {:ok, retrieved_b} = Store.get_profile("agent_b")

      assert retrieved_a.agent_id == "agent_a"
      assert retrieved_b.agent_id == "agent_b"
    end

    test "durable persistence failure is returned and does not populate the cache", %{
      pid: pid,
      profile: profile
    } do
      GenServer.stop(pid, :normal)
      assert Process.whereis(:arbor_trust_profiles) == nil

      {:ok, durable_pid} = Store.start_link(persistence: :durable)
      on_exit(fn -> if Process.alive?(durable_pid), do: GenServer.stop(durable_pid, :normal) end)

      assert {:error, :trust_profile_persistence_unavailable} =
               Store.store_profile(profile)

      assert {:error, :not_found} = Store.get_profile(profile.agent_id)
    end

    test "durable backend failure is returned and does not populate the cache", %{
      pid: pid,
      profile: profile
    } do
      GenServer.stop(pid, :normal)
      DurableBackend.reset()
      DurableBackend.fail_writes?(true)

      {:ok, durable_pid} =
        Store.start_link(persistence: :durable, durable_backend: DurableBackend)

      on_exit(fn -> if Process.alive?(durable_pid), do: GenServer.stop(durable_pid, :normal) end)

      assert {:error, {:trust_profile_persist_failed, :simulated_backend_failure}} =
               Store.store_profile(profile)

      assert {:error, :not_found} = Store.get_profile(profile.agent_id)
    end
  end

  describe "profile_exists?/1" do
    test "returns true for stored profile", %{profile: profile} do
      :ok = Store.store_profile(profile)
      assert Store.profile_exists?(profile.agent_id) == true
    end

    test "returns false for missing profile" do
      assert Store.profile_exists?("nonexistent_agent") == false
    end
  end

  describe "delete_profile/1" do
    test "deletes an existing profile by replacing it with a deny-all tombstone", %{
      profile: profile
    } do
      :ok = Store.store_profile(profile)
      assert Store.profile_exists?(profile.agent_id) == true

      assert :ok = Store.delete_profile(profile.agent_id)
      assert Store.profile_exists?(profile.agent_id) == true
      assert {:ok, tombstone} = Store.get_profile(profile.agent_id)
      assert tombstone.baseline == :block
      assert tombstone.frozen
    end

    test "returns :ok when deleting a non-existent profile" do
      assert :ok = Store.delete_profile("nonexistent_agent")
    end

    test "durable deletion failure remains deny-all after a store restart", %{
      pid: pid,
      profile: profile
    } do
      GenServer.stop(pid, :normal)
      DurableBackend.reset()

      {:ok, durable_pid} =
        Store.start_link(persistence: :durable, durable_backend: DurableBackend)

      assert :ok = Store.store_profile(profile)
      DurableBackend.fail_writes?(true)

      assert {:error, {:trust_profile_persist_failed, :simulated_backend_failure}} =
               Store.delete_profile(profile.agent_id)

      assert {:ok, denied} = Store.get_profile(profile.agent_id)
      assert denied.baseline == :block
      assert denied.frozen

      GenServer.stop(durable_pid, :normal)
      DurableBackend.fail_writes?(false)

      {:ok, restarted_pid} =
        Store.start_link(persistence: :durable, durable_backend: DurableBackend)

      on_exit(fn ->
        if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid, :normal)
      end)

      assert {:ok, denied_after_restart} = Store.get_profile(profile.agent_id)
      assert denied_after_restart.baseline == :block
      assert denied_after_restart.frozen
    end
  end

  describe "list_profiles/0 and list_profiles/1" do
    test "lists all stored profiles" do
      {:ok, p1} = Profile.new("agent_list_1")
      {:ok, p2} = Profile.new("agent_list_2")
      {:ok, p3} = Profile.new("agent_list_3")

      :ok = Store.store_profile(p1)
      :ok = Store.store_profile(p2)
      :ok = Store.store_profile(p3)

      {:ok, profiles} = Store.list_profiles()
      agent_ids = Enum.map(profiles, & &1.agent_id)

      assert "agent_list_1" in agent_ids
      assert "agent_list_2" in agent_ids
      assert "agent_list_3" in agent_ids
    end

    test "returns empty list when no profiles exist" do
      {:ok, profiles} = Store.list_profiles()
      assert profiles == []
    end

    test "respects limit option" do
      for i <- 1..5 do
        {:ok, p} = Profile.new("agent_limit_#{i}")
        :ok = Store.store_profile(p)
      end

      {:ok, profiles} = Store.list_profiles(limit: 3)
      assert length(profiles) == 3
    end

    test "sorts profiles by agent_id" do
      {:ok, c} = Profile.new("agent_c")
      {:ok, a} = Profile.new("agent_a")
      {:ok, b} = Profile.new("agent_b")

      :ok = Store.store_profile(c)
      :ok = Store.store_profile(a)
      :ok = Store.store_profile(b)

      {:ok, profiles} = Store.list_profiles()
      ids = Enum.map(profiles, & &1.agent_id)
      assert ids == Enum.sort(ids)
    end
  end

  describe "update_profile/2" do
    test "updates a profile using an update function", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, updated} =
        Store.update_profile(profile.agent_id, fn p ->
          %{p | baseline: :allow}
        end)

      assert updated.baseline == :allow
      # updated_at should be refreshed
      assert DateTime.compare(updated.updated_at, profile.updated_at) != :lt
    end

    test "returns {:error, :not_found} for missing profile" do
      result =
        Store.update_profile("nonexistent", fn p ->
          %{p | baseline: :allow}
        end)

      assert result == {:error, :not_found}
    end
  end

  describe "freeze_profile/2 and unfreeze_profile/1" do
    test "freezes and unfreezes a profile", %{profile: profile} do
      :ok = Store.store_profile(profile)

      {:ok, frozen} = Store.freeze_profile(profile.agent_id, :anomalous_behavior)
      assert frozen.frozen == true
      assert frozen.frozen_reason == :anomalous_behavior
      assert frozen.frozen_at != nil

      {:ok, unfrozen} = Store.unfreeze_profile(profile.agent_id)
      assert unfrozen.frozen == false
      assert unfrozen.frozen_reason == nil
      assert unfrozen.frozen_at == nil
    end
  end

  # Events now live exclusively in EventStore — see event_store_test.exs

  describe "get_cache_stats/0" do
    test "returns cache statistics" do
      stats = Store.get_cache_stats()

      assert Map.has_key?(stats, :hits)
      assert Map.has_key?(stats, :misses)
      assert Map.has_key?(stats, :writes)
      assert Map.has_key?(stats, :deletes)
      assert Map.has_key?(stats, :profiles_size)
      assert Map.has_key?(stats, :profiles_memory)
      # Events table removed — events live in EventStore
    end

    test "tracks writes", %{profile: profile} do
      :ok = Store.store_profile(profile)
      stats = Store.get_cache_stats()
      assert stats.writes >= 1
    end

    test "direct ETS reads bypass GenServer (no hit tracking)", %{profile: profile} do
      :ok = Store.store_profile(profile)
      {:ok, _} = Store.get_profile(profile.agent_id)

      # Direct ETS reads skip GenServer, so hits aren't tracked
      # This is intentional — the hot path avoids serialization
      stats = Store.get_cache_stats()
      assert stats.hits == 0
    end

    test "tracks cache misses" do
      {:error, :not_found} = Store.get_profile("miss_agent")

      stats = Store.get_cache_stats()
      assert stats.misses >= 1
    end

    test "tracks deletes", %{profile: profile} do
      :ok = Store.store_profile(profile)
      :ok = Store.delete_profile(profile.agent_id)

      stats = Store.get_cache_stats()
      assert stats.deletes >= 1
    end

    # Events tracking removed — events now live in EventStore exclusively
  end
end
