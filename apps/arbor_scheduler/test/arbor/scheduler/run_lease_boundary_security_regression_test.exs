defmodule Arbor.Scheduler.RunLeaseBoundarySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004,SSEC-013"

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, RunLease}
  alias Arbor.Scheduler.RunLeaseIdentityFixture
  alias Arbor.Security
  alias Arbor.Trust

  @envelope_uri "arbor://fs/write/reports/**"
  @lobby_uri "arbor://orchestrator/execute"

  setup do
    :ok = RunLeaseIdentityFixture.ensure_started!()
    {:ok, issuer} = Identity.generate()
    :ok = Security.register_identity_fixture(issuer)

    {:ok, envelope} =
      Capability.new(resource_uri: @envelope_uri, principal_id: issuer.agent_id)

    :ok =
      Security.register_issuer_fixture(issuer.agent_id, [envelope], reason: "run_lease_boundary")

    tmp_dir = scratch_dir!("run-lease-boundary")

    on_exit(fn ->
      Security.revoke_issuer_fixture(issuer.agent_id, "test cleanup")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, issuer: issuer, tmp_dir: tmp_dir}
  end

  @tag spec: "SSEC-004,SSEC-013"
  test "security regression: signed capability descriptors form an exact one-shot lease budget",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    resource = "arbor://fs/write/reports/budget/**"
    constraints = %{requires_approval: true}

    attestation =
      verified_attestation(issuer, tmp_dir, [%{resource_uri: resource, constraints: constraints}])

    assert {:ok, lease} = start_lease(attestation)
    assert {:ok, identity} = Security.generate_identity(name: "lease-budget")
    assert :ok = RunLease.register_identity(lease, identity, Security)

    assert {:error, {:grant_failed, ^resource, :lease_capability_binding_denied}} =
             RunLease.grant_capability(
               lease,
               [principal: "agent_not_the_lease", resource: resource, constraints: constraints],
               Security
             )

    assert {:error, {:grant_failed, ^resource, :unsigned_capability_descriptor}} =
             RunLease.grant_capability(
               lease,
               [principal: identity.agent_id, resource: resource, constraints: %{}],
               Security
             )

    unsigned_resource = "arbor://fs/write/reports/unsigned/**"

    assert {:error, {:grant_failed, ^unsigned_resource, :unsigned_capability_descriptor}} =
             RunLease.grant_capability(
               lease,
               [principal: identity.agent_id, resource: unsigned_resource],
               Security
             )

    assert {:error, {:grant_failed, ^resource, :lease_capability_binding_denied}} =
             RunLease.grant_capability(
               lease,
               [
                 principal: identity.agent_id,
                 resource: resource,
                 constraints: constraints,
                 metadata: %{forged: true}
               ],
               Security
             )

    exact = [principal: identity.agent_id, resource: resource, constraints: constraints]
    assert {:ok, _capability} = RunLease.grant_capability(lease, exact, Security)

    assert {:error, {:grant_failed, ^resource, :unsigned_capability_descriptor}} =
             RunLease.grant_capability(lease, exact, Security)

    lobby = [principal: identity.agent_id, resource: @lobby_uri]
    assert {:ok, _lobby_capability} = RunLease.grant_capability(lease, lobby, Security)

    assert {:error, {:grant_failed, @lobby_uri, :unsigned_capability_descriptor}} =
             RunLease.grant_capability(lease, lobby, Security)

    assert :ok = RunLease.revoke(lease)
  end

  test "security regression: lease identity and signing authority are single assignment",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    attestation = verified_attestation(issuer, tmp_dir, [])
    assert {:ok, lease} = start_lease(attestation)
    assert {:ok, identity} = Security.generate_identity(name: "lease-bound")
    assert {:ok, replacement} = Security.generate_identity(name: "lease-replacement")

    assert :ok = RunLease.register_identity(lease, identity, Security)

    assert {:error, {:identity_registration_failed, :lease_identity_already_bound}} =
             RunLease.register_identity(lease, replacement, Security)

    assert {:error, {:authority_open_failed, :lease_authority_binding_denied}} =
             RunLease.open_authority(lease, replacement, Security)

    assert {:ok, authority} = RunLease.open_authority(lease, identity, Security)

    assert {:error, {:authority_open_failed, :lease_authority_already_open}} =
             RunLease.open_authority(lease, identity, Security)

    assert {:ok, _signed} =
             Security.sign_with_authority(authority, "arbor://test/signing/lease-bound")

    assert {:error, :invalid_resource_binding} =
             Security.sign_with_authority(authority, "lease-bound")

    assert :ok = RunLease.revoke(lease)
  end

  test "security regression: lease lifetime and cleanup policy are server bounded",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    attestation = verified_attestation(issuer, tmp_dir, [])

    configured_max =
      Application.get_env(:arbor_scheduler, :run_identity_max_lease_ttl_ms, :timer.hours(24))

    max_ttl =
      if is_integer(configured_max) and configured_max > 0,
        do: configured_max,
        else: :timer.hours(24)

    assert_creation_denied(attestation, ttl_ms: max_ttl + 1)
    assert_creation_denied(attestation, cleanup_max_attempts: 101)
    assert_creation_denied(attestation, cleanup_retry_base_ms: 51, cleanup_retry_max_ms: 50)

    assert_creation_denied(attestation,
      cleanup_reconcile_base_ms: 51,
      cleanup_reconcile_max_ms: 50
    )

    assert_creation_denied(attestation, cleanup_retry_max_ms: :timer.hours(1) + 1)
  end

  test "security regression: public lease creation and authority operations are owner bound",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    resource = "arbor://fs/write/reports/owner-bound/**"

    attestation =
      verified_attestation(issuer, tmp_dir, [%{resource_uri: resource, constraints: %{}}])

    victim = self()

    assert {:error, :unauthorized} =
             Task.async(fn ->
               RunLease.start(victim, attestation,
                 ttl_ms: 30_000,
                 security_facade: Security,
                 trust_facade: Trust
               )
             end)
             |> Task.await()

    assert {:ok, lease} = start_lease(attestation)
    assert {:ok, identity} = Security.generate_identity(name: "public-owner-bound")

    assert {:error, :unauthorized} =
             Task.async(fn -> RunLease.register_identity(lease, identity, Security) end)
             |> Task.await()

    assert :ok = RunLease.register_identity(lease, identity, Security)

    exact = [principal: identity.agent_id, resource: resource, constraints: %{}]

    assert {:error, :unauthorized} =
             Task.async(fn -> RunLease.grant_capability(lease, exact, Security) end)
             |> Task.await()

    assert {:error, :unauthorized} =
             Task.async(fn -> RunLease.open_authority(lease, identity, Security) end)
             |> Task.await()

    assert {:ok, _capability} = RunLease.grant_capability(lease, exact, Security)
    assert {:ok, authority} = RunLease.open_authority(lease, identity, Security)

    assert {:ok, _signed} =
             Security.sign_with_authority(authority, "arbor://test/signing/public-owner-bound")

    assert :ok = RunLease.revoke(lease)
  end

  test "security regression: an owner-created Store record cannot mint authority without a lease worker",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    resource = "arbor://fs/write/reports/no-worker/**"

    attestation =
      verified_attestation(issuer, tmp_dir, [%{resource_uri: resource, constraints: %{}}])

    lease = "lease_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    assert {:ok, _creation_token} =
             RunLease.Store.create(lease, self(), attestation,
               ttl_ms: 50,
               security_facade: Security,
               trust_facade: Trust
             )

    assert {:ok, identity} = Security.generate_identity(name: "unstarted-lease")

    assert {:error, :lease_closing} =
             RunLease.Store.register_identity(lease, identity, Security)

    assert {:error, :lease_closing} = RunLease.register_identity(lease, identity, Security)

    assert {:error, :lease_closing} =
             RunLease.grant_capability(
               lease,
               [principal: identity.agent_id, resource: resource],
               Security
             )

    assert {:error, :lease_closing} = RunLease.open_authority(lease, identity, Security)
    assert_eventually(fn -> RunLease.Store.exists?(lease) == false end)
    assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)
  end

  test "security regression: a missing lease worker cannot be used as an owner-side Store deputy",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    resource = "arbor://fs/write/reports/stopped-worker/**"

    attestation =
      verified_attestation(issuer, tmp_dir, [%{resource_uri: resource, constraints: %{}}])

    assert {:ok, lease} = start_lease(attestation)
    assert {:ok, identity} = Security.generate_identity(name: "stopped-worker")
    assert :ok = RunLease.register_identity(lease, identity, Security)

    assert {:ok, capability} =
             RunLease.grant_capability(
               lease,
               [principal: identity.agent_id, resource: resource],
               Security
             )

    assert {:ok, authority} = RunLease.open_authority(lease, identity, Security)
    worker = RunLease.whereis(lease)
    assert :ok = DynamicSupervisor.terminate_child(RunLease.DynamicSupervisor, worker)
    assert_eventually(fn -> is_nil(RunLease.whereis(lease)) end)

    assert {:error, :lease_closing} =
             RunLease.Store.grant_capability(
               lease,
               [principal: identity.agent_id, resource: resource],
               Security
             )

    assert {:error, :lease_closing} = RunLease.register_identity(lease, identity, Security)
    assert :ok = RunLease.revoke(lease)

    assert_eventually(fn ->
      match?({:error, _reason}, Security.get_capability_fixture(capability.id)) and
        match?({:error, :not_found}, Security.lookup_public_key(identity.agent_id))
    end)

    assert {:error, :authority_not_found} =
             Security.sign_with_authority(
               authority,
               "arbor://test/signing/stopped-worker-cleaned"
             )
  end

  test "security regression: raw internal calls and messages cannot mutate a lease or restart owners",
       %{issuer: issuer, tmp_dir: tmp_dir} do
    attestation = verified_attestation(issuer, tmp_dir, [])
    assert {:ok, lease} = start_lease(attestation)
    assert {:ok, identity} = Security.generate_identity(name: "raw-boundary")

    worker = RunLease.whereis(lease)
    reconciler = Process.whereis(RunLease.Reconciler)
    store = Process.whereis(RunLease.Store)

    assert is_pid(worker)
    assert is_pid(reconciler)
    assert is_pid(store)

    outsider_result = Task.async(fn -> RunLease.revoke(lease) end) |> Task.await()
    assert {:error, :unauthorized} = outsider_result
    assert RunLease.whereis(lease) == worker
    assert RunLease.Store.exists?(lease)

    assert {:error, :unauthorized} = GenServer.call(worker, :revoke)
    GenServer.cast(worker, :revoke)
    send(worker, :expire)
    send(worker, :cleanup)
    send(worker, {:expire, make_ref()})
    send(worker, {:cleanup, make_ref()})

    assert {:error, :unauthorized} =
             GenServer.call(RunLease.Store, {:register_identity, lease, identity, Security})

    assert {:error, :unauthorized} =
             forged_call(RunLease.Store, reconciler, :begin_recovery)

    assert {:error, :unauthorized} =
             forged_call(RunLease.StateOwner, store, {:fetch, lease})

    assert {:error, :unauthorized} =
             forged_call(
               RunLease.JournalOwner,
               Process.whereis(RunLease.StateOwner),
               {:fetch, lease}
             )

    assert {:error, :unauthorized} = GenServer.call(reconciler, :force_recovery)
    GenServer.cast(reconciler, :force_recovery)
    send(reconciler, {:reconcile, make_ref()})
    Process.sleep(50)

    assert Process.whereis(RunLease.Reconciler) == reconciler
    assert RunLease.whereis(lease) == worker
    assert Process.alive?(worker)
    assert RunLease.Store.exists?(lease)
    assert :ok = RunLease.revoke(lease)
  end

  test "security regression: a public Registry claimant is not a run lease process" do
    lease = "lease_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    parent = self()

    claimant =
      spawn(fn ->
        {:ok, _registration} = Registry.register(RunLease.Registry, lease, :claimant)
        send(parent, {:registry_claimed, self()})
        registry_claimant_loop(parent)
      end)

    on_exit(fn -> Process.exit(claimant, :kill) end)
    assert_receive {:registry_claimed, ^claimant}, 1_000

    assert {:error, _reason} =
             RunLease.authorize_routine_effect(
               %{lease: lease, token: token},
               %{resource_uri: "arbor://fs/write/reports/stolen"}
             )

    refute_receive {:registry_claimant_intercepted, _message}, 100
  end

  defp start_lease(attestation, overrides \\ []) do
    Code.ensure_loaded!(RunLease)

    opts =
      Keyword.merge(
        [ttl_ms: 30_000, security_facade: Security, trust_facade: Trust],
        overrides
      )

    if function_exported?(RunLease, :start, 3) do
      RunLease.start(self(), attestation, opts)
    else
      RunLease.start(self(), opts)
    end
  end

  defp assert_creation_denied(attestation, overrides) do
    assert {:error, {:lease_admission_denied, :invalid_lease_options}} =
             start_lease(attestation, overrides)
  end

  defp verified_attestation(issuer, tmp_dir, capabilities) do
    path = Path.join(tmp_dir, "boundary.caps.json")
    source = "digraph Boundary { start [shape=Mdiamond] }"

    {:ok, payload} =
      CapsFile.build(issuer.agent_id, capabilities,
        pipeline_root: "boundary",
        pipeline_path: "boundary.dot",
        graph_hash: sha256(source),
        workdir: Path.expand(tmp_dir),
        initial_args: %{"mode" => "scheduled"}
      )

    signature =
      Security.sign_ed25519_fixture(CapsFile.signing_payload(payload), issuer.private_key)

    File.write!(path, payload |> CapsFile.manifest_map(signature) |> Jason.encode!())
    assert {:ok, attestation} = CapsFile.load(path)
    attestation
  end

  defp forged_call(server, claimed_caller, request) do
    test = self()

    spawn(fn ->
      reply_alias = :erlang.alias()
      send(server, {:"$gen_call", {claimed_caller, [:alias | reply_alias]}, request})

      receive do
        {[:alias | ^reply_alias], reply} -> send(test, {:forged_reply, reply})
      after
        5_000 -> send(test, {:forged_reply, :timeout})
      end
    end)

    assert_receive {:forged_reply, reply}, 6_000
    reply
  end

  defp registry_claimant_loop(test) do
    receive do
      :stop ->
        :ok

      {:"$gen_call", from, _request} = message ->
        GenServer.reply(from, :ok)
        send(test, {:registry_claimant_intercepted, message})
        registry_claimant_loop(test)

      message ->
        send(test, {:registry_claimant_intercepted, message})
        registry_claimant_loop(test)
    end
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

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp scratch_dir!(prefix) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "#{prefix}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
