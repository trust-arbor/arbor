defmodule Arbor.Agent.SeedTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.Seed
  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory
  alias Arbor.Memory.{KnowledgeGraph, Preferences, WorkingMemory}

  @agent_id "test_seed_agent"

  @ets_tables [
    :arbor_working_memory,
    :arbor_memory_graphs,
    :arbor_memory_goals,
    :arbor_memory_intents,
    :arbor_preferences,
    :arbor_memory_self_knowledge
  ]

  setup do
    Enum.each(@ets_tables, &ensure_ets/1)
    Enum.each(@ets_tables, &clean_ets/1)
    :ok
  end

  defp ensure_ets(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp clean_ets(name) do
    if :ets.whereis(name) != :undefined do
      :ets.delete_all_objects(name)
    end
  rescue
    ArgumentError -> :ok
  end

  # ============================================================================
  # new/2
  # ============================================================================

  describe "new/2" do
    test "creates seed with agent_id and defaults" do
      seed = Seed.new(@agent_id)

      assert seed.agent_id == @agent_id
      assert seed.seed_version == 1
      assert seed.version == 0
      assert seed.self_model == %{}
      assert seed.metadata == %{}
      assert seed.goals == []
      assert seed.recent_intents == []
      assert seed.recent_percepts == []
      assert seed.learned_capabilities == %{}
      assert seed.action_history == []
      assert seed.capture_reason == :manual
      assert String.starts_with?(seed.id, "seed_")
    end

    test "accepts name, self_model, metadata, profile options" do
      model = %{nature: "curious", values: ["accuracy"]}
      meta = %{source: "test"}
      profile = %{"agent_id" => @agent_id, "trust_tier" => "trusted"}

      seed =
        Seed.new(@agent_id,
          name: "Scout",
          self_model: model,
          metadata: meta,
          profile: profile
        )

      assert seed.name == "Scout"
      assert seed.self_model == model
      assert seed.metadata == meta
      assert seed.profile == profile
    end

    test "generates unique IDs" do
      seed1 = Seed.new(@agent_id)
      seed2 = Seed.new(@agent_id)
      assert seed1.id != seed2.id
    end
  end

  # ============================================================================
  # capture/2
  # ============================================================================

  describe "capture/2" do
    test "captures with metadata fields set" do
      {:ok, seed} = Seed.capture(@agent_id, reason: :checkpoint)

      assert seed.agent_id == @agent_id
      assert seed.capture_reason == :checkpoint
      assert seed.captured_on_node == node()
      assert %DateTime{} = seed.captured_at
      assert String.starts_with?(seed.id, "seed_")
      assert seed.version == 1
    end

    test "captures working_memory when present" do
      wm = WorkingMemory.new(@agent_id)
      Arbor.Memory.save_working_memory(@agent_id, wm)

      {:ok, seed} = Seed.capture(@agent_id)

      assert seed.working_memory != nil
      assert is_map(seed.working_memory)
      assert seed.working_memory["agent_id"] == @agent_id
    end

    test "handles missing working_memory gracefully" do
      {:ok, seed} = Seed.capture(@agent_id)
      assert seed.working_memory == nil
    end

    test "captures knowledge_graph when initialized" do
      graph = KnowledgeGraph.new(@agent_id)
      :ets.insert(:arbor_memory_graphs, {@agent_id, graph})

      {:ok, seed} = Seed.capture(@agent_id)

      assert seed.knowledge_graph != nil
      assert is_map(seed.knowledge_graph)
    end

    test "captures goals from GoalStore" do
      goal = Goal.new("Test goal", type: :achieve, priority: 80)
      :ets.insert(:arbor_memory_goals, {{@agent_id, goal.id}, goal})

      {:ok, seed} = Seed.capture(@agent_id)

      assert length(seed.goals) == 1
      [exported_goal] = seed.goals
      assert exported_goal[:description] == "Test goal"
      assert exported_goal[:type] == :achieve
    end

    test "handles missing subsystems gracefully" do
      {:ok, seed} = Seed.capture(@agent_id)

      assert seed.working_memory == nil
      assert seed.knowledge_graph == nil
      assert seed.self_knowledge == nil
      assert seed.preferences == nil
      assert seed.goals == []
      assert seed.recent_intents == []
      assert seed.recent_percepts == []
    end

    test "captures preferences when present" do
      prefs = Preferences.new(@agent_id)
      :ets.insert(:arbor_preferences, {@agent_id, prefs})

      {:ok, seed} = Seed.capture(@agent_id)

      assert seed.preferences != nil
      assert is_map(seed.preferences)
    end

    test "passes through name, self_model, and metadata opts" do
      {:ok, seed} =
        Seed.capture(@agent_id,
          name: "TestBot",
          self_model: %{nature: "helpful"},
          metadata: %{env: "test"}
        )

      assert seed.name == "TestBot"
      assert seed.self_model == %{nature: "helpful"}
      assert seed.metadata == %{env: "test"}
    end
  end

  # ============================================================================
  # restore/2
  # ============================================================================

  describe "restore/2" do
    test "restores working_memory via Memory facade" do
      wm = WorkingMemory.new(@agent_id)
      wm_map = Memory.serialize_working_memory(wm)

      seed = %Seed{
        id: "seed_test",
        agent_id: @agent_id,
        working_memory: wm_map
      }

      {:ok, _} = Seed.restore(seed)

      restored = Arbor.Memory.get_working_memory(@agent_id)
      assert restored != nil
      assert restored.agent_id == @agent_id
    end

    test "restores knowledge_graph via Memory facade" do
      graph = KnowledgeGraph.new(@agent_id)
      graph_map = KnowledgeGraph.to_map(graph)

      seed = %Seed{
        id: "seed_test",
        agent_id: @agent_id,
        knowledge_graph: graph_map
      }

      {:ok, _} = Seed.restore(seed)

      {:ok, restored_map} = Arbor.Memory.export_knowledge_graph(@agent_id)
      assert restored_map != nil
    end

    test "restores goals via GoalStore" do
      goal_map = %{
        id: "goal_test1",
        description: "Restored goal",
        type: :achieve,
        status: :active,
        priority: 75,
        parent_id: nil,
        progress: 0.5,
        created_at: DateTime.to_iso8601(DateTime.utc_now()),
        achieved_at: nil,
        metadata: %{}
      }

      seed = %Seed{
        id: "seed_test",
        agent_id: @agent_id,
        goals: [goal_map]
      }

      {:ok, _} = Seed.restore(seed)

      {:ok, restored} = Memory.get_goal(@agent_id, "goal_test1")
      assert restored.description == "Restored goal"
      assert restored.priority == 75
    end

    test "skips subsystems in opts[:skip]" do
      wm = WorkingMemory.new(@agent_id)
      wm_map = Memory.serialize_working_memory(wm)

      seed = %Seed{
        id: "seed_test",
        agent_id: @agent_id,
        working_memory: wm_map,
        goals: [
          %{
            id: "goal_skip",
            description: "Skip me",
            type: :achieve,
            status: :active,
            priority: 50,
            parent_id: nil,
            progress: 0.0,
            created_at: nil,
            achieved_at: nil,
            metadata: %{}
          }
        ]
      }

      {:ok, _} = Seed.restore(seed, skip: [:working_memory, :goals])

      assert Arbor.Memory.get_working_memory(@agent_id) == nil
      assert Memory.get_goal(@agent_id, "goal_skip") == {:error, :not_found}
    end

    test "handles nil subsystem snapshots gracefully" do
      seed = %Seed{
        id: "seed_test",
        agent_id: @agent_id,
        working_memory: nil,
        knowledge_graph: nil,
        preferences: nil,
        goals: []
      }

      assert {:ok, _} = Seed.restore(seed)
    end
  end

  # ============================================================================
  # serialize/1 and deserialize/1
  # ============================================================================

  describe "serialize/1 and deserialize/1" do
    test "ETF roundtrip preserves all fields" do
      seed =
        Seed.new(@agent_id,
          name: "Roundtrip",
          self_model: %{nature: "test"},
          metadata: %{key: "value"}
        )

      binary = Seed.serialize(seed)
      assert is_binary(binary)

      {:ok, restored} = Seed.deserialize(binary)
      assert restored.agent_id == seed.agent_id
      assert restored.name == "Roundtrip"
      assert restored.self_model == %{nature: "test"}
      assert restored.metadata == %{key: "value"}
      assert restored.id == seed.id
    end

    test "handles corrupt binary gracefully" do
      assert {:error, {:deserialize_failed, _}} = Seed.deserialize(<<0, 1, 2, 3>>)
    end
  end

  # ============================================================================
  # to_map/1 and from_map/1
  # ============================================================================

  describe "to_map/1 and from_map/1" do
    test "JSON-safe map roundtrip preserves all fields" do
      seed =
        Seed.new(@agent_id,
          name: "MapTrip",
          self_model: %{values: ["accuracy"]},
          metadata: %{source: "test"}
        )

      map = Seed.to_map(seed)

      assert is_map(map)
      assert map["agent_id"] == @agent_id
      assert map["name"] == "MapTrip"
      assert map["capture_reason"] == "manual"

      {:ok, restored} = Seed.from_map(map)
      assert restored.agent_id == @agent_id
      assert restored.name == "MapTrip"
      assert restored.self_model == %{values: ["accuracy"]}
    end

    test "converts DateTimes to ISO8601 strings" do
      seed = %Seed{
        id: "seed_dt",
        agent_id: @agent_id,
        captured_at: ~U[2026-02-07 12:00:00Z],
        last_checkpoint_at: ~U[2026-02-07 11:00:00Z]
      }

      map = Seed.to_map(seed)

      assert map["captured_at"] == "2026-02-07T12:00:00Z"
      assert map["last_checkpoint_at"] == "2026-02-07T11:00:00Z"
    end

    test "from_map parses ISO8601 DateTime strings back" do
      map = %{
        "id" => "seed_parse",
        "agent_id" => @agent_id,
        "captured_at" => "2026-02-07T12:00:00Z",
        "capture_reason" => "checkpoint"
      }

      {:ok, seed} = Seed.from_map(map)

      assert %DateTime{} = seed.captured_at
      assert seed.capture_reason == :checkpoint
    end

    test "JSON encodable" do
      seed = Seed.new(@agent_id, name: "JSON Test")
      map = Seed.to_map(seed)

      assert {:ok, json} = Jason.encode(map)
      assert is_binary(json)
    end
  end

  # ============================================================================
  # save_to_file/2 and load_from_file/1
  # ============================================================================

  describe "save_to_file/2 and load_from_file/1" do
    @tag :tmp_dir
    test "roundtrip to file preserves state", %{tmp_dir: dir} do
      seed =
        Seed.new(@agent_id,
          name: "FileTest",
          self_model: %{nature: "persistent"},
          metadata: %{saved: true}
        )

      path = Path.join(dir, "test.seed")
      assert :ok = Seed.save_to_file(seed, path)
      assert {:ok, loaded} = Seed.load_from_file(path)

      assert loaded.agent_id == @agent_id
      assert loaded.name == "FileTest"
      assert loaded.self_model == %{nature: "persistent"}
      assert loaded.id == seed.id
    end

    test "handles missing file gracefully" do
      assert {:error, :enoent} = Seed.load_from_file("/nonexistent/path/seed.bin")
    end
  end

  # ============================================================================
  # Identity Evolution
  # ============================================================================

  describe "update_self_model/3" do
    test "merges changes into self_model" do
      seed = Seed.new(@agent_id, self_model: %{nature: "curious", values: ["accuracy"]})

      {:ok, updated} = Seed.update_self_model(seed, %{interests: ["elixir"]})

      assert updated.self_model == %{
               nature: "curious",
               values: ["accuracy"],
               interests: ["elixir"]
             }
    end

    test "deep merges nested maps" do
      seed = Seed.new(@agent_id, self_model: %{traits: %{speed: 8, accuracy: 9}})

      {:ok, updated} = Seed.update_self_model(seed, %{traits: %{creativity: 7}})

      assert updated.self_model.traits == %{speed: 8, accuracy: 9, creativity: 7}
    end

    test "snapshots previous version for rollback" do
      original = %{nature: "v1"}
      seed = Seed.new(@agent_id, self_model: original)

      {:ok, updated} = Seed.update_self_model(seed, %{nature: "v2"})

      assert length(updated.self_model_versions) == 1
      assert hd(updated.self_model_versions) == original
    end

    test "increments version" do
      seed = Seed.new(@agent_id)
      assert seed.version == 0

      {:ok, updated} = Seed.update_self_model(seed, %{x: 1})
      assert updated.version == 1

      {:ok, updated2} = Seed.update_self_model(updated, %{y: 2}, force: true)
      assert updated2.version == 2
    end

    test "enforces rate limit (max 3 changes per 24h)" do
      seed = Seed.new(@agent_id)

      {:ok, s1} = Seed.update_self_model(seed, %{a: 1})
      {:ok, s2} = Seed.update_self_model(s1, %{b: 2}, force: true)
      {:ok, s3} = Seed.update_self_model(s2, %{c: 3}, force: true)

      # 4th change should be rate limited (3 changes_today + cooldown)
      assert {:error, :rate_limited} = Seed.update_self_model(s3, %{d: 4})
    end

    test "force bypasses rate limit" do
      seed = Seed.new(@agent_id)

      {:ok, s1} = Seed.update_self_model(seed, %{a: 1})
      {:ok, s2} = Seed.update_self_model(s1, %{b: 2}, force: true)
      {:ok, s3} = Seed.update_self_model(s2, %{c: 3}, force: true)
      {:ok, s4} = Seed.update_self_model(s3, %{d: 4}, force: true)

      assert s4.self_model == %{a: 1, b: 2, c: 3, d: 4}
    end

    test "caps version history at 10" do
      seed = Seed.new(@agent_id)

      final =
        Enum.reduce(1..12, seed, fn i, acc ->
          {:ok, updated} = Seed.update_self_model(acc, %{i: i}, force: true)
          updated
        end)

      assert length(final.self_model_versions) == 10
    end
  end

  describe "rollback_self_model/1" do
    test "restores previous version" do
      seed = Seed.new(@agent_id, self_model: %{nature: "original"})
      {:ok, updated} = Seed.update_self_model(seed, %{nature: "changed"})

      {:ok, rolled_back} = Seed.rollback_self_model(updated)

      assert rolled_back.self_model == %{nature: "original"}
      assert rolled_back.self_model_versions == []
    end

    test "errors when no versions available" do
      seed = Seed.new(@agent_id)
      assert {:error, :no_versions} = Seed.rollback_self_model(seed)
    end

    test "increments version on rollback" do
      seed = Seed.new(@agent_id, self_model: %{v: 1})
      {:ok, updated} = Seed.update_self_model(seed, %{v: 2})
      {:ok, rolled_back} = Seed.rollback_self_model(updated)

      assert rolled_back.version == 2
    end
  end

  # ============================================================================
  # Learned Capabilities
  # ============================================================================

  describe "record_action_outcome/4" do
    test "tracks success" do
      seed = Seed.new(@agent_id)

      updated = Seed.record_action_outcome(seed, :search, :success, %{query: "test"})

      cap = updated.learned_capabilities[:search]
      assert cap.attempts == 1
      assert cap.successes == 1
      assert cap.failures == 0
      assert cap.last_outcome == :success
      assert %DateTime{} = cap.last_used
    end

    test "tracks failure" do
      seed = Seed.new(@agent_id)

      updated = Seed.record_action_outcome(seed, :deploy, :failure, %{error: "timeout"})

      cap = updated.learned_capabilities[:deploy]
      assert cap.attempts == 1
      assert cap.successes == 0
      assert cap.failures == 1
      assert cap.last_outcome == :failure
    end

    test "accumulates across multiple outcomes" do
      seed = Seed.new(@agent_id)

      seed = Seed.record_action_outcome(seed, :search, :success)
      seed = Seed.record_action_outcome(seed, :search, :success)
      seed = Seed.record_action_outcome(seed, :search, :failure)

      cap = seed.learned_capabilities[:search]
      assert cap.attempts == 3
      assert cap.successes == 2
      assert cap.failures == 1
    end

    test "prepends to action_history" do
      seed = Seed.new(@agent_id)

      updated =
        seed
        |> Seed.record_action_outcome(:search, :success, %{q: "a"})
        |> Seed.record_action_outcome(:deploy, :failure, %{env: "prod"})

      assert length(updated.action_history) == 2
      assert hd(updated.action_history).action == :deploy
    end

    test "caps action_history at 50" do
      seed = Seed.new(@agent_id)

      final =
        Enum.reduce(1..55, seed, fn i, acc ->
          # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
          Seed.record_action_outcome(acc, :"action_#{i}", :success)
        end)

      assert length(final.action_history) == 50
    end
  end

  # ============================================================================
  # Checkpoint Behaviour
  # ============================================================================

  describe "Arbor.Persistence.Checkpoint behaviour" do
    test "extract_checkpoint_data returns serializable map" do
      data = Seed.extract_checkpoint_data(@agent_id)

      assert is_map(data)
      assert data["agent_id"] == @agent_id
      assert data["capture_reason"] == "checkpoint"
    end

    test "restore_from_checkpoint reconstructs seed" do
      data = Seed.extract_checkpoint_data(@agent_id)
      seed = Seed.restore_from_checkpoint(data, %{})

      assert %Seed{} = seed
      assert seed.agent_id == @agent_id
    end

    test "roundtrip through checkpoint" do
      data = Seed.extract_checkpoint_data(@agent_id)
      seed = Seed.restore_from_checkpoint(data, %{})

      assert seed.agent_id == @agent_id
      assert seed.capture_reason == :checkpoint
    end
  end

  # ============================================================================
  # stats/1
  # ============================================================================

  describe "stats/1" do
    test "returns summary of all subsystem presence" do
      seed = Seed.new(@agent_id)
      stats = Seed.stats(seed)

      assert stats.agent_id == @agent_id
      assert stats.has_working_memory == false
      assert stats.has_context_window == false
      assert stats.has_knowledge_graph == false
      assert stats.has_self_knowledge == false
      assert stats.has_preferences == false
      assert stats.has_profile == false
      assert stats.goal_count == 0
      assert stats.intent_count == 0
      assert stats.percept_count == 0
      assert stats.learned_capability_count == 0
      assert stats.action_history_count == 0
    end

    test "includes counts for populated seed" do
      seed =
        Seed.new(@agent_id)
        |> Map.put(:working_memory, %{})
        |> Map.put(:goals, [%{id: "g1"}, %{id: "g2"}])
        |> Map.put(:recent_intents, [%{id: "i1"}])
        |> Seed.record_action_outcome(:search, :success)

      stats = Seed.stats(seed)

      assert stats.has_working_memory == true
      assert stats.goal_count == 2
      assert stats.intent_count == 1
      assert stats.learned_capability_count == 1
      assert stats.action_history_count == 1
    end

    test "includes self_model keys" do
      seed = Seed.new(@agent_id, self_model: %{nature: "curious", values: ["accuracy"]})
      stats = Seed.stats(seed)

      assert :nature in stats.self_model_keys
      assert :values in stats.self_model_keys
    end
  end

  # ============================================================================
  # Integration: capture → serialize → deserialize → restore
  # ============================================================================

  describe "full lifecycle" do
    test "capture → serialize → deserialize preserves state" do
      # Set up some state
      wm = WorkingMemory.new(@agent_id)
      Arbor.Memory.save_working_memory(@agent_id, wm)

      goal = Goal.new("Lifecycle goal", type: :explore)
      :ets.insert(:arbor_memory_goals, {{@agent_id, goal.id}, goal})

      # Capture
      {:ok, seed} =
        Seed.capture(@agent_id,
          reason: :periodic,
          name: "LifecycleBot",
          self_model: %{nature: "test"}
        )

      # Serialize + Deserialize
      binary = Seed.serialize(seed)
      {:ok, restored} = Seed.deserialize(binary)

      assert restored.agent_id == @agent_id
      assert restored.name == "LifecycleBot"
      assert restored.capture_reason == :periodic
      assert restored.working_memory != nil
      assert length(restored.goals) == 1
    end

    test "capture → to_map → from_map preserves state" do
      wm = WorkingMemory.new(@agent_id)
      Arbor.Memory.save_working_memory(@agent_id, wm)

      {:ok, seed} = Seed.capture(@agent_id, name: "MapBot")

      map = Seed.to_map(seed)
      {:ok, restored} = Seed.from_map(map)

      assert restored.agent_id == @agent_id
      assert restored.name == "MapBot"
      assert restored.working_memory != nil
    end

    test "capture → serialize → deserialize → restore roundtrip" do
      # Set up state
      wm = WorkingMemory.new(@agent_id)
      Arbor.Memory.save_working_memory(@agent_id, wm)

      # Capture and serialize
      {:ok, seed} = Seed.capture(@agent_id, reason: :shutdown)
      binary = Seed.serialize(seed)

      # Clear state
      :ets.delete_all_objects(:arbor_working_memory)
      assert Arbor.Memory.get_working_memory(@agent_id) == nil

      # Deserialize and restore
      {:ok, restored_seed} = Seed.deserialize(binary)
      {:ok, _} = Seed.restore(restored_seed)

      # Verify state is back
      assert Arbor.Memory.get_working_memory(@agent_id) != nil
    end
  end

  # ============================================================================
  # Learned capabilities serialization roundtrip
  # ============================================================================

  describe "learned capabilities serialization" do
    test "roundtrip through to_map/from_map preserves capability data" do
      seed =
        Seed.new(@agent_id)
        |> Seed.record_action_outcome(:search, :success, %{q: "test"})
        |> Seed.record_action_outcome(:search, :failure, %{q: "bad"})
        |> Seed.record_action_outcome(:deploy, :success)

      map = Seed.to_map(seed)
      {:ok, restored} = Seed.from_map(map)

      assert map_size(restored.learned_capabilities) == 2

      search_cap = restored.learned_capabilities[:search]
      assert search_cap[:attempts] == 2
      assert search_cap[:successes] == 1
      assert search_cap[:failures] == 1
      assert search_cap[:last_outcome] == :failure

      deploy_cap = restored.learned_capabilities[:deploy]
      assert deploy_cap[:attempts] == 1
      assert deploy_cap[:successes] == 1
    end
  end
end
