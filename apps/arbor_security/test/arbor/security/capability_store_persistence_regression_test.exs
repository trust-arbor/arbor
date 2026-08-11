defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest.DeleteFailingJSONFile do
  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Security.Store.JSONFile

  @delete_failures_key {__MODULE__, :delete_failures}
  @put_failures_key {__MODULE__, :put_failures}

  def fail_deletes(count) when is_integer(count) and count >= 0 do
    :persistent_term.put(@delete_failures_key, count)
  end

  def fail_puts(count) when is_integer(count) and count >= 0 do
    :persistent_term.put(@put_failures_key, count)
  end

  def clear do
    :persistent_term.erase(@delete_failures_key)
    :persistent_term.erase(@put_failures_key)
  end

  @impl true
  def put(key, record, opts \\ []) do
    case :persistent_term.get(@put_failures_key, 0) do
      count when count > 0 ->
        :persistent_term.put(@put_failures_key, count - 1)
        {:error, :injected_put_failure}

      _ ->
        JSONFile.put(key, record, opts)
    end
  end

  @impl true
  def get(key, opts \\ []), do: JSONFile.get(key, opts)

  @impl true
  def delete(key, opts \\ []) do
    case :persistent_term.get(@delete_failures_key, 0) do
      count when count > 0 ->
        :persistent_term.put(@delete_failures_key, count - 1)
        {:error, :injected_delete_failure}

      _ ->
        JSONFile.delete(key, opts)
    end
  end

  @impl true
  def list(opts \\ []), do: JSONFile.list(opts)

  @impl true
  def exists?(key, opts \\ []), do: JSONFile.exists?(key, opts)
end

defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest.CasUnsupportedJSONFile do
  @moduledoc false
  # CRUD-only double: deliberately does not export compare_and_swap/compare_and_delete
  # so acknowledged CAS admission remains fail-closed on unsupported backends.
  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Security.Store.JSONFile

  @impl true
  def put(key, record, opts \\ []), do: JSONFile.put(key, record, opts)

  @impl true
  def get(key, opts \\ []), do: JSONFile.get(key, opts)

  @impl true
  def delete(key, opts \\ []), do: JSONFile.delete(key, opts)

  @impl true
  def list(opts \\ []), do: JSONFile.list(opts)

  @impl true
  def exists?(key, opts \\ []), do: JSONFile.exists?(key, opts)
end

defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
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

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.CapabilityStorePersistenceRegressionTest.CasUnsupportedJSONFile
  alias Arbor.Security.CapabilityStorePersistenceRegressionTest.DeleteFailingJSONFile
  alias Arbor.Security.Config
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Store.JSONFile

  test "security regression: replacement removes the superseded JSON record" do
    principal_id = "agent_capability_store_persistence_regression"
    resource_uri = "arbor://fs/read/capability-store-persistence-regression"

    backend_dir = Path.join("var", "capability-store-regression-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)

    assert {:ok, 1} = CapabilityStore.increment_usage(original.id)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    assert {:ok, replacement} = Security.grant(principal: principal_id, resource: resource_uri)
    assert original.id != replacement.id

    state = :sys.get_state(CapabilityStore)
    assert replacement.id in Map.get(state.by_issuer, replacement.issuer_id, [])
    refute original.id in Map.get(state.by_issuer, original.issuer_id, [])
    refute Map.has_key?(state.by_usage, original.id)

    assert {:ok, listed} = Security.list_capabilities(principal_id)
    assert [%{id: replacement_id}] = listed
    assert replacement_id == replacement.id

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(replacement.id, name: @capability_store)

    restart_capability_store()

    assert {:ok, [%{id: ^replacement_id}]} = Security.list_capabilities(principal_id)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(replacement.id, name: @capability_store)
  end

  test "security regression: failed replacement compensates durable state" do
    principal_id = "agent_capability_store_compensation_regression"
    resource_uri = "arbor://fs/read/capability-store-compensation-regression"
    backend_dir = Path.join("var", "capability-store-compensation-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&DeleteFailingJSONFile.clear/0)

    configure_isolated_json_store(backend_dir, DeleteFailingJSONFile)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)
    original_id = original.id

    DeleteFailingJSONFile.fail_deletes(1)

    assert {:error, {:capability_replacement_failed, :outcome_unknown}} =
             Security.grant(principal: principal_id, resource: resource_uri)

    assert {:ok, [%{id: ^original_id}]} = Security.list_capabilities(principal_id)

    assert {:ok, [^original_id]} =
             BufferedStore.authoritative_list(name: @capability_store)
  end

  test "security regression: same-id replacement compensation retains restored record" do
    principal_id = "agent_capability_store_same_id_regression"
    resource_uri = "arbor://fs/read/capability-store-same-id-regression"
    backend_dir = Path.join("var", "capability-store-same-id-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&DeleteFailingJSONFile.clear/0)

    configure_isolated_json_store(backend_dir, DeleteFailingJSONFile)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)
    original_id = original.id
    DeleteFailingJSONFile.fail_puts(1)

    assert {:error, {:capability_replacement_failed, :outcome_unknown}} =
             CapabilityStore.put(original)

    assert {:ok, [%{id: ^original_id}]} = Security.list_capabilities(principal_id)

    assert {:ok, %Record{}} =
             BufferedStore.authoritative_get(original_id, name: @capability_store)
  end

  test "security regression: unknown replacement compensation never reports success" do
    principal_id = "agent_capability_store_unknown_outcome_regression"
    resource_uri = "arbor://fs/read/capability-store-unknown-outcome-regression"
    backend_dir = Path.join("var", "capability-store-unknown-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&DeleteFailingJSONFile.clear/0)

    configure_isolated_json_store(backend_dir, DeleteFailingJSONFile)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)
    original_id = original.id

    DeleteFailingJSONFile.fail_deletes(2)

    result = Security.grant(principal: principal_id, resource: resource_uri)
    assert {:error, {:capability_replacement_outcome_unknown, details}} = result
    assert details.original == :outcome_unknown

    assert {:ok, persisted_ids} = BufferedStore.authoritative_list(name: @capability_store)
    assert original_id in persisted_ids
    assert length(persisted_ids) == 2
  end

  test "security regression: remote replacement revocation removes durable projection" do
    principal_id = "agent_capability_store_remote_revoke_regression"
    resource_uri = "arbor://fs/read/capability-store-remote-revoke-regression"
    backend_dir = Path.join("var", "capability-store-remote-revoke-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir)

    assert {:ok, original} = Security.grant(principal: principal_id, resource: resource_uri)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    send(
      CapabilityStore,
      {:signal_received,
       %{
         type: :capability_revoked,
         data: %{
           capability_ids: [original.id],
           principal_id: principal_id,
           origin_node: "remote-capability-store-test@localhost"
         }
       }}
    )

    :sys.get_state(CapabilityStore)

    assert {:ok, []} = Security.list_capabilities(principal_id)

    assert {:error, :unauthorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)

    restart_capability_store()

    assert {:ok, []} = Security.list_capabilities(principal_id)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(original.id, name: @capability_store)
  end

  test "security regression: delegated capability remains authorized after persistence restart" do
    backend_dir = Path.join("var", "capability-store-delegation-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir)

    {:ok, parent} = Identity.generate(name: "restart-delegator")
    {:ok, worker} = Identity.generate(name: "restart-delegatee")
    :ok = Registry.register(parent)
    :ok = Registry.register(worker)

    resource = "arbor://fs/read/delegation-restart-regression"

    assert {:ok, _parent_cap} =
             Security.grant(principal: parent.agent_id, resource: resource, delegation_depth: 3)

    assert {:ok, [delegated]} =
             Security.delegate_to_agent(parent.agent_id, worker.agent_id,
               delegator_private_key: parent.private_key,
               resources: [resource]
             )

    assert is_binary(hd(delegated.delegation_chain).delegator_signature)

    assert {:ok, :authorized} =
             Security.authorize(worker.agent_id, resource, nil, verify_identity: false)

    restart_capability_store()

    assert {:ok, :authorized} =
             Security.authorize(worker.agent_id, resource, nil, verify_identity: false)
  end

  test "security regression: limited-use capability cannot regain uses after restart" do
    principal_id = "agent_capability_store_limited_restart"
    resource_uri = "arbor://fs/read/capability-store-limited-restart"
    backend_dir = Path.join("var", "capability-store-limited-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir)

    assert {:ok, _cap} =
             Security.grant(principal: principal_id, resource: resource_uri, max_uses: 3)

    assert {:ok, :authorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    restart_capability_store()

    assert {:error, :unauthorized} =
             Security.authorize(principal_id, resource_uri, nil, verify_identity: false)

    assert %{restore_rejected: 1, restore_active: 0} = CapabilityStore.stats()
  end

  test "security regression: authorize survives full BufferedStore+CapabilityStore restart above 10_000 durable records" do
    backend_dir = Path.join("var", "capability-store-hydrate-10k-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    on_exit(&restore_security_children/0)

    target_principal = "agent_capability_store_hydrate_target"
    target_resource = "arbor://fs/read/capability-store-hydrate-target"
    target_id = "cap_hydrate_target"

    {:ok, target_cap} =
      Capability.new(
        id: target_id,
        principal_id: target_principal,
        resource_uri: target_resource,
        granted_at: DateTime.utc_now(),
        delegation_depth: 0
      )

    # Seed durable backend only — do not leave residual ETS from a live store.
    seed_count = 10_001
    seed_durable_capabilities!(backend_dir, target_cap, seed_count)

    # Detach permanent supervisor children first (do not GenServer.stop them).
    :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    :ok = Supervisor.terminate_child(@security_supervisor, @capability_store)

    start_capability_buffered_store!(backend_dir)
    assert {:ok, _pid} = CapabilityStore.start_link([])

    assert {:ok, :authorized} =
             Security.authorize(target_principal, target_resource, nil, verify_identity: false)

    assert {:ok,
            %{
              status: :ready,
              loaded_count: loaded,
              configured_limit: limit
            }} = BufferedStore.hydration_status(name: @capability_store)

    assert loaded == seed_count
    assert limit >= seed_count

    # Full recreate of both test-owned processes so parent cannot pass via residual ETS.
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)

    start_capability_buffered_store!(backend_dir)

    assert {:ok, %{status: :ready, loaded_count: loaded_after}} =
             BufferedStore.hydration_status(name: @capability_store)

    assert loaded_after == seed_count

    assert {:ok, _pid} = CapabilityStore.start_link([])

    assert {:ok, :authorized} =
             Security.authorize(target_principal, target_resource, nil, verify_identity: false)
  end

  test "security regression: acknowledged mutation fails closed on a CAS-unsupported backend" do
    # Use an explicit CRUD-only double (no compare_and_swap/compare_and_delete)
    # so acknowledged CAS admission fails closed (:outcome_unknown) and never
    # reports success or mutates live/durable state. (Authoritative failure mode
    # for unsupported backends per the C3A correction. JSONFile itself now
    # implements CAS in P2; this regression pins the unsupported-backend path.)
    principal = "agent_ack_unsupported_backend"
    resource = "arbor://fs/read/ack-unsupported-backend"

    backend_dir = Path.join("var", "ack-unsupported-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    configure_isolated_json_store(backend_dir, CasUnsupportedJSONFile)

    if function_exported?(Security, :acknowledged_grant, 1) and
         function_exported?(Security, :acknowledged_revoke, 1) do
      det_id = "cap_" <> (:erlang.md5("ack-unsupported") |> Base.encode16(case: :lower))

      opts = [
        capability_id: det_id,
        granted_at: ~U[2026-01-01 00:00:00Z],
        principal: principal,
        resource: resource
      ]

      assert {:error, :outcome_unknown} = Security.acknowledged_grant(opts)
      assert {:error, :not_found} = CapabilityStore.get(det_id)

      # No durable mutation either: the CAS-unsupported backend never admitted.
      assert {:error, :not_found} =
               BufferedStore.authoritative_get(det_id, name: @capability_store)

      # An ordinary (non-CAS) cap seeds live + durable; its acknowledged revoke
      # also fails closed on the CAS-unsupported backend without evicting live.
      {:ok, seeded} = Security.grant(principal: principal, resource: resource)
      assert {:error, :outcome_unknown} = Security.acknowledged_revoke(seeded.id)

      assert {:ok, :authorized} =
               Security.authorize(principal, resource, nil, verify_identity: false)

      # The seeded cap remains durable (the failed acknowledged revoke mutated
      # nothing on the CAS-unsupported backend).
      assert {:ok, %Record{}} =
               BufferedStore.authoritative_get(seeded.id, name: @capability_store)
    end
  end

  # P3 public admission proof on the default durable JSONFile backend.
  # Store-layer causal ABA evidence: JSONFileDurableCasTest (P2) and pre-P2
  # baseline 4582ec8de9acb2280109b76c6d797d8872240a2d. This test adds the
  # public facade + BufferedStore + CapabilityStore dual-restart path.
  test "security regression: public acknowledged grant/revoke on JSONFile survives full two-process restart with generation fence (ABA)" do
    principal = "agent_ack_jsonfile_public"
    resource = "arbor://fs/read/ack-jsonfile-public"

    cap_id =
      "cap_" <> Base.encode16(:erlang.md5("ack-jsonfile-public-p3"), case: :lower)

    granted_at = ~U[2026-01-15 12:00:00Z]

    opts = [
      capability_id: cap_id,
      granted_at: granted_at,
      principal: principal,
      resource: resource
    ]

    backend_dir = Path.join("var", "ack-jsonfile-public-#{unique_integer()}")
    tmp_dir = Path.expand(backend_dir, File.cwd!())
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Real default durable backend — not CASSandbox, ETS, or a CAS wrapper.
    configure_isolated_json_store(backend_dir)

    # Phase A — public grant + idempotency + authorize
    assert {:ok, :applied, id} = Security.acknowledged_grant(opts)
    assert id == cap_id
    assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:ok, %Record{generation: g1, revision: r1} = pre_revoke} =
             BufferedStore.authoritative_get(id, name: @capability_store)

    assert is_integer(g1) and g1 >= 1
    assert is_integer(r1) and r1 >= 1

    # Phase B — restart #1: both named processes over the same JSON directory
    full_restart_capability_stack!(backend_dir)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)

    assert {:ok, %Record{generation: ^g1, revision: ^r1}} =
             BufferedStore.authoritative_get(id, name: @capability_store)

    # Phase C — public revoke + idempotency + no live auth
    assert {:ok, :applied, ^id} = Security.acknowledged_revoke(id)
    assert {:ok, :idempotent, ^id} = Security.acknowledged_revoke(id)

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(id, name: @capability_store)

    # Phase D — restart #2: revocation must not resurrect
    full_restart_capability_stack!(backend_dir)

    assert {:error, :unauthorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:ok, []} = Security.list_capabilities(principal)

    assert {:error, :not_found} =
             BufferedStore.authoritative_get(id, name: @capability_store)

    assert {:ok, :idempotent, ^id} = Security.acknowledged_revoke(id)

    # Phase E — same-id re-grant advances durable generation
    assert {:ok, :applied, ^id} = Security.acknowledged_grant(opts)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:ok, %Record{generation: g2, revision: r2}} =
             BufferedStore.authoritative_get(id, name: @capability_store)

    # Tombstone + reinsert must strictly advance the Record generation fence.
    assert g2 > g1

    # Phase F — stale pre-revoke fence rejected by real JSONFile CAS/CAD
    json_opts = [base_dir: backend_dir, name: "capabilities"]

    stale_data =
      case pre_revoke.data do
        data when is_map(data) -> Map.put(data, "_stale", true)
        _ -> %{"_stale" => true}
      end

    assert {:error, :conflict} =
             JSONFile.compare_and_swap(
               id,
               {:value, pre_revoke},
               Record.update(pre_revoke, stale_data),
               json_opts
             )

    assert {:error, :conflict} =
             JSONFile.compare_and_delete(id, pre_revoke, json_opts)

    assert {:ok, %Record{generation: ^g2, revision: ^r2}} =
             JSONFile.get(id, json_opts)

    assert {:ok, :authorized} =
             Security.authorize(principal, resource, nil, verify_identity: false)

    assert {:ok, :idempotent, ^id} = Security.acknowledged_grant(opts)
  end

  defp configure_isolated_json_store(tmp_dir, backend \\ JSONFile) do
    on_exit(&restore_security_children/0)

    :ok = Supervisor.terminate_child(@security_supervisor, CapabilityStore)
    :ok = Supervisor.terminate_child(@security_supervisor, @capability_store)

    {:ok, _pid} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: backend,
        backend_opts: [base_dir: tmp_dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )

    {:ok, _pid} = CapabilityStore.start_link([])
  end

  defp restart_capability_store do
    stop_named_process(CapabilityStore)
    {:ok, _pid} = CapabilityStore.start_link([])
  end

  # Full recreate of both test-owned processes so residual ETS cannot pass a
  # durability assertion. Same isolated JSON directory is re-attached.
  defp full_restart_capability_stack!(backend_dir) do
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)
    start_capability_buffered_store!(backend_dir)

    assert {:ok, %{status: :ready}} =
             BufferedStore.hydration_status(name: @capability_store)

    assert {:ok, _pid} = CapabilityStore.start_link([])
  end

  defp start_capability_buffered_store!(backend_dir) do
    {:ok, _pid} =
      BufferedStore.start_link(
        name: @capability_store,
        backend: JSONFile,
        backend_opts: [base_dir: backend_dir],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "capabilities",
        hydration_limit: Config.max_global_capabilities()
      )
  end

  defp seed_durable_capabilities!(backend_dir, target_cap, total_count)
       when total_count >= 1 do
    assert :ok =
             JSONFile.put(
               target_cap.id,
               Record.new(target_cap.id, Serializer.serialize(target_cap)),
               name: "capabilities",
               base_dir: backend_dir
             )

    filler_count = total_count - 1

    for i <- 1..filler_count do
      id = "cap_hydrate_filler_#{i}"
      principal = "agent_capability_store_hydrate_filler_#{i}"
      resource = "arbor://fs/read/capability-store-hydrate-filler-#{i}"

      {:ok, cap} =
        Capability.new(
          id: id,
          principal_id: principal,
          resource_uri: resource,
          granted_at: DateTime.utc_now(),
          delegation_depth: 0
        )

      assert :ok =
               JSONFile.put(
                 id,
                 Record.new(id, Serializer.serialize(cap)),
                 name: "capabilities",
                 base_dir: backend_dir
               )
    end
  end

  # This module terminates children on the SHARED Arbor.Security.Supervisor to
  # occupy their registered names (production resolves the store by name, so
  # intercepting requires taking the name). Restoring them afterwards is
  # therefore load-bearing for every test that runs after this module.
  #
  # It previously guarded the restart on `is_nil(pid)` from which_children/1.
  # Supervisor.which_children/1 reports a TERMINATED child as `:undefined`, not
  # `nil`, so that predicate was never true and the function restarted nothing —
  # a silent no-op. Every security test scheduled after this module then failed
  # with `no process`, and because ExUnit shuffles module order by seed, the
  # suite ranged from 0 to 290 failures run to run on the same commit.
  #
  # restart_child/2 already reports {:error, :running} when a child is up, so
  # the correct shape is to call it unconditionally and treat "already running"
  # as success — no inspection, no predicate to get wrong. The final assertion
  # exists so that if restoration ever breaks again it fails HERE, loudly, in
  # the module that caused it, rather than as a cascade of unrelated failures.
  defp restore_security_children do
    stop_named_process(CapabilityStore)
    stop_named_process(@capability_store)

    Enum.each(@security_children, &restart_security_child!/1)
    assert_security_children_alive!()
  end

  defp restart_security_child!(child_id) do
    case Supervisor.restart_child(@security_supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      # Already running, or never terminated in the first place.
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      # Not a child of this supervisor in this test profile.
      {:error, :not_found} -> :ok
      {:error, reason} -> raise "failed to restore #{inspect(child_id)}: #{inspect(reason)}"
    end
  end

  defp assert_security_children_alive! do
    dead =
      Enum.filter(@security_children, fn child_id ->
        case Process.whereis(child_id) do
          nil -> child_id not in optional_children()
          pid -> not Process.alive?(pid)
        end
      end)

    if dead != [] do
      raise """
      security children left dead after this module: #{inspect(dead)}

      Every subsequent test that touches them will fail with `no process`, and
      the failure will look like it belongs to whichever module ExUnit happened
      to schedule next. Fix the restore path here.
      """
    end
  end

  # Children that may legitimately be absent depending on the test profile.
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
      nil ->
        :ok

      pid ->
        if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp unique_integer, do: :erlang.unique_integer([:positive])
end
