defmodule Arbor.Agent.ProfileStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{Character, Profile, ProfileStore}
  alias Arbor.Persistence.BufferedStore

  @store_name :arbor_agent_profiles
  @test_agents_dir Path.join(
                     System.tmp_dir!(),
                     "arbor_profile_store_test_#{System.unique_integer([:positive])}"
                   )

  setup do
    # Start a BufferedStore instance for tests (ETS-only, no backend)
    start_supervised!(
      Supervisor.child_spec(
        {BufferedStore, name: @store_name, backend: nil, write_mode: :sync},
        id: @store_name
      )
    )

    on_exit(fn ->
      File.rm_rf!(@test_agents_dir)
    end)

    :ok
  end

  defp make_profile(agent_id, opts \\ []) do
    character = Character.new(name: Keyword.get(opts, :name, "Test Agent"))

    %Profile{
      agent_id: agent_id,
      display_name: Keyword.get(opts, :display_name, "Test"),
      character: character,
      trust_tier: Keyword.get(opts, :trust_tier, :probationary),
      auto_start: Keyword.get(opts, :auto_start, false),
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now(),
      version: 1
    }
  end

  # ============================================================================
  # Store / Load round-trip
  # ============================================================================

  describe "store_profile/1 and load_profile/1" do
    test "round-trip preserves all fields" do
      profile = make_profile("round-trip-1", auto_start: true, trust_tier: :trusted)

      assert :ok = ProfileStore.store_profile(profile)
      assert {:ok, loaded} = ProfileStore.load_profile("round-trip-1")

      assert loaded.agent_id == "round-trip-1"
      assert loaded.display_name == "Test"
      assert loaded.trust_tier == :trusted
      assert loaded.auto_start == true
      assert loaded.character.name == "Test Agent"
    end

    test "overwrite on re-store" do
      profile1 = make_profile("overwrite-1", display_name: "Version 1")
      assert :ok = ProfileStore.store_profile(profile1)

      profile2 = make_profile("overwrite-1", display_name: "Version 2")
      assert :ok = ProfileStore.store_profile(profile2)

      assert {:ok, loaded} = ProfileStore.load_profile("overwrite-1")
      assert loaded.display_name == "Version 2"
    end

    test "not found error for nonexistent profile" do
      assert {:error, :not_found} = ProfileStore.load_profile("does-not-exist")
    end
  end

  # ============================================================================
  # List profiles
  # ============================================================================

  describe "list_profiles/0" do
    test "returns all stored profiles" do
      for i <- 1..3 do
        ProfileStore.store_profile(make_profile("list-#{i}", name: "Agent #{i}"))
      end

      profiles = ProfileStore.list_profiles()
      ids = Enum.map(profiles, & &1.agent_id)

      assert "list-1" in ids
      assert "list-2" in ids
      assert "list-3" in ids
    end

    test "returns empty list when no profiles" do
      assert ProfileStore.list_profiles() == []
    end
  end

  # ============================================================================
  # Auto-start filtering
  # ============================================================================

  describe "list_auto_start_profiles/0" do
    test "returns only auto_start profiles" do
      ProfileStore.store_profile(make_profile("auto-1", auto_start: true))
      ProfileStore.store_profile(make_profile("auto-2", auto_start: false))
      ProfileStore.store_profile(make_profile("auto-3", auto_start: true))

      auto_profiles = ProfileStore.list_auto_start_profiles()
      ids = Enum.map(auto_profiles, & &1.agent_id)

      assert "auto-1" in ids
      assert "auto-3" in ids
      refute "auto-2" in ids
    end

    test "returns empty list when no auto_start profiles" do
      ProfileStore.store_profile(make_profile("no-auto-1", auto_start: false))
      assert ProfileStore.list_auto_start_profiles() == []
    end
  end

  # ============================================================================
  # Delete
  # ============================================================================

  describe "delete_profile/1" do
    test "removes profile from store" do
      ProfileStore.store_profile(make_profile("delete-1"))
      assert {:ok, _} = ProfileStore.load_profile("delete-1")

      assert :ok = ProfileStore.delete_profile("delete-1")
      assert {:error, :not_found} = ProfileStore.load_profile("delete-1")
    end

    test "delete is idempotent for nonexistent profile" do
      assert :ok = ProfileStore.delete_profile("never-existed")
    end
  end

  # ============================================================================
  # JSON migration
  # ============================================================================

  describe "migrate_json_profiles/0" do
    test "migrates profiles from JSON files" do
      # Write a JSON profile to the legacy directory
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)

      agent_id = "migrate-test-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, name: "Migrated Agent")
      {:ok, json} = Profile.to_json(profile)
      path = Path.join(agents_dir, "#{agent_id}.agent.json")
      File.write!(path, json)

      # Verify it's not in the store yet
      assert {:error, :not_found} = load_from_store_only(agent_id)

      # Run migration
      assert {:ok, count} = ProfileStore.migrate_json_profiles()
      assert count >= 1

      # Now it should be in the store
      assert {:ok, loaded} = ProfileStore.load_profile(agent_id)
      assert loaded.character.name == "Migrated Agent"

      # Cleanup
      File.rm(path)
    end

    test "migration is idempotent" do
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)

      agent_id = "idempotent-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id)
      {:ok, json} = Profile.to_json(profile)
      path = Path.join(agents_dir, "#{agent_id}.agent.json")
      File.write!(path, json)

      # First migration
      assert {:ok, first_count} = ProfileStore.migrate_json_profiles()
      assert first_count >= 1

      # Second migration should not re-import
      assert {:ok, 0} = ProfileStore.migrate_json_profiles()

      # Cleanup
      File.rm(path)
    end
  end

  # ============================================================================
  # Dual-read fallback + lazy migration
  # ============================================================================

  describe "dual-read fallback" do
    test "load_profile falls back to JSON file and lazy-migrates" do
      agents_dir = Path.join(File.cwd!(), ".arbor/agents")
      File.mkdir_p!(agents_dir)

      agent_id = "fallback-#{System.unique_integer([:positive])}"
      profile = make_profile(agent_id, name: "Fallback Agent")
      {:ok, json} = Profile.to_json(profile)
      path = Path.join(agents_dir, "#{agent_id}.agent.json")
      File.write!(path, json)

      # Not in store, but should load via fallback
      assert {:error, :not_found} = load_from_store_only(agent_id)
      assert {:ok, loaded} = ProfileStore.load_profile(agent_id)
      assert loaded.character.name == "Fallback Agent"

      # After fallback, should now be in store (lazy migration)
      assert {:ok, stored} = load_from_store_only(agent_id)
      assert stored.character.name == "Fallback Agent"

      # Cleanup
      File.rm(path)
    end
  end

  # ============================================================================
  # auto_start field serialization
  # ============================================================================

  describe "auto_start field" do
    test "auto_start defaults to false" do
      profile = make_profile("default-auto")
      assert profile.auto_start == false
    end

    test "auto_start survives store round-trip" do
      profile = make_profile("auto-rt", auto_start: true)
      ProfileStore.store_profile(profile)

      {:ok, loaded} = ProfileStore.load_profile("auto-rt")
      assert loaded.auto_start == true
    end

    test "auto_start survives JSON round-trip" do
      profile = make_profile("auto-json", auto_start: true)
      {:ok, json} = Profile.to_json(profile)
      {:ok, restored} = Profile.from_json(json)

      assert restored.auto_start == true
    end

    test "old profiles without auto_start deserialize as false" do
      # Simulate old JSON without auto_start field
      old_json =
        Jason.encode!(%{
          "agent_id" => "old-agent",
          "character" => %{"name" => "Old"},
          "trust_tier" => "untrusted",
          "version" => 1
        })

      {:ok, profile} = Profile.from_json(old_json)
      assert profile.auto_start == false
    end
  end

  # ============================================================================
  # available?/0
  # ============================================================================

  describe "available?/0" do
    test "returns true when store is running" do
      assert ProfileStore.available?()
    end
  end

  # Helper: load directly from store (no JSON fallback)
  defp load_from_store_only(agent_id) do
    case BufferedStore.get(agent_id, name: @store_name) do
      {:ok, raw} ->
        data =
          case raw do
            %Arbor.Contracts.Persistence.Record{data: d} -> d
            %{} = d -> d
          end

        Profile.deserialize(data)

      {:error, _} = error ->
        error
    end
  end
end
