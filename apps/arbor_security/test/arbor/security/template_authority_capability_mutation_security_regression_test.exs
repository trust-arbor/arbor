defmodule Arbor.Security.TemplateAuthorityCapabilityMutationSecurityRegressionTest.CASSandbox do
  @moduledoc false
  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Store.ETS

  # A thin failure-injection wrapper around the EXISTING genuinely-linearizable
  # Arbor.Persistence.Store.ETS CAS backend (structured Record
  # generation+revision fencing + delete tombstones, GenServer-serialized). All
  # real CAS semantics come from ETS; this module only injects bounded failures
  # for the ambiguous/conflict regression paths. Process-lifetime durable: it
  # persists across a CapabilityStore restart because the test keeps this
  # backend + the BufferedStore alive (only CapabilityStore is restarted).

  @puts_key {__MODULE__, :puts}
  @deletes_key {__MODULE__, :deletes}
  @cas_conflict_key {__MODULE__, :cas_conflict}
  # Post-admission failure injection: armed on a genuine CAS insert success;
  # the next get (the post-admission reobserve inside ack_commit_reobserved)
  # exits to simulate a crash at or after the durable admission boundary.
  @post_admission_key {__MODULE__, :post_admission}
  @poison_get_key {__MODULE__, :poison_get}
  # Mismatched concurrent CAS occupant: the conflict branch admits THIS record
  # (not our replacement) under the id so the acknowledged path must classify
  # :id_conflict without overwriting it.
  @cas_mismatch_key {__MODULE__, :cas_mismatch}
  # No-scan probe: counts full-inventory reads (Store.list/1), which backs the
  # authoritative_entries/authoritative_list fallback. Tests reset this AFTER
  # the store starts (restore's list already ran) and assert it stays 0 during
  # an acknowledged grant.
  @list_calls_key {__MODULE__, :list_calls}
  # Post-delete failure injection: armed on a genuine compare_and_delete
  # success, it exits to simulate a crash at or after a durable revoke
  # admission boundary (durable gone, live retained, outcome unknown).
  @post_delete_key {__MODULE__, :post_delete}

  def fail_puts(n) when is_integer(n) and n >= 0, do: :persistent_term.put(@puts_key, n)
  def fail_deletes(n) when is_integer(n) and n >= 0, do: :persistent_term.put(@deletes_key, n)

  def fail_cas_conflict(n) when is_integer(n) and n >= 0,
    do: :persistent_term.put(@cas_conflict_key, n)

  def fail_post_admission(n) when is_integer(n) and n >= 0,
    do: :persistent_term.put(@post_admission_key, n)

  def fail_post_delete(n) when is_integer(n) and n >= 0,
    do: :persistent_term.put(@post_delete_key, n)

  def inventory_scan_count, do: :persistent_term.get(@list_calls_key, 0)

  def reset_inventory_scan_count, do: :persistent_term.erase(@list_calls_key)

  def seed_cas_conflict_mismatch(%Record{} = record),
    do: :persistent_term.put(@cas_mismatch_key, record)

  def clear do
    :persistent_term.erase(@puts_key)
    :persistent_term.erase(@deletes_key)
    :persistent_term.erase(@cas_conflict_key)
    :persistent_term.erase(@post_admission_key)
    :persistent_term.erase(@poison_get_key)
    :persistent_term.erase(@cas_mismatch_key)
    :persistent_term.erase(@list_calls_key)
    :persistent_term.erase(@post_delete_key)
  end

  def start_link(opts), do: ETS.start_link(opts)

  @impl true
  def put(key, record, opts) do
    if inject?(@puts_key), do: {:error, :injected_put_failure}, else: ETS.put(key, record, opts)
  end

  @impl true
  def get(key, opts) do
    if consume_poison_get?() do
      # Post-admission crash: admission already committed, the reobserve get
      # (the first read AFTER admission) exits to force :outcome_unknown.
      exit({:post_admission, :timeout})
    else
      ETS.get(key, opts)
    end
  end

  @impl true
  def delete(key, opts) do
    if inject?(@deletes_key), do: {:error, :injected_delete_failure}, else: ETS.delete(key, opts)
  end

  @impl true
  def list(opts) do
    :persistent_term.put(@list_calls_key, :persistent_term.get(@list_calls_key, 0) + 1)
    ETS.list(opts)
  end

  @impl true
  def exists?(key, opts), do: ETS.exists?(key, opts)

  @impl true
  def compare_and_swap(key, expected, replacement, opts) do
    case pop_seeded_mismatch() do
      {:mismatch, mismatch} ->
        # A concurrent writer admitted a MISMATCHED occupant under this id just
        # before our CAS, then reported conflict. The acknowledged path
        # reobserves the mismatched record and must classify :id_conflict
        # without overwriting it.
        _ = ETS.put(key, mismatch, opts)
        {:error, :conflict}

      :none ->
        cond do
          inject?(@cas_conflict_key) ->
            # Simulate a concurrent writer that admitted the record just before
            # our CAS, then reported conflict. The acknowledged path reobserves
            # and classifies the now-present record (a REAL conflict
            # reobservation).
            _ = ETS.put(key, replacement, opts)
            {:error, :conflict}

          inject?(@puts_key) ->
            {:error, :injected_put_failure}

          true ->
            case ETS.compare_and_swap(key, expected, replacement, opts) do
              {:ok, _stored} = ok ->
                # Genuine admission succeeded: arm the post-admission poison so
                # the immediately-following reobserve get can be made to crash
                # for the convergence regression.
                :ok = maybe_arm_post_admission()
                ok

              other ->
                other
            end
        end
    end
  end

  @impl true
  def compare_and_delete(key, expected, opts) do
    if inject?(@deletes_key) do
      {:error, :injected_delete_failure}
    else
      case ETS.compare_and_delete(key, expected, opts) do
        :ok ->
          # Genuine durable delete committed. If armed, exit to simulate a
          # crash at or after the durable revoke boundary so the caller cannot
          # confirm whether live eviction + signal completed.
          if inject?(@post_delete_key), do: exit({:post_delete, :timeout})
          :ok

        other ->
          other
      end
    end
  end

  defp inject?(key) do
    case :persistent_term.get(key, 0) do
      n when n > 0 ->
        :persistent_term.put(key, n - 1)
        true

      _ ->
        false
    end
  end

  # Atomically pop a seeded mismatch record (only one conflict per seed).
  defp pop_seeded_mismatch do
    case :persistent_term.get(@cas_mismatch_key, :none) do
      :none ->
        :none

      record ->
        :persistent_term.erase(@cas_mismatch_key)
        {:mismatch, record}
    end
  end

  # Arm the post-admission poison flag when a genuine CAS insert succeeds and
  # a post-admission failure is requested. The counter is consumed when the
  # poisoned get actually fires (one-shot).
  defp maybe_arm_post_admission do
    case :persistent_term.get(@post_admission_key, 0) do
      n when n > 0 ->
        :persistent_term.put(@poison_get_key, true)
        :ok

      _ ->
        :ok
    end
  end

  # Consume the post-admission poison flag on the next get; decrement the
  # counter so the failure is one-shot.
  defp consume_poison_get? do
    case :persistent_term.get(@poison_get_key, false) do
      true ->
        :persistent_term.erase(@poison_get_key)

        remaining = :persistent_term.get(@post_admission_key, 0) - 1
        :persistent_term.put(@post_admission_key, remaining)
        true

      _ ->
        false
    end
  end
end

