defmodule Arbor.Agent.SeedTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Seed
  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory

  alias Arbor.Memory.{
    GoalStore,
    KnowledgeGraph,
    Preferences,
    Provenance,
    WorkingMemory,
    WorkingMemoryStore
  }

  alias Arbor.Persistence.BufferedStore

  @agent_id "test_seed_agent"
  @memory_store :arbor_memory_durable

  setup do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(System.tmp_dir!(), "seed-" <> token)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tmp_dir: root}
  end

  defmodule CaptureFailingBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: {:error, :forced_failure}

    @impl true
    def get(_key, _opts), do: {:error, :forced_failure}

    @impl true
    def delete(_key, _opts), do: {:error, :forced_failure}

    @impl true
    def list(_opts), do: {:error, :forced_failure}

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule UnavailableBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: {:error, :configured_unavailable}
    def get(_key, _opts), do: {:error, :configured_unavailable}
    def delete(_key, _opts), do: {:error, :configured_unavailable}
    def list(_opts), do: {:error, :configured_unavailable}
    def query(_filter, _opts), do: {:error, :configured_unavailable}

    def compare_and_swap(_key, _expected, _replacement, _opts),
      do: {:error, :configured_unavailable}

    def compare_and_delete(_key, _expected, _opts), do: {:error, :configured_unavailable}
    def durability_class(_opts), do: :node_restart
  end

  defmodule GoalExportUnavailableBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: {:error, :configured_unavailable}
    def get(_key, _opts), do: {:error, :not_found}
    def delete(_key, _opts), do: {:error, :configured_unavailable}
    def list(_opts), do: {:error, :configured_unavailable}
    def query(_filter, _opts), do: {:error, :configured_unavailable}

    def compare_and_swap(_key, _expected, _replacement, _opts),
      do: {:error, :configured_unavailable}

    def compare_and_delete(_key, _expected, _opts), do: {:error, :configured_unavailable}
    def durability_class(_opts), do: :node_restart
  end

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
    ensure_memory_services()
    _ = Memory.delete_working_memory(@agent_id)
    _ = Provenance.delete_agent(@agent_id)
    Enum.each(@ets_tables, &clean_ets/1)
    ensure_goal_runtime()
    assert :ok = GoalStore.clear_goals(@agent_id)

    on_exit(fn ->
      _ = Memory.delete_working_memory(@agent_id)
      _ = Provenance.delete_agent(@agent_id)
    end)

    :ok
  end

  defp ensure_memory_services do
    if Process.whereis(@memory_store) == nil do
      start_supervised!({BufferedStore, name: @memory_store, backend: nil, write_mode: :sync})
    end

    if Process.whereis(Provenance) == nil do
      start_supervised!({Provenance, []})
    end
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
      profile = %{"agent_id" => @agent_id}

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
      assert :ok = Arbor.Memory.save_working_memory(@agent_id, wm)

      {:ok, seed} = Seed.capture(@agent_id)

      assert seed.working_memory != nil
      assert is_map(seed.working_memory)
      assert seed.working_memory["snapshot_kind"] == "arbor_working_memory_provenance"
      assert seed.working_memory["snapshot_version"] == 1
      assert seed.working_memory["working_memory"]["payload"]["agent_id"] == @agent_id
    end

    test "handles missing working_memory gracefully" do
      {:ok, seed} = Seed.capture(@agent_id)
      assert seed.working_memory == nil
    end

    test "security regression: configured goal authority outage fails capture" do
      use_unavailable_goal_export!()

      assert {:error, {:capture_failed, :goal_store_unavailable}} =
               Seed.capture(@agent_id)
    end

    test "security regression: configured WorkingMemory outage fails Seed capture explicitly" do
      take_authority_ownership!()
      _ = stop_supervised(BufferedStore)

      start_supervised!(
        {BufferedStore, name: @memory_store, backend: CaptureFailingBackend, write_mode: :sync}
      )

      assert {:error, {:capture_failed, :working_memory_snapshot_unavailable}} =
               Seed.capture(@agent_id)
    end

    test "captures knowledge_graph when initialized" do
      # Create the graph through the real API, as the working_memory sibling
      # above does. Inserting into :arbor_memory_graphs directly stopped working
      # when the durable graph authority landed (2026-08-05): that table is now
      # a write-only PROJECTION maintained by KnowledgeGraphStore, which reads
      # from the durable store and never from ETS. A direct insert is invisible
      # to Memory.export_knowledge_graph/1, so capture saw nil.
      # A DEDICATED agent id, not @agent_id. The graph now lives in the durable
      # store rather than a per-test ETS table, so seeding the shared id leaks
      # into sibling tests — "handles missing subsystems gracefully" asserts
      # knowledge_graph == nil and went order-dependently red.
      agent_id = "seed_kg_#{System.unique_integer([:positive])}"
      assert {:ok, _pid} = Memory.init_for_agent(agent_id)
      assert {:ok, _node_id} = Memory.add_knowledge(agent_id, %{type: :fact, content: "seeded"})
      on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)

      {:ok, seed} = Seed.capture(agent_id)

      assert seed.knowledge_graph != nil
      assert is_map(seed.knowledge_graph)
    end

    test "captures goals from GoalStore" do
      goal = Goal.new("Test goal", type: :achieve, priority: 80)
      assert {:ok, ^goal} = Memory.add_goal(@agent_id, goal)

      {:ok, seed} = Seed.capture(@agent_id)

      assert seed.goals["snapshot_kind"] == "arbor_goal_provenance"
      assert seed.goals["goal_store"]["agent_id"] == @agent_id
      [exported_goal] = seed.goals["goal_store"]["goals"]
      assert get_in(exported_goal, ["payload", Access.key(:description)]) == "Test goal"
      assert get_in(exported_goal, ["payload", Access.key(:type)]) == :achieve
    end

    test "handles missing subsystems gracefully" do
      # A PRISTINE agent id. This test asserts ABSENCE, so it cannot share
      # @agent_id with siblings that populate it — the restore/2 tests put a
      # knowledge graph there. That used to be harmless because the graph lived
      # in a per-test ETS table; since the durable graph authority landed
      # (2026-08-05) it persists, and this test went order-dependently red
      # roughly one run in three.
      agent_id = "seed_missing_#{System.unique_integer([:positive])}"
      on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)

      {:ok, seed} = Seed.capture(agent_id)

      assert seed.working_memory == nil
      assert seed.knowledge_graph == nil
      assert seed.self_knowledge == nil
      assert seed.preferences == nil
      assert seed.goals["goal_store"]["agent_id"] == agent_id
      assert seed.goals["goal_store"]["goals"] == []
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
    test "GoalStore owner routing preserves public Seed goal roundtrip" do
      ensure_goal_runtime()

      goal = Goal.new("Seed compatibility goal", id: "goal_seed_owner_compat")

      assert {:ok, ^goal} = Memory.add_goal(@agent_id, goal)
      assert {:ok, seed} = Seed.capture(@agent_id)

      assert Enum.any?(seed.goals["goal_store"]["goals"], fn record ->
               get_in(record, ["payload", Access.key(:id)]) == goal.id
             end)

      assert :ok = GoalStore.clear_goals(@agent_id)
      assert {:error, :not_found} = Memory.get_goal(@agent_id, goal.id)

      assert {:ok, _restored_seed} = Seed.restore(seed)
      assert {:ok, ^goal} = Memory.get_goal(@agent_id, goal.id)

      assert :ok = GoalStore.clear_goals(@agent_id)
    end

    test "security regression: public Seed roundtrip preserves hostile goal provenance" do
      ensure_goal_runtime()

      goal = Goal.new("Hostile Seed provenance", id: "goal_seed_hostile_provenance")

      {:ok, hostile} =
        Taint.new(%{
          level: :hostile,
          sensitivity: :restricted,
          sanitizations: 0,
          confidence: :unverified,
          source: "seed_hostile_roundtrip",
          chain: []
        })

      assert {:ok, ^goal} = GoalStore.add_goal_tainted(@agent_id, goal, hostile)
      assert {:ok, seed} = Seed.capture(@agent_id)
      assert {:ok, decoded} = seed |> Seed.serialize() |> Seed.deserialize()

      assert :ok = GoalStore.clear_goals(@agent_id)
      assert {:ok, _restored_seed} = Seed.restore(decoded)

      assert {:ok, %TaintedValue{value: ^goal, taint: ^hostile}, :verified} =
               GoalStore.get_goal_tainted(@agent_id, goal.id)

      assert :ok = GoalStore.clear_goals(@agent_id)
    end

    test "security regression: corrupt exact working memory cannot partially restore valid goals" do
      {seed, current_working_memory, current_goals} = cross_domain_seed_fixture()

      corrupt_working_memory =
        put_in(
          seed.working_memory,
          ["outer_envelope", "payload_sha256"],
          String.duplicate("0", 64)
        )

      assert {:error, {:restore_failed, :working_memory_snapshot_invalid}} =
               Seed.restore(%{seed | working_memory: corrupt_working_memory})

      assert {:ok, ^current_working_memory} =
               Memory.export_working_memory_provenance_snapshot(@agent_id)

      assert {:ok, ^current_goals} = Memory.export_goal_provenance_snapshot(@agent_id)
    end

    test "security regression: corrupt or partial goals cannot partially restore valid working memory" do
      {seed, current_working_memory, current_goals} = cross_domain_seed_fixture()

      corrupt_goals =
        put_in(
          seed.goals,
          ["outer_envelope", "payload_sha256"],
          String.duplicate("0", 64)
        )

      [exact_record] = seed.goals["goal_store"]["goals"]
      partial_goals = [Map.delete(exact_record, "provenance")]

      for malformed_goals <- [corrupt_goals, partial_goals] do
        assert {:error, {:restore_failed, :invalid_goal_snapshot}} =
                 Seed.restore(%{seed | goals: malformed_goals})

        assert {:ok, ^current_working_memory} =
                 Memory.export_working_memory_provenance_snapshot(@agent_id)

        assert {:ok, ^current_goals} = Memory.export_goal_provenance_snapshot(@agent_id)
      end
    end

    test "exact snapshot preflight honors each independent skip option" do
      {seed, current_working_memory, current_goals} = cross_domain_seed_fixture()

      corrupt_working_memory =
        put_in(
          seed.working_memory,
          ["outer_envelope", "payload_sha256"],
          String.duplicate("0", 64)
        )

      corrupt_goals =
        put_in(
          seed.goals,
          ["outer_envelope", "payload_sha256"],
          String.duplicate("0", 64)
        )

      assert {:ok, _seed} =
               Seed.restore(%{seed | working_memory: corrupt_working_memory, goals: []},
                 skip: [:working_memory]
               )

      assert {:ok, _seed} =
               Seed.restore(%{seed | working_memory: nil, goals: corrupt_goals}, skip: [:goals])

      assert {:ok, ^current_working_memory} =
               Memory.export_working_memory_provenance_snapshot(@agent_id)

      assert {:ok, ^current_goals} = Memory.export_goal_provenance_snapshot(@agent_id)
    end

    test "security regression: corrupt exact goal snapshot fails restore" do
      goal = Goal.new("Corrupt exact Seed goal", id: "goal_seed_corrupt_exact")

      seed = %Seed{
        id: "seed_corrupt_goal",
        agent_id: @agent_id,
        goals: [%{version: 1, payload: goal |> Map.from_struct()}]
      }

      assert {:error, {:restore_failed, :invalid_goal_snapshot}} = Seed.restore(seed)
      assert {:error, :not_found} = Memory.get_goal(@agent_id, goal.id)
    end

    test "security regression: configured goal authority outage fails restore" do
      goal = Goal.new("Unavailable Seed restore", id: "goal_seed_unavailable_restore")

      seed = %Seed{
        id: "seed_unavailable_goal",
        agent_id: @agent_id,
        goals: [goal |> Map.from_struct()]
      }

      use_unavailable_goal_store!()

      assert {:error, {:restore_failed, :goal_store_unavailable}} = Seed.restore(seed)
      assert [] = :ets.lookup(:arbor_memory_goals, {@agent_id, goal.id})
    end

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

    test "security regression: hostile provenance survives Seed serialization and restore" do
      {:ok, trusted} =
        Taint.new(%{
          level: :trusted,
          sensitivity: :public,
          sanitizations: 0,
          confidence: :verified,
          source: "seed-trusted-base",
          chain: []
        })

      {:ok, hostile} =
        Taint.new(%{
          level: :hostile,
          sensitivity: :restricted,
          sanitizations: 0,
          confidence: :verified,
          source: "seed-hostile-roundtrip",
          chain: []
        })

      base = WorkingMemory.new(@agent_id, rebuild_from_signals: false)
      assert :ok = WorkingMemoryStore.save_working_memory_tainted(@agent_id, base, trusted)

      wm = WorkingMemory.add_thought(base, "hostile portable thought")

      [thought] = wm.recent_thoughts

      assert :ok = WorkingMemoryStore.save_working_memory_tainted(@agent_id, wm, hostile)
      assert {:ok, seed} = Seed.capture(@agent_id)
      captured_snapshot = seed.working_memory

      serialized = Seed.serialize(seed)
      assert {:ok, decoded_seed} = Seed.deserialize(serialized)

      assert :ok = Memory.delete_working_memory(@agent_id)
      assert nil == Memory.get_working_memory(@agent_id)
      assert {:ok, _restored_seed} = Seed.restore(decoded_seed)

      assert {:ok, ^captured_snapshot} =
               Memory.export_working_memory_provenance_snapshot(@agent_id)

      assert {:ok, restored} = WorkingMemoryStore.get_working_memory_tainted(@agent_id)
      assert {:ok, expected_aggregate} = Taint.join_many([trusted, hostile])
      assert restored.value.taint == expected_aggregate

      assert %{value: %{value: ^thought, taint: ^hostile}, provenance_status: :verified} =
               hd(restored.items.recent_thoughts)
    end

    test "security regression: corrupt or partial provenance snapshot restore fails without mutation" do
      {:ok, trusted} =
        Taint.new(%{
          level: :trusted,
          sensitivity: :public,
          sanitizations: 0,
          confidence: :verified,
          source: "seed-restore-baseline",
          chain: []
        })

      baseline = WorkingMemory.new(@agent_id, rebuild_from_signals: false)
      assert :ok = WorkingMemoryStore.save_working_memory_tainted(@agent_id, baseline, trusted)
      assert {:ok, original} = Memory.export_working_memory_provenance_snapshot(@agent_id)

      corrupt =
        put_in(original, ["outer_envelope", "payload_sha256"], String.duplicate("0", 64))

      changed_raw =
        baseline
        |> WorkingMemory.add_thought("must not enter through legacy import")
        |> Memory.serialize_working_memory()
        |> Map.put("snapshot_version", 1)

      for malformed <- [corrupt, changed_raw] do
        seed = %Seed{id: "seed_malformed", agent_id: @agent_id, working_memory: malformed}

        assert {:error, {:restore_failed, :working_memory_snapshot_invalid}} =
                 Seed.restore(seed)

        assert {:ok, ^original} =
                 Memory.export_working_memory_provenance_snapshot(@agent_id)
      end
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

  defp cross_domain_seed_fixture do
    {:ok, hostile} =
      Taint.new(%{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: "seed_cross_domain_incoming",
        chain: []
      })

    incoming_memory =
      @agent_id
      |> WorkingMemory.new(rebuild_from_signals: false)
      |> WorkingMemory.add_thought("incoming hostile working memory")

    incoming_goal = Goal.new("incoming hostile goal", id: "goal_seed_cross_domain_incoming")

    assert :ok =
             WorkingMemoryStore.save_working_memory_tainted(
               @agent_id,
               incoming_memory,
               hostile
             )

    assert {:ok, ^incoming_goal} =
             GoalStore.add_goal_tainted(@agent_id, incoming_goal, hostile)

    assert {:ok, seed} = Seed.capture(@agent_id)

    assert :ok = Memory.delete_working_memory(@agent_id)
    assert :ok = GoalStore.clear_goals(@agent_id)

    {:ok, trusted} =
      Taint.new(%{
        level: :trusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :verified,
        source: "seed_cross_domain_current",
        chain: []
      })

    current_memory =
      @agent_id
      |> WorkingMemory.new(rebuild_from_signals: false)
      |> WorkingMemory.add_thought("current working memory must remain")

    current_goal = Goal.new("current goal must remain", id: "goal_seed_cross_domain_current")

    assert :ok =
             WorkingMemoryStore.save_working_memory_tainted(@agent_id, current_memory, trusted)

    assert {:ok, ^current_goal} = GoalStore.add_goal_tainted(@agent_id, current_goal, trusted)

    assert {:ok, current_working_memory} =
             Memory.export_working_memory_provenance_snapshot(@agent_id)

    assert {:ok, current_goals} = Memory.export_goal_provenance_snapshot(@agent_id)

    {seed, current_working_memory, current_goals}
  end

  # test_helper starts a suite-wide :arbor_memory_durable via
  # Arbor.Memory.TestBootstrap — 18 tests in this app (Lifecycle.create,
  # TrustPresetApply) need it. The outage simulations below must still be able
  # to OWN that name, so they hand it to ExUnit's supervisor first.
  defp take_authority_ownership! do
    # Releasing the name is a no-op ({:error, :not_found}) when Memory.Supervisor
    # does not own it, so this needs no detection heuristic — just always release
    # and always restore.
    case Supervisor.terminate_child(Arbor.Memory.Supervisor, Arbor.Persistence.BufferedStore) do
      :ok ->
        ExUnit.Callbacks.on_exit(fn ->
          Supervisor.restart_child(Arbor.Memory.Supervisor, Arbor.Persistence.BufferedStore)
        end)

      {:error, _} ->
        :ok
    end
  end

  defp ensure_goal_runtime do
    if Process.whereis(:arbor_memory_durable) == nil do
      start_supervised!({BufferedStore, name: :arbor_memory_durable, backend: nil})
    end

    if Process.whereis(Provenance) == nil do
      start_supervised!(Provenance)
    end

    if Process.whereis(GoalStore) == nil do
      start_supervised!(GoalStore)
    end
  end

  defp use_unavailable_goal_store! do
    take_authority_ownership!()
    _ = stop_supervised(BufferedStore)

    start_supervised!(
      {BufferedStore,
       name: :arbor_memory_durable,
       backend: UnavailableBackend,
       collection: :seed_unavailable,
       write_mode: :async,
       ack_mode: :cache}
    )
  end

  defp use_unavailable_goal_export! do
    take_authority_ownership!()
    _ = stop_supervised(BufferedStore)

    start_supervised!(
      {BufferedStore,
       name: :arbor_memory_durable,
       backend: GoalExportUnavailableBackend,
       collection: :seed_goal_export_unavailable,
       write_mode: :async,
       ack_mode: :cache}
    )
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
      assert {:ok, ^goal} = Memory.add_goal(@agent_id, goal)

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
      assert Seed.stats(restored).goal_count == 1
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
      assert :ok = Arbor.Memory.delete_working_memory(@agent_id)
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
