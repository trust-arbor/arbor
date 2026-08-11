defmodule Arbor.Agent.TemplateAuthorityReconciliationStoreTest do
  use ExUnit.Case, async: false

  # Phase 4C C1B — focused behavioral tests for the Agent-owned durable record
  # store and linearizable CAS/idempotency boundary. Covers same-digest
  # concurrency (one winner, no split-brain), different-digest exclusion,
  # terminal replacement, stale generation/revision CAS, ABA fencing (revision
  # advanced while operation data is restored byte-identical), identity
  # preservation, the 256-byte target bound, malformed durable data (fail
  # closed, no replacement), cache-only / non-node-restart refusal with redacted
  # bounded errors, backend/restart persistence, outstanding filtering, and
  # ambiguous acknowledged-mutation reconciliation.
  #
  # Every test exercises the FIXED production store name
  # (:arbor_agent_template_authority_reconciliation). No runtime API accepts a
  # caller-selected store, and no dynamically-created atoms are used.

  @moduletag :fast

  # The exact production store name and collection wired in
  # Arbor.Agent.Application. Tests start this name under async: false; they do
  # not create dynamic store-name atoms.
  @store_name :arbor_agent_template_authority_reconciliation
  @collection "template_authority_reconciliation"

  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Core
  alias Arbor.Agent.TemplateAuthorityReconciliationStore, as: Store
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Persistence.Store, as: StoreBehaviour
  alias Arbor.Persistence.BufferedStore

  @digest_a String.duplicate("aa", 32)
  @digest_b String.duplicate("bb", 32)

  @template_data %{
    "name" => "coding_agent",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
      %{"resource" => "arbor://fs/write"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{"arbor://fs/read" => "auto", "arbor://fs/write" => "ask"}
    },
    "template_source" => %{"name" => "coding_agent", "layer" => "shipped"}
  }

  # -------------------------------------------------------------------------
  # Test storage + backends
  # -------------------------------------------------------------------------

  defmodule Storage do
    @moduledoc false
    @table __MODULE__

    def reset! do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _table -> :ets.delete_all_objects(@table)
      end

      :ok
    end

    def raw_put(collection, key, value) do
      true = :ets.insert(@table, {{collection, key}, value})
      :ok
    end

    def get(collection, key) do
      case :ets.lookup(@table, {collection, key}) do
        [{_, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end
    end

    def delete(collection, key) do
      :ets.delete(@table, {collection, key})
      :ok
    end

    def list(collection) do
      @table
      |> :ets.select([{{{collection, :"$1"}, :_}, [], [:"$1"]}])
      |> Enum.sort()
      |> then(&{:ok, &1})
    end

    def count(collection) do
      @table |> :ets.select([{{{collection, :_}, :_}, [], [true]}]) |> length()
    end
  end

  defmodule NodeRestartBackend do
    @moduledoc false
    @behaviour StoreBehaviour

    alias Arbor.Agent.TemplateAuthorityReconciliationStoreTest.Storage

    @impl true
    def put(key, %Record{key: key} = record, opts) do
      Storage.raw_put(Keyword.fetch!(opts, :name), key, record)
    end

    def put(_key, %Record{}, _opts), do: {:error, :key_mismatch}
    def put(_key, _value, _opts), do: {:error, :record_required}

    @impl true
    def get(key, opts), do: Storage.get(Keyword.fetch!(opts, :name), key)

    @impl true
    def delete(key, opts), do: Storage.delete(Keyword.fetch!(opts, :name), key)

    @impl true
    def list(opts), do: Storage.list(Keyword.fetch!(opts, :name))

    @impl true
    def compare_and_swap(key, expected, %Record{} = replacement, opts) do
      collection = Keyword.fetch!(opts, :name)

      cond do
        replacement.key != key ->
          {:error, :key_mismatch}

        match?({:value, %Record{key: k}} when k != key, expected) ->
          {:error, :key_mismatch}

        true ->
          apply_cas(collection, key, expected, replacement)
      end
    end

    @impl true
    def compare_and_delete(key, %Record{key: key} = expected, opts) do
      collection = Keyword.fetch!(opts, :name)

      case Storage.get(collection, key) do
        {:ok, %Record{generation: g, revision: r}}
        when g == expected.generation and r == expected.revision ->
          Storage.delete(collection, key)
          :ok

        _ ->
          {:error, :conflict}
      end
    end

    def compare_and_delete(_key, _expected, _opts), do: {:error, :conflict}

    @impl true
    def durability_class(_opts), do: :node_restart

    defp apply_cas(collection, key, :not_found, replacement) do
      case Storage.get(collection, key) do
        {:error, :not_found} ->
          stored = stamp_insert(replacement)
          Storage.raw_put(collection, key, stored)
          {:ok, stored}

        {:ok, _existing} ->
          {:error, :conflict}
      end
    end

    defp apply_cas(collection, key, {:value, %Record{generation: g, revision: r}}, replacement) do
      case Storage.get(collection, key) do
        {:ok, %Record{generation: ^g, revision: ^r} = current} ->
          stored = stamp_update(current, replacement)
          Storage.raw_put(collection, key, stored)
          {:ok, stored}

        _ ->
          {:error, :conflict}
      end
    end

    defp apply_cas(_collection, _key, {:value, _other}, _replacement), do: {:error, :conflict}

    defp stamp_insert(replacement) do
      now = DateTime.utc_now()

      %{
        replacement
        | generation: 1,
          revision: 1,
          inserted_at: now,
          updated_at: now
      }
    end

    defp stamp_update(current, replacement) do
      %{
        replacement
        | id: current.id,
          key: current.key,
          generation: current.generation,
          revision: current.revision + 1,
          inserted_at: current.inserted_at || replacement.inserted_at,
          updated_at: DateTime.utc_now()
      }
    end
  end

  defmodule ProcessLifetimeBackend do
    @moduledoc false
    @behaviour StoreBehaviour

    alias Arbor.Agent.TemplateAuthorityReconciliationStoreTest.NodeRestartBackend

    @impl true
    def put(key, value, opts), do: NodeRestartBackend.put(key, value, opts)
    @impl true
    def get(key, opts), do: NodeRestartBackend.get(key, opts)
    @impl true
    def delete(key, opts), do: NodeRestartBackend.delete(key, opts)
    @impl true
    def list(opts), do: NodeRestartBackend.list(opts)
    @impl true
    def compare_and_swap(key, expected, replacement, opts),
      do: NodeRestartBackend.compare_and_swap(key, expected, replacement, opts)

    @impl true
    def compare_and_delete(key, expected, opts),
      do: NodeRestartBackend.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :process_lifetime
  end

  # A node-restart backend whose compare_and_swap can be made to raise before or
  # after applying the mutation, so the BufferedStore reports :outcome_unknown
  # and the store must reconcile by authoritative reobservation. A single global
  # mode flag is sufficient: the suite is async: false and only flaky tests set
  # it, with the flags table reset in setup.
  defmodule FlakyBackend do
    @moduledoc false
    @behaviour StoreBehaviour
    @flags __MODULE__.Flags

    alias Arbor.Agent.TemplateAuthorityReconciliationStoreTest.NodeRestartBackend

    def flags_table!, do: @flags

    def set_mode(mode)
        when mode in [
               :off,
               :raise_before,
               :raise_after,
               :raise_after_reinsert,
               :raise_after_corrupt,
               :raise_after_meta_drift,
               :raise_after_key_drift,
               :raise_after_bad_id,
               :raise_after_bad_timestamp
             ] do
      :ets.insert(@flags, {:mode, mode})
      :ok
    end

    defp mode do
      case :ets.lookup(@flags, :mode) do
        [{:mode, m}] -> m
        [] -> :off
      end
    end

    @impl true
    def put(key, value, opts), do: NodeRestartBackend.put(key, value, opts)
    @impl true
    def get(key, opts), do: NodeRestartBackend.get(key, opts)
    @impl true
    def delete(key, opts), do: NodeRestartBackend.delete(key, opts)
    @impl true
    def list(opts), do: NodeRestartBackend.list(opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      case mode() do
        :raise_before ->
          raise "backend crashed before applying CAS"

        :raise_after ->
          # Apply the real mutation, then crash. The write is durable; the ack
          # is lost. The store must reconcile by reobservation.
          {:ok, _stored} = NodeRestartBackend.compare_and_swap(key, expected, replacement, opts)
          raise "backend crashed after applying CAS"

        :raise_after_reinsert ->
          # Fence like a real CAS, then apply a delete/reinsert instead of an
          # in-place update: the data lands under a NEW generation (revision
          # reset to 1). The ack then crashes, so BufferedStore reports
          # outcome_unknown and the store must NOT treat the matching data as
          # proof the update applied (equal data after delete/reinsert stays
          # unknown).
          reinsert_on_match(key, expected, replacement, opts)

        :raise_after_corrupt ->
          # Fence like a real CAS, then overwrite the slot with a plain
          # (non-Record) map and crash. Outcome-unknown reobservation must
          # decode the corrupt value and return bounded :invalid_record
          # without raising.
          corrupt_on_match(key, expected, opts)

        :raise_after_meta_drift ->
          # Apply the real successor, then drift ONLY the metadata, then crash.
          # Exact-successor reconciliation must NOT accept this as proof our
          # mutation applied (equal data, different metadata stays
          # outcome_unknown).
          drift_metadata(key, expected, replacement, opts)

        :raise_after_key_drift ->
          # Apply a successor with a WRONG physical key (valid envelope
          # otherwise), then crash. Reobservation must reject it (key != target)
          # as :invalid_record.
          drift_key(key, expected, replacement, opts)

        :raise_after_bad_id ->
          # Apply the real successor, then NULL the logical id (valid envelope
          # otherwise), then crash. Outcome-unknown reobservation must reject
          # the id-less persisted envelope as :invalid_record.
          drift_id_nil(key, expected, replacement, opts)

        :raise_after_bad_timestamp ->
          # Apply the real successor, then corrupt a non-nil timestamp before
          # crashing. Outcome-unknown reobservation must reject the envelope.
          drift_timestamp(key, expected, replacement, opts)

        :off ->
          NodeRestartBackend.compare_and_swap(key, expected, replacement, opts)
      end
    end

    @impl true
    def compare_and_delete(key, expected, opts),
      do: NodeRestartBackend.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart

    defp reinsert_on_match(key, expected, replacement, opts) do
      collection = Keyword.fetch!(opts, :name)

      case Storage.get(collection, key) do
        {:ok, %Record{generation: g, revision: r}}
        when is_integer(g) and is_integer(r) ->
          fence_match? =
            case expected do
              {:value, %Record{generation: eg, revision: er}} -> g == eg and r == er
              _ -> false
            end

          if fence_match? do
            now = DateTime.utc_now()

            reinserted = %{
              replacement
              | id: replacement.id,
                key: key,
                generation: g + 1,
                revision: 1,
                inserted_at: now,
                updated_at: now
            }

            Storage.raw_put(collection, key, reinserted)
            raise "backend crashed after delete/reinsert"
          else
            {:error, :conflict}
          end

        _ ->
          {:error, :conflict}
      end
    end

    defp corrupt_on_match(key, expected, opts) do
      collection = Keyword.fetch!(opts, :name)

      if fence_matches?(expected, Storage.get(collection, key)) do
        Storage.raw_put(collection, key, %{corrupt_backend_value: true})
        raise "backend crashed after corrupt write"
      else
        {:error, :conflict}
      end
    end

    defp drift_metadata(key, expected, replacement, opts) do
      {:ok, stored} = NodeRestartBackend.compare_and_swap(key, expected, replacement, opts)

      drifted = %{stored | metadata: %{"concurrent_writer" => true}}
      Storage.raw_put(Keyword.fetch!(opts, :name), key, drifted)
      raise "backend crashed after metadata drift"
    end

    defp drift_id_nil(key, expected, replacement, opts) do
      {:ok, stored} = NodeRestartBackend.compare_and_swap(key, expected, replacement, opts)

      bad = %{stored | id: nil}
      Storage.raw_put(Keyword.fetch!(opts, :name), key, bad)
      raise "backend crashed after bad-id write"
    end

    defp drift_timestamp(key, expected, replacement, opts) do
      {:ok, stored} = NodeRestartBackend.compare_and_swap(key, expected, replacement, opts)

      bad = %{stored | updated_at: "not-a-datetime"}
      Storage.raw_put(Keyword.fetch!(opts, :name), key, bad)
      raise "backend crashed after bad-timestamp write"
    end

    defp drift_key(key, expected, replacement, opts) do
      collection = Keyword.fetch!(opts, :name)
      current = Storage.get(collection, key)

      with {:ok, %Record{generation: g, revision: r} = rec} <- current,
           true <- fence_matches?(expected, current) do
        drifted = %{
          replacement
          | id: rec.id,
            key: "agent_wrong_drift_key",
            generation: g,
            revision: r + 1,
            inserted_at: rec.inserted_at,
            updated_at: DateTime.utc_now()
        }

        Storage.raw_put(collection, key, drifted)
        raise "backend crashed after key drift"
      else
        _ -> {:error, :conflict}
      end
    end

    defp fence_matches?(expected, current) do
      case {expected, current} do
        {:not_found, {:error, :not_found}} ->
          true

        {{:value, %Record{generation: eg, revision: er}},
         {:ok, %Record{generation: g, revision: r}}} ->
          g == eg and r == er

        _ ->
          false
      end
    end
  end

  setup context do
    Storage.reset!()

    if context[:flaky] do
      case :ets.whereis(FlakyBackend.flags_table!()) do
        :undefined -> :ets.new(FlakyBackend.flags_table!(), [:named_table, :public, :set])
        _t -> :ets.delete_all_objects(FlakyBackend.flags_table!())
      end
    end

    :ok
  end

  # -------------------------------------------------------------------------
  # Store lifecycle helpers (fixed production name)
  # -------------------------------------------------------------------------

  defp start_store!(backend, opts \\ []) do
    stop_recon_store!()

    start_supervised!(
      {BufferedStore,
       [
         name: @store_name,
         backend: backend,
         backend_opts: [],
         write_mode: :sync,
         ack_mode: :backend,
         collection: @collection
       ] ++ opts},
      id: :recon_store
    )

    :ok
  end

  defp start_ephemeral_store! do
    stop_recon_store!()

    start_supervised!(
      {BufferedStore,
       name: @store_name, backend: nil, write_mode: :sync, collection: @collection},
      id: :recon_store
    )

    :ok
  end

  defp stop_recon_store! do
    # stop_supervised/1 returns {:error, :not_found} when nothing is tracked
    # under the id; ignore it so callers can always ensure a clean slate.
    _ = stop_supervised(:recon_store)
    :ok
  end

  # -------------------------------------------------------------------------
  # Domain helpers
  # -------------------------------------------------------------------------

  defp facts(target, digest, op_id, caller \\ "agent_caller_recon") do
    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)

    %{
      "operation_id" => op_id,
      "target_agent_id" => target,
      "authorizing_caller_id" => caller,
      "expected_preview_reconciliation_digest" => digest,
      "desired_authority" => %{"envelope" => envelope},
      "scope" => "local_owner",
      "durability" => "node_restart",
      "created_at_unix_ms" => 1_000
    }
  end

  defp t(n), do: 1_000 + n

  @repo_root "/Users/dev/arbor"

  defp profile_cas(gen \\ 1, rev \\ 1),
    do: %{"record_id" => "profile_rec_1", "generation" => gen, "revision" => rev}

  defp profile_mutation_replay do
    %{
      "version" => ProfileAuthorityMutationCore.commitment_version(),
      "kind" => ProfileAuthorityMutationCore.commitment_kind(),
      "algorithm" => ProfileAuthorityMutationCore.commitment_algorithm(),
      "encoding" => ProfileAuthorityMutationCore.commitment_encoding(),
      "domain" => ProfileAuthorityMutationCore.commitment_domain(),
      "anchor_digest" => String.duplicate("11", 32),
      "successor_digest" => String.duplicate("22", 32)
    }
  end

  defp frozen_authority(operation, repo_root \\ @repo_root) do
    envelope = operation["desired_authority"]["envelope"]
    snap = TemplateAuthorityPolicy.snapshot(envelope)
    declared = TemplateAuthorityPolicy.capabilities(snap)

    assert {:ok, caps} =
             TemplateAuthorityCapabilityProjection.project_normalized(
               declared,
               operation["target_agent_id"],
               repo_root: repo_root
             )

    %{"repo_root" => repo_root, "effective_capabilities" => caps}
  end

  defp open!(target, digest, op_id) do
    assert {:ok, op} = Store.open(facts(target, digest, op_id))
    op
  end

  defp snapshot!(target) do
    assert {:ok, record} = Store.snapshot(target)
    record
  end

  # A Record shaped like a persisted one (backend stamps generation/revision
  # to 1 on insert). Used to seed durable state that exercises the DATA
  # admission path rather than the fence-token guard.
  defp persisted_record(target, data) do
    Record.new(target, data, generation: 1, revision: 1)
  end

  # Apply one pure-core reducer to the observed Record and persist it through
  # the store's compare-and-swap boundary. Returns the committed Record so the
  # next reducer step chains on the exact authoritative snapshot.
  defp apply_step!(observed_record, reducer) do
    observed_op = observed_record.data
    assert {:ok, next, _effects} = reducer.(observed_op)
    assert {:ok, committed_record} = Store.compare_and_swap(observed_record, next)
    committed_record
  end

  defp ack(observed_record, phase, at, extra \\ %{}) do
    apply_step!(observed_record, &Core.acknowledge(&1, ack_facts(phase, at, extra)))
  end

  defp prepare(observed_record, at) do
    operation = observed_record.data

    facts = %{
      "at_unix_ms" => at,
      "profile_cas" => profile_cas(),
      "frozen_authority" => frozen_authority(operation),
      "profile_mutation_replay" => profile_mutation_replay()
    }

    apply_step!(observed_record, &Core.prepare(&1, facts))
  end

  defp plan(observed_record, at, entries) do
    facts = %{"at_unix_ms" => at, "entries" => entries}
    apply_step!(observed_record, &Core.plan_capability_effects(&1, facts))
  end

  defp cleanup(observed_record, at) do
    apply_step!(observed_record, &Core.ack_cleanup(&1, %{"at_unix_ms" => at}))
  end

  defp hold(observed_record, reason, at) do
    facts = %{"reason_code" => reason, "at_unix_ms" => at}
    apply_step!(observed_record, &Core.hold_blocked(&1, facts))
  end

  defp to_replacable_terminal!(target, digest, op_id) do
    open!(target, digest, op_id)

    observed = snapshot!(target)
    observed = ack(observed, "reserved", t(1))
    observed = prepare(observed, t(2))
    observed = ack(observed, "prepared", t(3))
    observed = ack(observed, "deny_all_intent", t(4))

    observed =
      ack(observed, "deny_all_installed", t(5), %{"runtime_was_running" => true})

    observed = plan(observed, t(10), [])
    observed = ack(observed, "capability_effects", t(11))
    observed = ack(observed, "profile_commit", t(12))
    observed = ack(observed, "desired_trust", t(13))
    observed = ack(observed, "verifying", t(14))
    observed = ack(observed, "runtime_restore", t(15))

    # Now completed with the dispatch fence still installed (outstanding). Ack
    # cleanup to settle the fence and make the terminal record replaceable.
    cleanup(observed, t(20))
  end

  defp to_blocked!(target, digest, op_id) do
    open!(target, digest, op_id)
    observed = snapshot!(target)
    observed = ack(observed, "reserved", t(1))
    hold(observed, "explicit_hold", t(2))
  end

  defp to_completed_with_fence!(target, digest, op_id) do
    open!(target, digest, op_id)

    observed = snapshot!(target)
    observed = ack(observed, "reserved", t(1))
    observed = prepare(observed, t(2))
    observed = ack(observed, "prepared", t(3))
    observed = ack(observed, "deny_all_intent", t(4))

    observed =
      ack(observed, "deny_all_installed", t(5), %{"runtime_was_running" => true})

    observed = plan(observed, t(10), [])
    observed = ack(observed, "capability_effects", t(11))
    observed = ack(observed, "profile_commit", t(12))
    observed = ack(observed, "desired_trust", t(13))
    observed = ack(observed, "verifying", t(14))
    ack(observed, "runtime_restore", t(15))
  end

  defp ack_facts(phase, at, extra \\ %{}),
    do: Map.merge(%{"phase_intent" => phase, "at_unix_ms" => at}, extra)

  # -------------------------------------------------------------------------
  # Authority attestation
  # -------------------------------------------------------------------------

  test "attests node-restart authority and rejects ephemeral / process-lifetime" do
    start_store!(NodeRestartBackend)
    assert :ok = Store.attest_authority()
    stop_recon_store!()

    start_store!(ProcessLifetimeBackend)
    assert {:error, :authority_not_durable} = Store.attest_authority()
    stop_recon_store!()

    start_ephemeral_store!()
    assert {:error, :authority_not_durable} = Store.attest_authority()
  end

  test "non-node-restart authority is rejected before any mutation or read" do
    start_ephemeral_store!()
    target = "agent_recon_e1"

    assert {:error, :authority_not_durable} =
             Store.open(facts(target, @digest_a, "op1"))

    assert {:error, :authority_not_durable} = Store.fetch(target)

    assert {:error, :authority_not_durable} = Store.list_outstanding()

    assert {:error, :authority_not_durable} = Store.snapshot(target)

    start_store!(ProcessLifetimeBackend)

    assert {:error, :authority_not_durable} =
             Store.open(facts("agent_recon_e2", @digest_a, "op2"))
  end

  test "redacted durability: attestation returns bounded atoms and leaks no backend internals" do
    start_store!(NodeRestartBackend)
    assert :ok = Store.attest_authority()
    stop_recon_store!()

    start_store!(ProcessLifetimeBackend)
    assert {:error, reason} = Store.attest_authority()
    # The error is a single bounded atom — it carries no backend class, reason,
    # record, digest, payload, or exception text.
    assert reason == :authority_not_durable
    assert is_atom(reason)
    stop_recon_store!()

    start_ephemeral_store!()
    assert {:error, :authority_not_durable} = Store.attest_authority()

    # A fetch against an unavailable store returns the unavailable atom, never
    # the backend's underlying reason.
    stop_recon_store!()

    assert {:error, :authority_unavailable} = Store.fetch("agent_recon_unavail")
  end

  # -------------------------------------------------------------------------
  # Idempotent open / resume / replace
  # -------------------------------------------------------------------------

  test "open creates one operation and is idempotent for same target and digest" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_idem"

    op = open!(target, @digest_a, "op1")
    assert op["operation_id"] == "op1"
    assert op["status"] == "active"
    assert op["phase"] == "reserved"

    # Same (target, digest), different op_id: returns the EXISTING operation.
    op_again = open!(target, @digest_a, "op_other")
    assert op_again["operation_id"] == "op1"
    assert op_again == op
  end

  @tag :concurrency
  test "same-digest concurrency yields one winner and no split-brain target operation" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_race"

    tasks =
      for i <- 1..20 do
        Task.async(fn -> Store.open(facts(target, @digest_a, "op_#{i}")) end)
      end

    results = Task.await_many(tasks, 5_000)

    assert length(results) == 20
    assert Enum.all?(results, &match?({:ok, _}, &1))

    operations = for {:ok, op} <- results, do: op
    winner_ids = operations |> Enum.map(& &1["operation_id"]) |> MapSet.new()
    assert MapSet.size(winner_ids) == 1

    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == [target]
  end

  @tag :concurrency
  test "different-digest exclusion: one digest wins, the other cannot replace outstanding" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_excl"

    tasks =
      for i <- 1..20 do
        digest = if rem(i, 2) == 0, do: @digest_a, else: @digest_b
        Task.async(fn -> Store.open(facts(target, digest, "op_#{i}")) end)
      end

    results = Task.await_many(tasks, 5_000)
    oks = for {:ok, op} <- results, do: op
    outstanding = for {:error, :operation_outstanding} <- results, do: true

    # Exactly one digest's opens won; the rest were excluded.
    assert oks != []

    winning_digests =
      oks |> Enum.map(& &1["expected_preview_reconciliation_digest"]) |> MapSet.new()

    assert MapSet.size(winning_digests) == 1
    assert length(outstanding) == 20 - length(oks)

    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == [target]

    # A subsequent different-digest open is still excluded.
    other = if(Enum.member?(winning_digests, @digest_a), do: @digest_b, else: @digest_a)

    assert {:error, :operation_outstanding} =
             Store.open(facts(target, other, "op_late"))
  end

  test "a different digest cannot replace an active or blocked operation" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_block"

    open!(target, @digest_a, "op1")

    assert {:error, :operation_outstanding} =
             Store.open(facts(target, @digest_b, "op2"))

    to_blocked!(target, @digest_a, "op3")

    assert {:error, :operation_outstanding} =
             Store.open(facts(target, @digest_b, "op4"))

    # The original outstanding operation is untouched.
    assert {:ok, op} = Store.fetch(target)
    assert op["expected_preview_reconciliation_digest"] == @digest_a
    assert op["status"] == "blocked"
  end

  test "terminal replacement requires a replaceable terminal snapshot plus authoritative CAS" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_replace"

    settled = to_replacable_terminal!(target, @digest_a, "op1")
    assert Core.replaceable?(settled.data)

    # Same digest on a replaceable terminal returns the terminal receipt — it
    # does NOT re-create the operation.
    assert {:ok, receipt} = Store.open(facts(target, @digest_a, "op_same"))
    assert receipt["operation_id"] == "op1"
    assert receipt["status"] == "completed"

    # Different digest replaces the settled terminal via CAS.
    assert {:ok, op2} = Store.open(facts(target, @digest_b, "op2"))
    assert op2["operation_id"] == "op2"
    assert op2["expected_preview_reconciliation_digest"] == @digest_b
    assert op2["status"] == "active"

    # The new operation is outstanding; the old digest is now excluded.
    assert {:error, :operation_outstanding} =
             Store.open(facts(target, @digest_a, "op3"))

    assert {:ok, op2_again} = Store.open(facts(target, @digest_b, "op2b"))
    assert op2_again["operation_id"] == "op2"
  end

  # -------------------------------------------------------------------------
  # Internal compare-and-swap update boundary
  # -------------------------------------------------------------------------

  test "compare_and_swap advances an operation and preserves immutable identity" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_cas"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)

    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    assert {:ok, committed_record} = Store.compare_and_swap(observed, next)
    committed = committed_record.data
    assert committed["phase"] == "fenced"
    assert committed["operation_id"] == "op1"
    assert committed["target_agent_id"] == target
    assert committed["expected_preview_reconciliation_digest"] == @digest_a
    assert committed["created_at_unix_ms"] == observed.data["created_at_unix_ms"]

    # Logical Record identity (id) is preserved across the update.
    assert committed_record.id == observed.id
    assert committed_record.generation == observed.generation
    assert committed_record.revision == observed.revision + 1

    assert {:ok, fetched} = Store.fetch(target)
    assert fetched == committed
  end

  test "stale generation/revision cannot update and is reported as conflict" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_stale"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)

    # A concurrent writer advances the slot first.
    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))
    assert {:ok, _committed} = Store.compare_and_swap(observed, next)

    # The stale observed snapshot (reserved, rev 1) can no longer update the
    # now-fenced slot: a concurrent writer advanced its generation/revision.
    assert {:error, :cas_conflict} = Store.compare_and_swap(observed, next)
  end

  test "ABA fencing: a stale snapshot conflicts even when operation data is byte-identical" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_aba"

    open!(target, @digest_a, "op1")
    r1 = snapshot!(target)

    # A concurrent writer advances the revision while restoring IDENTICAL
    # operation data — the ABA setup. The store's own boundary advances the
    # slot from rev 1 to rev 2 without changing the operation.
    assert {:ok, r2} = Store.compare_and_swap(r1, r1.data)
    assert r2.data == r1.data
    assert r2.generation == r1.generation
    assert r2.revision > r1.revision

    # The stale observed snapshot r1 must conflict even though r1.data is
    # byte-for-byte equal to the current operation data. The boundary fences on
    # the exact observed Record generation+revision; it never re-fetches and
    # adopts a newer revision merely because the data is equal.
    {:ok, fenced_next, _} = Core.acknowledge(r1.data, ack_facts("reserved", t(1)))
    assert {:error, :cas_conflict} = Store.compare_and_swap(r1, fenced_next)

    # The current snapshot (r2) still advances normally — the slot is healthy.
    assert {:ok, advanced} = Store.compare_and_swap(r2, fenced_next)
    assert advanced.data["phase"] == "fenced"
    assert advanced.revision == r2.revision + 1

    # Exactly one operation exists for the target.
    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == [target]
  end

  test "compare_and_swap rejects a next operation whose identity fields changed" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_identity"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)
    tampered = Map.put(observed.data, "operation_id", "op_other")

    assert {:error, :identity_changed} = Store.compare_and_swap(observed, tampered)

    # The slot is untouched.
    assert {:ok, fetched} = Store.fetch(target)
    assert fetched["operation_id"] == "op1"
  end

  test "compare_and_swap rejects a non-Record observed anchor and a non-map next op" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_shape"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)

    assert {:error, :invalid_request} = Store.compare_and_swap(observed.data, observed.data)
    assert {:error, :invalid_request} = Store.compare_and_swap(observed, nil)
    assert {:error, :invalid_request} = Store.compare_and_swap(nil, observed.data)
  end

  test "compare_and_swap refuses a tampered observed envelope (data swapped, tokens preserved)" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_tamper"

    open!(target, @digest_a, "op1")
    legitimate = snapshot!(target)

    # A second, fully valid operation identity for the same target (real
    # envelope + digest tokens), distinct from what is durably stored.
    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)

    {smuggled, _} = build_minimal_operation(target, @digest_b, "op_smuggled", envelope)

    # The caller swaps the observed Record's data to the smuggled operation
    # while preserving its tokens (id/key/metadata/generation/revision), and
    # supplies the same smuggled operation as next. Identity is "preserved"
    # (observed.data == next), so only the full-envelope stability check can
    # stop a different operation being written under a stolen anchor.
    tampered = %{legitimate | data: smuggled}

    assert {:error, :cas_conflict} = Store.compare_and_swap(tampered, smuggled)

    # Durable state is byte-for-byte unchanged: still op1.
    assert {:ok, fetched} = Store.fetch(target)
    assert fetched["operation_id"] == "op1"
    assert {:ok, %Record{data: data}} = Storage.get(@collection, target)
    assert data["operation_id"] == "op1"
  end

  # -------------------------------------------------------------------------
  # Target-agent bound
  # -------------------------------------------------------------------------

  test "target_agent_id is bounded to 256 bytes before regex work" do
    start_store!(NodeRestartBackend)

    # "agent_" (6) + 251 chars = 257 bytes — over the 256-byte bound.
    too_long = "agent_" <> String.duplicate("a", 251)
    assert byte_size(too_long) == 257

    assert {:error, :invalid_candidate} =
             Store.open(facts(too_long, @digest_a, "op1"))

    # fetch/snapshot reject the oversized key at the boundary (before regex).
    assert {:error, :invalid_request} = Store.fetch(too_long)
    assert {:error, :invalid_request} = Store.snapshot(too_long)

    # A 256-byte target (the maximum) is admitted by the bound.
    max_ok = "agent_" <> String.duplicate("a", 250)
    assert byte_size(max_ok) == 256

    assert {:ok, op} = Store.open(facts(max_ok, @digest_a, "op1"))
    assert op["target_agent_id"] == max_ok

    assert {:ok, fetched} = Store.fetch(max_ok)
    assert fetched["target_agent_id"] == max_ok

    # A non-agent_id grammar is rejected at the boundary.
    assert {:error, :invalid_request} = Store.fetch("not_an_agent")
    assert {:error, :invalid_candidate} = Store.open(facts("not_an_agent", @digest_a, "op"))
  end

  # -------------------------------------------------------------------------
  # Malformed durable data — fail closed, never repair/replace
  # -------------------------------------------------------------------------

  test "fetch fails closed for malformed, wrong-key, and wrong-target records" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_bad"

    # Wrong Record.key (physical key disagrees with envelope key).
    :ok = Storage.raw_put(@collection, target, Record.new("agent_other", %{}))
    assert {:error, :invalid_record} = Store.fetch(target)

    # Raw value, not a Record.
    :ok = Storage.raw_put(@collection, target, %{not_a: :record})
    assert {:error, :invalid_record} = Store.fetch(target)

    # Valid Record whose data admits but target disagrees with the key.
    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)

    other_target_op =
      build_minimal_operation("agent_other", @digest_a, "op_x", envelope)
      |> elem(0)

    :ok = Storage.raw_put(@collection, target, persisted_record(target, other_target_op))
    assert {:error, :invalid_record} = Store.fetch(target)
  end

  test "persisted Records with invalid or nonpositive fence tokens fail closed" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_fencetoken"

    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)
    {good_op, _} = build_minimal_operation(target, @digest_a, "op1", envelope)

    # generation = 0 (never persisted / nonpositive) — data is otherwise valid.
    :ok =
      Storage.raw_put(
        @collection,
        target,
        Record.new(target, good_op, generation: 0, revision: 1)
      )

    assert {:error, :invalid_record} = Store.fetch(target)
    assert {:error, :invalid_record} = Store.snapshot(target)

    # revision = 0 (nonpositive).
    :ok =
      Storage.raw_put(
        @collection,
        target,
        Record.new(target, good_op, generation: 1, revision: 0)
      )

    assert {:error, :invalid_record} = Store.fetch(target)

    # nil fence tokens (an unpersisted envelope smuggled into durable state).
    bad = %Record{Record.new(target, good_op) | generation: nil, revision: nil}
    :ok = Storage.raw_put(@collection, target, bad)

    assert {:error, :invalid_record} = Store.fetch(target)
    assert {:error, :invalid_record} = Store.list_outstanding()
  end

  test "fetch and snapshot fail closed for malformed required Record envelope fields" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_bad_env"

    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)
    {good_op, _} = build_minimal_operation(target, @digest_a, "op1", envelope)
    base = persisted_record(target, good_op)

    # nil logical id.
    :ok = Storage.raw_put(@collection, target, %Record{base | id: nil})
    assert {:error, :invalid_record} = Store.fetch(target)
    assert {:error, :invalid_record} = Store.snapshot(target)

    # Non-nil timestamps must be DateTime structs.
    :ok = Storage.raw_put(@collection, target, %Record{base | inserted_at: "not-a-datetime"})
    assert {:error, :invalid_record} = Store.fetch(target)

    :ok = Storage.raw_put(@collection, target, %Record{base | updated_at: 123})
    assert {:error, :invalid_record} = Store.snapshot(target)

    # Timestamps remain optional under the Record contract.
    :ok = Storage.raw_put(@collection, target, %Record{base | inserted_at: nil, updated_at: nil})
    assert {:ok, _operation} = Store.fetch(target)

    # empty logical id.
    :ok = Storage.raw_put(@collection, target, %Record{base | id: ""})
    assert {:error, :invalid_record} = Store.fetch(target)

    # oversized logical id (257 bytes — over the 256-byte bound).
    :ok =
      Storage.raw_put(@collection, target, %Record{base | id: String.duplicate("a", 257)})

    assert {:error, :invalid_record} = Store.fetch(target)

    # invalid-UTF-8 logical id.
    :ok = Storage.raw_put(@collection, target, %Record{base | id: <<0xFF, 0xFE, 0xFD>>})
    assert {:error, :invalid_record} = Store.fetch(target)

    # non-binary logical id.
    :ok = Storage.raw_put(@collection, target, %Record{base | id: 123})
    assert {:error, :invalid_record} = Store.fetch(target)

    # non-map metadata (id/data/tokens otherwise valid).
    :ok = Storage.raw_put(@collection, target, %Record{base | metadata: "not a map"})
    assert {:error, :invalid_record} = Store.fetch(target)
    assert {:error, :invalid_record} = Store.snapshot(target)

    # A 256-byte valid-UTF-8 id is admitted (the bound is inclusive).
    :ok =
      Storage.raw_put(@collection, target, %Record{base | id: String.duplicate("a", 256)})

    assert {:ok, op} = Store.fetch(target)
    assert op["operation_id"] == "op1"
  end

  test "open never repairs or replaces malformed durable state" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_norepair"

    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)
    {good_op, _} = build_minimal_operation(target, @digest_a, "op1", envelope)
    malformed = put_in(good_op, ["desired_authority", "declaration_digest"], @digest_b)
    :ok = Storage.raw_put(@collection, target, persisted_record(target, malformed))

    assert {:error, :invalid_record} = Store.open(facts(target, @digest_a, "op1"))

    # The malformed record is still there, unchanged — open did not replace it.
    assert {:ok, %Record{data: still_malformed}} = Storage.get(@collection, target)
    assert still_malformed == malformed
  end

  test "list_outstanding fails the whole inventory on malformed durable state" do
    start_store!(NodeRestartBackend)

    # One good record plus one malformed record.
    to_blocked!("agent_inv_good", @digest_a, "op_good")
    :ok = Storage.raw_put(@collection, "agent_inv_bad", %{garbage: true})

    assert {:error, :invalid_record} = Store.list_outstanding()
  end

  # -------------------------------------------------------------------------
  # Deterministic outstanding-operation inventory
  # -------------------------------------------------------------------------

  test "list_outstanding returns only outstanding operations, sorted by target" do
    start_store!(NodeRestartBackend)

    # active (reserved) — outstanding.
    open!("agent_inv_active", @digest_a, "op_active")
    # blocked — outstanding.
    to_blocked!("agent_inv_blocked", @digest_a, "op_blocked")
    # completed with dispatch fence still installed — outstanding.
    to_completed_with_fence!("agent_inv_fence", @digest_a, "op_fence")
    # completed and cleanup-acknowledged — replaceable, NOT outstanding.
    to_replacable_terminal!("agent_inv_settled", @digest_a, "op_settled")

    assert {:ok, outstanding} = Store.list_outstanding()

    targets = Enum.map(outstanding, & &1["target_agent_id"])
    assert targets == ["agent_inv_active", "agent_inv_blocked", "agent_inv_fence"]
    assert Enum.all?(outstanding, &Core.outstanding?/1)
  end

  # -------------------------------------------------------------------------
  # Backend / restart persistence
  # -------------------------------------------------------------------------

  test "an attested node-restart backend survives BufferedStore owner restart" do
    start_store!(NodeRestartBackend)
    assert :ok = Store.attest_authority()
    op = open!("agent_restart", @digest_a, "op1")
    assert op["operation_id"] == "op1"

    # Stop the BufferedStore owner; its ETS cache dies, but the backend storage
    # (a separate ETS table) survives.
    stop_recon_store!()

    start_store!(NodeRestartBackend)
    assert :ok = Store.attest_authority()
    assert {:ok, fetched} = Store.fetch("agent_restart")
    assert fetched["operation_id"] == "op1"

    # Idempotent re-open after restart still returns the persisted operation.
    assert {:ok, again} = Store.open(facts("agent_restart", @digest_a, "op_other"))
    assert again["operation_id"] == "op1"
  end

  # -------------------------------------------------------------------------
  # Ambiguous acknowledged-mutation reconciliation (outcome_unknown)
  # -------------------------------------------------------------------------

  @tag :flaky
  test "outcome_unknown after the write applied reconciles to the single operation" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:raise_after)
    target = "agent_recon_flaky_after"

    assert {:ok, op} = Store.open(facts(target, @digest_a, "op1"))
    assert op["operation_id"] == "op1"

    # The write applied (reobservation proved it) and exactly one operation
    # exists — reobservation reconciled without creating a second operation.
    assert {:ok, %Record{data: data}} = Storage.get(@collection, target)
    assert data["operation_id"] == "op1"

    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == [target]
  end

  @tag :flaky
  test "outcome_unknown before the write applied reports ambiguity and creates nothing" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:raise_before)
    target = "agent_recon_flaky_before"

    assert {:error, :outcome_unknown} = Store.open(facts(target, @digest_a, "op1"))

    # Nothing was created.
    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == []
  end

  @tag :flaky
  test "outcome_unknown on update reconciles by reobservation without a second operation" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_flaky_update"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)

    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after)

    # The CAS applied then crashed; reobservation must confirm the fenced state.
    assert {:ok, committed_record} = Store.compare_and_swap(observed, next)
    assert committed_record.data["phase"] == "fenced"

    :ok = FlakyBackend.set_mode(:off)

    assert {:ok, fetched} = Store.fetch(target)
    assert fetched == committed_record.data

    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == [target]
  end

  @tag :flaky
  test "outcome_unknown with delete/reinsert (equal data, new generation) stays unknown" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_reinsert"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)

    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after_reinsert)

    # The CAS would succeed (the envelope was stable), but the backend applies
    # a delete/reinsert instead of an in-place update: `next` data lands under a
    # NEW generation (revision reset to 1), then the ack crashes. The store
    # must NOT treat the matching data as proof the update applied — equal data
    # after delete/reinsert stays :outcome_unknown.
    assert {:error, :outcome_unknown} = Store.compare_and_swap(observed, next)

    :ok = FlakyBackend.set_mode(:off)

    # Exactly one slot exists; its data advanced but under a new generation,
    # which the store refused to attribute to our update.
    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == [target]

    assert {:ok, %Record{generation: gen, revision: rev, data: data}} =
             Storage.get(@collection, target)

    assert gen == observed.generation + 1
    assert rev == 1
    assert data["phase"] == "fenced"
  end

  @tag :flaky
  test "outcome_unknown insert reconciliation returns :invalid_record for a malformed backend value" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:raise_after_corrupt)
    target = "agent_recon_corrupt_insert"

    # The insert CAS overwrites the slot with a plain (non-Record) map, then
    # crashes. Reobservation must decode the corrupt value and return bounded
    # :invalid_record — it must NOT raise on Record field access.
    assert {:error, :invalid_record} = Store.open(facts(target, @digest_a, "op1"))

    # The corrupt value survived in the backend; the store neither repaired nor
    # replaced it.
    assert {:ok, %{corrupt_backend_value: true}} = Storage.get(@collection, target)
  end

  @tag :flaky
  test "outcome_unknown update reconciliation returns :invalid_record for a malformed backend value" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_corrupt_update"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)
    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after_corrupt)

    # The update CAS overwrites the slot with a plain map, then crashes.
    # Reobservation must decode it and return :invalid_record without raising.
    assert {:error, :invalid_record} = Store.compare_and_swap(observed, next)

    assert {:ok, %{corrupt_backend_value: true}} = Storage.get(@collection, target)
  end

  @tag :flaky
  test "outcome_unknown update reconciliation rejects metadata drift (equal data, different metadata)" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_meta_drift"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)
    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after_meta_drift)

    # The CAS applied the correct successor (id/key/generation/revision/data)
    # then drifted ONLY the metadata before crashing. Exact-successor
    # reconciliation must NOT accept this — equal data under different metadata
    # stays :outcome_unknown (same id/generation/revision/data, different
    # metadata).
    assert {:error, :outcome_unknown} = Store.compare_and_swap(observed, next)

    :ok = FlakyBackend.set_mode(:off)

    assert {:ok, %Record{data: data, metadata: meta}} = Storage.get(@collection, target)
    assert data["phase"] == "fenced"
    assert meta == %{"concurrent_writer" => true}
  end

  @tag :flaky
  test "outcome_unknown update reconciliation rejects a wrong-key successor" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_key_drift"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)
    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after_key_drift)

    # The CAS wrote a successor with a WRONG physical key (valid envelope
    # otherwise), then crashed. Reobservation must reject it (key != target) as
    # :invalid_record without raising.
    assert {:error, :invalid_record} = Store.compare_and_swap(observed, next)

    assert {:ok, %Record{key: "agent_wrong_drift_key"}} = Storage.get(@collection, target)
  end

  @tag :flaky
  test "outcome_unknown update reconciliation rejects a Record with a nil logical id" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_bad_id"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)
    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after_bad_id)

    # The CAS wrote a successor with a nil logical id (valid envelope otherwise),
    # then crashed. Outcome-unknown reobservation must decode the envelope and
    # reject the id-less persisted Record as :invalid_record without raising.
    assert {:error, :invalid_record} = Store.compare_and_swap(observed, next)

    assert {:ok, %Record{id: nil}} = Storage.get(@collection, target)
  end

  @tag :flaky
  test "outcome_unknown update reconciliation rejects malformed non-nil timestamps" do
    start_store!(FlakyBackend)
    :ok = FlakyBackend.set_mode(:off)
    target = "agent_recon_bad_timestamp"

    open!(target, @digest_a, "op1")
    observed = snapshot!(target)
    assert {:ok, next, _} = Core.acknowledge(observed.data, ack_facts("reserved", t(1)))

    :ok = FlakyBackend.set_mode(:raise_after_bad_timestamp)

    assert {:error, :invalid_record} = Store.compare_and_swap(observed, next)
    assert {:ok, %Record{updated_at: "not-a-datetime"}} = Storage.get(@collection, target)
  end

  # -------------------------------------------------------------------------
  # Argument validation & redaction
  # -------------------------------------------------------------------------

  test "invalid candidate facts are rejected without touching durable state" do
    start_store!(NodeRestartBackend)

    assert {:error, :invalid_candidate} =
             Store.open(facts("agent_recon_bad", "not-a-digest", "op1"))

    # An empty map is a valid call shape but the core rejects it.
    assert {:error, :invalid_candidate} = Store.open(%{})
    # A non-map facts argument is a bad call shape, not a candidate problem.
    assert {:error, :invalid_request} = Store.open(nil)
    assert {:error, :invalid_request} = Store.fetch("not_an_agent")
    assert {:error, :invalid_request} = Store.snapshot("not_an_agent")

    {:ok, keys} = BufferedStore.authoritative_list(name: @store_name)
    assert keys == []
    assert Storage.count(@collection) == 0
  end

  test "errors are bounded atoms and never leak records, digests, or payloads" do
    start_store!(NodeRestartBackend)
    target = "agent_recon_redact"

    {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)
    {good_op, _} = build_minimal_operation(target, @digest_a, "op1", envelope)
    malformed = put_in(good_op, ["desired_authority", "declaration_digest"], @digest_b)
    :ok = Storage.raw_put(@collection, target, persisted_record(target, malformed))

    result = Store.fetch(target)
    assert {:error, reason} = result
    assert reason == :invalid_record
    # The error atom carries no nested record, digest, payload, or exception.
    refute match?({_, _}, reason)
  end

  # -------------------------------------------------------------------------
  # No caller-selectable store authority (compile-time contract)
  # -------------------------------------------------------------------------

  test "no public runtime function accepts a caller-selected store argument" do
    # The fixed-store contract is enforced by arity: attest_authority/0,
    # fetch/1, snapshot/1, list_outstanding/0, open/1, compare_and_swap/2.
    # These arities are asserted so a future refactor cannot silently re-add a
    # store/collaborator parameter.
    funcs = Store.__info__(:functions)

    assert funcs[:attest_authority] == 0
    assert funcs[:fetch] == 1
    assert funcs[:snapshot] == 1
    assert funcs[:list_outstanding] == 0
    assert funcs[:open] == 1
    assert funcs[:compare_and_swap] == 2
  end

  # -------------------------------------------------------------------------
  # Misc helper
  # -------------------------------------------------------------------------

  defp build_minimal_operation(target, digest, op_id, envelope) do
    {:ok, op, _effects} =
      Core.new(%{
        "operation_id" => op_id,
        "target_agent_id" => target,
        "authorizing_caller_id" => "agent_caller_build",
        "expected_preview_reconciliation_digest" => digest,
        "desired_authority" => %{"envelope" => envelope},
        "scope" => "local_owner",
        "durability" => "node_restart",
        "created_at_unix_ms" => 1_000
      })

    {op, envelope}
  end
end
