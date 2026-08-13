defmodule Arbor.Memory.FourDomainMutationInventoryClosureTest do
  @moduledoc """
  Four-domain MutationAdmission inventory closure (VP-05D2C3I1B2E).

  Behavioral drain proof plus an AST-backed public-entry and effect-site
  guard. Does not claim the source inventory proves runtime ordering.
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.CodeStore
  alias Arbor.Memory.Events
  alias Arbor.Memory.IdentityConsolidator
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.DrainFence
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.Preferences
  alias Arbor.Memory.PreferencesStore
  alias Arbor.Memory.Relationship
  alias Arbor.Memory.RelationshipStore
  alias Arbor.Memory.SelfKnowledge
  alias Arbor.Memory.Signals
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :database
  @moduletag packet: "VP-05D2C3I1B2E"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @preferences_ets :arbor_preferences
  @self_knowledge_ets :arbor_self_knowledge
  @code_ets :arbor_memory_code_store
  @preferences_ns "preferences"
  @self_knowledge_ns "self_knowledge"
  @code_ns "code_patterns"
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :four_domain_close_ma_fake
  @signal_absent_timeout 200
  @content_tables MapSet.new([
                    :arbor_preferences,
                    :arbor_self_knowledge,
                    :arbor_memory_code_store
                  ])
  @ignored_ets_tables MapSet.new([
                        :arbor_identity_rate_limits,
                        :arbor_consolidation_state
                      ])

  @lib_dir Path.expand("../../../lib/arbor/memory", __DIR__)
  @tracked_files [
    {"preferences_store.ex", Path.join(@lib_dir, "preferences_store.ex")},
    {"identity_consolidator.ex", Path.join(@lib_dir, "identity_consolidator.ex")},
    {"code_store.ex", Path.join(@lib_dir, "code_store.ex")},
    {"relationship_store.ex", Path.join(@lib_dir, "relationship_store.ex")}
  ]

  @public_entries %{
    {"preferences_store.ex", :save_preferences, 2} => :mutation,
    {"preferences_store.ex", :get_or_create, 1} => :mutation,
    {"preferences_store.ex", :adjust_preference, 4} => :mutation,
    {"preferences_store.ex", :pin_memory, 3} => :mutation,
    {"preferences_store.ex", :unpin_memory, 2} => :mutation,
    {"preferences_store.ex", :set_context_preference, 3} => :mutation,
    {"preferences_store.ex", :save_preferences_for_agent, 2} => :mutation,
    {"preferences_store.ex", :restore_from_store, 0} => :mutation,
    {"preferences_store.ex", :get_preferences, 1} => :read,
    {"preferences_store.ex", :inspect_preferences, 1} => :read,
    {"preferences_store.ex", :introspect_preferences, 1} => :read,
    {"preferences_store.ex", :get_context_preference, 3} => :read,
    {"preferences_store.ex", :delete_agent_content, 1} => :cleanup,
    {"preferences_store.ex", :agent_content_absent?, 1} => :cleanup,
    {"identity_consolidator.ex", :save_self_knowledge, 2} => :mutation,
    {"identity_consolidator.ex", :apply_accepted_change, 2} => :mutation,
    {"identity_consolidator.ex", :rollback, 2} => :mutation,
    {"identity_consolidator.ex", :get_self_knowledge, 1} => :read,
    {"identity_consolidator.ex", :delete_agent_content, 1} => :cleanup,
    {"identity_consolidator.ex", :agent_content_absent?, 1} => :cleanup,
    {"identity_consolidator.ex", :consolidate, 2} => :adjacent,
    {"identity_consolidator.ex", :should_consolidate?, 2} => :adjacent,
    {"identity_consolidator.ex", :history, 2} => :adjacent,
    {"identity_consolidator.ex", :get_consolidation_state, 1} => :adjacent,
    {"identity_consolidator.ex", :find_promotion_candidates, 2} => :adjacent,
    {"identity_consolidator.ex", :block_insight, 3} => :adjacent,
    {"identity_consolidator.ex", :unblock_insight, 2} => :adjacent,
    {"code_store.ex", :store, 2} => :mutation,
    {"code_store.ex", :delete, 2} => :mutation,
    {"code_store.ex", :clear, 1} => :mutation,
    {"code_store.ex", :find_by_purpose, 2} => :read,
    {"code_store.ex", :list, 2} => :read,
    {"code_store.ex", :get, 2} => :read,
    {"code_store.ex", :delete_agent_content, 1} => :cleanup,
    {"code_store.ex", :agent_content_absent?, 1} => :cleanup,
    {"code_store.ex", :start_link, 1} => :adjacent,
    {"code_store.ex", :init, 1} => :adjacent,
    {"relationship_store.ex", :put, 2} => :mutation,
    {"relationship_store.ex", :delete, 2} => :mutation,
    {"relationship_store.ex", :update, 3} => :mutation,
    {"relationship_store.ex", :touch, 2} => :mutation,
    {"relationship_store.ex", :get_with_tracking, 2} => :mutation,
    {"relationship_store.ex", :get_by_name_with_tracking, 2} => :mutation,
    {"relationship_store.ex", :get_primary_with_tracking, 1} => :mutation,
    {"relationship_store.ex", :save, 2} => :mutation,
    {"relationship_store.ex", :add_moment, 4} => :mutation,
    {"relationship_store.ex", :get, 2} => :read,
    {"relationship_store.ex", :get_by_name, 2} => :read,
    {"relationship_store.ex", :list, 2} => :read,
    {"relationship_store.ex", :get_primary, 1} => :read,
    {"relationship_store.ex", :count, 1} => :read,
    {"relationship_store.ex", :delete_all, 1} => :cleanup,
    {"relationship_store.ex", :absent?, 1} => :cleanup
  }

  @accepted_effect_sites MapSet.new([
                           {"preferences_store.ex", {:commit_preferences, 3},
                            {Arbor.Memory.MemoryStore, :reserve_persist_async, 4}},
                           {"preferences_store.ex", {:admit_and_commit, 4},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"preferences_store.ex", {:admit_and_commit, 4},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"preferences_store.ex", {:admit_and_commit, 4},
                            {Arbor.Memory.MemoryStore, :activate_async, 1}},
                           {"preferences_store.ex", {:admit_and_commit, 4},
                            {Arbor.Memory.MemoryStore, :cancel_async, 1}},
                           {"preferences_store.ex", {:admit_and_commit, 4}, {:ets, :insert, 2}},
                           {"preferences_store.ex", {:project_loaded_pair, 1},
                            {Arbor.Memory.MutationAdmission, :status, 1}},
                           {"preferences_store.ex", {:project_loaded_pair, 1},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"preferences_store.ex", {:project_loaded_pair, 1},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"preferences_store.ex", {:project_loaded_pair, 1},
                            {:ets, :insert, 2}},
                           {"preferences_store.ex", {:confirm_preferences_ets_evicted, 1},
                            {:ets, :delete, 2}},
                           {"preferences_store.ex", {:delete_authoritative_content_only, 1},
                            {Arbor.Memory.MemoryStore, :delete_tainted_authoritative, 2}},
                           {"identity_consolidator.ex", {:save_self_knowledge, 2},
                            {Arbor.Memory.MemoryStore, :reserve_persist_async, 4}},
                           {"identity_consolidator.ex", {:admit_and_save, 3},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"identity_consolidator.ex", {:admit_and_save, 3},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"identity_consolidator.ex", {:admit_and_save, 3},
                            {Arbor.Memory.MemoryStore, :activate_async, 1}},
                           {"identity_consolidator.ex", {:admit_and_save, 3},
                            {Arbor.Memory.MemoryStore, :cancel_async, 1}},
                           {"identity_consolidator.ex", {:admit_and_save, 3}, {:ets, :insert, 2}},
                           {"identity_consolidator.ex", {:project_loaded_self_knowledge, 2},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"identity_consolidator.ex", {:project_loaded_self_knowledge, 2},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"identity_consolidator.ex", {:project_loaded_self_knowledge, 2},
                            {:ets, :insert, 2}},
                           {"identity_consolidator.ex", {:confirm_self_knowledge_ets_evicted, 1},
                            {:ets, :delete, 2}},
                           {"identity_consolidator.ex",
                            {:delete_authoritative_self_knowledge_content, 1},
                            {Arbor.Memory.MemoryStore, :delete_tainted_authoritative, 2}},
                           {"code_store.ex", {:store, 2},
                            {Arbor.Memory.MemoryStore, :reserve_persist_async, 4}},
                           {"code_store.ex", {:reserve_embed_and_store, 5},
                            {Arbor.Memory.MemoryStore, :reserve_embed_async, 4}},
                           {"code_store.ex", {:reserve_embed_and_store, 5},
                            {Arbor.Memory.MemoryStore, :cancel_async, 1}},
                           {"code_store.ex", {:admit_and_store, 4},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"code_store.ex", {:admit_and_store, 4},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"code_store.ex", {:admit_and_store, 4},
                            {Arbor.Memory.MemoryStore, :cancel_async, 1}},
                           {"code_store.ex", {:admit_and_store, 4}, {:ets, :insert, 2}},
                           {"code_store.ex", {:activate_store_children, 4},
                            {Arbor.Memory.MemoryStore, :activate_async, 1}},
                           {"code_store.ex", {:activate_store_children, 4},
                            {Arbor.Memory.MemoryStore, :cancel_async, 1}},
                           {"code_store.ex", {:delete, 2},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"code_store.ex", {:delete, 2},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"code_store.ex", {:delete, 2}, {:ets, :insert, 2}},
                           {"code_store.ex", {:delete, 2},
                            {Arbor.Memory.MemoryStore, :delete, 2}},
                           {"code_store.ex", {:clear, 1},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"code_store.ex", {:clear, 1},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"code_store.ex", {:clear, 1}, {:ets, :delete, 2}},
                           {"code_store.ex", {:clear, 1},
                            {Arbor.Memory.MemoryStore, :delete_by_prefix, 2}},
                           {"code_store.ex", {:project_agent_entries, 2},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"code_store.ex", {:project_agent_entries, 2},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"code_store.ex", {:project_agent_entries, 2}, {:ets, :insert, 2}},
                           {"code_store.ex", {:confirm_code_ets_evicted, 1}, {:ets, :delete, 2}},
                           {"code_store.ex", {:delete_code_records, 2},
                            {Arbor.Memory.MemoryStore, :delete_tainted_authoritative, 2}},
                           {"relationship_store.ex", {:with_fresh_admission, 2},
                            {Arbor.Memory.MutationAdmission, :acquire, 1}},
                           {"relationship_store.ex", {:with_fresh_admission, 2},
                            {Arbor.Memory.MutationAdmission, :release, 1}},
                           {"relationship_store.ex", {:persist_put, 2},
                            {Arbor.Persistence, :put_relationship, 2}},
                           {"relationship_store.ex", {:persist_update, 3},
                            {Arbor.Persistence, :update_relationship, 3}},
                           {"relationship_store.ex", {:persist_delete, 2},
                            {Arbor.Persistence, :delete_relationship, 2}},
                           {"relationship_store.ex", {:persist_touch, 2},
                            {Arbor.Persistence, :touch_relationship, 2}},
                           {"relationship_store.ex", {:delete_all, 1},
                            {Arbor.Persistence, :delete_all_relationships, 1}}
                         ])

  @tag :integration
  @tag :database
  test "same-agent drain denies all four public mutations while an independent agent remains writable" do
    ensure_durable_store!()
    ensure_preferences_ets!()
    ensure_self_knowledge_ets!()
    ensure_code_store!()
    ensure_default_admission!()

    {:ok, cell} = Agent.start(fn -> %{subs: [], lease: nil} end)

    on_exit(fn ->
      state =
        try do
          Agent.get(cell, & &1)
        catch
          :exit, _ -> %{subs: [], lease: nil}
        end

      unsubscribe_all(state.subs)
      stop_agent(cell)
    end)

    target = unique_agent("t")
    control = unique_agent("c")

    prefs = Preferences.new(target)
    assert :ok = PreferencesStore.save_preferences(target, prefs)
    await_durable!(@preferences_ns, target)

    sk = target |> SelfKnowledge.new() |> SelfKnowledge.add_trait(:curious, 0.8)
    assert :ok = IdentityConsolidator.save_self_knowledge(target, sk)
    await_durable!(@self_knowledge_ns, target)

    assert {:ok, code_entry} =
             CodeStore.store(target, %{
               code: "fn x -> x end",
               language: "elixir",
               purpose: "seed-cross-domain"
             })

    await_durable!(@code_ns, target <> ":" <> code_entry.id)

    assert {:ok, seeded_rel} = RelationshipStore.put(target, Relationship.new("SeedPeer"))

    wait_until(fn ->
      match?({:ok, %{active_roots: 0}}, MutationAdmission.status(target))
    end)

    wait_until(fn -> writer_children() == [] end)

    before = %{
      prefs_ets: :ets.lookup(@preferences_ets, target),
      prefs_bytes: durable_bytes!(@preferences_ns, target),
      prefs_signals: recent_signals(target),
      sk_ets: :ets.lookup(@self_knowledge_ets, target),
      sk_bytes: durable_bytes!(@self_knowledge_ns, target),
      sk_signals: recent_signals(target),
      sk_events: identity_history(target),
      code_ets: :ets.lookup(@code_ets, target),
      code_bytes: durable_bytes!(@code_ns, target <> ":" <> code_entry.id),
      rel_bytes: row_bytes!(target, seeded_rel.id),
      rel_created: event_ids(target, :relationship_created),
      rel_moments: event_ids(target, :relationship_moment)
    }

    subs = subscribe!([:relationship_created, :relationship_updated, :moment_added])
    Agent.update(cell, &%{&1 | subs: subs})

    assert {:ok, lease} = MutationAdmission.acquire(target)
    Agent.update(cell, &%{&1 | lease: lease})

    try do
      tester = self()

      {drain_pid, drain_mon} =
        spawn_monitor(fn ->
          send(tester, {:drain_done, MutationAdmission.drain(target, timeout_ms: 10_000)})
        end)

      wait_until(fn ->
        match?(
          {:ok, %{gate: :draining, active_roots: n, drain_waiters: w}}
          when n >= 1 and w >= 1,
          MutationAdmission.status(target)
        )
      end)

      assert Process.alive?(drain_pid)
      refute_received {:DOWN, ^drain_mon, :process, ^drain_pid, _}

      before_children = writer_children()

      {:ok, changed_prefs} = Preferences.adjust(prefs, :decay_rate, 0.12)
      changed_sk = SelfKnowledge.add_trait(sk, :methodical, 0.9)
      denied_rel = Relationship.new("DeniedPeer")

      results = [
        PreferencesStore.save_preferences(target, changed_prefs),
        IdentityConsolidator.save_self_knowledge(target, changed_sk),
        CodeStore.store(target, %{
          code: "fn y -> y end",
          language: "elixir",
          purpose: "denied-cross-domain"
        }),
        RelationshipStore.save(target, denied_rel)
      ]

      assert results == [
               {:error, :store_unavailable},
               {:error, :store_unavailable},
               {:error, :store_unavailable},
               {:error, :store_unavailable}
             ]

      assert :ets.lookup(@preferences_ets, target) == before.prefs_ets
      assert durable_bytes!(@preferences_ns, target) == before.prefs_bytes
      assert recent_signals(target) == before.prefs_signals
      assert :ets.lookup(@self_knowledge_ets, target) == before.sk_ets
      assert durable_bytes!(@self_knowledge_ns, target) == before.sk_bytes
      assert recent_signals(target) == before.sk_signals
      assert identity_history(target) == before.sk_events
      assert :ets.lookup(@code_ets, target) == before.code_ets
      assert durable_bytes!(@code_ns, target <> ":" <> code_entry.id) == before.code_bytes
      refute code_purpose?(target, "denied-cross-domain")
      assert row_bytes!(target, seeded_rel.id) == before.rel_bytes
      assert {:error, :not_found} = Persistence.fetch_relationship(target, denied_rel.id)
      assert event_ids(target, :relationship_created) == before.rel_created
      assert event_ids(target, :relationship_moment) == before.rel_moments
      refute_receive {:sig, :relationship_created, _}, @signal_absent_timeout
      refute_receive {:sig, :relationship_updated, _}, @signal_absent_timeout
      refute_receive {:sig, :moment_added, _}, @signal_absent_timeout
      assert writer_children() == before_children

      assert {:ok, %{gate: :draining, active_roots: n}} =
               MutationAdmission.status(target)

      assert n >= 1

      assert :ok = PreferencesStore.save_preferences(control, Preferences.new(control))

      assert :ok =
               IdentityConsolidator.save_self_knowledge(
                 control,
                 control |> SelfKnowledge.new() |> SelfKnowledge.add_trait(:curious, 0.7)
               )

      assert {:ok, control_code} =
               CodeStore.store(control, %{
                 code: "fn z -> z end",
                 language: "elixir",
                 purpose: "control-cross-domain"
               })

      assert {:ok, control_rel} =
               RelationshipStore.save(control, Relationship.new("OpenPeer"))

      assert_receive {:sig, :relationship_created, created_sig}, 2_000
      assert created_sig.data.relationship_id == control_rel.id
      assert event_ids(control, :relationship_created) != []

      assert wait_until(fn ->
               durable_relationship_event?(control, control_rel.id)
             end)

      await_durable!(@preferences_ns, control)
      await_durable!(@self_knowledge_ns, control)
      await_durable!(@code_ns, control <> ":" <> control_code.id)

      wait_until(fn ->
        match?({:ok, %{active_roots: 0}}, MutationAdmission.status(control))
      end)

      wait_until(fn -> writer_children() == [] end)

      assert :ok = MutationAdmission.release(lease)
      Agent.update(cell, &%{&1 | lease: nil})

      assert_receive {:drain_done, {:ok, %DrainFence{agent_id: ^target}}}, 10_000
      assert_receive {:DOWN, ^drain_mon, :process, ^drain_pid, _reason}, 2_000

      assert {:ok, %{gate: :draining, active_roots: 0, drain_waiters: 0}} =
               MutationAdmission.status(target)

      assert writer_children() == []
    after
      case Agent.get(cell, & &1.lease) do
        %Lease{} = held ->
          _ = MutationAdmission.release(held)
          Agent.update(cell, &%{&1 | lease: nil})

        _ ->
          :ok
      end
    end
  end

  @tag :fast
  test "source inventory matches the accepted four-domain manifest" do
    inventories =
      Enum.map(@tracked_files, fn {file, path} ->
        ast = path |> File.read!() |> Code.string_to_quoted!()
        {file, inventory(file, ast)}
      end)

    public =
      inventories
      |> Enum.flat_map(fn {_file, inv} -> Map.to_list(inv.public) end)
      |> Map.new()

    effects =
      inventories
      |> Enum.reduce(MapSet.new(), fn {_file, inv}, acc -> MapSet.union(acc, inv.effects) end)

    forbidden =
      Enum.flat_map(inventories, fn {file, inv} ->
        Enum.map(inv.forbidden, &{file, &1})
      end)

    unclassified =
      public
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(@public_entries, &1))

    missing =
      @public_entries
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(public, &1))

    assert Enum.all?(
             Map.values(@public_entries),
             &(&1 in [:mutation, :read, :cleanup, :adjacent])
           )

    assert unclassified == [], "unclassified public entries: #{inspect(unclassified)}"
    assert missing == [], "missing classified public entries: #{inspect(missing)}"
    assert forbidden == [], "forbidden forms: #{inspect(forbidden)}"

    added = MapSet.difference(effects, @accepted_effect_sites)
    removed = MapSet.difference(@accepted_effect_sites, effects)

    drift = effect_drift(added, removed)

    assert drift == [], "effect-site drift: #{inspect(drift)}"
  end

  @tag :fast
  test "red fixtures: alias and remote AsyncWriter" do
    source = """
    defmodule RedAlias do
      alias Arbor.Memory.AsyncWriter
      def go, do: AsyncWriter.start(:op)
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:alias, Arbor.Memory.AsyncWriter} in hits
    assert {:remote, Arbor.Memory.AsyncWriter, :start} in hits
  end

  @tag :fast
  test "red fixtures: fully-qualified persist_async" do
    source = """
    defmodule RedRemote do
      def go, do: Arbor.Memory.MemoryStore.persist_async("ns", "k", %{}, [])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:persist_async, Arbor.Memory.MemoryStore} in hits
  end

  @tag :fast
  test "red fixtures: function capture" do
    source = """
    defmodule RedCapture do
      def go, do: &Arbor.Memory.AsyncWriter.start/1
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:capture, Arbor.Memory.AsyncWriter} in hits
  end

  @tag :fast
  test "red fixtures: captured persist_async and embed_async" do
    source = """
    defmodule RedCapturePersist do
      alias Arbor.Memory.MemoryStore
      def go do
        &MemoryStore.persist_async/4
        &Arbor.Memory.MemoryStore.embed_async/4
      end
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:capture, Arbor.Memory.MemoryStore} in hits
    assert {:persist_async, Arbor.Memory.MemoryStore} in hits
    assert {:embed_async, Arbor.Memory.MemoryStore} in hits
  end

  @tag :fast
  test "red fixtures: imported persist_async" do
    source = """
    defmodule RedImportPersist do
      import Arbor.Memory.MemoryStore, only: [persist_async: 4]
      def go, do: persist_async("ns", "k", %{}, [])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:import, Arbor.Memory.MemoryStore} in hits
    assert {:persist_async, Arbor.Memory.MemoryStore} in hits
  end

  @tag :fast
  test "red fixtures: bare apply/3" do
    source = """
    defmodule RedApply do
      def go, do: apply(Arbor.Memory.MemoryStore, :embed_async, ["ns", "k", "c", []])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:apply, Arbor.Memory.MemoryStore} in hits
    assert {:embed_async, Arbor.Memory.MemoryStore} in hits
  end

  @tag :fast
  test "red fixtures: Kernel.apply before generic remote match" do
    source = """
    defmodule RedKernelApply do
      def go, do: Kernel.apply(Arbor.Memory.AsyncWriter, :start, [:op])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:kernel_apply, Arbor.Memory.AsyncWriter} in hits
    refute Enum.any?(hits, &match?({:remote, Kernel, _}, &1))
  end

  @tag :fast
  test "red fixtures: :erlang.apply" do
    source = """
    defmodule RedErlangApply do
      def go, do: :erlang.apply(Arbor.Persistence.Repo, :all, [[]])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:erlang_apply, Arbor.Persistence.Repo} in hits
  end

  @tag :fast
  test "red fixtures: Task.async and spawn" do
    source = """
    defmodule RedDetach do
      def go do
        Task.async(fn -> :ok end)
        spawn(fn -> :ok end)
      end
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:task, :async} in hits
    assert {:spawn, :spawn} in hits
  end

  @tag :fast
  test "red fixtures: Task alias" do
    source = """
    defmodule RedTaskAlias do
      alias Task, as: Jobs
      def go, do: Jobs.async(fn -> :ok end)
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:alias, Task} in hits
    assert {:task, :async} in hits
  end

  @tag :fast
  test "red fixtures: caller-supplied lease and Persistence.Repo" do
    source = """
    defmodule RedLeaseAndRepo do
      def go(id, lease) do
        Arbor.Memory.MutationAdmission.acquire(id, lease: lease)
        Arbor.Memory.MutationAdmission.force_release(lease)
        Arbor.Persistence.Repo.all(:q)
      end
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:acquire_lease, Arbor.Memory.MutationAdmission} in hits
    assert {:force_release, Arbor.Memory.MutationAdmission} in hits
    assert {:remote, Arbor.Persistence.Repo, :all} in hits
  end

  @tag :fast
  test "red fixtures: Persistence internal other than the public facade" do
    source = """
    defmodule RedPersistenceInternal do
      def go, do: Arbor.Persistence.BufferedStore.get("k", [])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:remote, Arbor.Persistence.BufferedStore, :get} in hits
  end

  @tag :fast
  test "clean public Persistence facade and reserve/activate patterns are admitted" do
    source = """
    defmodule Clean do
      alias Arbor.Memory.MemoryStore
      alias Arbor.Memory.MutationAdmission
      alias Arbor.Persistence

      def go(agent, data) do
        {:ok, reservation} = MemoryStore.reserve_persist_async("ns", agent, data, agent_id: agent)
        {:ok, lease} = MutationAdmission.acquire(agent)
        :ets.insert(:arbor_preferences, {agent, data})
        _ = MemoryStore.activate_async(reservation)
        _ = MutationAdmission.release(lease)
        _ = MutationAdmission.status(agent)
        _ = MemoryStore.load("ns", agent)
        Persistence.put_relationship(agent, %{})
      end
    end
    """

    assert detect_forbidden(Code.string_to_quoted!(source)) == []
  end

  # ---------------------------------------------------------------------------
  # Behavioral helpers
  # ---------------------------------------------------------------------------

  defp unique_agent(label), do: "close_#{label}_#{System.unique_integer([:positive])}"

  defp durable_bytes!(namespace, key) do
    assert {:ok, _value, _status, record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(namespace, key)

    :erlang.term_to_binary(record.data)
  end

  defp await_durable!(namespace, key) do
    assert wait_until(fn ->
             match?(
               {:ok, _, _, _, _},
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)
             )
           end)
  end

  defp row_bytes!(agent_id, relationship_id) do
    assert {:ok, plain} = Persistence.fetch_relationship(agent_id, relationship_id)
    :erlang.term_to_binary(plain)
  end

  defp event_ids(agent_id, type) do
    assert {:ok, events} = Events.get_by_type(agent_id, type)
    events |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp durable_relationship_event?(agent_id, relationship_id) do
    case Persistence.read_stream(
           :historian_durable_event_log,
           Arbor.Persistence.EventLog.Ecto,
           "memory:" <> agent_id,
           repo: Arbor.Persistence.Repo
         ) do
      {:ok, events} ->
        Enum.any?(events, fn event ->
          data = Map.get(event, :data) || Map.get(event, "data") || %{}
          type = Map.get(event, :type) || Map.get(event, "type")
          persisted_id = Map.get(data, :relationship_id) || Map.get(data, "relationship_id")

          type == "relationship_created" and persisted_id == relationship_id
        end)

      _ ->
        false
    end
  end

  defp identity_history(agent_id) do
    case IdentityConsolidator.history(agent_id) do
      {:ok, events} when is_list(events) ->
        Enum.map(events, fn event ->
          {Map.get(event, :type) || Map.get(event, "type"),
           Map.get(event, :id) || Map.get(event, "id")}
        end)

      _ ->
        []
    end
  end

  defp recent_signals(agent_id) do
    case Signals.query_recent(agent_id, types: [:cognitive_adjustment]) do
      {:ok, signals} -> Enum.map(signals, fn signal -> {signal.type, signal.id} end)
      _ -> []
    end
  end

  defp code_purpose?(agent_id, purpose) do
    case :ets.lookup(@code_ets, agent_id) do
      [{^agent_id, entries}] when is_list(entries) ->
        Enum.any?(entries, fn entry -> Map.get(entry, :purpose) == purpose end)

      _ ->
        false
    end
  end

  defp writer_children do
    case Process.whereis(WriterSupervisor.name()) do
      nil -> []
      pid -> DynamicSupervisor.which_children(pid)
    end
  end

  defp subscribe!(types) do
    Enum.map(types, fn type ->
      tester = self()
      pattern = "memory." <> Atom.to_string(type)

      {:ok, sub_id} =
        Arbor.Signals.subscribe(pattern, fn signal ->
          send(tester, {:sig, type, signal})
        end)

      sub_id
    end)
  end

  defp unsubscribe_all(subs) when is_list(subs) do
    Enum.each(subs, fn sub_id ->
      try do
        _ = Arbor.Signals.unsubscribe(sub_id)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp unsubscribe_all(_), do: :ok

  defp stop_agent(cell) do
    Agent.stop(cell)
  catch
    :exit, _ -> :ok
  end

  defp wait_until(fun, attempts \\ 80)
  defp wait_until(fun, 0), do: fun.() || flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        25 -> wait_until(fun, attempts - 1)
      end
    end
  end

  defp ensure_default_admission! do
    case MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      _ ->
        start_parent_admission_stack!()
    end
  end

  defp start_parent_admission_stack! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    unless Process.whereis(MutationAdmission) do
      start_supervised!(
        {MutationAdmission,
         [
           target: %{
             namespace: :memory_mutation_admission,
             backend: Fake,
             opts: [agent_name: @fake_name]
           }
         ]}
      )
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  defp ensure_preferences_ets! do
    if :ets.whereis(@preferences_ets) == :undefined do
      :ets.new(@preferences_ets, [:named_table, :public, :set])
    end

    :ok
  end

  defp ensure_self_knowledge_ets! do
    if :ets.whereis(@self_knowledge_ets) == :undefined do
      :ets.new(@self_knowledge_ets, [:named_table, :public, :set])
    end

    :ok
  end

  defp ensure_code_store! do
    case Process.whereis(CodeStore) do
      pid when is_pid(pid) ->
        if :ets.whereis(@code_ets) == :undefined do
          assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, CodeStore)
          restart_code_store_child!()
        else
          :ok
        end

      nil ->
        restart_code_store_child!()
    end
  end

  defp restart_code_store_child! do
    case Supervisor.restart_child(Arbor.Memory.Supervisor, CodeStore) do
      {:ok, _pid} ->
        assert is_pid(Process.whereis(CodeStore))
        assert :ets.whereis(@code_ets) != :undefined
        :ok

      {:error, {:already_started, _pid}} ->
        assert is_pid(Process.whereis(CodeStore))
        assert :ets.whereis(@code_ets) != :undefined
        :ok

      other ->
        flunk("failed to restart CodeStore: #{inspect(other)}")
    end
  end

  # ---------------------------------------------------------------------------
  # AST inventory
  # ---------------------------------------------------------------------------

  defp inventory(file, ast) do
    aliases = collect_aliases(ast)
    imports = collect_imports(ast)
    attrs = collect_attributes(ast)

    {_ast, acc} =
      Macro.prewalk(ast, %{public: %{}, effects: MapSet.new(), forbidden: MapSet.new()}, fn
        {kind, _, [sig | rest]} = node, acc when kind in [:def, :defp, :defdelegate] ->
          case unwrap_signature(sig) do
            {name, arity} ->
              acc =
                if kind in [:def, :defdelegate] do
                  put_in(acc, [:public, {file, name, arity}], true)
                else
                  acc
                end

              body = def_body(rest)
              {node, walk_body(file, {name, arity}, body, aliases, imports, attrs, acc)}

            :error ->
              {node, acc}
          end

        node, acc ->
          {node,
           Map.update!(acc, :forbidden, &MapSet.union(&1, hits_for_node(node, aliases, imports)))}
      end)

    %{
      public: acc.public,
      effects: acc.effects,
      forbidden: MapSet.to_list(acc.forbidden) |> Enum.sort()
    }
  end

  defp walk_body(file, fun, body, aliases, imports, attrs, acc) do
    {_ast, acc} =
      Macro.prewalk(body, acc, fn node, acc ->
        acc =
          acc
          |> Map.update!(:forbidden, &MapSet.union(&1, hits_for_node(node, aliases, imports)))
          |> maybe_put_effect(file, fun, node, aliases, attrs)

        {node, acc}
      end)

    acc
  end

  defp maybe_put_effect(acc, file, fun, node, aliases, attrs) do
    case effect_callee(node, aliases, attrs) do
      {:ok, callee} ->
        Map.update!(acc, :effects, &MapSet.put(&1, {file, fun, callee}))

      :error ->
        acc
    end
  end

  defp effect_callee({{:., _, [mod_ast, fun]}, _, args}, aliases, attrs)
       when is_atom(fun) and is_list(args) do
    arity = length(args)

    if mod_ast == :ets and
         fun in [:insert, :delete, :insert_new, :update_element, :update_counter] do
      case resolve_ets_table(List.first(args), attrs) do
        {:ok, table} ->
          if table in @content_tables do
            {:ok, {:ets, fun, arity}}
          else
            :error
          end

        :error ->
          :error
      end
    else
      case expand_alias_node(mod_ast, aliases) do
        Arbor.Memory.MutationAdmission
        when fun in [:acquire, :release, :status] ->
          {:ok, {Arbor.Memory.MutationAdmission, fun, arity}}

        Arbor.Memory.MemoryStore
        when fun in [
               :reserve_persist_async,
               :reserve_embed_async,
               :activate_async,
               :cancel_async,
               :delete,
               :delete_by_prefix,
               :delete_tainted_authoritative
             ] ->
          {:ok, {Arbor.Memory.MemoryStore, fun, arity}}

        Arbor.Persistence
        when fun in [
               :put_relationship,
               :update_relationship,
               :delete_relationship,
               :touch_relationship,
               :delete_all_relationships
             ] ->
          {:ok, {Arbor.Persistence, fun, arity}}

        _ ->
          :error
      end
    end
  end

  defp effect_callee(_node, _aliases, _attrs), do: :error

  defp resolve_ets_table({:@, _, [{name, _, _}]}, attrs) when is_atom(name) do
    case Map.fetch(attrs, name) do
      {:ok, table} when is_atom(table) -> {:ok, table}
      _ -> :error
    end
  end

  defp resolve_ets_table(table, _attrs) when is_atom(table) do
    if table in @content_tables or table in @ignored_ets_tables do
      {:ok, table}
    else
      :error
    end
  end

  defp resolve_ets_table(_table, _attrs), do: :error

  defp effect_drift(added, removed) do
    added_list = MapSet.to_list(added)
    removed_list = MapSet.to_list(removed)

    {relocated, leftover_added, leftover_removed} =
      Enum.reduce(added_list, {[], added_list, removed_list}, fn
        {file, _fun, callee} = site, {reloc, add_acc, rem_acc} ->
          case Enum.find(rem_acc, fn {rfile, _rfun, rcallee} ->
                 rfile == file and rcallee == callee
               end) do
            nil ->
              {reloc, add_acc, rem_acc}

            match ->
              {[{file, elem(site, 1), callee, :relocated} | reloc], List.delete(add_acc, site),
               List.delete(rem_acc, match)}
          end
      end)

    Enum.map(leftover_added, fn {file, fun, callee} -> {file, fun, callee, :added} end) ++
      Enum.map(leftover_removed, fn {file, fun, callee} -> {file, fun, callee, :removed} end) ++
      relocated
  end

  defp detect_forbidden(ast) do
    aliases = collect_aliases(ast)
    imports = collect_imports(ast)

    {_ast, hits} =
      Macro.prewalk(ast, MapSet.new(), fn node, hits ->
        {node, MapSet.union(hits, hits_for_node(node, aliases, imports))}
      end)

    hits |> MapSet.to_list() |> Enum.sort()
  end

  # Clause order is load-bearing: alias/import → Kernel.apply → :erlang.apply →
  # bare apply → capture → spawn → imported local call → remote (Task alias,
  # persist_async, acquire-with-lease, force_release, forbidden modules).
  defp hits_for_node(node, aliases, imports)

  defp hits_for_node({:alias, _, args}, _aliases, _imports) do
    alias_hits(args)
  end

  defp hits_for_node({:import, _, args}, _aliases, _imports) do
    import_hits(args)
  end

  defp hits_for_node(
         {{:., _, [kernel, :apply]}, _, [module, fun, args]},
         aliases,
         _imports
       )
       when kernel == Kernel or
              (is_tuple(kernel) and elem(kernel, 0) == :__aliases__ and
                 elem(kernel, 2) == [:Kernel]) do
    apply_hits(:kernel_apply, module, fun, args, aliases)
  end

  defp hits_for_node(
         {{:., _, [:erlang, :apply]}, _, [module, fun, args]},
         aliases,
         _imports
       ) do
    apply_hits(:erlang_apply, module, fun, args, aliases)
  end

  defp hits_for_node({:apply, _, [module, fun, args]}, aliases, _imports) do
    apply_hits(:apply, module, fun, args, aliases)
  end

  defp hits_for_node(
         {:&, _, [{:/, _, [{{:., _, [module, fun]}, _, []}, _arity]}]},
         aliases,
         _imports
       ) do
    case expand_alias_node(module, aliases) do
      Arbor.Memory.MemoryStore when fun in [:persist_async, :embed_async] ->
        MapSet.new([{:capture, Arbor.Memory.MemoryStore}, {fun, Arbor.Memory.MemoryStore}])

      mod when is_atom(mod) ->
        if forbidden_module?(mod), do: MapSet.new([{:capture, mod}]), else: MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp hits_for_node({kind, _, _args}, _aliases, _imports)
       when kind in [:spawn, :spawn_link, :spawn_monitor] do
    MapSet.new([{:spawn, kind}])
  end

  defp hits_for_node({{:., _, [:erlang, kind]}, _, _args}, _aliases, _imports)
       when kind in [:spawn, :spawn_link, :spawn_monitor] do
    MapSet.new([{:spawn, kind}])
  end

  defp hits_for_node({fun, _, args}, _aliases, imports)
       when is_atom(fun) and is_list(args) do
    cond do
      imported?(imports, Arbor.Memory.MemoryStore, fun) and
          fun in [:persist_async, :embed_async] ->
        MapSet.new([{fun, Arbor.Memory.MemoryStore}])

      imported?(imports, Task, fun) and fun in [:async, :start, :start_link] ->
        MapSet.new([{:task, fun}])

      true ->
        MapSet.new()
    end
  end

  defp hits_for_node({{:., _, [mod_ast, fun]}, _, args}, aliases, _imports)
       when is_atom(fun) do
    remote_hits(expand_alias_node(mod_ast, aliases), fun, args)
  end

  defp hits_for_node(_node, _aliases, _imports), do: MapSet.new()

  defp remote_hits(Task, fun, _args) when fun in [:async, :start, :start_link] do
    MapSet.new([{:task, fun}])
  end

  defp remote_hits(Arbor.Memory.MutationAdmission, :acquire, [_agent, opts])
       when is_list(opts) do
    if keyword_has_lease?(opts) do
      MapSet.new([{:acquire_lease, Arbor.Memory.MutationAdmission}])
    else
      MapSet.new()
    end
  end

  defp remote_hits(Arbor.Memory.MutationAdmission, :force_release, _args) do
    MapSet.new([{:force_release, Arbor.Memory.MutationAdmission}])
  end

  defp remote_hits(Arbor.Memory.MemoryStore, fun, _args)
       when fun in [:persist_async, :embed_async] do
    MapSet.new([{fun, Arbor.Memory.MemoryStore}])
  end

  defp remote_hits(mod, fun, _args) when is_atom(mod) and is_atom(fun) do
    if forbidden_module?(mod) do
      MapSet.new([{:remote, mod, fun}])
    else
      MapSet.new()
    end
  end

  defp remote_hits(_mod, _fun, _args), do: MapSet.new()

  defp apply_hits(tag, module, fun, args, aliases) do
    hits =
      case expand_alias_node(module, aliases) do
        Arbor.Memory.MemoryStore ->
          fun_atom = literal_atom(fun)

          base = MapSet.new([{tag, Arbor.Memory.MemoryStore}])

          if fun_atom in [:persist_async, :embed_async] do
            MapSet.put(base, {fun_atom, Arbor.Memory.MemoryStore})
          else
            base
          end

        mod when is_atom(mod) ->
          if forbidden_module?(mod), do: MapSet.new([{tag, mod}]), else: MapSet.new()

        _ ->
          MapSet.new()
      end

    _ = args
    hits
  end

  defp literal_atom(fun) when is_atom(fun), do: fun
  defp literal_atom(_), do: nil

  defp keyword_has_lease?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {:lease, _} -> true
      _ -> false
    end)
  end

  defp keyword_has_lease?(_), do: false

  defp unwrap_signature({:when, _, [sig | _]}), do: unwrap_signature(sig)
  defp unwrap_signature({name, _, nil}) when is_atom(name), do: {name, 0}

  defp unwrap_signature({name, _, args}) when is_atom(name) and is_list(args) do
    {name, declared_arity(args)}
  end

  defp unwrap_signature(_), do: :error

  defp declared_arity(args) do
    Enum.reduce(args, 0, fn
      {:\\, _, [_arg, _default]}, n -> n + 1
      _, n -> n + 1
    end)
  end

  defp def_body([opts]) when is_list(opts), do: Keyword.get(opts, :do)
  defp def_body(_), do: nil

  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts} | rest]} = node, acc ->
          as_name =
            case rest do
              [[as: {:__aliases__, _, [name]}]] -> name
              _ -> List.last(parts)
            end

          {node, Map.put(acc, as_name, Module.concat(parts))}

        {:alias, _, [{{:., _, [base, :{}]}, _, names} | _]} = node, acc ->
          base_mod = expand_alias_node(base, %{})

          acc =
            Enum.reduce(names, acc, fn
              {:__aliases__, _, tail}, a ->
                Map.put(a, List.last(tail), Module.concat([base_mod | tail]))

              {name, _, _}, a when is_atom(name) ->
                Map.put(a, name, Module.concat([base_mod, name]))

              name, a when is_atom(name) ->
                Map.put(a, name, Module.concat([base_mod, name]))

              _, a ->
                a
            end)

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp collect_imports(ast) do
    {_ast, imports} =
      Macro.prewalk(ast, %{}, fn
        {:import, _, [mod_ast | rest]} = node, acc ->
          case expand_alias_node(mod_ast, %{}) do
            mod when is_atom(mod) ->
              {node, Map.put(acc, mod, imported_funs(rest))}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    imports
  end

  defp imported_funs([]), do: :all
  defp imported_funs(nil), do: :all

  defp imported_funs([opts | _]) when is_list(opts) do
    case Keyword.get(opts, :only) do
      funs when is_list(funs) ->
        funs |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      _ ->
        :all
    end
  end

  defp imported_funs(_), do: :all

  defp imported?(imports, mod, fun) do
    case Map.get(imports, mod) do
      :all -> true
      %MapSet{} = set -> MapSet.member?(set, fun)
      _ -> false
    end
  end

  defp collect_attributes(ast) do
    {_ast, attrs} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  defp alias_hits([{:__aliases__, _, parts} | _]) do
    mod = Module.concat(parts)
    if forbidden_module?(mod), do: MapSet.new([{:alias, mod}]), else: MapSet.new()
  end

  defp alias_hits([{{:., _, [base, :{}]}, _, names} | _]) do
    base_mod = expand_alias_node(base, %{})

    Enum.reduce(names, MapSet.new(), fn
      {:__aliases__, _, tail}, acc ->
        mod = Module.concat([base_mod | tail])
        if forbidden_module?(mod), do: MapSet.put(acc, {:alias, mod}), else: acc

      {name, _, _}, acc when is_atom(name) ->
        mod = Module.concat([base_mod, name])
        if forbidden_module?(mod), do: MapSet.put(acc, {:alias, mod}), else: acc

      name, acc when is_atom(name) ->
        mod = Module.concat([base_mod, name])
        if forbidden_module?(mod), do: MapSet.put(acc, {:alias, mod}), else: acc

      _, acc ->
        acc
    end)
  end

  defp alias_hits(_), do: MapSet.new()

  defp import_hits([mod_ast | rest]) do
    case expand_alias_node(mod_ast, %{}) do
      Arbor.Memory.MemoryStore ->
        if imported_funs_include?(rest, [:persist_async, :embed_async]) do
          MapSet.new([{:import, Arbor.Memory.MemoryStore}])
        else
          MapSet.new()
        end

      Task ->
        MapSet.new([{:import, Task}])

      mod when is_atom(mod) ->
        if forbidden_module?(mod), do: MapSet.new([{:import, mod}]), else: MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp import_hits(_), do: MapSet.new()

  defp imported_funs_include?(rest, funs) do
    case imported_funs(rest) do
      :all -> true
      %MapSet{} = set -> Enum.any?(funs, &MapSet.member?(set, &1))
    end
  end

  defp expand_alias_node({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      case parts do
        [head | tail] ->
          case Map.fetch(aliases, head) do
            {:ok, base} when tail == [] -> base
            {:ok, base} -> Module.concat([base | tail])
            :error -> Module.concat(parts)
          end

        [] ->
          nil
      end
    else
      nil
    end
  end

  defp expand_alias_node(mod, _aliases) when is_atom(mod), do: mod
  defp expand_alias_node(_, _), do: nil

  defp forbidden_module?(Task), do: true
  defp forbidden_module?(Arbor.Memory.AsyncWriter), do: true
  defp forbidden_module?(Arbor.Persistence), do: false
  defp forbidden_module?(Ecto.Query), do: true

  defp forbidden_module?(mod) when is_atom(mod) do
    name = Atom.to_string(mod)

    String.starts_with?(name, "Elixir.Arbor.Memory.AsyncWriter.") or
      String.starts_with?(name, "Elixir.Arbor.Persistence.") or
      name == "Elixir.Ecto.Query" or
      name == "Elixir.Task"
  end

  defp forbidden_module?(_), do: false
end
