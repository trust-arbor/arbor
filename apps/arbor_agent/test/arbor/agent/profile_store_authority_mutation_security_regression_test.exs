# Agent-owned linearizable Store double for C3B1 regression tests.
#
# This double implements Arbor.Contracts.Persistence.Store with genuine
# structured-Record generation/revision fencing and tombstone generations
# re-implemented inside the test (NOT delegating to Arbor.Persistence.Store.ETS
# or any other arbor_persistence internal). It is GenServer-serialized, reports
# durability_class :node_restart, and injects bounded failures for causal proof
# of the ambiguous-reobservation paths.
defmodule Arbor.Agent.ProfileStoreAuthorityMutationSecurityRegressionTest.NodeRestartCAS do
  @behaviour Arbor.Contracts.Persistence.Store

  use GenServer

  alias Arbor.Contracts.Persistence.Record

  @arm_pre_commit {__MODULE__, :arm_pre_commit}
  @arm_post_commit {__MODULE__, :arm_post_commit}
  @arm_poison_get_after_cas {__MODULE__, :arm_poison_get_after_cas}
  @poison_get_pending {__MODULE__, :poison_get_pending}
  @cas_count {__MODULE__, :cas_count}
  @get_count {__MODULE__, :get_count}
  @arm_malformed_successor {__MODULE__, :arm_malformed_successor}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # --- injection control (process-independent persistent_term flags) ---

  def clear_flags do
    :persistent_term.erase(@arm_pre_commit)
    :persistent_term.erase(@arm_post_commit)
    :persistent_term.erase(@arm_poison_get_after_cas)
    :persistent_term.erase(@poison_get_pending)
    :persistent_term.erase(@cas_count)
    :persistent_term.erase(@get_count)
    :persistent_term.erase(@arm_malformed_successor)
    :ok
  end

  def arm_pre_commit_exit, do: :persistent_term.put(@arm_pre_commit, true)
  def arm_post_commit_exit, do: :persistent_term.put(@arm_post_commit, true)
  def arm_poison_get_after_cas, do: :persistent_term.put(@arm_poison_get_after_cas, true)

  def arm_malformed_successor,
    do: :persistent_term.put(@arm_malformed_successor, true)

  def cas_count, do: :persistent_term.get(@cas_count, 0)
  def get_count, do: :persistent_term.get(@get_count, 0)

  # --- direct state manipulation (test setup only) ---

  def seed(key, value), do: GenServer.call(__MODULE__, {:seed, key, value})
  def raw_get(key), do: GenServer.call(__MODULE__, {:raw_get, key})
  def replace(key, value), do: GenServer.call(__MODULE__, {:seed, key, value})

  def delete_and_reinsert(key, %Record{data: data, metadata: meta, id: id}) do
    GenServer.call(__MODULE__, {:delete_reinsert, key, data, meta, id})
  end

  # --- Store behaviour callbacks ---

  @impl true
  def put(key, value, _opts), do: GenServer.call(__MODULE__, {:put, key, value})

  @impl true
  def get(key, _opts) do
    :persistent_term.put(@get_count, :persistent_term.get(@get_count, 0) + 1)

    if poison_get_pending?() do
      :persistent_term.erase(@poison_get_pending)
      raise("poison_get")
    end

    GenServer.call(__MODULE__, {:get, key})
  end

  @impl true
  def delete(key, _opts), do: GenServer.call(__MODULE__, {:delete, key})

  @impl true
  def list(_opts), do: GenServer.call(__MODULE__, :list)

  @impl true
  def exists?(key, _opts), do: GenServer.call(__MODULE__, {:exists, key})

  @impl true
  def compare_and_swap(key, expected, replacement, _opts) do
    :persistent_term.put(@cas_count, :persistent_term.get(@cas_count, 0) + 1)

    if pre_commit?(), do: raise("pre_commit_exit")

    result = GenServer.call(__MODULE__, {:cas, key, expected, replacement})

    if match?({:ok, _}, result) do
      maybe_arm_poison_get()
      if post_commit?(), do: raise("post_commit_exit")
    end

    maybe_malform_successor(result)
  end

  @impl true
  def compare_and_delete(key, expected, _opts),
    do: GenServer.call(__MODULE__, {:compare_and_delete, key, expected})

  @impl true
  def durability_class(_opts), do: :node_restart

  defp pre_commit?, do: :persistent_term.get(@arm_pre_commit, false)
  defp post_commit?, do: :persistent_term.get(@arm_post_commit, false)
  defp poison_get_pending?, do: :persistent_term.get(@poison_get_pending, false)

  defp maybe_arm_poison_get do
    if :persistent_term.get(@arm_poison_get_after_cas, false) do
      :persistent_term.erase(@arm_poison_get_after_cas)
      :persistent_term.put(@poison_get_pending, true)
    end
  end

  defp malformed_successor?, do: :persistent_term.get(@arm_malformed_successor, false)

  # The CAS committed a VALID Record to durable state; only the RETURNED value
  # is malformed (an invalid updated_at). successor_envelope?/3 excludes
  # timestamps, so without the decode_profile_record/2 gate the shell would
  # report this :applied. Reobservation reads back the valid durable successor.
  defp maybe_malform_successor({:ok, %Record{} = record} = result) do
    if malformed_successor?() do
      :persistent_term.erase(@arm_malformed_successor)
      {:ok, %{record | updated_at: "not-a-valid-datetime"}}
    else
      result
    end
  end

  defp maybe_malform_successor(other), do: other

  # --- GenServer ---

  @impl true
  def init(:ok), do: {:ok, %{entries: %{}}}

  @impl true
  def handle_call({:seed, key, value}, _from, state),
    do: {:reply, :ok, put_in(state, [:entries, key], value)}

  def handle_call({:raw_get, key}, _from, state),
    do: {:reply, live_value(Map.get(state.entries, key)), state}

  def handle_call({:delete_reinsert, key, data, meta, id}, _from, state) do
    current = Map.get(state.entries, key)
    prev_gen = generation_of(current)
    now = DateTime.utc_now()

    stored = %Record{
      id: id,
      key: key,
      data: data,
      metadata: meta,
      generation: prev_gen + 1,
      revision: 1,
      inserted_at: now,
      updated_at: now
    }

    {:reply, :ok, put_in(state, [:entries, key], stored)}
  end

  def handle_call({:put, key, value}, _from, state),
    do: {:reply, :ok, put_entry(state, key, value)}

  def handle_call({:get, key}, _from, state) do
    {:reply, live_value(Map.get(state.entries, key)), state}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, put_in(state, [:entries, key], tombstone_for(Map.get(state.entries, key)))}
  end

  def handle_call(:list, _from, state) do
    keys =
      state.entries
      |> Enum.filter(fn {_, v} -> live?(v) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {:reply, {:ok, keys}, state}
  end

  def handle_call({:exists, key}, _from, state),
    do: {:reply, live?(Map.get(state.entries, key)), state}

  def handle_call({:cas, key, expected, replacement}, _from, state) do
    current = Map.get(state.entries, key)

    case cas_outcome(current, expected, replacement) do
      {:ok, stored} -> {:reply, {:ok, stored}, put_in(state, [:entries, key], stored)}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:compare_and_delete, key, expected}, _from, state) do
    current = Map.get(state.entries, key)

    if delete_matches?(current, expected) do
      {:reply, :ok, put_in(state, [:entries, key], tombstone_for(current))}
    else
      {:reply, {:error, :conflict}, state}
    end
  end

  # --- entry helpers (mirror backend Record fencing) ---

  defp live?(%Record{}), do: true
  defp live?({:tombstone, _}), do: false
  defp live?(_), do: true

  defp live_value(%Record{} = v), do: {:ok, v}
  defp live_value({:tombstone, _}), do: {:error, :not_found}
  defp live_value(nil), do: {:error, :not_found}
  defp live_value(v), do: {:ok, v}

  defp generation_of(%Record{generation: g}) when is_integer(g) and g >= 1, do: g
  defp generation_of({:tombstone, g}), do: g
  defp generation_of(_), do: 0

  defp tombstone_for(%Record{generation: g}), do: {:tombstone, g}
  defp tombstone_for({:tombstone, _g} = t), do: t
  defp tombstone_for(_), do: nil

  defp put_entry(state, key, %Record{} = record) do
    case Map.get(state.entries, key) do
      %Record{generation: g, revision: r, id: id, inserted_at: ins} = c ->
        stored = %Record{
          record
          | id: id,
            generation: g,
            revision: r + 1,
            inserted_at: ins || record.inserted_at,
            updated_at: DateTime.utc_now()
        }

        _ = c
        put_in(state, [:entries, key], stored)

      {:tombstone, g} ->
        stored = %Record{
          record
          | generation: g + 1,
            revision: 1,
            updated_at: DateTime.utc_now()
        }

        put_in(state, [:entries, key], stored)

      _ ->
        stored = %Record{
          record
          | generation: 1,
            revision: 1,
            updated_at: DateTime.utc_now()
        }

        put_in(state, [:entries, key], stored)
    end
  end

  defp put_entry(state, key, value), do: put_in(state, [:entries, key], value)

  defp cas_outcome(current, expected, %Record{} = replacement) do
    case expected do
      :not_found ->
        if current == nil or match?({:tombstone, _}, current) do
          gen = generation_of(current) + 1
          now = DateTime.utc_now()
          stored = %{replacement | generation: gen, revision: 1, updated_at: now}
          {:ok, stored}
        else
          {:error, :conflict}
        end

      {:value, expected_record} ->
        case current do
          %Record{generation: g, revision: r, id: id, inserted_at: ins}
          when g == expected_record.generation and r == expected_record.revision ->
            now = DateTime.utc_now()

            stored = %{
              replacement
              | id: id,
                key: current.key,
                generation: g,
                revision: r + 1,
                inserted_at: ins || replacement.inserted_at,
                updated_at: now
            }

            {:ok, stored}

          _ ->
            {:error, :conflict}
        end
    end
  end

  defp delete_matches?(%Record{generation: g, revision: r}, %Record{
         generation: eg,
         revision: er
       }),
       do: g == eg and r == er

  defp delete_matches?(current, expected), do: current == expected