defmodule Arbor.Security.TemplateAuthorityCapabilityMutationSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3A — crash-journal-safe acknowledged capability mutation.

  CANONICAL SUITE: this is the canonical general acknowledged-mutation
  regression file for the Security capability store (acknowledged grant/revoke,
  same-resource admission, post-admission ambiguity, convergence signals,
  signed_at determinism, and bounded uncertainty). Do not split or duplicate
  these invariants into other files without moving them here.

  The regression file is RUNNABLE on the immediate parent (HEAD~1): each test
  branches on `acknowledged_available?/0`. On the candidate it exercises the
  acknowledged API against a TRUTHFUL CAS backend (CASSandbox, mirroring
  Store.ETS gen/rev/tombstone fencing); on the parent it exercises the ORDINARY
  grant/revoke API on the SAME retained topology and asserts the SAME
  invariant, which the ordinary API violates, so the assertion fails
  behaviorally (never via UndefinedFunctionError).
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.Events
  alias Arbor.Security.SystemAuthority

  alias __MODULE__.CASSandbox

  @security_supervisor Arbor.Security.Supervisor
  @capability_store :arbor_security_capabilities

  @security_children [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers,
    Arbor.Security.Identity.Registry,
    Arbor.Security.IssuerRegistry,
    Arbor.Security.Identity.NonceCache,
    Arbor.Security.SystemAuthority,
    Arbor.Security.SigningAuthorityStateOwner,
    Arbor.Security.SigningAuthorityBroker,
    Arbor.Security.Constraint.RateLimiter,
    Arbor.Security.CapabilityStore,
    Arbor.Security.Reflex.Registry,
    Arbor.Security.DeliveryReceiptBroker
  ]

  defp acknowledged_available? do
    function_exported?(Arbor.Security, :acknowledged_grant, 1) and
      function_exported?(Arbor.Security, :acknowledged_revoke, 1) and
      function_exported?(Arbor.Security.CapabilityStore, :acknowledged_put, 1) and
      function_exported?(Arbor.Security.CapabilityStore, :acknowledged_revoke, 1)
  end

  defp det_id(seed), do: "cap_" <> (:erlang.md5(seed) |> Base.encode16(case: :lower))
  defp fixed_granted_at, do: ~U[2026-01-01 00:00:00Z]

  defp det_grant_opts(seed, principal, resource, extra \\ []) do
    [
      capability_id: det_id(seed),
      granted_at: fixed_granted_at(),
      principal: principal,
      resource: resource
    ] ++ extra
  end

  defp build_signed_cap(opts) do
    {:ok, cap} =
      Capability.new(
        resource_uri: Keyword.fetch!(opts, :resource),
        principal_id: Keyword.fetch!(opts, :principal),
        id: Keyword.fetch!(opts, :capability_id),
        granted_at: Keyword.fetch!(opts, :granted_at),
        expires_at: Keyword.get(opts, :expires_at),
        not_before: Keyword.get(opts, :not_before),
        constraints: Keyword.get(opts, :constraints, %{}),
        delegation_depth: Keyword.get(opts, :delegation_depth, 3),
        max_uses: Keyword.get(opts, :max_uses),
        allowed_delegatees: Keyword.get(opts, :allowed_delegatees),
        session_id: Keyword.get(opts, :session_id),
        task_id: Keyword.get(opts, :task_id),
        principal_scope: Keyword.get(opts, :principal_scope),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    # Mirror the acknowledged facade: pin signed_at deterministically to
    # granted_at before signing so the signing payload is byte-identical to
    # Arbor.Security.acknowledged_grant/1 (identity-exact across retries).
    cap = %{cap | signed_at: cap.granted_at}
    {:ok, signed} = SystemAuthority.sign_capability(cap)
    signed
  end

  # Retained topology: a truthful in-memory CAS backend + named BufferedStore +
  # CapabilityStore. Persists across a CapabilityStore restart (only
  # CapabilityStore is restarted; the backend + BufferedStore stay alive).
  defp fresh_isolated_store do
    start_isolated_store(:"cas_sandbox_#{unique_integer()}")
  end

  defp fresh_isolated_store_with_failures do
    on_exit(&CASSandbox.clear/0)
    start_isolated_store(:"cas_sandbox_fail_#{unique_integer()}")
  end

  defp start_isolated_store(backend_name) do
    on_exit(&restore_security_children/0)

    :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    :ok = Supervisor.terminate_child(@security_supervisor, @capability_store)

    {:ok, _pid} = CASSandbox.start_link(name: backend_name)
    on_exit(fn -> stop_named_process(backend_name) end)

    {:ok, _pid} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: CASSandbox,
        collection: backend_name,
        write_mode: :sync,
        ack_mode: :backend,
        hydration_limit: 1_000_000
      )

    {:ok, _pid} = CapabilityStore.start_link([])
    backend_name
  end

  defp restart_capability_store do
    stop_named_process(CapabilityStore)
    {:ok, _pid} = CapabilityStore.start_link([])
  end

  defp restore_security_children do
    terminate_security_child(CapabilityStore)
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)

    Enum.each(@security_children, &restart_security_child!/1)
    assert_security_children_alive!()
  end

  defp terminate_security_child(child_id) do
    case Supervisor.terminate_child(@security_supervisor, child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restart_security_child!(child_id) do
    case Supervisor.restart_child(@security_supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> raise "failed to restore #{inspect(child_id)}: #{inspect(reason)}"
    end
  end

  defp assert_security_children_alive! do
    dead =
      Enum.reject(@security_children, fn child_id ->
        case Process.whereis(child_id) do
          nil -> child_id in optional_children()
          pid -> Process.alive?(pid)
        end
      end)

    if dead != [] do
      raise "security children left dead after this module: #{inspect(dead)}"
    end
  end

  defp optional_children do
    [
      :arbor_security_issuers,
      Arbor.Security.IssuerRegistry,
      Arbor.Security.SigningAuthorityStateOwner,
      Arbor.Security.SigningAuthorityBroker,
      Arbor.Security.DeliveryReceiptBroker
    ]
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp unique_integer, do: :erlang.unique_integer([:positive])

  # ==========================================================================
  # G1 — preserved same-resource grant is not replaced.
  # ==========================================================================

  test "security regression: preserved same-resource grant is not replaced" do
    fresh_isolated_store()
    principal = "agent_ack_g1"
    resource = "arbor://fs/read/ack-g1"

    if acknowledged_available?() do
      assert {:ok, original} = Security.grant(principal: principal, resource: resource)
      original_id = original.id

      assert {:error, :resource_conflict} =
               Security.acknowledged_grant(det_grant_opts("g1", principal, resource))

      assert {:ok, %Capability{id: ^original_id}} = CapabilityStore.get(original_id)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    else
      assert {:ok, first} = Security.grant(principal: principal, resource: resource)
      first_id = first.id
      assert {:ok, _second} = Security.grant(principal: principal, resource: resource)
      assert {:ok, %Capability{id: ^first_id}} = CapabilityStore.get(first_id)
    end
  end

  # ==========================================================================
  # G2 — exact retry idempotent, no duplicate emission.
  # ==========================================================================

  test "security regression: exact retry is idempotent and emits no duplicate" do
    fresh_isolated_store()
    principal = "agent_ack_g2"
    resource = "arbor://fs/read/ack-g2"
    opts = det_grant_opts("g2", principal, resource)

    if acknowledged_available?() do
      granted_before = CapabilityStore.stats().total_granted

      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)

      assert CapabilityStore.stats().total_granted == granted_before + 1

      assert {:ok, %Capability{id: ^id}} = CapabilityStore.get(id)
    else
      assert {:ok, first} = Security.grant(principal: principal, resource: resource)
      first_id = first.id
      assert {:ok, second} = Security.grant(principal: principal, resource: resource)
      assert second.id == first_id
    end
  end

  # ==========================================================================
  # G3 — same-id mismatch rejected and untouched.
  # ==========================================================================

  test "security regression: same-id mismatch rejected and untouched" do
    fresh_isolated_store()
    resource = "arbor://fs/read/ack-g3"
    seeded_id = det_id("g3-seed")

    seeded =
      build_signed_cap(
        capability_id: seeded_id,
        granted_at: fixed_granted_at(),
        principal: "agent_ack_g3_seed",
        resource: resource
      )

    assert {:ok, :stored} = CapabilityStore.put(seeded)

    if acknowledged_available?() do
      assert {:error, :id_conflict} =
               Security.acknowledged_grant(
                 det_grant_opts("g3-seed", "agent_ack_g3_other", resource)
               )

      assert {:ok, %Capability{id: ^seeded_id, principal_id: "agent_ack_g3_seed"}} =
               CapabilityStore.get(seeded_id)
    else
      replacement =
        build_signed_cap(
          capability_id: seeded_id,
          granted_at: fixed_granted_at(),
          principal: "agent_ack_g3_other",
          resource: resource
        )

      assert {:ok, :stored} = CapabilityStore.put(replacement)

      assert {:ok, %Capability{principal_id: "agent_ack_g3_seed"}} =
               CapabilityStore.get(seeded_id)
    end
  end

  # ==========================================================================
  # G4 — ambiguous acknowledged put fails closed.
  # ==========================================================================

  test "security regression: ambiguous acknowledged put fails closed" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_g4"
    resource = "arbor://fs/read/ack-g4"
    opts = det_grant_opts("g4", principal, resource)

    CASSandbox.fail_puts(1)

    if acknowledged_available?() do
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(opts)

      assert {:error, :not_found} = CapabilityStore.get(opts[:capability_id])
      assert {:ok, durable_ids} = BufferedStore.authoritative_list(name: @capability_store)
      refute opts[:capability_id] in durable_ids

      assert {:error, :unauthorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    else
      assert {:ok, %Capability{}} = Security.grant(principal: principal, resource: resource)
      flunk("parent ordinary grant reported success on an ambiguous durable write")
    end
  end

  # ==========================================================================
  # G5 — malformed authoritative reobservation fails closed.
  # ==========================================================================

  test "security regression: malformed authoritative reobservation fails closed" do
    fresh_isolated_store()
    principal = "agent_ack_g5"
    target_id = det_id("g5")
    resource = "arbor://fs/read/ack-g5"

    # Seed a malformed record under the deterministic id (passes the Record
    # shape + map data, but fails capability validation + authority verify).
    assert {:ok, _} =
             BufferedStore.acknowledged_put(
               target_id,
               Record.new(target_id, %{"garbage" => true}),
               name: @capability_store
             )

    if acknowledged_available?() do
      opts = [
        capability_id: target_id,
        granted_at: fixed_granted_at(),
        principal: principal,
        resource: resource
      ]

      assert {:error, :outcome_unknown} = Security.acknowledged_grant(opts)

      assert {:error, :not_found} = CapabilityStore.get(target_id)
      assert {:ok, durable_ids} = BufferedStore.authoritative_list(name: @capability_store)
      assert target_id in durable_ids
    else
      assert {:error, :not_found} = CapabilityStore.get(target_id)
    end
  end

  # ==========================================================================
  # G6 — acknowledged revoke idempotent absence (no stat/signal/audit).
  # ==========================================================================

  test "security regression: acknowledged revoke treats authoritative absence as idempotent" do
    fresh_isolated_store()
    unknown_id = det_id("g6-unknown")

    if acknowledged_available?() do
      revoked_before = CapabilityStore.stats().total_revoked

      assert {:ok, :idempotent, ^unknown_id} = Security.acknowledged_revoke(unknown_id)

      # Durable-absent revoke evicts a stale live projection WITHOUT stats,
      # signal, or audit: the revoked counter is unchanged.
      assert CapabilityStore.stats().total_revoked == revoked_before

      assert {:error, :not_found} = CapabilityStore.get(unknown_id)
      assert {:ok, durable_ids} = BufferedStore.authoritative_list(name: @capability_store)
      assert unknown_id not in durable_ids
    else
      assert :ok = Security.revoke(unknown_id)
    end
  end

  # ==========================================================================
  # G7 — acknowledged revoke applied evicts live + durable.
  # ==========================================================================

  test "security regression: acknowledged revoke applied evicts live and durable" do
    fresh_isolated_store()
    principal = "agent_ack_g7"
    resource = "arbor://fs/read/ack-g7"
    opts = det_grant_opts("g7", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)
      assert {:ok, :applied, ^id} = Security.acknowledged_revoke(id)

      assert {:error, :not_found} = CapabilityStore.get(id)
      assert {:ok, durable_ids} = BufferedStore.authoritative_list(name: @capability_store)
      assert id not in durable_ids
    else
      assert {:ok, %Capability{id: id}} = Security.grant(principal: principal, resource: resource)
      assert {:ok, :applied, ^id} = Security.revoke(id)
    end
  end

  # ==========================================================================
  # G8 — acknowledged revoke does not resurrect after CapabilityStore restart.
  # ==========================================================================

  test "security regression: acknowledged revoke does not resurrect after restart" do
    fresh_isolated_store()
    principal = "agent_ack_g8"
    resource = "arbor://fs/read/ack-g8"
    opts = det_grant_opts("g8", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)
      assert {:ok, :applied, ^id} = Security.acknowledged_revoke(id)

      restart_capability_store()

      assert {:error, :not_found} = CapabilityStore.get(id)
      assert {:ok, durable_ids} = BufferedStore.authoritative_list(name: @capability_store)
      assert id not in durable_ids

      assert {:error, :unauthorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    else
      assert {:ok, %Capability{id: id}} = Security.grant(principal: principal, resource: resource)
      CASSandbox.fail_deletes(1)
      assert :ok = Security.revoke(id)
      CASSandbox.clear()

      restart_capability_store()

      assert {:error, :unauthorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    end
  end

  # ==========================================================================
  # G9 — acknowledged fresh grant remains exactly present after restart.
  # ==========================================================================

  test "security regression: acknowledged fresh grant remains present after restart" do
    fresh_isolated_store()
    principal = "agent_ack_g9"
    resource = "arbor://fs/read/ack-g9"
    opts = det_grant_opts("g9", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)

      restart_capability_store()

      assert {:ok, %Capability{id: ^id}} = CapabilityStore.get(id)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    else
      CASSandbox.fail_puts(1)
      assert {:ok, %Capability{}} = Security.grant(principal: principal, resource: resource)
      CASSandbox.clear()

      restart_capability_store()

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    end
  end

  # ==========================================================================
  # G10 — ambiguous acknowledged delete fails closed, not reported applied.
  # ==========================================================================

  test "security regression: ambiguous acknowledged delete fails closed" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_g10"
    resource = "arbor://fs/read/ack-g10"
    opts = det_grant_opts("g10", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)

      CASSandbox.fail_deletes(1)

      assert {:error, :outcome_unknown} = Security.acknowledged_revoke(id)

      # NOT applied: live NOT evicted (still authorizes).
      assert {:ok, %Capability{id: ^id}} = CapabilityStore.get(id)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)

      CASSandbox.clear()
      assert {:ok, :applied, ^id} = Security.acknowledged_revoke(id)
      assert {:error, :not_found} = CapabilityStore.get(id)
    else
      assert {:ok, %Capability{id: id}} = Security.grant(principal: principal, resource: resource)
      CASSandbox.fail_deletes(1)
      assert {:error, _reason} = Security.revoke(id)
    end
  end

  # ==========================================================================
  # G11 — fresh acknowledged grant indexes the id exactly once.
  # ==========================================================================

  test "security regression: fresh acknowledged grant indexes the id exactly once" do
    fresh_isolated_store()
    principal = "agent_ack_g11"
    resource = "arbor://fs/read/ack-g11"
    opts = det_grant_opts("g11", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)

      state = :sys.get_state(CapabilityStore)

      principal_ids = Map.get(state.by_principal, principal, [])
      assert Enum.count(principal_ids, &(&1 == id)) == 1

      assert {:ok, %Capability{} = cap} = Map.fetch(state.by_id, id)
      assert cap.id == id

      # by_usage is canonicalized for the exact id (no ghost entry on a fresh
      # projection) and other ids are untouched.
      refute Map.has_key?(state.by_usage, id)

      assert {:ok, %Record{}} = BufferedStore.authoritative_get(id, name: @capability_store)
    else
      seeded =
        build_signed_cap(
          capability_id: det_id("g11"),
          granted_at: fixed_granted_at(),
          principal: principal,
          resource: resource
        )

      assert {:ok, :stored} = CapabilityStore.put(seeded)

      replacement =
        build_signed_cap(
          capability_id: det_id("g11"),
          granted_at: fixed_granted_at(),
          principal: principal,
          resource: "arbor://fs/read/ack-g11-other"
        )

      assert {:ok, :stored} = CapabilityStore.put(replacement)

      assert {:ok, %Capability{resource_uri: "arbor://fs/read/ack-g11"}} =
               CapabilityStore.get(det_id("g11"))
    end
  end

  # ==========================================================================
  # G12 — durable-absent/live-exact is durable repair with no side-effect dup.
  # ==========================================================================

  test "security regression: durable-absent/live-exact is durable repair with no duplicate" do
    fresh_isolated_store()
    principal = "agent_ack_g12"
    resource = "arbor://fs/read/ack-g12"
    opts = det_grant_opts("g12", principal, resource)

    if acknowledged_available?() do
      seeded = build_signed_cap(opts)
      assert {:ok, :stored} = CapabilityStore.put(seeded)
      :ok = BufferedStore.acknowledged_delete(opts[:capability_id], name: @capability_store)

      granted_before = CapabilityStore.stats().total_granted
      revoked_before = CapabilityStore.stats().total_revoked

      assert {:ok, :idempotent, id} = Security.acknowledged_grant(opts)
      assert id == opts[:capability_id]

      assert {:ok, %Record{}} =
               BufferedStore.authoritative_get(opts[:capability_id], name: @capability_store)

      assert CapabilityStore.stats().total_granted == granted_before
      assert CapabilityStore.stats().total_revoked == revoked_before

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    else
      granted_before = CapabilityStore.stats().total_granted
      assert {:ok, _first} = Security.grant(principal: principal, resource: resource)
      assert {:ok, _second} = Security.grant(principal: principal, resource: resource)
      assert CapabilityStore.stats().total_granted == granted_before
    end
  end

  # ==========================================================================
  # G13 — acknowledged grant CAS conflict is classified and fails closed.
  # ==========================================================================

  test "security regression: acknowledged grant CAS conflict is reobserved and classified" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_g13"
    resource = "arbor://fs/read/ack-g13"
    opts = det_grant_opts("g13", principal, resource)

    if acknowledged_available?() do
      # fail_cas_conflict makes the backend admit the record then report CAS
      # conflict, simulating a concurrent writer. The acknowledged path
      # REOBSERVES the now-present record, classifies the exact-already-applied
      # identity as idempotent, and projects it live — without re-admitting or
      # re-emitting.
      granted_before = CapabilityStore.stats().total_granted

      CASSandbox.fail_cas_conflict(1)

      assert {:ok, :idempotent, id} = Security.acknowledged_grant(opts)
      assert id == opts[:capability_id]

      # The reobserved record is durable and live; no duplicate grant stat.
      assert {:ok, %Record{}} =
               BufferedStore.authoritative_get(opts[:capability_id], name: @capability_store)

      assert {:ok, %Capability{id: ^id}} = CapabilityStore.get(id)
      assert CapabilityStore.stats().total_granted == granted_before

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)

      # An ambiguous (non-conflict) CAS failure still fails closed.
      CASSandbox.clear()
      CASSandbox.fail_puts(1)
      other = det_grant_opts("g13b", principal, "arbor://fs/read/ack-g13b")
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(other)
    else
      CASSandbox.fail_puts(1)
      assert {:error, _reason} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # G14 — closed, globally-bounded admission input.
  # ==========================================================================

  test "security regression: acknowledged grant validates a closed bounded input" do
    fresh_isolated_store()
    principal = "agent_ack_g14"
    resource = "arbor://fs/read/ack-g14"
    base = [principal: principal, resource: resource, granted_at: fixed_granted_at()]

    if acknowledged_available?() do
      # Unknown / forbidden keys, non-keyword, and duplicate keys are rejected.
      assert {:error, :invalid_request} =
               Security.acknowledged_grant(base ++ [capability_id: det_id("k0"), issuer_id: "x"])

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(base ++ [capability_id: det_id("k0"), foreign: 1])

      # Missing required key.
      assert {:error, :invalid_request} = Security.acknowledged_grant(base)

      # Malformed capability id.
      assert {:error, :invalid_request} =
               Security.acknowledged_grant(base ++ [capability_id: "not-a-cap-id"])

      # Oversized map value, over-deep nesting, and oversized integer are rejected.
      big_binary = String.duplicate("a", 512)

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 base ++
                   [capability_id: det_id("k1"), constraints: %{k: big_binary}]
               )

      deep = %{n: %{n: %{n: %{n: %{n: %{n: %{n: %{n: 1}}}}}}}}

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(base ++ [capability_id: det_id("k2"), metadata: deep])

      huge_int = Integer.pow(2, 70)

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 base ++ [capability_id: det_id("k3"), constraints: %{n: huge_int}]
               )

      # A well-formed minimal grant still succeeds.
      assert {:ok, :applied, _id} =
               Security.acknowledged_grant(det_grant_opts("g14-ok", principal, resource))
    else
      # PARENT behavioral probe: ordinary grant accepts arbitrary unbounded maps.
      assert {:ok, %Capability{}} =
               Security.grant(
                 principal: principal,
                 resource: resource,
                 metadata: %{deep: %{deep: %{deep: %{deep: %{deep: %{deep: %{deep: 1}}}}}}}
               )

      # The invariant: admission must validate a closed bounded input. Ordinary
      # grant accepted the over-deep map, so this is unreachable on the parent.
      flunk("parent ordinary grant accepted unbounded admission input")
    end
  end

  # ==========================================================================
  # F1 — same-resource conflict detected from by_id even when by_principal is
  # stale; a different capability is never replaced or mutated.
  # ==========================================================================
  test "security regression: by_id conflict detection ignores a stale by_principal" do
    fresh_isolated_store()
    principal = "agent_ack_f1"
    resource = "arbor://fs/read/ack-f1"
    assert {:ok, original} = Security.grant(principal: principal, resource: resource)
    original_id = original.id

    # Simulate a stale by_principal: the cap is present in by_id (authoritative)
    # but missing from its by_principal list.
    :sys.replace_state(CapabilityStore, fn state ->
      stale =
        Map.update(state.by_principal, principal, [], fn ids ->
          List.delete(ids, original_id)
        end)

      %{state | by_principal: stale}
    end)

    if acknowledged_available?() do
      opts = det_grant_opts("f1", principal, resource)

      assert {:error, :resource_conflict} = Security.acknowledged_grant(opts)

      # The different capability is never replaced or mutated.
      assert {:ok, %Capability{id: ^original_id, principal_id: ^principal}} =
               CapabilityStore.get(original_id)

      state = :sys.get_state(CapabilityStore)
      same = same_resource_in_by_id(state, principal, resource)
      assert length(same) == 1
      assert hd(same) == original_id
    else
      # Parent: assert the SAME no-replacement invariant. The ordinary path
      # reads the stale by_principal inside existing_capability_id/2, misses the
      # original, and admits a duplicate, so the 'exactly one in by_id'
      # assertion fails behaviorally.
      assert {:ok, _dup} = Security.grant(principal: principal, resource: resource)
      assert {:ok, %Capability{id: ^original_id}} = CapabilityStore.get(original_id)

      state = :sys.get_state(CapabilityStore)
      same = same_resource_in_by_id(state, principal, resource)
      assert length(same) == 1
    end
  end

  # ==========================================================================
  # F2 — authoritative-absent acknowledged revoke purges the exact capability
  # id from by_principal/by_issuer/by_parent/by_usage even when by_id is already
  # absent, without stats/signal/audit.
  # ==========================================================================
  test "security regression: authoritative-absent revoke purges dangling exact-id indexes" do
    fresh_isolated_store()
    dangling_id = det_id("f2")

    # Seed dangling references in every projection index EXCEPT by_id (by_id is
    # already absent), simulating a stale projection after a durable delete.
    :sys.replace_state(CapabilityStore, fn state ->
      %{
        state
        | by_principal:
            Map.update(state.by_principal, "agent_ack_f2", [dangling_id], fn ids ->
              [dangling_id | ids]
            end),
          by_issuer:
            Map.update(state.by_issuer, "issuer_ack_f2", [dangling_id], fn ids ->
              [dangling_id | ids]
            end),
          by_parent:
            Map.update(state.by_parent, "parent_ack_f2", [dangling_id], fn ids ->
              [dangling_id | ids]
            end),
          by_usage: Map.put(state.by_usage, dangling_id, 7)
      }
    end)

    if acknowledged_available?() do
      revoked_before = CapabilityStore.stats().total_revoked

      assert {:ok, :idempotent, ^dangling_id} = Security.acknowledged_revoke(dangling_id)

      # No stat side effect (durable absence is idempotent, not an applied delete).
      assert CapabilityStore.stats().total_revoked == revoked_before

      state = :sys.get_state(CapabilityStore)
      refute Enum.member?(Map.get(state.by_principal, "agent_ack_f2", []), dangling_id)
      refute Enum.member?(Map.get(state.by_issuer, "issuer_ack_f2", []), dangling_id)
      refute Enum.member?(Map.get(state.by_parent, "parent_ack_f2", []), dangling_id)
      refute Map.has_key?(state.by_usage, dangling_id)
      refute Map.has_key?(state.by_id, dangling_id)
    else
      # Parent: ordinary revoke of an absent-by_id id returns :not_found and
      # purges nothing, so the dangling ref survives and this fails.
      assert {:error, :not_found} = Security.revoke(dangling_id)

      state = :sys.get_state(CapabilityStore)
      assert Enum.member?(Map.get(state.by_principal, "agent_ack_f2", []), dangling_id) == false
    end
  end

  # ==========================================================================
  # F3 — admission bounds: omission-vs-presence for constraints/metadata, one
  # shared node budget, signed-64-bit max_uses, valid bounded UTF-8 nested
  # keys/values, nested struct rejection.
  # ==========================================================================
  test "security regression: acknowledged grant bounds constraints/metadata with one shared budget" do
    fresh_isolated_store()
    principal = "agent_ack_f3"
    resource = "arbor://fs/read/ack-f3"
    base = [principal: principal, resource: resource, granted_at: fixed_granted_at()]

    if acknowledged_available?() do
      # Omission of both keys normalizes to %{} and admits.
      assert {:ok, :applied, _} =
               Security.acknowledged_grant(det_grant_opts("f3-omit", principal, resource))

      # A present empty map also admits.
      assert {:ok, :applied, _} =
               Security.acknowledged_grant(
                 det_grant_opts("f3-empty", principal, "arbor://fs/read/ack-f3-empty")
                 |> Keyword.put(:constraints, %{})
               )

      # Explicit nil / list / scalar / struct are INVALID for BOTH fields.
      for field <- [:constraints, :metadata] do
        for {value, suffix} <- [
              {nil, "nil"},
              {[1, 2, 3], "list"},
              {5, "scalar"},
              {"x", "bin"},
              {DateTime.utc_now(), "struct"}
            ] do
          bad =
            Keyword.put(
              base ++ [capability_id: det_id("f3-#{suffix}-#{field}")],
              field,
              value
            )

          assert {:error, :invalid_request} = Security.acknowledged_grant(bad)
        end
      end

      # Datetimes must survive the serializer's UTC restoration byte-for-byte;
      # offset-zone or malformed structs would otherwise durably admit a record
      # whose signature cannot be verified on reobservation.
      noncanonical_datetime = %{
        fixed_granted_at()
        | time_zone: "America/Chicago",
          zone_abbr: "CST",
          utc_offset: -21_600
      }

      malformed_datetime = %{fixed_granted_at() | calendar: :not_a_calendar}

      for {field, value, suffix} <- [
            {:granted_at, noncanonical_datetime, "offset-granted"},
            {:expires_at, noncanonical_datetime, "offset-expires"},
            {:not_before, malformed_datetime, "malformed-not-before"}
          ] do
        bad =
          det_grant_opts("f3-#{suffix}", principal, "arbor://fs/read/ack-f3-#{suffix}")
          |> Keyword.put(field, value)

        assert {:error, :invalid_request} = Security.acknowledged_grant(bad)
      end

      # Atom and string keys canonicalize to the same JSON object key. Reject
      # the ambiguous input before signing rather than relying on map order.
      duplicate_canonical_keys = %{:source => "atom", "source" => "string"}

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 det_grant_opts("f3-duplicate-key", principal, "arbor://fs/read/ack-f3-dup")
                 |> Keyword.put(:metadata, duplicate_canonical_keys)
               )

      # One shared budget spanning constraints + metadata: each nested
      # container alone is under the budget AND within the 64-key / depth-6
      # caps, but the COMBINED node count exceeds @acknowledged_grant_max_nodes.
      big = big_nested_map()

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 base ++
                   [
                     capability_id: det_id("f3-combined"),
                     constraints: big,
                     metadata: big
                   ]
               )

      # Each alone still admits (proves the per-tree caps are not what rejects).
      assert {:ok, :applied, _} =
               Security.acknowledged_grant(
                 det_grant_opts("f3-conly", principal, "arbor://fs/read/ack-f3-conly")
                 |> Keyword.put(:constraints, big)
               )

      assert {:ok, :applied, _} =
               Security.acknowledged_grant(
                 det_grant_opts("f3-monly", principal, "arbor://fs/read/ack-f3-monly")
                 |> Keyword.put(:metadata, big)
               )

      # max_uses is signed-64-bit bounded (1 <= value < 2^63).
      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 det_grant_opts("f3-max", principal, "arbor://fs/read/ack-f3-max")
                 |> Keyword.put(:max_uses, Integer.pow(2, 63))
               )

      assert {:ok, :applied, _} =
               Security.acknowledged_grant(
                 det_grant_opts("f3-maxok", principal, "arbor://fs/read/ack-f3-maxok")
                 |> Keyword.put(:max_uses, Integer.pow(2, 63) - 1)
               )

      # Nested invalid-UTF-8 binary value and key.
      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 base ++
                   [
                     capability_id: det_id("f3-utf8val"),
                     constraints: %{k: <<0xFF>>}
                   ]
               )

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 base ++
                   [
                     capability_id: det_id("f3-utf8key"),
                     constraints: %{<<0xFF>> => "v"}
                   ]
               )

      # Nested non-DateTime struct rejected.
      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 base ++
                   [
                     capability_id: det_id("f3-nestedstruct"),
                     metadata: %{d: ~D[2026-01-01]}
                   ]
               )
    else
      # Parent: ordinary grant does not bound max_uses to signed-64-bit. The
      # candidate invariant (reject 2^63) fails behaviorally here.
      assert {:error, _} =
               Security.grant(
                 principal: principal,
                 resource: resource,
                 max_uses: Integer.pow(2, 63)
               )
    end
  end

  test "security regression: acknowledged grant requires canonical persistence values" do
    fresh_isolated_store()
    principal = "agent_ack_f3b"
    resource = "arbor://fs/read/ack-f3b"

    noncanonical_datetime = %{
      ~U[2030-01-01 00:00:00Z]
      | time_zone: "America/Chicago",
        zone_abbr: "CST",
        utc_offset: -21_600
    }

    malformed_datetime = %{fixed_granted_at() | calendar: :not_a_calendar}
    duplicate_canonical_keys = %{:source => "atom", "source" => "string"}

    if acknowledged_available?() do
      for {field, value, suffix} <- [
            {:granted_at, noncanonical_datetime, "offset-granted"},
            {:expires_at, noncanonical_datetime, "offset-expires"},
            {:not_before, malformed_datetime, "malformed-not-before"}
          ] do
        bad =
          det_grant_opts("f3b-#{suffix}", principal, "arbor://fs/read/ack-f3b-#{suffix}")
          |> Keyword.put(field, value)

        assert {:error, :invalid_request} = Security.acknowledged_grant(bad)
      end

      assert {:error, :invalid_request} =
               Security.acknowledged_grant(
                 det_grant_opts("f3b-duplicate-key", principal, resource)
                 |> Keyword.put(:metadata, duplicate_canonical_keys)
               )
    else
      # Parent ordinary admission accepts both persistence-unstable shapes, so
      # these assertions fail behaviorally before the acknowledged boundary.
      assert {:error, _reason} =
               Security.grant(
                 principal: principal,
                 resource: resource,
                 expires_at: noncanonical_datetime
               )

      assert {:error, _reason} =
               Security.grant(
                 principal: principal,
                 resource: resource,
                 metadata: duplicate_canonical_keys
               )
    end
  end

  # ==========================================================================
  # F4 — count REAL direct store cluster signals and EventLog audit rows.
  # ==========================================================================
  test "security regression: applied acknowledged grant emits one store signal and one audit row" do
    if acknowledged_available?() do
      fresh_isolated_store()
      ensure_event_log()
      ensure_signals_children()

      prev = Application.get_env(:arbor_security, :distributed_signals)
      Application.put_env(:arbor_security, :distributed_signals, true)
      on_exit(fn -> Application.put_env(:arbor_security, :distributed_signals, prev) end)

      principal = "agent_ack_f4g"
      resource = "arbor://fs/read/ack-f4g"
      opts = det_grant_opts("f4g", principal, resource)
      id = opts[:capability_id]

      {ref, sub} = subscribe_store_grant_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      audit_before = count_audit(:capability_granted, id)

      assert {:ok, :applied, ^id} = Security.acknowledged_grant(opts)

      # Idempotent retries emit NO additional signal or audit row.
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)

      grants = collect_signals(ref, :store_grant, 200)
      audit_after = count_audit(:capability_granted, id)

      assert grants == 1
      assert audit_after - audit_before == 1
    end
  end

  test "security regression: applied acknowledged revoke emits one signal/row; absence emits none" do
    if acknowledged_available?() do
      fresh_isolated_store()
      ensure_event_log()
      ensure_signals_children()

      prev = Application.get_env(:arbor_security, :distributed_signals)
      Application.put_env(:arbor_security, :distributed_signals, true)
      on_exit(fn -> Application.put_env(:arbor_security, :distributed_signals, prev) end)

      principal = "agent_ack_f4r"
      resource = "arbor://fs/read/ack-f4r"
      opts = det_grant_opts("f4r", principal, resource)
      id = opts[:capability_id]

      assert {:ok, :applied, ^id} = Security.acknowledged_grant(opts)

      {ref, sub} = subscribe_store_revoke_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      audit_before = count_audit(:capability_revoked, id)

      assert {:ok, :applied, ^id} = Security.acknowledged_revoke(id)

      revokes = collect_signals(ref, :store_revoke, 200)
      audit_after_applied = count_audit(:capability_revoked, id)

      assert revokes == 1
      assert audit_after_applied - audit_before == 1

      # Authoritative-absent revoke is idempotent and emits NO signal/audit.
      unknown_id = det_id("f4r-absent")
      {uref, usub} = subscribe_store_revoke_signal(unknown_id)
      on_exit(fn -> Arbor.Signals.unsubscribe(usub) end)

      absent_audit_before = count_audit(:capability_revoked, unknown_id)

      assert {:ok, :idempotent, ^unknown_id} = Security.acknowledged_revoke(unknown_id)

      absent_revokes = collect_signals(uref, :store_revoke, 200)
      absent_audit_after = count_audit(:capability_revoked, unknown_id)

      assert absent_revokes == 0
      assert absent_audit_after - absent_audit_before == 0
    end
  end

  # ==========================================================================
  # F5a — post-admission timeout/exit returns outcome_unknown; retry converges.
  # ==========================================================================
  test "security regression: post-admission timeout returns outcome_unknown and retry converges" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_f5a"
    resource = "arbor://fs/read/ack-f5a"
    opts = det_grant_opts("f5a", principal, resource)
    id = opts[:capability_id]

    if acknowledged_available?() do
      CASSandbox.fail_post_admission(1)

      assert {:error, :outcome_unknown} = Security.acknowledged_grant(opts)

      # Live unprojected (incoming state retained) but durable admitted.
      assert {:error, :not_found} = CapabilityStore.get(id)
      assert {:ok, %Record{}} = BufferedStore.authoritative_get(id, name: @capability_store)

      # Retry converges idempotently and projects live.
      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
      assert {:ok, %Capability{id: ^id}} = CapabilityStore.get(id)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)
    end
  end

  # ==========================================================================
  # F5b — concurrent mismatched exact-id CAS occupant classified without
  # overwrite.
  # ==========================================================================
  test "security regression: mismatched concurrent exact-id CAS occupant classified without overwrite" do
    fresh_isolated_store_with_failures()
    id = det_id("f5b")

    mismatched =
      build_signed_cap(
        capability_id: id,
        granted_at: fixed_granted_at(),
        principal: "agent_ack_f5b_mismatch",
        resource: "arbor://fs/read/ack-f5b-mismatch"
      )

    if acknowledged_available?() do
      mismatch_record = Record.new(id, Serializer.serialize(mismatched))
      CASSandbox.seed_cas_conflict_mismatch(mismatch_record)

      opts = [
        capability_id: id,
        granted_at: fixed_granted_at(),
        principal: "agent_ack_f5b_grant",
        resource: "arbor://fs/read/ack-f5b"
      ]

      assert {:error, :id_conflict} = Security.acknowledged_grant(opts)

      # Our cap was never projected live.
      assert {:error, :not_found} = CapabilityStore.get(id)

      # The mismatched occupant is durable and NOT overwritten.
      assert {:ok, %Record{} = durable} =
               BufferedStore.authoritative_get(id, name: @capability_store)

      # The backend owns generation/revision/timestamps, so compare the logical
      # record that the conflicting writer admitted. None of our requested
      # capability payload may replace it.
      assert durable.id == mismatch_record.id
      assert durable.key == mismatch_record.key
      assert durable.data == mismatch_record.data
      assert durable.metadata == mismatch_record.metadata

      assert {:ok, %Capability{principal_id: "agent_ack_f5b_mismatch"}} =
               Serializer.deserialize(durable.data)
    end
  end

  # ==========================================================================
  # F5c — a post-admission durable-only capability still occupies its
  # principal/resource; a different deterministic id must not be admitted.
  # ==========================================================================
  test "security regression: durable-only same-resource grant remains a conflict" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_f5c"
    resource = "arbor://fs/read/ack-f5c"
    first = det_grant_opts("f5c-first", principal, resource)
    second = det_grant_opts("f5c-second", principal, resource)

    if acknowledged_available?() do
      CASSandbox.fail_post_admission(1)

      assert {:error, :outcome_unknown} = Security.acknowledged_grant(first)
      assert {:error, :not_found} = CapabilityStore.get(first[:capability_id])

      assert {:ok, %Record{} = first_record} =
               BufferedStore.authoritative_get(first[:capability_id], name: @capability_store)

      assert {:error, :resource_conflict} = Security.acknowledged_grant(second)

      assert {:error, :not_found} =
               BufferedStore.authoritative_get(second[:capability_id], name: @capability_store)

      assert {:ok, ^first_record} =
               BufferedStore.authoritative_get(first[:capability_id], name: @capability_store)

      assert {:ok, :idempotent, first_id} = Security.acknowledged_grant(first)
      assert first_id == first[:capability_id]
      assert {:ok, %Capability{id: ^first_id}} = CapabilityStore.get(first_id)
    else
      assert {:ok, original} = Security.grant(principal: principal, resource: resource)
      assert {:ok, replacement} = Security.grant(principal: principal, resource: resource)
      assert replacement.id == original.id
    end
  end

  # ==========================================================================
  # F5d — exact identity is defined by the signed canonical payload, not raw
  # map-key representation after a persistence round trip.
  # ==========================================================================
  test "security regression: exact identity repair tolerates normalized map keys" do
    fresh_isolated_store()
    principal = "agent_ack_f5d"
    resource = "arbor://fs/read/ack-f5d"

    opts =
      det_grant_opts("f5d", principal, resource)
      |> Keyword.put(:metadata, %{source: "template_authority_policy"})

    if acknowledged_available?() do
      seeded = build_signed_cap(opts)
      assert {:ok, :stored} = CapabilityStore.put(seeded)
      :ok = BufferedStore.acknowledged_delete(opts[:capability_id], name: @capability_store)

      # JSON persistence normalizes object keys to strings. The signature and
      # grant identity remain exact because the canonical payload stringifies
      # keys before signing.
      normalized = %{seeded | metadata: %{"source" => "template_authority_policy"}}
      assert :ok = SystemAuthority.verify_authority_capability_signature(normalized)

      :sys.replace_state(CapabilityStore, fn state ->
        put_in(state, [:by_id, seeded.id], normalized)
      end)

      assert {:ok, :idempotent, id} = Security.acknowledged_grant(opts)
      assert id == seeded.id
      assert {:ok, %Capability{id: ^id}} = CapabilityStore.get(id)
      assert {:ok, %Record{}} = BufferedStore.authoritative_get(id, name: @capability_store)
    else
      assert {:ok, original} = Security.grant(principal: principal, resource: resource)
      assert {:ok, replacement} = Security.grant(principal: principal, resource: resource)
      assert replacement.id == original.id
    end
  end

  # ==========================================================================
  # C1 — acknowledged admission never scans the full live or authoritative
  # inventory (canonical by_resource index + bounded ledger). Size-independent.
  # ==========================================================================
  test "security regression: acknowledged grant admits without any full inventory scan" do
    fresh_isolated_store()

    for i <- 1..12 do
      assert {:ok, _} =
               Security.grant(
                 principal: "agent_unrelated_c1_#{i}",
                 resource: "arbor://fs/read/unrelated-c1-#{i}"
               )
    end

    principal = "agent_ack_c1"
    resource = "arbor://fs/read/ack-c1"
    opts = det_grant_opts("c1", principal, resource)

    if acknowledged_available?() do
      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :applied, _id} = Security.acknowledged_grant(opts)
      assert CASSandbox.inventory_scan_count() == 0

      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :idempotent, _id} = Security.acknowledged_grant(opts)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # C2 — the canonical by_resource index is maintained on every mutation path
  # so a stale by_principal cannot hide a same-resource conflict, with zero
  # full-inventory scans.
  # ==========================================================================
  test "security regression: by_resource maintenance detects conflicts without scanning" do
    fresh_isolated_store()
    principal = "agent_ack_c2"
    resource = "arbor://fs/read/ack-c2"

    if acknowledged_available?() do
      a = det_grant_opts("c2-a", principal, resource)
      b = det_grant_opts("c2-b", principal, resource)

      assert {:ok, :applied, _} = Security.acknowledged_grant(a)

      CASSandbox.reset_inventory_scan_count()
      assert {:error, :resource_conflict} = Security.acknowledged_grant(b)
      assert CASSandbox.inventory_scan_count() == 0

      assert :ok = Security.revoke(a[:capability_id])

      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :applied, _} = Security.acknowledged_grant(b)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  test "security regression: cascade revoke frees the canonical resource index" do
    fresh_isolated_store()
    principal = "agent_ack_c2c"
    resource = "arbor://fs/read/ack-c2c"

    if acknowledged_available?() do
      a = det_grant_opts("c2c-a", principal, resource)
      b = det_grant_opts("c2c-b", principal, resource)

      assert {:ok, :applied, _} = Security.acknowledged_grant(a)
      assert {:ok, _count} = CapabilityStore.cascade_revoke(a[:capability_id])

      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :applied, _} = Security.acknowledged_grant(b)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  test "security regression: acknowledged revoke frees the canonical resource index" do
    fresh_isolated_store()
    principal = "agent_ack_c2r"
    resource = "arbor://fs/read/ack-c2r"

    if acknowledged_available?() do
      a = det_grant_opts("c2r-a", principal, resource)
      b = det_grant_opts("c2r-b", principal, resource)

      assert {:ok, :applied, aid} = Security.acknowledged_grant(a)
      assert {:ok, :applied, ^aid} = Security.acknowledged_revoke(aid)

      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :applied, _} = Security.acknowledged_grant(b)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  test "security regression: expiry frees the canonical resource index" do
    fresh_isolated_store()
    principal = "agent_ack_c2e"
    resource = "arbor://fs/read/ack-c2e"

    if acknowledged_available?() do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      a = det_grant_opts("c2e-a", principal, resource, expires_at: past)
      b = det_grant_opts("c2e-b", principal, resource)

      assert {:ok, :applied, _} = Security.acknowledged_grant(a)
      send(CapabilityStore, :cleanup)
      _ = :sys.get_state(CapabilityStore)

      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :applied, _} = Security.acknowledged_grant(b)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # C3 — post-admission ambiguous grant retains a bounded ledger intent; a
  # different id conflicts and an exact retry converges, both without scanning.
  # ==========================================================================
  test "security regression: post-admission alternate-id conflict is ledger-driven without scanning" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_c3"
    resource = "arbor://fs/read/ack-c3"
    first = det_grant_opts("c3-first", principal, resource)
    second = det_grant_opts("c3-second", principal, resource)

    if acknowledged_available?() do
      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(first)

      CASSandbox.reset_inventory_scan_count()
      assert {:error, :resource_conflict} = Security.acknowledged_grant(second)
      assert CASSandbox.inventory_scan_count() == 0

      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :idempotent, fid} = Security.acknowledged_grant(first)
      assert CASSandbox.inventory_scan_count() == 0
      assert {:ok, %Capability{id: ^fid}} = CapabilityStore.get(fid)
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # C3A — an outcome-unknown admission intent survives a mismatched same-id
  # retry (byte-for-byte) and keeps blocking an alternate id for the same
  # principal/resource. Council finding: exact-ID uncertainty intent
  # replacement.
  # ==========================================================================
  test "security regression: outcome-unknown intent survives a mismatched same-id retry and keeps blocking an alternate id" do
    fresh_isolated_store_with_failures()
    principal = "agent_ack_c3a"
    r1 = "arbor://fs/read/ack-c3a-r1"
    r2 = "arbor://fs/read/ack-c3a-r2"

    # X/R1: deterministic id x_id, principal, resource r1.
    first = det_grant_opts("c3a-x", principal, r1)
    x_id = first[:capability_id]

    # X/R2: SAME deterministic id x_id (same seed), DIFFERENT resource r2 — a
    # mismatched same-id retry whose canonical signed identity differs.
    mismatched = det_grant_opts("c3a-x", principal, r2)

    # X/R1': same id AND resource, but a different signed field. This proves
    # intent identity is the full canonical signing payload, not only the
    # principal/resource occupancy key.
    same_resource_mismatched =
      det_grant_opts("c3a-x", principal, r1, metadata: %{"variant" => "different"})

    # Y/R1: a different deterministic id, same principal + resource r1.
    alternate = det_grant_opts("c3a-y", principal, r1)
    y_id = alternate[:capability_id]

    if acknowledged_available?() do
      first_signed = build_signed_cap(first)
      first_payload = Capability.signing_payload(first_signed)

      # 1. X/R1 outcome-unknown: durable admission committed, reobserve crashed.
      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(first)

      # Live unprojected; durable admitted.
      assert {:error, :not_found} = CapabilityStore.get(x_id)

      assert {:ok, %Record{} = first_record} =
               BufferedStore.authoritative_get(x_id, name: @capability_store)

      # The retained uncertainty intent is identity-safe: canonical
      # principal/resource key plus the exact signed grant payload. On the
      # unfixed base the intent is a {principal, resource} pair with no payload.
      state_after_unknown = :sys.get_state(CapabilityStore)
      intent_after_unknown = Map.get(state_after_unknown.pending_intents, x_id)
      assert intent_after_unknown != nil
      assert tuple_size(intent_after_unknown) == 3
      {^principal, _r1_canon, ^first_payload} = intent_after_unknown

      # 2. Even when principal/resource are unchanged, a different signed field
      # is a distinct grant and cannot replace or clear the uncertainty lock.
      assert {:error, :id_conflict} = Security.acknowledged_grant(same_resource_mismatched)

      assert Map.get(:sys.get_state(CapabilityStore).pending_intents, x_id) ==
               intent_after_unknown

      assert {:ok, ^first_record} =
               BufferedStore.authoritative_get(x_id, name: @capability_store)

      # A different-resource same-id retry is rejected on the same full-identity
      # rule, also without touching durable state or entering the finalizer.
      assert {:error, :id_conflict} = Security.acknowledged_grant(mismatched)

      assert {:error, :not_found} = CapabilityStore.get(x_id)

      assert {:ok, ^first_record} =
               BufferedStore.authoritative_get(x_id, name: @capability_store)

      # Prior pending intent is byte-for-byte intact (never re-armed/finalized).
      state_after_mismatch = :sys.get_state(CapabilityStore)
      assert Map.get(state_after_mismatch.pending_intents, x_id) == intent_after_unknown

      # 3. Alternate Y/R1 is still blocked by the surviving X/R1 occupancy and
      # is never admitted.
      assert {:error, :resource_conflict} = Security.acknowledged_grant(alternate)

      assert {:error, :not_found} = CapabilityStore.get(y_id)

      assert {:error, :not_found} =
               BufferedStore.authoritative_get(y_id, name: @capability_store)

      assert {:ok, ^first_record} =
               BufferedStore.authoritative_get(x_id, name: @capability_store)

      # 4. The original X/R1 still converges on an exact retry, no inventory scan.
      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :idempotent, ^x_id} = Security.acknowledged_grant(first)
      assert CASSandbox.inventory_scan_count() == 0
      assert {:ok, %Capability{id: ^x_id}} = CapabilityStore.get(x_id)
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: r1)
    end
  end

  # ==========================================================================
  # C4 — the uncertainty ledger is bounded by the per-principal/global quotas
  # and fails closed at capacity (no scan, no over-admission).
  # ==========================================================================
  test "security regression: bounded uncertainty ledger fails closed at capacity" do
    fresh_isolated_store_with_failures()

    prev_per = Application.get_env(:arbor_security, :max_capabilities_per_agent)
    Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)

    on_exit(fn ->
      Application.put_env(:arbor_security, :max_capabilities_per_agent, prev_per)
    end)

    principal = "agent_ack_c4"

    if acknowledged_available?() do
      o1 = det_grant_opts("c4-1", principal, "arbor://fs/read/ack-c4-r1")
      o2 = det_grant_opts("c4-2", principal, "arbor://fs/read/ack-c4-r2")
      o3 = det_grant_opts("c4-3", principal, "arbor://fs/read/ack-c4-r3")

      assert {:ok, :applied, _} = Security.acknowledged_grant(o1)

      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(o2)

      CASSandbox.reset_inventory_scan_count()
      assert {:error, :quota_exceeded} = Security.acknowledged_grant(o3)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: "arbor://fs/read/ack-c4")
    end
  end

  # ==========================================================================
  # C4b — repeated post-admission :outcome_unknown intents stay bounded even
  # when ordinary quota_enforcement is disabled (pending-only ceiling).
  # ==========================================================================
  test "security regression: uncertainty ledger stays bounded when quota_enforcement is disabled" do
    fresh_isolated_store_with_failures()

    prev_enforcement = Application.get_env(:arbor_security, :quota_enforcement_enabled)
    prev_per = Application.get_env(:arbor_security, :max_capabilities_per_agent)

    Application.put_env(:arbor_security, :quota_enforcement_enabled, false)
    Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)

    on_exit(fn ->
      restore_application_env(:quota_enforcement_enabled, prev_enforcement)
      restore_application_env(:max_capabilities_per_agent, prev_per)
    end)

    principal = "agent_ack_c4b"

    if acknowledged_available?() do
      o1 = det_grant_opts("c4b-1", principal, "arbor://fs/read/ack-c4b-r1")
      o2 = det_grant_opts("c4b-2", principal, "arbor://fs/read/ack-c4b-r2")
      o3 = det_grant_opts("c4b-3", principal, "arbor://fs/read/ack-c4b-r3")

      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(o1)

      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(o2)

      CASSandbox.reset_inventory_scan_count()
      assert {:error, :quota_exceeded} = Security.acknowledged_grant(o3)
      assert CASSandbox.inventory_scan_count() == 0

      # Ordinary grant remains open under disabled enforcement (no live quota
      # smuggled into definitive ordinary operation semantics).
      assert {:ok, _} =
               Security.grant(
                 principal: "agent_ack_c4b_ordinary",
                 resource: "arbor://fs/read/ack-c4b-ordinary"
               )
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: "arbor://fs/read/ack-c4b")
    end
  end

  # ==========================================================================
  # C4c — structural proof: uncertainty admission helpers never Enum-walk the
  # full live by_id map (companion to durable Store.list inventory probe).
  # ==========================================================================
  test "security regression: uncertainty admission helpers do not enumerate full live by_id" do
    source =
      Path.expand("../../../lib/arbor/security/capability_store.ex", __DIR__)
      |> File.read!()

    # Tight window: uncertainty ledger helpers only (arm through finalize).
    # Exclude cleanup/restore paths that legitimately walk by_id.
    start_marker = "# Bounded uncertainty ledger (pending_intents)."
    end_marker = "defp decode_and_verify_capability("

    start_at = :binary.match(source, start_marker)
    end_at = :binary.match(source, end_marker)

    assert is_tuple(start_at)
    assert is_tuple(end_at)

    {start_idx, _} = start_at
    {end_idx, _} = end_at
    assert end_idx > start_idx

    window = binary_part(source, start_idx, end_idx - start_idx)

    refute window =~ "Enum.count(state.by_id"
    refute window =~ "Enum.filter(state.by_id"
    refute window =~ "Enum.reduce(state.by_id"
    refute window =~ "for {_id, _} <- state.by_id"
    refute window =~ "for {_, _} <- state.by_id"

    # Public behavioral companion: acknowledged admission still avoids durable
    # inventory scans (existing CASSandbox list probe).
    fresh_isolated_store()
    principal = "agent_ack_c4c"
    resource = "arbor://fs/read/ack-c4c"
    opts = det_grant_opts("c4c", principal, resource)

    if acknowledged_available?() do
      CASSandbox.reset_inventory_scan_count()
      assert {:ok, :applied, _} = Security.acknowledged_grant(opts)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # C4d — remote projection occupies by_resource and blocks a different
  # acknowledged id for the same principal/resource without inventory scan.
  # Coverage of existing distributed wiring (not a claimed base-red defect).
  # ==========================================================================
  test "security regression: remote projection occupies by_resource and blocks alternate acknowledged id without inventory scan" do
    fresh_isolated_store()
    principal = "agent_ack_c4d"
    resource = "arbor://fs/read/ack-c4d"
    remote_opts = det_grant_opts("c4d-remote", principal, resource)
    local_opts = det_grant_opts("c4d-local", principal, resource)
    remote_id = remote_opts[:capability_id]

    if acknowledged_available?() do
      remote_cap = build_signed_cap(remote_opts)

      assert {:ok, %Record{}} =
               BufferedStore.acknowledged_put(
                 remote_id,
                 Record.new(remote_id, Serializer.serialize(remote_cap)),
                 name: @capability_store
               )

      # Deliver a remote-origin capability_granted signal so the store loads
      # the durable record and projects it through add_capability_to_indexes
      # (which maintains by_resource).
      send(
        CapabilityStore,
        {:signal_received,
         %{
           type: :capability_granted,
           data: %{
             capability_id: remote_id,
             origin_node: :remote@c4d_projection
           }
         }}
      )

      # Linearize on the store mailbox so the projection is applied.
      _ = :sys.get_state(CapabilityStore)

      assert {:ok, %Capability{id: ^remote_id}} = CapabilityStore.get(remote_id)

      state = :sys.get_state(CapabilityStore)

      # Canonical form may differ from the raw URI; find the bucket that
      # contains the remotely projected id for this principal.
      occupied_key =
        Enum.find_value(state.by_resource, fn
          {{^principal, uri}, ids} ->
            if MapSet.member?(ids, remote_id), do: {principal, uri}

          _ ->
            nil
        end)

      assert occupied_key != nil
      assert MapSet.member?(Map.fetch!(state.by_resource, occupied_key), remote_id)

      CASSandbox.reset_inventory_scan_count()
      assert {:error, :resource_conflict} = Security.acknowledged_grant(local_opts)
      assert CASSandbox.inventory_scan_count() == 0

      assert {:ok, %Capability{id: ^remote_id}} = CapabilityStore.get(remote_id)
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # C5 — signed_at is pinned deterministically to granted_at before signing and
  # stays identity-exact across delayed retries.
  # ==========================================================================
  test "security regression: signed_at is pinned to granted_at and stays exact across retries" do
    fresh_isolated_store()
    principal = "agent_ack_c5"
    resource = "arbor://fs/read/ack-c5"
    opts = det_grant_opts("c5", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, id} = Security.acknowledged_grant(opts)
      assert {:ok, %Capability{} = cap1} = CapabilityStore.get(id)
      assert cap1.signed_at == cap1.granted_at
      assert cap1.signed_at == opts[:granted_at]
      payload1 = Capability.signing_payload(cap1)

      Process.sleep(10)

      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
      assert {:ok, %Capability{} = cap2} = CapabilityStore.get(id)
      assert cap2.signed_at == cap2.granted_at
      assert Capability.signing_payload(cap2) == payload1
    else
      assert {:ok, cap} = Security.grant(principal: principal, resource: resource)
      assert cap.signed_at == cap.granted_at
    end
  end

  # ==========================================================================
  # C6 — durable-only grant convergence that newly projects into live emits
  # exactly one restricted cluster signal; a true replay emits none.
  # ==========================================================================
  test "security regression: idempotent grant convergence emits one signal, replay emits none" do
    if acknowledged_available?() do
      fresh_isolated_store_with_failures()
      ensure_signals_children()

      prev = Application.get_env(:arbor_security, :distributed_signals)
      Application.put_env(:arbor_security, :distributed_signals, true)
      on_exit(fn -> Application.put_env(:arbor_security, :distributed_signals, prev) end)

      principal = "agent_ack_c6"
      resource = "arbor://fs/read/ack-c6"
      opts = det_grant_opts("c6", principal, resource)
      id = opts[:capability_id]

      {ref, sub} = subscribe_store_grant_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      CASSandbox.fail_post_admission(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_grant(opts)

      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
      assert collect_signals(ref, :store_grant, 200) == 1

      assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
      assert collect_signals(ref, :store_grant, 200) == 0
    else
      fresh_isolated_store()

      assert {:ok, _} =
               Security.grant(principal: "agent_ack_c6", resource: "arbor://fs/read/ack-c6")
    end
  end

  # ==========================================================================
  # C7 — durable-only revoke convergence that newly evicts live emits exactly
  # one restricted cluster signal; a true replay emits none.
  # ==========================================================================
  test "security regression: idempotent revoke convergence emits one signal, replay emits none" do
    if acknowledged_available?() do
      fresh_isolated_store_with_failures()
      ensure_signals_children()

      prev = Application.get_env(:arbor_security, :distributed_signals)
      Application.put_env(:arbor_security, :distributed_signals, true)
      on_exit(fn -> Application.put_env(:arbor_security, :distributed_signals, prev) end)

      principal = "agent_ack_c7"
      resource = "arbor://fs/read/ack-c7"
      opts = det_grant_opts("c7", principal, resource)
      id = opts[:capability_id]

      assert {:ok, :applied, ^id} = Security.acknowledged_grant(opts)

      {ref, sub} = subscribe_store_revoke_signal(id)
      on_exit(fn -> Arbor.Signals.unsubscribe(sub) end)

      CASSandbox.fail_post_delete(1)
      assert {:error, :outcome_unknown} = Security.acknowledged_revoke(id)

      assert {:ok, :idempotent, ^id} = Security.acknowledged_revoke(id)
      assert collect_signals(ref, :store_revoke, 200) == 1

      assert {:ok, :idempotent, ^id} = Security.acknowledged_revoke(id)
      assert collect_signals(ref, :store_revoke, 200) == 0
    else
      fresh_isolated_store()

      assert {:ok, _} =
               Security.grant(principal: "agent_ack_c7", resource: "arbor://fs/read/ack-c7")
    end
  end

  # ==========================================================================
  # C8 — a CapabilityStore restart rebuilds the canonical by_resource occupancy
  # from the complete restored durable projection, so a post-restart same-
  # resource grant conflicts without any full-inventory scan. (The CASSandbox
  # backend + BufferedStore stay alive across the restart; only CapabilityStore
  # is restarted, so restore reads the retained durable set.)
  # ==========================================================================
  test "security regression: restart rebuilds by_resource occupancy without scanning" do
    fresh_isolated_store()
    principal = "agent_ack_c8"
    resource = "arbor://fs/read/ack-c8"
    a = det_grant_opts("c8-a", principal, resource)
    b = det_grant_opts("c8-b", principal, resource)

    if acknowledged_available?() do
      assert {:ok, :applied, aid} = Security.acknowledged_grant(a)
      assert {:ok, %Capability{id: ^aid}} = CapabilityStore.get(aid)

      # Restart rebuilds by_id + by_resource from the restored durable set
      # (pending_intents is in-memory only and stays empty after restart).
      restart_capability_store()
      assert {:ok, %Capability{id: ^aid}} = CapabilityStore.get(aid)

      CASSandbox.reset_inventory_scan_count()
      assert {:error, :resource_conflict} = Security.acknowledged_grant(b)
      assert CASSandbox.inventory_scan_count() == 0
    else
      assert {:ok, _} = Security.grant(principal: principal, resource: resource)
    end
  end

  # ==========================================================================
  # State-shape upgrade regressions (Phase 4C C3A) — a pre-C3A live state
  # (one whose code was development-reloaded without an OTP upgrade, so it
  # lacks by_resource / pending_intents / state_version) must survive the next
  # callback without KeyError or lost authority.
  # ==========================================================================

  test "security regression: pre-C3A live state processes ordinary grant and revoke after hot reload without crash" do
    fresh_isolated_store()

    principal = "agent_upgrade_g1"
    resource_a = "arbor://fs/read/upgrade-g1-a"
    resource_b = "arbor://fs/read/upgrade-g1-b"

    assert {:ok, %Capability{id: a_id}} =
             Security.grant(principal: principal, resource: resource_a)

    simulate_pre_c3a_state()

    assert {:ok, %Capability{}} = Security.grant(principal: principal, resource: resource_b)
    assert :ok = Security.revoke(a_id)

    assert Process.whereis(CapabilityStore) != nil
    assert {:error, :not_found} = CapabilityStore.get(a_id)
  end

  test "security regression: pre-C3A live state blocks a different-id acknowledged grant after hot reload" do
    fresh_isolated_store()

    principal = "agent_upgrade_g2"
    resource = "arbor://fs/read/upgrade-g2"

    assert {:ok, original} = Security.grant(principal: principal, resource: resource)
    original_id = original.id

    simulate_pre_c3a_state()

    opts = det_grant_opts("upgrade-g2-other", principal, resource)

    assert {:error, :resource_conflict} = Security.acknowledged_grant(opts)
    assert {:ok, %Capability{id: ^original_id}} = CapabilityStore.get(original_id)
  end

  test "security regression: pre-C3A live state processes acknowledged revoke after hot reload without lost authority" do
    fresh_isolated_store()

    principal = "agent_upgrade_g3"

    assert {:ok, %Capability{id: keep_id}} =
             Security.grant(principal: principal, resource: "arbor://fs/read/upgrade-g3-keep")

    unknown_id = det_id("upgrade-g3-unknown")

    simulate_pre_c3a_state()

    assert {:ok, :idempotent, ^unknown_id} = Security.acknowledged_revoke(unknown_id)

    assert Process.whereis(CapabilityStore) != nil
    assert {:ok, %Capability{id: ^keep_id}} = CapabilityStore.get(keep_id)
  end

  test "security regression: pre-C3A live state processes expiry cleanup after hot reload" do
    fresh_isolated_store()

    principal = "agent_upgrade_g4"
    resource = "arbor://fs/read/upgrade-g4-exp"
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {:ok, %Capability{id: keep_id}} =
             Security.grant(principal: principal, resource: "arbor://fs/read/upgrade-g4-keep")

    assert {:ok, expiring} =
             Capability.new(
               principal_id: principal,
               resource_uri: resource,
               expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
             )

    expired = %{expiring | expires_at: past}
    exp_id = expired.id
    assert {:ok, :stored} = CapabilityStore.put(expired)

    simulate_pre_c3a_state()

    send(CapabilityStore, :cleanup)
    _ = :sys.get_state(CapabilityStore)

    assert Process.whereis(CapabilityStore) != nil
    assert {:error, :not_found} = CapabilityStore.get(exp_id)
    assert {:ok, %Capability{id: ^keep_id}} = CapabilityStore.get(keep_id)
  end

  test "security regression: pre-C3A live state projects a real remote add and revoke signal after hot reload" do
    fresh_isolated_store()

    principal = "agent_upgrade_g5"
    resource = "arbor://fs/read/upgrade-g5"
    remote_opts = det_grant_opts("upgrade-g5-remote", principal, resource)
    remote_id = remote_opts[:capability_id]
    remote_cap = build_signed_cap(remote_opts)

    assert {:ok, %Record{}} =
             BufferedStore.acknowledged_put(
               remote_id,
               Record.new(remote_id, Serializer.serialize(remote_cap)),
               name: @capability_store
             )

    simulate_pre_c3a_state()

    add_signal =
      Arbor.Signals.Signal.new(
        :security,
        :capability_granted,
        %{
          capability_id: remote_id,
          principal_id: principal,
          resource_uri: resource,
          origin_node: :"remote@upgrade-g5"
        },
        scope: :cluster
      )

    send(CapabilityStore, {:signal_received, add_signal})
    _ = :sys.get_state(CapabilityStore)

    assert {:ok, %Capability{id: ^remote_id}} = CapabilityStore.get(remote_id)

    assert resource_index_holds?(
             :sys.get_state(CapabilityStore).by_resource,
             principal,
             resource,
             remote_id
           )

    revoke_signal =
      Arbor.Signals.Signal.new(
        :security,
        :capability_revoked,
        %{
          capability_ids: [remote_id],
          principal_id: principal,
          origin_node: :"remote@upgrade-g5"
        },
        scope: :cluster
      )

    send(CapabilityStore, {:signal_received, revoke_signal})
    _ = :sys.get_state(CapabilityStore)

    assert {:error, :not_found} = CapabilityStore.get(remote_id)

    refute resource_index_holds?(
             :sys.get_state(CapabilityStore).by_resource,
             principal,
             resource,
             remote_id
           )
  end

  test "security regression: code_change normalizes pre-C3A state to the lazy shape and is idempotent" do
    fresh_isolated_store()

    principal = "agent_upgrade_cc"
    resource = "arbor://fs/read/upgrade-cc"

    assert {:ok, %Capability{id: cap_id}} =
             Security.grant(principal: principal, resource: resource)

    simulate_pre_c3a_state()

    change_capability_store_code()

    state = :sys.get_state(CapabilityStore)
    assert state.state_version == 1
    assert resource_index_holds?(state.by_resource, principal, resource, cap_id)
    assert state.pending_intents == %{}

    assert {:error, :resource_conflict} =
             Security.acknowledged_grant(det_grant_opts("upgrade-cc-other", principal, resource))

    snapshot = :sys.get_state(CapabilityStore)
    change_capability_store_code()
    assert :sys.get_state(CapabilityStore) == snapshot
  end

  test "security regression: opaque legacy two-field intent blocks an alternate id and rejects a same-id retry without durable mutation" do
    fresh_isolated_store()

    principal = "agent_upgrade_t7"
    resource = "arbor://fs/read/upgrade-t7"
    canon = canonical_resource_for(resource)

    x_opts = det_grant_opts("upgrade-t7-x", principal, resource)
    x_id = x_opts[:capability_id]
    y_opts = det_grant_opts("upgrade-t7-y", principal, resource)
    y_id = y_opts[:capability_id]

    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, %{x_id => {principal, canon}})
      |> Map.delete(:state_version)
    end)

    CASSandbox.reset_inventory_scan_count()
    assert {:error, :resource_conflict} = Security.acknowledged_grant(y_opts)
    assert CASSandbox.inventory_scan_count() == 0

    assert {:error, :id_conflict} = Security.acknowledged_grant(x_opts)

    intent = Map.get(:sys.get_state(CapabilityStore).pending_intents, x_id)
    assert intent == {principal, canon, :legacy_uncertain_identity}

    assert {:ok, durable_ids} = BufferedStore.authoritative_list(name: @capability_store)
    refute x_id in durable_ids
    refute y_id in durable_ids
  end

  test "security regression: an exact live capability upgrades a matching legacy intent and converges idempotently" do
    fresh_isolated_store()

    principal = "agent_upgrade_t8"
    resource = "arbor://fs/read/upgrade-t8"
    canon = canonical_resource_for(resource)
    opts = det_grant_opts("upgrade-t8", principal, resource)
    cap_id = opts[:capability_id]

    seeded = build_signed_cap(opts)
    assert {:ok, :stored} = CapabilityStore.put(seeded)

    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, %{cap_id => {principal, canon}})
      |> Map.delete(:state_version)
    end)

    assert {:ok, :idempotent, ^cap_id} = Security.acknowledged_grant(opts)

    refute Map.has_key?(:sys.get_state(CapabilityStore).pending_intents, cap_id)
    assert {:ok, %Capability{id: ^cap_id}} = CapabilityStore.get(cap_id)
  end

  test "security regression: malformed non-map pending_intents fails closed" do
    fresh_isolated_store()

    principal = "agent_upgrade_m1"
    opts = det_grant_opts("upgrade-m1", principal, "arbor://fs/read/upgrade-m1")

    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, "not-a-map")
      |> Map.delete(:state_version)
    end)

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(opts) end)
  end

  test "security regression: malformed pending_intent entry shape fails closed" do
    fresh_isolated_store()

    principal = "agent_upgrade_m2"
    opts = det_grant_opts("upgrade-m2", principal, "arbor://fs/read/upgrade-m2")
    bad_id = det_id("upgrade-m2-bad")

    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, %{bad_id => {:nope}})
      |> Map.delete(:state_version)
    end)

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(opts) end)
  end

  test "security regression: malformed by_id value fails closed" do
    fresh_isolated_store()

    principal = "agent_upgrade_m3"
    opts = det_grant_opts("upgrade-m3", principal, "arbor://fs/read/upgrade-m3")

    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:by_id, %{"cap_bad" => "not-a-capability"})
      |> Map.delete(:state_version)
    end)

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(opts) end)
  end

  test "security regression: unsupported future state version fails closed" do
    fresh_isolated_store()

    principal = "agent_upgrade_v"
    opts = det_grant_opts("upgrade-v", principal, "arbor://fs/read/upgrade-v")

    :sys.replace_state(CapabilityStore, fn state -> %{state | state_version: 2} end)

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(opts) end)
  end

  test "security regression: present :missing pending_intents value fails closed" do
    fresh_isolated_store()

    principal = "agent_upgrade_missing_sentinel"

    opts =
      det_grant_opts(
        "upgrade-missing-sentinel",
        principal,
        "arbor://fs/read/upgrade-missing-sentinel"
      )

    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, :missing)
      |> Map.delete(:state_version)
    end)

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(opts) end)
  end

  # ==========================================================================
  # Phase 4C C3A upgrade-safety certification regressions. A current-v1 state
  # reached at an upgrade/reload boundary is accepted only after authoritative
  # deep validation; certified steady callbacks stay O(1). A present nil or any
  # unsupported state_version fails closed with one fixed bounded reason that
  # never embeds observed state data.
  # ==========================================================================

  test "security regression: deep validation rejects a malformed current by_resource index" do
    fresh_isolated_store()

    assert {:ok, %Capability{}} =
             Security.grant(
               principal: "agent_ack_dv_byres_seed",
               resource: "arbor://fs/read/ack-dv-byres-seed"
             )

    # Corrupt the canonical by_resource projection (empty it) while keeping a
    # valid by_id and a current state_version. Drop the private certificate so
    # the state is UNCERTIFIED and the next callback must deep-validate once.
    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:by_resource, %{})
      |> Map.delete(:__c3a_cert__)
    end)

    # Unrelated grant so the parent (no deep validation) admits it and the deny
    # assertion fails for the intended reason.
    unrelated =
      det_grant_opts(
        "dv-byres-other",
        "agent_ack_dv_byres_other",
        "arbor://fs/read/ack-dv-byres-other"
      )

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(unrelated) end)
  end

  test "security regression: deep validation rejects a malformed current pending intent" do
    fresh_isolated_store()

    principal = "agent_ack_dv_curpi"
    canon = canonical_resource_for("arbor://fs/read/ack-dv-curpi-x")
    bad_id = det_id("dv-curpi-bad")

    # A current-v1 state carrying a pending intent with a malformed payload
    # (not binary, not the legacy sentinel). Drop the certificate so the next
    # callback deep-validates once.
    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, %{bad_id => {principal, canon, %{bad: :payload}}})
      |> Map.delete(:__c3a_cert__)
    end)

    # Unrelated resource/principal so the parent admits (no conflict with the
    # bad intent) and the deny assertion fails for the intended reason.
    unrelated =
      det_grant_opts(
        "dv-curpi-other",
        "agent_ack_dv_curpi_other",
        "arbor://fs/read/ack-dv-curpi-other"
      )

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(unrelated) end)
  end

  test "security regression: legacy migration rejects a malformed three-field intent" do
    fresh_isolated_store()

    principal = "agent_ack_dv_legacy3"
    canon = canonical_resource_for("arbor://fs/read/ack-dv-legacy3-x")
    bad_id = det_id("dv-legacy3-bad")

    # A pre-v1 state (state_version absent) carrying a three-field intent with
    # a malformed payload. Base migration keeps {p, r, _} whenever p, r are
    # binaries; the fix deep-validates the migrated output and rejects it.
    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.put(:pending_intents, %{bad_id => {principal, canon, %{bad: :payload}}})
      |> Map.delete(:state_version)
    end)

    unrelated =
      det_grant_opts(
        "dv-legacy3-other",
        "agent_ack_dv_legacy3_other",
        "arbor://fs/read/ack-dv-legacy3-other"
      )

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(unrelated) end)
  end

  test "security regression: explicit nil state_version denies before mutation" do
    fresh_isolated_store()

    opts = det_grant_opts("dv-nil", "agent_ack_dv_nil", "arbor://fs/read/ack-dv-nil")

    :sys.replace_state(CapabilityStore, fn state -> %{state | state_version: nil} end)

    assert_store_denies_and_restarts(fn -> Security.acknowledged_grant(opts) end)

    # No mutation occurred: the grant id was never durably admitted.
    assert {:error, :not_found} =
             BufferedStore.authoritative_get(opts[:capability_id], name: @capability_store)
  end

  # Pure-OTP regressions: exercise code_change/3 directly with crafted states
  # (no live process, no setup). code_change always forces deep validation of a
  # current-v1 state regardless of any certificate.

  test "pure OTP regression: code_change deep-validates a current state" do
    valid = minimal_valid_current_state()

    assert {:ok, certified} = CapabilityStore.code_change(0, valid, [])
    assert certified.state_version == 1

    {cap_id, %Capability{} = cap} = valid |> Map.get(:by_id) |> Enum.at(0)

    # by_resource does not equal the canonical rebuild from by_id.
    assert {:error, _} =
             CapabilityStore.code_change(0, %{valid | by_resource: %{}}, [])

    # by_id key != value.id (identity mismatch).
    assert {:error, _} =
             CapabilityStore.code_change(0, %{valid | by_id: %{("wrong_" <> cap_id) => cap}}, [])

    # by_id field non-binary (principal_id not a binary), key still == id.
    assert {:error, _} =
             CapabilityStore.code_change(
               0,
               %{valid | by_id: %{cap_id => %Capability{cap | principal_id: 123}}},
               []
             )

    # by_id ids and resource URIs must also be binary before canonical indexing.
    assert {:error, _} =
             CapabilityStore.code_change(
               0,
               %{valid | by_id: %{123 => %Capability{cap | id: 123}}},
               []
             )

    assert {:error, _} =
             CapabilityStore.code_change(
               0,
               %{valid | by_id: %{cap_id => %Capability{cap | resource_uri: 123}}},
               []
             )

    # Unsupported pending-intent shape.
    assert {:error, _} =
             CapabilityStore.code_change(0, %{valid | pending_intents: %{"y" => {:bad}}}, [])

    for intents <- [
          %{123 => {"agent", "arbor://fs/read/intent", "payload"}},
          %{"intent" => {123, "arbor://fs/read/intent", "payload"}},
          %{"intent" => {"agent", 123, "payload"}},
          %{"intent" => {"agent", "arbor://fs/read/intent", :unsupported_payload}}
        ] do
      assert {:error, _} =
               CapabilityStore.code_change(0, %{valid | pending_intents: intents}, [])
    end

    valid_intents = %{
      "binary_payload" => {"agent", "arbor://fs/read/intent", "payload"},
      "legacy_sentinel" => {"agent", "arbor://fs/read/legacy-intent", :legacy_uncertain_identity}
    }

    assert {:ok, _} =
             CapabilityStore.code_change(0, %{valid | pending_intents: valid_intents}, [])
  end

  test "pure OTP regression: unsupported state_version reasons are bounded" do
    valid = minimal_valid_current_state()

    for v <- [nil, 2, :weird, "1"] do
      result = CapabilityStore.code_change(0, %{valid | state_version: v}, [])

      assert result == {:error, :unsupported_state_version},
             "version #{inspect(v)} resolved to #{inspect(result)}, " <>
               "expected the fixed bounded reason {:error, :unsupported_state_version}"
    end
  end

  defp simulate_pre_c3a_state do
    :sys.replace_state(CapabilityStore, fn state ->
      state
      |> Map.delete(:by_resource)
      |> Map.delete(:pending_intents)
      |> Map.delete(:state_version)
    end)

    :ok
  end

  defp change_capability_store_code do
    :ok = :sys.suspend(CapabilityStore)

    try do
      :ok = :sys.change_code(CapabilityStore, Arbor.Security.CapabilityStore, 0, [])
    after
      :ok = :sys.resume(CapabilityStore)
    end
  end

  defp assert_store_denies_and_restarts(call) do
    old_pid = Process.whereis(CapabilityStore)
    Process.unlink(old_pid)
    monitor = Process.monitor(old_pid)

    assert {:error, :capability_store_unavailable} = call.()
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, _reason}, 1_000
    assert Process.whereis(CapabilityStore) == nil

    assert {:ok, new_pid} = Supervisor.restart_child(@security_supervisor, CapabilityStore)
    assert new_pid != old_pid
    assert :sys.get_state(new_pid).state_version == 1
  end

  defp canonical_resource_for(uri) do
    case Arbor.Contracts.Security.CapabilityUri.parse(uri) do
      {:ok, parsed} -> Arbor.Contracts.Security.CapabilityUri.canonical(parsed)
      _ -> uri
    end
  end

  # A minimal, well-formed current-v1 state for the pure-OTP code_change/3
  # regressions: by_id keyed by cap.id, by_resource built from the canonical
  # resource key, empty pending ledger. No live process required.
  defp minimal_valid_current_state do
    {:ok, cap} =
      Capability.new(resource_uri: "arbor://fs/read/otp-dv", principal_id: "agent_otp_dv")

    key = {cap.principal_id, canonical_resource_for(cap.resource_uri)}

    %{
      by_id: %{cap.id => cap},
      by_principal: %{cap.principal_id => [cap.id]},
      by_resource: %{key => MapSet.new([cap.id])},
      pending_intents: %{},
      by_issuer: %{},
      by_parent: %{},
      by_usage: %{},
      state_version: 1,
      signal_sync: nil,
      stats: %{
        total_granted: 0,
        total_revoked: 0,
        total_expired: 0,
        total_cascade_revoked: 0,
        restore_scanned: 0,
        restore_active: 0,
        restore_expired: 0,
        restore_superseded: 0,
        restore_rejected: 0
      }
    }
  end

  defp resource_index_holds?(by_resource, principal, resource, id) do
    by_resource
    |> Map.get({principal, canonical_resource_for(resource)}, MapSet.new())
    |> MapSet.member?(id)
  end

  # ==========================================================================
  # Helpers for the F1-F5 regressions.
  # ==========================================================================

  defp same_resource_in_by_id(state, principal, resource) do
    state.by_id
    |> Enum.filter(fn
      {_id, %Capability{principal_id: ^principal, resource_uri: ^resource}} -> true
      _ -> false
    end)
    |> Enum.map(fn {id, _} -> id end)
  end

  # 64-key outer map whose each value is a 9-key scalar map =
  # 1 (outer) + 64 (inner) + 64*9 (leaves) = 641 nodes, within the 64-key and
  # depth-6 caps and < @acknowledged_grant_max_nodes(1024) alone.
  defp big_nested_map do
    Enum.into(1..64, %{}, fn i ->
      {Integer.to_string(i), Enum.into(1..9, %{}, fn j -> {Integer.to_string(j), "v"} end)}
    end)
  end

  defp ensure_event_log do
    name = Arbor.Historian.EventLog.ETS
    backend = Arbor.Persistence.EventLog.ETS

    case apply(backend, :start_link, [[name: name]]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:arbor_security, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:arbor_security, key, value)

  # The arbor_signals supervision tree is not started by default in the
  # arbor_security test profile; start it so the store's direct cluster
  # signal is observable on the bus.
  defp ensure_signals_children do
    {:ok, _started} = Application.ensure_all_started(:arbor_signals)

    started =
      Enum.reduce(
        [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ],
        [],
        fn {module, _opts} = child, started ->
          case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
            {:ok, _pid} ->
              [module | started]

            {:error, {:already_started, _pid}} ->
              started

            {:error, :already_present} ->
              :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
              {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)
              [module | started]
          end
        end
      )

    on_exit(fn ->
      Enum.each(started, fn module ->
        :ok = Supervisor.terminate_child(Arbor.Signals.Supervisor, module)
        :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
      end)
    end)

    :ok
  end

  defp count_audit(event_type, capability_id) do
    case Events.get_by_type(event_type) do
      {:ok, events} when is_list(events) ->
        Enum.count(events, fn e ->
          data = Map.get(e, :data, %{})
          (Map.get(data, :capability_id) || Map.get(data, "capability_id")) == capability_id
        end)

      _ ->
        0
    end
  end

  # Subscribe to the DIRECT store cluster grant signal (filtered by this id +
  # this node). The audit-bridge payload carries :permanent, not :origin_node,
  # so it is excluded; only the store's own emit_capability_signal matches.
  defp subscribe_store_grant_signal(capability_id) do
    parent = self()
    ref = make_ref()
    observer = signal_observer_id("grant")

    {:ok, sub} =
      Arbor.Signals.subscribe(
        "security.*",
        fn signal ->
          data = signal.data
          cid = data[:capability_id] || data["capability_id"]
          origin = data[:origin_node] || data["origin_node"]

          if cid == capability_id and same_node?(origin) do
            send(parent, {ref, :store_grant})
          end

          :ok
        end,
        principal_id: observer
      )

    {ref, sub}
  end

  defp subscribe_store_revoke_signal(capability_id) do
    parent = self()
    ref = make_ref()
    observer = signal_observer_id("revoke")

    {:ok, sub} =
      Arbor.Signals.subscribe(
        "security.*",
        fn signal ->
          data = signal.data
          origin = data[:origin_node] || data["origin_node"]
          ids = data[:capability_ids] || data["capability_ids"]

          if ids == [capability_id] and same_node?(origin) do
            send(parent, {ref, :store_revoke})
          end

          :ok
        end,
        principal_id: observer
      )

    {ref, sub}
  end

  defp signal_observer_id(tag) do
    "agent_ack_signal_observer_" <>
      tag <>
      "_" <>
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # The bus decrypts restricted-topic signals (Jason round-trip), so origin_node
  # arrives as a STRING while node()/1 is an ATOM. Compare both forms.
  defp same_node?(nil), do: false
  defp same_node?(origin) when is_atom(origin), do: origin == node()
  defp same_node?(origin) when is_binary(origin), do: origin == Atom.to_string(node())

  # Drain async bus-delivered signals tagged {ref, tag} until window_ms elapses.
  defp collect_signals(ref, tag, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_collect_signals(ref, tag, deadline, 0)
  end

  defp do_collect_signals(ref, tag, deadline, acc) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^ref, ^tag} -> do_collect_signals(ref, tag, deadline, acc + 1)
    after
      remaining -> acc
    end
  end
end
