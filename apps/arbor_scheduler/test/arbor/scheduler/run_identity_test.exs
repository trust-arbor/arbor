defmodule Arbor.Scheduler.RunIdentityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, RunIdentity, RunIdentityReaper, RunLease}
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Crypto
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Trust

  @envelope_uri "arbor://fs/write/reports/**"
  @lobby_uri "arbor://orchestrator/execute"
  @per_node_resources [
    "arbor://orchestrator/execute/llm_query",
    "arbor://orchestrator/execute/graph_mutation",
    "arbor://orchestrator/map/dispatch",
    "arbor://orchestrator/execute/compose"
  ]

  defmodule TrustFailureStub do
    def get_trust_profile(agent_id) do
      send(test_pid(), {:trust_agent_id, agent_id})

      case Application.fetch_env!(:arbor_scheduler, :run_identity_trust_failure) do
        :lookup -> {:error, :forced_lookup_failure}
        :update -> {:error, :not_found}
      end
    end

    def ensure_trust_profile(agent_id, opts) do
      {:ok, _profile} = Arbor.Trust.ensure_trust_profile(agent_id, opts)
      {:error, :forced_update_failure}
    end

    defdelegate delete_trust_profile(agent_id), to: Arbor.Trust

    defp test_pid, do: Application.fetch_env!(:arbor_scheduler, :run_identity_test_pid)
  end

  defmodule CleanupSecurityStub do
    defdelegate generate_identity(opts), to: Arbor.Security
    defdelegate register_identity(identity), to: Arbor.Security
    defdelegate grant(opts), to: Arbor.Security

    defdelegate build_signing_authority_acquisition_proof(agent_id, private_key, opts),
      to: Arbor.Security

    defdelegate open_ephemeral_signing_authority(proof, private_key), to: Arbor.Security

    def close_signing_authority(authority) do
      maybe_fail(:authority, fn -> Arbor.Security.close_signing_authority(authority) end)
    end

    def revoke(cap_id) do
      maybe_fail(:capability, fn -> Arbor.Security.revoke(cap_id) end)
    end

    def deregister_identity(agent_id) do
      maybe_fail(:identity, fn -> Arbor.Security.deregister_identity(agent_id) end)
    end

    defp maybe_fail(operation, fallback) do
      attempt = :ets.update_counter(:run_identity_cleanup_stub, {operation, :attempts}, 1)
      failures = :ets.lookup_element(:run_identity_cleanup_stub, {operation, :failures}, 2)

      if attempt <= failures do
        {:error, {:forced_cleanup_failure, operation}}
      else
        fallback.()
      end
    end
  end

  defmodule CleanupTrustStub do
    defdelegate get_trust_profile(agent_id), to: Arbor.Trust
    defdelegate ensure_trust_profile(agent_id, opts), to: Arbor.Trust

    def delete_trust_profile(agent_id) do
      attempt = :ets.update_counter(:run_identity_cleanup_stub, {:trust_profile, :attempts}, 1)
      failures = :ets.lookup_element(:run_identity_cleanup_stub, {:trust_profile, :failures}, 2)

      if attempt <= failures do
        {:error, {:forced_cleanup_failure, :trust_profile}}
      else
        Arbor.Trust.delete_trust_profile(agent_id)
      end
    end
  end

  defmodule ProvisionRaceSecurityStub do
    defdelegate generate_identity(opts), to: Arbor.Security
    defdelegate revoke(cap_id), to: Arbor.Security
    defdelegate deregister_identity(agent_id), to: Arbor.Security
    defdelegate close_signing_authority(authority), to: Arbor.Security

    defdelegate build_signing_authority_acquisition_proof(agent_id, private_key, opts),
      to: Arbor.Security

    def register_identity(identity) do
      result = Arbor.Security.register_identity(identity)
      if result == :ok, do: send(test_pid(), {:race_agent, identity.agent_id})
      result
    end

    def grant(opts) do
      Arbor.Security.grant(opts)
      |> maybe_pause(:grant)
    end

    def open_ephemeral_signing_authority(proof, private_key) do
      Arbor.Security.open_ephemeral_signing_authority(proof, private_key)
      |> maybe_pause(:authority)
    end

    defp maybe_pause({:ok, artifact} = result, stage) do
      if Application.get_env(:arbor_scheduler, :run_identity_race_stage) == stage do
        send(test_pid(), {:race_effect, stage, artifact, self()})
        receive do: ({:release_race, ^stage} -> result)
      else
        result
      end
    end

    defp maybe_pause(result, _stage), do: result

    defp test_pid, do: Application.fetch_env!(:arbor_scheduler, :run_identity_test_pid)
  end

  defmodule ReaperFacadeStub do
    def lookup_identity_ids_by_display_name(name) do
      send(test_pid(), {:lookup, name})
      response(:lookup)
    end

    def list_capabilities(agent_id) do
      send(test_pid(), {:list_capabilities, agent_id})
      response(:list_capabilities)
    end

    def revoke(cap_id) do
      send(test_pid(), {:revoke, cap_id})
      response(:revoke)
    end

    def delete_trust_profile(agent_id) do
      send(test_pid(), {:delete_trust_profile, agent_id})
      response(:delete_trust_profile)
    end

    def deregister_identity(agent_id) do
      send(test_pid(), {:deregister_identity, agent_id})
      response(:deregister_identity)
    end

    defp response(operation) do
      :arbor_scheduler
      |> Application.fetch_env!(:run_identity_reaper_responses)
      |> Map.fetch!(operation)
    end

    defp test_pid, do: Application.fetch_env!(:arbor_scheduler, :run_identity_test_pid)
  end

  setup do
    Application.put_env(:arbor_scheduler, :run_identity_test_pid, self())
    :ets.new(:run_identity_cleanup_stub, [:named_table, :public, :set])

    for operation <- [:authority, :capability, :trust_profile, :identity] do
      :ets.insert(:run_identity_cleanup_stub, [
        {{operation, :attempts}, 0},
        {{operation, :failures}, 0}
      ])
    end

    {:ok, issuer} = Identity.generate()
    :ok = Security.register_identity(issuer)

    envelopes =
      Enum.map(
        [@envelope_uri, "arbor://orchestrator/execute/**", "arbor://orchestrator/map/**"],
        fn resource_uri ->
          {:ok, envelope} =
            Capability.new(resource_uri: resource_uri, principal_id: issuer.agent_id)

          envelope
        end
      )

    :ok = IssuerRegistry.register(issuer.agent_id, envelopes, reason: "run_identity_test")

    tmp_dir =
      System.tmp_dir!() |> Path.join("run_identity_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Application.delete_env(:arbor_scheduler, :run_identity_test_pid)
      Application.delete_env(:arbor_scheduler, :run_identity_trust_failure)
      Application.delete_env(:arbor_scheduler, :run_identity_reaper_responses)
      Application.delete_env(:arbor_scheduler, :run_identity_runtime_id)
      Application.delete_env(:arbor_scheduler, :run_identity_race_stage)
      IssuerRegistry.revoke(issuer.agent_id, "test cleanup")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, issuer: issuer, tmp_dir: tmp_dir}
  end

  test "mints only attested caps and returns an opaque authority handle", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation =
      verified_attestation(issuer, tmp_dir, [
        %{resource_uri: "arbor://fs/write/reports/narrow/**", constraints: %{}}
      ])

    assert {:ok, handle} = RunIdentity.mint(attestation)
    assert String.starts_with?(handle.agent_id, "agent_")
    assert Map.keys(handle) |> Enum.sort() == [:agent_id, :cap_ids, :lease, :signing_authority]
    refute Enum.any?(Map.values(handle), &is_function/1)
    refute Map.has_key?(handle, :private_key)
    assert {:error, :no_signing_key} = SigningKeyStore.get(handle.agent_id)

    capabilities = Enum.map(handle.cap_ids, &fetch_cap!/1)

    assert Enum.sort(Enum.map(capabilities, & &1.resource_uri)) ==
             Enum.sort([
               @lobby_uri,
               "arbor://fs/write/reports/narrow/**"
             ])

    refute Enum.any?(capabilities, &(&1.resource_uri == @envelope_uri))

    declared = Enum.find(capabilities, &(&1.resource_uri != @lobby_uri))
    assert declared.principal_id == handle.agent_id
    assert declared.metadata.provenance.issuer_id == issuer.agent_id
    assert declared.metadata.provenance.graph_hash == attestation.graph_hash

    assert {:ok, _public_key} = Security.lookup_public_key(handle.agent_id)
    RunIdentity.revoke(handle)
  end

  test "security regression: empty attestation leaves per-node operations unauthorized", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])

    assert {:ok, handle} = RunIdentity.mint(attestation)
    assert [lobby_cap] = Enum.map(handle.cap_ids, &fetch_cap!/1)
    assert lobby_cap.resource_uri == @lobby_uri
    assert {:ok, :authorized} = authorize_as(handle, @lobby_uri)

    for resource <- @per_node_resources do
      assert {:error, :unauthorized} = authorize_as(handle, resource)
    end

    RunIdentity.revoke(handle)
  end

  test "explicitly attested per-node operations remain authorized", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    capabilities =
      Enum.map(@per_node_resources, &%{resource_uri: &1, constraints: %{}})

    attestation = verified_attestation(issuer, tmp_dir, capabilities)

    assert {:ok, handle} = RunIdentity.mint(attestation)

    for resource <- @per_node_resources do
      assert {:ok, :authorized} = authorize_as(handle, resource)
    end

    RunIdentity.revoke(handle)
  end

  test "requires the verified attestation type" do
    assert {:error, :verified_attestation_required} = RunIdentity.mint(%{})
    assert {:error, :verified_attestation_required} = RunIdentity.mint("file.caps.json")
  end

  test "security regression: a forged attestation struct cannot mint authority", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    forged = %{attestation | graph_hash: String.duplicate("0", 64)}

    assert {:error, :invalid_signature} = RunIdentity.mint(forged)
  end

  test "revoke removes every cap and deregisters the ephemeral identity", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation =
      verified_attestation(issuer, tmp_dir, [
        %{resource_uri: "arbor://fs/write/reports/lifecycle/**", constraints: %{}}
      ])

    {:ok, handle} = RunIdentity.mint(attestation)
    authority = handle.signing_authority
    assert :ok = RunIdentity.revoke(handle)

    for cap_id <- handle.cap_ids do
      case CapabilityStore.get(cap_id) do
        {:error, _reason} -> :ok
        {:ok, capability} -> assert Map.get(capability, :revoked, true)
      end
    end

    assert {:error, :not_found} = Security.lookup_public_key(handle.agent_id)

    if Process.whereis(Arbor.Trust.Manager) do
      assert {:error, :not_found} = Trust.get_trust_profile(handle.agent_id)
    end

    assert {:error, :authority_not_found} = Security.sign_with_authority(authority, "closed")
  end

  test "cleanup is nil-safe and idempotent", %{issuer: issuer, tmp_dir: tmp_dir} do
    attestation = verified_attestation(issuer, tmp_dir, [])
    {:ok, handle} = RunIdentity.mint(attestation)

    assert :ok = RunIdentity.revoke(nil)
    assert :ok = RunIdentity.revoke(handle)
    assert :ok = RunIdentity.revoke(handle)
  end

  test "security regression: trust lookup failure atomically rolls back run state", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    Application.put_env(:arbor_scheduler, :run_identity_trust_failure, :lookup)
    attestation = verified_attestation(issuer, tmp_dir, [])

    assert {:error, {:trust_profile_lookup_failed, :forced_lookup_failure}} =
             RunIdentity.mint(attestation, trust_facade: TrustFailureStub)

    assert_receive {:trust_agent_id, agent_id}
    assert_run_state_removed(agent_id)
  end

  test "security regression: trust update failure atomically rolls back run state", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    Application.put_env(:arbor_scheduler, :run_identity_trust_failure, :update)
    attestation = verified_attestation(issuer, tmp_dir, [])

    assert {:error, {:trust_profile_provision_failed, :forced_update_failure}} =
             RunIdentity.mint(attestation, trust_facade: TrustFailureStub)

    assert_receive {:trust_agent_id, agent_id}
    assert_run_state_removed(agent_id)
  end

  test "security regression: hard-killing owner revokes the complete run lease", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} = RunIdentity.mint(attestation)
        send(parent, {:run_handle, handle})
        Process.sleep(:infinity)
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:run_handle, handle}, 5_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000

    assert_eventually(fn -> run_state_removed?(handle) end)

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(handle.signing_authority, "closed")
  end

  test "security regression: killing a lease worker preserves live owner authority", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    assert {:ok, handle} = RunIdentity.mint(attestation)

    lease_pid = RunLease.whereis(handle.lease)
    lease_ref = Process.monitor(lease_pid)
    Process.exit(lease_pid, :kill)
    assert_receive {:DOWN, ^lease_ref, :process, ^lease_pid, :killed}, 5_000

    assert_eventually(fn ->
      case RunLease.whereis(handle.lease) do
        pid when is_pid(pid) -> pid != lease_pid
        nil -> false
      end
    end)

    assert {:ok, _signed_request} =
             Security.sign_with_authority(handle.signing_authority, "still-live")

    assert :ok = RunIdentity.revoke(handle)
  end

  test "security regression: dynamic supervisor restart reconstructs active lease monitors", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} = RunIdentity.mint(attestation)
        send(parent, {:reconstructed_run_handle, handle})
        Process.sleep(:infinity)
      end)

    assert_receive {:reconstructed_run_handle, handle}, 5_000

    old_supervisor = Process.whereis(RunLease.DynamicSupervisor)
    old_lease = RunLease.whereis(handle.lease)
    Process.exit(old_supervisor, :kill)

    assert_eventually(fn ->
      new_supervisor = Process.whereis(RunLease.DynamicSupervisor)
      new_lease = RunLease.whereis(handle.lease)

      is_pid(new_supervisor) and new_supervisor != old_supervisor and is_pid(new_lease) and
        new_lease != old_lease
    end)

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_eventually(fn -> run_state_removed?(handle) end)
  end

  test "security regression: store restart preserves journals and opaque authority handles", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    assert {:ok, handle} = RunIdentity.mint(attestation)

    old_store = Process.whereis(RunLease.Store)
    old_lease = RunLease.whereis(handle.lease)
    Process.exit(old_store, :kill)

    assert_eventually(fn ->
      new_store = Process.whereis(RunLease.Store)
      new_lease = RunLease.whereis(handle.lease)

      is_pid(new_store) and new_store != old_store and is_pid(new_lease) and
        new_lease != old_lease
    end)

    assert {:ok, _signed_request} =
             Security.sign_with_authority(handle.signing_authority, "survived-store-restart")

    assert :ok = RunIdentity.revoke(handle)
    assert_eventually(fn -> run_state_removed?(handle) end)
  end

  test "security regression: lease journal and process diagnostics hide authority bearer state",
       %{
         issuer: issuer,
         tmp_dir: tmp_dir
       } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    assert {:ok, handle} = RunIdentity.mint(attestation)

    token = handle.signing_authority.token

    assert_raise ArgumentError, fn ->
      :ets.lookup(RunLease.StateOwner, handle.lease)
    end

    assert {:error, :unauthorized} = RunLease.StateOwner.fetch(handle.lease)
    refute term_contains?(:sys.get_status(RunLease.Store), token)
    refute term_contains?(:sys.get_status(RunLease.StateOwner), token)
    refute term_contains?(:sys.get_state(RunLease.StateOwner), token)

    assert :ok = RunIdentity.revoke(handle)
  end

  test "security regression: owner death cannot split grant or authority recording", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])

    for stage <- [:grant, :authority] do
      Application.put_env(:arbor_scheduler, :run_identity_race_stage, stage)

      owner =
        spawn(fn ->
          RunIdentity.mint(attestation, security_facade: ProvisionRaceSecurityStub)
        end)

      owner_ref = Process.monitor(owner)
      assert_receive {:race_agent, agent_id}, 5_000
      assert_receive {:race_effect, ^stage, artifact, store_pid}, 5_000

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
      send(store_pid, {:release_race, stage})

      assert_eventually(fn ->
        match?({:error, :not_found}, Security.lookup_public_key(agent_id))
      end)

      case stage do
        :grant ->
          assert {:error, _reason} = CapabilityStore.get(artifact.id)

        :authority ->
          assert {:error, :authority_not_found} = Security.sign_with_authority(artifact, "closed")
      end
    end
  end

  test "revoke retries cleanup and reports retained terminal failures", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])

    for operation <- [:authority, :capability, :trust_profile, :identity] do
      :ets.insert(:run_identity_cleanup_stub, [
        {{operation, :attempts}, 0},
        {{operation, :failures}, 2}
      ])

      assert {:ok, handle} =
               RunIdentity.mint(attestation,
                 security_facade: CleanupSecurityStub,
                 trust_facade: CleanupTrustStub,
                 cleanup_max_attempts: 2,
                 cleanup_retry_base_ms: 1,
                 cleanup_retry_max_ms: 1
               )

      assert {:error, {:cleanup_failed, failures}} = RunIdentity.revoke(handle)
      assert cleanup_failure_present?(failures, operation)
      assert :ets.lookup_element(:run_identity_cleanup_stub, {operation, :attempts}, 2) >= 2

      :ets.insert(:run_identity_cleanup_stub, {{operation, :failures}, 0})
      assert :ok = RunIdentity.revoke(handle)
    end
  end

  test "cleanup remains supervised after reporting the synchronous retry threshold", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    :ets.insert(:run_identity_cleanup_stub, {{:identity, :failures}, 1})

    assert {:ok, handle} =
             RunIdentity.mint(attestation,
               security_facade: CleanupSecurityStub,
               trust_facade: CleanupTrustStub,
               cleanup_max_attempts: 1,
               cleanup_reconcile_base_ms: 5,
               cleanup_reconcile_max_ms: 10
             )

    assert {:error, {:cleanup_failed, failures}} = RunIdentity.revoke(handle)
    assert cleanup_failure_present?(failures, :identity)
    assert is_pid(RunLease.whereis(handle.lease))

    :ets.insert(:run_identity_cleanup_stub, {{:identity, :failures}, 0})
    assert_eventually(fn -> run_state_removed?(handle) end)
    assert_eventually(fn -> is_nil(RunLease.whereis(handle.lease)) end)
  end

  test "startup reconciliation removes stable run residue after node display-name changes" do
    refute String.contains?(RunIdentity.identity_name(), Atom.to_string(node()))

    {:ok, stale_identity} = Identity.generate(name: RunIdentity.identity_name())

    :ok =
      stale_identity
      |> Identity.public_only()
      |> Security.register_identity()

    assert {:ok, _cap} = Security.grant(principal: stale_identity.agent_id, resource: @lobby_uri)

    assert {:ok, _profile} =
             Trust.ensure_trust_profile(stale_identity.agent_id, baseline: :ask, rules: %{})

    assert {:ok, _public_key} = Security.lookup_public_key(stale_identity.agent_id)

    assert :ok = RunIdentityReaper.reconcile()
    assert_eventually(fn -> run_state_removed?(%{agent_id: stale_identity.agent_id}) end)
  end

  test "reconciliation does not collide with a live runtime lease", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation = verified_attestation(issuer, tmp_dir, [])
    assert {:ok, handle} = RunIdentity.mint(attestation)

    assert :ok = RunIdentityReaper.reconcile()
    assert {:ok, _public_key} = Security.lookup_public_key(handle.agent_id)

    assert {:ok, _signed_request} =
             Security.sign_with_authority(handle.signing_authority, "still-active")

    assert :ok = RunIdentity.revoke(handle)
  end

  test "runtime scopes keep reaper lookup names disjoint" do
    Application.put_env(:arbor_scheduler, :run_identity_runtime_id, "runtime-a")
    first_name = RunIdentity.identity_name()
    Application.put_env(:arbor_scheduler, :run_identity_runtime_id, "runtime-b")
    second_name = RunIdentity.identity_name()

    assert String.starts_with?(first_name, "scheduler-run:runtime-a:")
    assert String.starts_with?(second_name, "scheduler-run:runtime-b:")
    refute first_name == second_name
  end

  test "configured runtime scopes remain disjoint across distributed peers" do
    Application.put_env(:arbor_scheduler, :run_identity_runtime_id, "shared-runtime")

    first_name = RunIdentity.identity_name(:"scheduler-a@cluster")
    second_name = RunIdentity.identity_name(:"scheduler-b@cluster")

    assert first_name == RunIdentity.identity_name(:"scheduler-a@cluster")
    refute first_name == second_name
  end

  test "security regression: local reaper scope cannot reap a peer runtime identity" do
    Application.put_env(:arbor_scheduler, :run_identity_runtime_id, "peer-runtime")
    peer_name = RunIdentity.identity_name()
    {:ok, peer_identity} = Identity.generate(name: peer_name)
    :ok = peer_identity |> Identity.public_only() |> Security.register_identity()
    assert {:ok, _cap} = Security.grant(principal: peer_identity.agent_id, resource: @lobby_uri)

    assert {:ok, _profile} =
             Trust.ensure_trust_profile(peer_identity.agent_id, baseline: :ask, rules: %{})

    Application.put_env(:arbor_scheduler, :run_identity_runtime_id, "local-runtime")
    assert :ok = RunIdentityReaper.reconcile()

    assert {:ok, _public_key} = Security.lookup_public_key(peer_identity.agent_id)
    assert {:ok, [_cap]} = Security.list_capabilities(peer_identity.agent_id)
    assert {:ok, _profile} = Trust.get_trust_profile(peer_identity.agent_id)

    assert :ok =
             RunIdentityReaper.reconcile(
               identity_name: peer_name,
               active_agent_ids: MapSet.new()
             )
  end

  test "startup reconciliation fails closed for every cleanup boundary" do
    cap = %{id: "cap_stale"}

    base = %{
      lookup: {:ok, ["agent_stale"]},
      list_capabilities: {:ok, [cap]},
      revoke: :ok,
      delete_trust_profile: :ok,
      deregister_identity: :ok
    }

    failures = [
      {:lookup, {:error, :lookup_down}, {:identity_lookup_failed, :lookup_down}},
      {:list_capabilities, {:error, :cap_store_down},
       {"agent_stale", {:capability_lookup_failed, :cap_store_down}}},
      {:revoke, {:error, :revoke_down},
       {"agent_stale", {:capability_revoke_failed, :revoke_down}}},
      {:delete_trust_profile, {:error, :trust_down},
       {"agent_stale", {:trust_profile_delete_failed, :trust_down}}},
      {:deregister_identity, {:error, :registry_down},
       {"agent_stale", {:identity_deregister_failed, :registry_down}}}
    ]

    for {operation, response, expected} <- failures do
      Application.put_env(
        :arbor_scheduler,
        :run_identity_reaper_responses,
        Map.put(base, operation, response)
      )

      assert {:error, ^expected} =
               RunIdentityReaper.reconcile(
                 security_facade: ReaperFacadeStub,
                 trust_facade: ReaperFacadeStub,
                 active_agent_ids: MapSet.new(),
                 identity_name: "scheduler-run:stable-runtime"
               )
    end
  end

  test "reaper child fails scheduler startup closed on reconciliation error" do
    Application.put_env(:arbor_scheduler, :run_identity_reaper_responses, %{
      lookup: {:error, :registry_down},
      list_capabilities: {:ok, []},
      revoke: :ok,
      delete_trust_profile: :ok,
      deregister_identity: :ok
    })

    assert {:error,
            {:run_identity_reconciliation_failed, {:identity_lookup_failed, :registry_down}}} =
             RunIdentityReaper.start_link(
               security_facade: ReaperFacadeStub,
               trust_facade: ReaperFacadeStub
             )
  end

  test "concurrent mints remain isolated", %{issuer: issuer, tmp_dir: tmp_dir} do
    attestation =
      verified_attestation(issuer, tmp_dir, [
        %{resource_uri: "arbor://fs/write/reports/isolation/**", constraints: %{}}
      ])

    {:ok, first} = RunIdentity.mint(attestation)
    {:ok, second} = RunIdentity.mint(attestation)

    refute first.agent_id == second.agent_id
    refute Enum.any?(first.cap_ids, &(&1 in second.cap_ids))

    RunIdentity.revoke(first)
    RunIdentity.revoke(second)
  end

  defp verified_attestation(issuer, tmp_dir, capabilities) do
    path = Path.join(tmp_dir, "run.caps.json")
    source = "digraph Run { start [shape=Mdiamond] }"

    {:ok, payload} =
      CapsFile.build(issuer.agent_id, capabilities,
        pipeline_root: "test",
        pipeline_path: "run.dot",
        graph_hash: sha256(source),
        workdir: Path.expand(tmp_dir),
        initial_args: %{"mode" => "scheduled"}
      )

    signature = Crypto.sign(CapsFile.signing_payload(payload), issuer.private_key)
    File.write!(path, payload |> CapsFile.manifest_map(signature) |> Jason.encode!())

    assert {:ok, attestation} = CapsFile.load(path)
    attestation
  end

  defp fetch_cap!(capability_id) do
    assert {:ok, capability} = CapabilityStore.get(capability_id)
    capability
  end

  defp assert_run_state_removed(agent_id) do
    assert {:error, :not_found} = Security.lookup_public_key(agent_id)
    assert {:ok, []} = Security.list_capabilities(agent_id)
    assert {:error, :not_found} = Trust.get_trust_profile(agent_id)
  end

  defp run_state_removed?(handle) do
    match?({:error, :not_found}, Security.lookup_public_key(handle.agent_id)) and
      match?({:ok, []}, Security.list_capabilities(handle.agent_id)) and
      match?({:error, :not_found}, Trust.get_trust_profile(handle.agent_id))
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp authorize_as(handle, resource) do
    assert {:ok, signed_request} =
             Security.sign_with_authority(handle.signing_authority, resource)

    Security.authorize(handle.agent_id, resource, :execute, signed_request: signed_request)
  end

  defp cleanup_failure_present?(failures, operation) do
    Enum.any?(failures, fn
      {^operation, {:forced_cleanup_failure, ^operation}} -> true
      {{:capability, _cap_id}, {:forced_cleanup_failure, :capability}} -> operation == :capability
      _other -> false
    end)
  end

  defp term_contains?(term, needle) when term == needle, do: true

  defp term_contains?(term, needle) when is_list(term),
    do: Enum.any?(term, &term_contains?(&1, needle))

  defp term_contains?(term, needle) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.any?(&term_contains?(&1, needle))
  end

  defp term_contains?(term, needle) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      term_contains?(key, needle) or term_contains?(value, needle)
    end)
  end

  defp term_contains?(_term, _needle), do: false

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