end

defmodule Arbor.Agent.ProfileStoreAuthorityMutationSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3B1 — authoritative profile snapshot + acknowledged generation/
  revision CAS public-boundary security regressions.

  CANONICAL SUITE: authoritative-mutation boundary for the fixed
  :arbor_agent_profiles ProfileStore (durability gate, envelope-stable pre-CAS
  check, acknowledged CAS, full ambiguous-reobservation classification). Do not
  split these invariants without moving them here.

  The file is RUNNABLE on the immediate parent (HEAD~1 = d934fa02bb1e): the
  marquee regression is unconditional and its candidate/parent branches are
  selected at COMPILE time via @mutation_available (Code.ensure_loaded?/1 +
  function_exported?/3), so the closed mutation API is never compiled on the
  parent. The parent branch exercises the ordinary `store_profile/1` API on the
  SAME ephemeral topology and asserts the invariant the ordinary API violates,
  so it FAILS behaviorally on the parent (never via UndefinedFunctionError).
  All other describes are candidate-only and elided on the parent.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  # Compile-time gate: candidate-only describes (which reference the closed
  # mutation API + MutationResult struct) are elided on builds where the API is
  # absent. Code.ensure_loaded?/1 is required because lib modules are compiled
  # to disk but not loaded into the compiling VM, so function_exported?/3 alone
  # would falsely report false. The marquee test below is always defined and
  # fails behaviorally on such builds (never via UndefinedFunctionError).
  @mutation_available Code.ensure_loaded?(Arbor.Agent.ProfileStore) and
                        function_exported?(Arbor.Agent.ProfileStore, :apply_authority_mutation, 2)

  alias Arbor.Agent.ProfileStore
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore

  alias __MODULE__.NodeRestartCAS

  @store_name :arbor_agent_profiles

  setup do
    NodeRestartCAS.clear_flags()
    :ok
  end

  # --- store topology helpers ---

  defp start_ephemeral_store do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
  end

  # Candidate-only fixtures (used only by the elided candidate describes
  # and the candidate branch of the marquee); gated so they are not compiled
  # (and thus not reported unused) on builds lacking the mutation API.
  if @mutation_available do
    @legacy_dir ".arbor/agents"

    defp start_node_restart_store do
      NodeRestartCAS.clear_flags()
      start_supervised!(NodeRestartCAS)

      start_supervised!(
        {BufferedStore, name: @store_name, backend: NodeRestartCAS, write_mode: :sync}
      )
    end

    # --- profile / record fixtures ---

    defp profile_data(agent_id, opts \\ []) do
      base = %{
        "agent_id" => agent_id,
        "version" => 1,
        "display_name" => Keyword.get(opts, :display_name, "Test Agent"),
        "character" => %{"name" => Keyword.get(opts, :name, "T")},
        "sandbox_level" => "strict",
        "initial_goals" => [],
        "identity" => nil,
        "keychain_ref" => nil,
        "auto_start" => false,
        "created_at" => "2026-01-01T00:00:00Z",
        "template" => Keyword.get(opts, :template, "old_template"),
        "initial_capabilities" =>
          Keyword.get(opts, :initial_capabilities, [
            %{"resource" => "arbor://legacy/read", "constraints" => %{}}
          ]),
        "metadata" =>
          Map.merge(
            %{
              "last_model_config" => %{"provider" => "ollama"},
              "external_agent" => true,
              "exact_template_policy" => %{"old" => true},
              "arbitrary_sibling" => "kept"
            },
            Keyword.get(opts, :metadata, %{})
          )
      }

      case Keyword.get(opts, :drop_metadata) do
        nil -> base
        _ -> Map.delete(base, "metadata")
      end
    end

    defp profile_record(agent_id, data, gen \\ 1, rev \\ 1, opts \\ []) do
      %Record{
        id: Keyword.get(opts, :id, "agent_profile:#{agent_id}"),
        key: agent_id,
        data: data,
        metadata: Keyword.get(opts, :metadata, %{}),
        generation: gen,
        revision: rev,
        inserted_at: ~U[2026-01-01 00:00:00Z],
        updated_at: ~U[2026-01-01 00:00:00Z]
      }
    end

    defp seed_profile(agent_id, data, opts \\ []) do
      NodeRestartCAS.seed(
        agent_id,
        profile_record(agent_id, data, opts[:gen] || 1, opts[:rev] || 1)
      )
    end

    defp governed(opts \\ []) do
      %{
        "template" => Keyword.get(opts, :template, "scout"),
        "initial_capabilities" =>
          Keyword.get(opts, :initial_capabilities, [
            %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
          ]),
        "metadata" => %{
          "exact_template_policy" =>
            Keyword.get(opts, :exact_template_policy, %{"version" => 1, "markers" => []})
        }
      }
    end

    defp legacy_path(agent_id) do
      File.mkdir_p!(@legacy_dir)
      Path.join(@legacy_dir, "#{agent_id}.agent.json")
    end

    defp write_legacy_json(agent_id, data) do
      path = legacy_path(agent_id)
      {:ok, json} = Jason.encode(data)
      File.write!(path, json)
      {path, json}
    end
  end

  # ============================================================================
  # 1. MARQUEE PARENT-FAILING REGRESSION — durability gate
  # ============================================================================

  describe "durability gate (marquee parent-failing regression)" do
    test "authority mutation is refused against a non-node_restart (ephemeral) store" do
      start_ephemeral_store()
      agent_id = "agent_marquee_#{System.unique_integer([:positive])}"

      assert_durability_gate_holds(agent_id)
    end
  end

  # The candidate branch calls the closed mutation API (absent on the parent);
  # the parent branch exercises the ordinary store_profile/1 write. Selecting
  # between them at COMPILE time via @mutation_available means the candidate-only
  # calls are never compiled on the parent — zero undefined-function warnings —
  # while the marquee test above stays unconditional and fails behaviorally on
  # the parent (never via UndefinedFunctionError/undefined struct).
  if @mutation_available do
    defp assert_durability_gate_holds(agent_id) do
      new_authority_data = profile_data(agent_id, template: "new_template")

      assert {:error, :authority_not_durable} =
               ProfileStore.authority_mutation_snapshot(agent_id)

      assert {:error, :authority_not_durable} =
               ProfileStore.apply_authority_mutation(
                 profile_record(agent_id, new_authority_data),
                 governed(template: "new_template")
               )

      assert {:error, :not_found} = BufferedStore.get(agent_id, name: @store_name)
    end
  else
    defp assert_durability_gate_holds(agent_id) do
      profile = %Arbor.Agent.Profile{
        agent_id: agent_id,
        character: Arbor.Agent.Character.new(name: "X"),
        template: "new_template",
        metadata: %{},
        created_at: DateTime.utc_now(),
        version: 1
      }

      assert :ok = ProfileStore.store_profile(profile)

      assert {:ok, loaded} = ProfileStore.load_profile(agent_id)

      refute loaded.template == "new_template",
             "parent regression: authority mutated against a non-node_restart store"
    end
  end

  # ============================================================================
  # Candidate-only boundary regressions
  # ============================================================================

  if @mutation_available do
    describe "authority_mutation_snapshot/1" do
      test "returns the exact authoritative Record under node_restart authority" do
        start_node_restart_store()
        agent_id = "agent_snap_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data, gen: 3, rev: 7)

        assert {:ok, record} = ProfileStore.authority_mutation_snapshot(agent_id)
        assert %Record{} = record
        assert record.key == agent_id
        assert record.generation == 3
        assert record.revision == 7
        assert record.data == data
      end

      test "fails closed for a legacy-only profile (no migration/deletion)" do
        start_node_restart_store()
        agent_id = "agent_legacy_#{System.unique_integer([:positive])}"
        {path, json} = write_legacy_json(agent_id, profile_data(agent_id))

        on_exit(fn -> File.rm(path) end)

        assert {:error, :not_found} = ProfileStore.authority_mutation_snapshot(agent_id)
        # JSON file untouched.
        assert File.exists?(path)
        assert File.read!(path) == json
      end

      test "refuses malformed backend records" do
        start_node_restart_store()
        agent_id = "agent_mal_#{System.unique_integer([:positive])}"

        # plain map occupant
        NodeRestartCAS.seed(agent_id, %{not: :a_record})
        assert {:error, :invalid_record} = ProfileStore.authority_mutation_snapshot(agent_id)

        NodeRestartCAS.replace(agent_id, nil)

        # wrong key
        NodeRestartCAS.seed(
          agent_id,
          profile_record("agent_other", profile_data("agent_other"))
        )

        assert {:error, :invalid_record} = ProfileStore.authority_mutation_snapshot(agent_id)

        NodeRestartCAS.replace(agent_id, nil)

        # generation 0 (unpersisted envelope)
        NodeRestartCAS.seed(agent_id, profile_record(agent_id, profile_data(agent_id), 0, 0))

        assert {:error, :invalid_record} = ProfileStore.authority_mutation_snapshot(agent_id)
      end

      test "never trusts the cache (authoritative read only)" do
        start_node_restart_store()
        agent_id = "agent_cache_#{System.unique_integer([:positive])}"
        durable = profile_data(agent_id)
        seed_profile(agent_id, durable)

        # Poison the ETS cache with a stale, differently-shaped value.
        stale = profile_record(agent_id, Map.put(durable, "display_name", "STALE_CACHE"))
        :ets.insert(@store_name, {agent_id, stale})

        assert {:ok, record} = ProfileStore.authority_mutation_snapshot(agent_id)
        assert record.data == durable
        refute record.data["display_name"] == "STALE_CACHE"
      end
    end

    describe "apply_authority_mutation/2 happy path and preservation" do
      test "applies the closed update and advances fencing by exactly one revision" do
        start_node_restart_store()
        agent_id = "agent_apply_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data, gen: 2, rev: 4)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        assert {:ok, %{outcome: :applied, record: successor}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        assert successor.generation == 2
        assert successor.revision == 5
        assert successor.data["template"] == "scout"
        assert successor.metadata == observed.metadata
      end

      test "preserves every unrelated top-level and nested metadata field" do
        start_node_restart_store()
        agent_id = "agent_preserve_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        assert {:ok, %{outcome: :applied, record: successor}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        for key <- [
              "agent_id",
              "version",
              "display_name",
              "character",
              "sandbox_level",
              "initial_goals",
              "identity",
              "keychain_ref",
              "auto_start",
              "created_at"
            ] do
          assert successor.data[key] == data[key]
        end

        assert successor.data["metadata"]["last_model_config"] ==
                 data["metadata"]["last_model_config"]

        assert successor.data["metadata"]["external_agent"] == data["metadata"]["external_agent"]

        assert successor.data["metadata"]["arbitrary_sibling"] ==
                 data["metadata"]["arbitrary_sibling"]

        assert successor.data["metadata"]["exact_template_policy"] == %{
                 "version" => 1,
                 "markers" => []
               }
      end
    end

    describe "apply_authority_mutation/2 pre-CAS envelope stability" do
      test "tampered observed DATA with unchanged tokens is conflict, no CAS" do
        start_node_restart_store()
        agent_id = "agent_tamper_data_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, %Record{} = real} = ProfileStore.authority_mutation_snapshot(agent_id)

        # Same id/key/gen/rev/metadata but tampered data.
        tampered_data = Map.put(real.data, "display_name", "TAMPERED")

        tampered = %{real | data: tampered_data}

        before_cas = NodeRestartCAS.cas_count()

        assert {:ok, %{outcome: :conflict}} =
                 ProfileStore.apply_authority_mutation(tampered, governed())

        # No CAS was attempted.
        assert NodeRestartCAS.cas_count() == before_cas

        # Durable record unchanged.
        {:ok, still} = NodeRestartCAS.raw_get(agent_id)
        assert still.data["display_name"] != "TAMPERED"
      end

      test "tampered observed ID with unchanged tokens is conflict, no CAS" do
        start_node_restart_store()
        agent_id = "agent_tamper_id_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, %Record{} = real} = ProfileStore.authority_mutation_snapshot(agent_id)
        tampered = %{real | id: "rec_tampered"}

        before_cas = NodeRestartCAS.cas_count()

        assert {:ok, %{outcome: :conflict}} =
                 ProfileStore.apply_authority_mutation(tampered, governed())

        assert NodeRestartCAS.cas_count() == before_cas
      end

      test "tampered observed METADATA with unchanged tokens is conflict, no CAS" do
        start_node_restart_store()
        agent_id = "agent_tamper_meta_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, %Record{} = real} = ProfileStore.authority_mutation_snapshot(agent_id)
        tampered = %{real | metadata: %{"poison" => true}}

        before_cas = NodeRestartCAS.cas_count()

        assert {:ok, %{outcome: :conflict}} =
                 ProfileStore.apply_authority_mutation(tampered, governed())

        assert NodeRestartCAS.cas_count() == before_cas
      end

      test "natural drift (concurrent advance) is conflict, nothing overwritten" do
        start_node_restart_store()
        agent_id = "agent_drift_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id), gen: 1, rev: 1)

        {:ok, %Record{} = observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # A concurrent writer advances the durable record to rev 2.
        {:ok, advanced} =
          NodeRestartCAS.compare_and_swap(
            agent_id,
            {:value, observed},
            %{observed | data: Map.put(observed.data, "display_name", "ADVANCED")},
            []
          )

        assert %Record{} = advanced

        before_cas = NodeRestartCAS.cas_count()

        assert {:ok, %{outcome: :conflict, record: conflict_record}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        # No CAS beyond the manual advance above.
        assert NodeRestartCAS.cas_count() == before_cas
        assert conflict_record.revision == 2
        assert conflict_record.data["display_name"] == "ADVANCED"
      end
    end

    describe "apply_authority_mutation/2 conflict and ABA" do
      test "ABA (delete/reinsert equal data, new generation) is conflict" do
        start_node_restart_store()
        agent_id = "agent_aba_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data, gen: 1, rev: 1)

        {:ok, %Record{} = observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # Delete + reinsert equal data under a NEW generation.
        NodeRestartCAS.delete_and_reinsert(
          agent_id,
          %{observed | data: data}
        )

        assert {:ok, %{outcome: :conflict}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        {:ok, current} = NodeRestartCAS.raw_get(agent_id)
        assert current.generation == 2
        # Our intended authority did NOT apply.
        assert current.data["template"] == data["template"]
      end

      test "later revision is conflict (not already_applied)" do
        start_node_restart_store()
        agent_id = "agent_later_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data, gen: 1, rev: 1)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # Advance durable two revisions.
        seed_profile(agent_id, data, gen: 1, rev: 3)

        assert {:ok, %{outcome: :conflict}} =
                 ProfileStore.apply_authority_mutation(observed, governed())
      end

      test "seeded mismatched occupant (same tokens, different data) is conflict" do
        start_node_restart_store()
        agent_id = "agent_occ_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data, gen: 1, rev: 1)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # A different occupant under the SAME tokens but different data.
        NodeRestartCAS.replace(
          agent_id,
          profile_record(agent_id, Map.put(data, "display_name", "OCCUPIED"), 1, 1)
        )

        before_cas = NodeRestartCAS.cas_count()

        assert {:ok, %{outcome: :conflict}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        assert NodeRestartCAS.cas_count() == before_cas

        {:ok, occupant} = NodeRestartCAS.raw_get(agent_id)
        # Occupant NOT overwritten by our intended authority.
        assert occupant.data["template"] == data["template"]
        assert occupant.data["display_name"] == "OCCUPIED"
      end
    end

    describe "apply_authority_mutation/2 ambiguous convergence" do
      test "commit + FAILED reobserve => outcome_unknown (never false :applied)" do
        start_node_restart_store()
        agent_id = "agent_conv_fail_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # CAS commits, then raises -> BufferedStore reports :outcome_unknown, AND
        # the classification reobserve is poisoned to fail.
        NodeRestartCAS.arm_post_commit_exit()
        NodeRestartCAS.arm_poison_get_after_cas()

        assert {:ok, %{outcome: :outcome_unknown, record: nil}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        # The durable write actually landed (commit succeeded before the raise).
        {:ok, current} = NodeRestartCAS.raw_get(agent_id)
        assert current.revision == observed.revision + 1
      end

      test "commit + SUCCESSFUL reobserve => already_applied" do
        start_node_restart_store()
        agent_id = "agent_conv_ok_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # CAS commits, then raises -> :outcome_unknown, but reobserve succeeds and
        # shows the exact successor.
        NodeRestartCAS.arm_post_commit_exit()

        assert {:ok, %{outcome: :already_applied, record: successor}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        assert successor.revision == observed.revision + 1
        assert successor.data["template"] == "scout"
      end

      test "pre-commit failure leaving anchor unchanged => not_applied" do
        start_node_restart_store()
        agent_id = "agent_notapplied_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # CAS raises BEFORE committing; durable stays at the anchor.
        NodeRestartCAS.arm_pre_commit_exit()

        assert {:ok, %{outcome: :not_applied, record: anchor}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        assert anchor.revision == observed.revision
        assert anchor.data["template"] == observed.data["template"]
      end
    end

    describe "apply_authority_mutation/2 input rejection" do
      test "rejects malformed governed input (no write)" do
        start_node_restart_store()
        agent_id = "agent_rej_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(observed, %{"template" => "x"})

        assert NodeRestartCAS.cas_count() == before_cas
      end

      test "rejects atom/string conflict (atom-only) in governed" do
        start_node_restart_store()
        agent_id = "agent_atom_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(
                   observed,
                   Map.put(governed(), :template, "x")
                 )
      end

      test "rejects a non-Record observed snapshot" do
        start_node_restart_store()

        assert {:error, :invalid_request} =
                 ProfileStore.apply_authority_mutation(%{not: :record}, governed())
      end

      test "rejects observed.data with nil metadata (no CAS, durable unchanged)" do
        start_node_restart_store()
        agent_id = "agent_meta_nil_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)
        bad = %{observed | data: Map.put(observed.data, "metadata", nil)}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
        {:ok, still} = NodeRestartCAS.raw_get(agent_id)
        assert still.data == data
      end

      test "rejects observed.data with scalar metadata (no CAS, durable unchanged)" do
        start_node_restart_store()
        agent_id = "agent_meta_sc_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)
        bad = %{observed | data: Map.put(observed.data, "metadata", "scalar")}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
        {:ok, still} = NodeRestartCAS.raw_get(agent_id)
        assert still.data == data
      end

      test "rejects observed.data with struct metadata (no CAS, durable unchanged)" do
        start_node_restart_store()
        agent_id = "agent_meta_st_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)
        bad = %{observed | data: Map.put(observed.data, "metadata", Record.new("k", %{}))}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
        {:ok, still} = NodeRestartCAS.raw_get(agent_id)
        assert still.data == data
      end

      test "rejects atom-only observed template alias (no CAS, durable unchanged)" do
        start_node_restart_store()
        agent_id = "agent_obs_atom_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        bad_data =
          observed.data
          |> Map.delete("template")
          |> Map.put(:template, "atom_only")

        bad = %{observed | data: bad_data}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
        {:ok, still} = NodeRestartCAS.raw_get(agent_id)
        assert still.data == data
        assert still.data["template"] == data["template"]
      end

      test "rejects atom-only observed exact_template_policy alias (no CAS, durable unchanged)" do
        start_node_restart_store()
        agent_id = "agent_obs_pol_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        bad_meta =
          observed.data["metadata"]
          |> Map.delete("exact_template_policy")
          |> Map.put(:exact_template_policy, %{"atom_only" => true})

        bad = %{observed | data: Map.put(observed.data, "metadata", bad_meta)}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :malformed_governed} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
        {:ok, still} = NodeRestartCAS.raw_get(agent_id)
        assert still.data == data
      end

      test "rejects oversized observed record id (no CAS)" do
        start_node_restart_store()
        agent_id = "agent_id_big_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)
        bad = %{observed | id: String.duplicate("a", 257)}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :invalid_request} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
      end

      test "rejects non-UTF-8 observed record id (no CAS)" do
        start_node_restart_store()
        agent_id = "agent_id_utf_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)
        bad = %{observed | id: <<0xFF, 0xFE>>}
        before_cas = NodeRestartCAS.cas_count()

        assert {:error, :invalid_request} =
                 ProfileStore.apply_authority_mutation(bad, governed())

        assert NodeRestartCAS.cas_count() == before_cas
      end
    end

    describe "authority_mutation_snapshot/1 agent_id bounds" do
      test "rejects oversized agent_id" do
        start_node_restart_store()
        # "agent_" (6) + 251 chars = 257 bytes — over the 256-byte bound.
        agent_id = "agent_" <> String.duplicate("a", 251)
        assert byte_size(agent_id) == 257

        assert {:error, :invalid_request} =
                 ProfileStore.authority_mutation_snapshot(agent_id)
      end

      test "rejects non-UTF-8 agent_id" do
        start_node_restart_store()

        assert {:error, :invalid_request} =
                 ProfileStore.authority_mutation_snapshot(<<0xFF, 0xFE>>)
      end
    end

    describe "apply_authority_mutation/2 successor decode validation" do
      test "a successful CAS returning a malformed Record is never reported :applied" do
        start_node_restart_store()
        agent_id = "agent_malsucc_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, %Record{} = observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # The backend acknowledges the CAS but returns a Record whose updated_at
        # is a string, not DateTime|nil. successor_envelope?/3 excludes
        # timestamps, so without the decode_profile_record/2 gate (C4) this
        # malformed successor would be reported :applied.
        NodeRestartCAS.arm_malformed_successor()

        assert {:ok, result} = ProfileStore.apply_authority_mutation(observed, governed())

        # The malformed successful response must NEVER be reported :applied.
        refute result.outcome == :applied

        # The durable write landed with a VALID Record, so reobservation
        # converges to already_applied — and the returned record is the valid
        # successor, not the malformed value.
        assert result.outcome == :already_applied
        assert %Record{} = result.record
        assert result.record.revision == observed.revision + 1
        assert %DateTime{} = result.record.updated_at
        assert result.record.data["template"] == "scout"
      end
    end

    describe "fixed-store authority and no hidden retry" do
      test "the mutation API accepts no store/backend/PID option" do
        start_node_restart_store()
        agent_id = "agent_fixed_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        # The functions take no store/backend argument; every call routes through
        # the fixed :arbor_agent_profiles named table (the only started store).
        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        assert {:ok, %{outcome: :applied}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        # The named store's cache now reflects the successor.
        assert {:ok, cached} = BufferedStore.get(agent_id, name: @store_name)
        assert cached.data["template"] == "scout"
      end

      test "apply performs at most one CAS attempt (no hidden retry)" do
        start_node_restart_store()
        agent_id = "agent_noretry_#{System.unique_integer([:positive])}"
        seed_profile(agent_id, profile_data(agent_id))

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        # On the outcome_unknown path: exactly one CAS, then one classification
        # reobserve. No second CAS.
        NodeRestartCAS.arm_post_commit_exit()

        before_cas = NodeRestartCAS.cas_count()

        assert {:ok, %{outcome: :already_applied}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        assert NodeRestartCAS.cas_count() == before_cas + 1
      end
    end

    describe "legacy data is never migrated or deleted" do
      test "a mutation path leaves a seeded legacy JSON file byte-identical" do
        start_node_restart_store()
        agent_id = "agent_keepjson_#{System.unique_integer([:positive])}"
        data = profile_data(agent_id)
        seed_profile(agent_id, data)

        {path, json} = write_legacy_json(agent_id, profile_data(agent_id, template: "legacy"))
        on_exit(fn -> File.rm(path) end)

        {:ok, observed} = ProfileStore.authority_mutation_snapshot(agent_id)

        assert {:ok, %{outcome: :applied}} =
                 ProfileStore.apply_authority_mutation(observed, governed())

        # Legacy JSON untouched.
        assert File.exists?(path)
        assert File.read!(path) == json
      end
    end
  end
end
