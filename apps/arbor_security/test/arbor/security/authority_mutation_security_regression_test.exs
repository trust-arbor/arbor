defmodule Arbor.Security.AuthorityMutationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004,SSEC-013"

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity, InvocationReceipt, SignedRequest}
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.InvocationReceiptBroker
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.SystemAuthority

  @tag spec: "SSEC-004,SSEC-013"
  test "security regression: unauthenticated grant and acknowledged grant fail closed" do
    principal = "agent_" <> String.duplicate("a", 64)

    assert {:error, :capability_mutation_unauthorized} =
             Security.grant(
               principal: principal,
               resource: "arbor://fs/read/security-regression"
             )

    assert {:error, :capability_mutation_unauthorized} =
             Security.acknowledged_grant(
               capability_id: "cap_" <> String.duplicate("b", 32),
               granted_at: DateTime.utc_now() |> DateTime.truncate(:second),
               principal: principal,
               resource: "arbor://fs/read/security-regression"
             )
  end

  test "security regression: role assignment cannot mint admin authority without an actor" do
    principal = "agent_" <> String.duplicate("c", 64)

    assert {:error, :capability_mutation_unauthorized} =
             Security.assign_role(principal, :admin)
  end

  test "security regression: direct system authority signing and rotation are denied" do
    {:ok, cap} =
      Capability.new(
        principal_id: "agent_" <> String.duplicate("d", 64),
        resource_uri: "arbor://fs/read/security-regression"
      )

    assert {:error, :capability_signing_unauthorized} =
             SystemAuthority.sign_capability(cap)

    assert {:error, :authority_rotation_unauthorized} = SystemAuthority.rotate()
  end

  test "security regression: forged supervised caller PIDs cannot invoke root signing oracles" do
    {:ok, cap} =
      Capability.new(
        principal_id: "agent_" <> String.duplicate("1", 64),
        resource_uri: "arbor://fs/read/raw-root-signing"
      )

    {:ok, receipt} =
      InvocationReceipt.new(
        capability_id: cap.id,
        principal_id: cap.principal_id,
        resource_uri: cap.resource_uri,
        action: :read,
        result: :granted
      )

    root = Process.whereis(SystemAuthority)
    capability_store = Process.whereis(Arbor.Security.CapabilityStore)
    receipt_broker = Process.whereis(InvocationReceiptBroker)

    assert is_pid(root)
    assert is_pid(capability_store)
    assert is_pid(receipt_broker)

    assert {:error, :system_authority_unauthorized} =
             forged_call(root, capability_store, {:sign_capability_from_store, cap})

    assert {:error, :system_authority_unauthorized} =
             forged_call(root, receipt_broker, {:sign_receipt_from_broker, receipt})
  end

  test "security regression: forged root PID cannot register an attacker identity" do
    {:ok, attacker} = Identity.generate(name: "forged-root-identity-registration")
    {:ok, proof} = Registry.registration_proof(attacker)
    registry = Process.whereis(Registry)
    root = Process.whereis(SystemAuthority)

    assert is_pid(registry)
    assert is_pid(root)

    on_exit(fn ->
      _ = Security.deregister_identity_fixture(attacker.agent_id)
    end)

    assert {:error, :identity_registration_unauthorized} =
             forged_call(
               registry,
               root,
               {:register_system_authority, Identity.public_only(attacker), proof, make_ref()}
             )

    assert {:error, :not_found} = Registry.lookup(attacker.agent_id)
  end

  test "security regression: an attacker process cannot mint invocation receipts or endorsements" do
    {:ok, target} = Identity.generate(name: "forged-endorsement-target")
    :ok = Registry.register_fixture(target)

    {:ok, receipt} =
      InvocationReceipt.new(
        capability_id: "cap_" <> String.duplicate("e", 32),
        principal_id: target.agent_id,
        resource_uri: "arbor://fs/read/forged-receipt",
        action: :read,
        result: :granted
      )

    task =
      Task.async(fn ->
        {
          SystemAuthority.sign_receipt(receipt),
          SystemAuthority.endorse_agent(target),
          Security.endorse_agent(target)
        }
      end)

    assert {
             {:error, :receipt_signing_unauthorized},
             {:error, :identity_endorsement_unauthorized},
             {:error, :identity_endorsement_unauthorized}
           } = Task.await(task)
  end

  test "security regression: direct invocation broker calls cannot mint granted evidence" do
    previous = Application.get_env(:arbor_security, :invocation_receipts_enabled, :__absent__)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, true)

    {:ok, identity} = Identity.generate(name: "invocation-receipt-deputy-regression")
    :ok = Registry.register_fixture(identity)
    resource = "arbor://fs/read/invocation-receipt-deputy-regression"

    assert {:ok, capability} =
             Security.grant_fixture(principal: identity.agent_id, resource: resource)

    on_exit(fn ->
      _ = Security.revoke_fixture(capability.id)
      _ = Security.deregister_identity_fixture(identity.agent_id)

      if previous == :__absent__ do
        Application.delete_env(:arbor_security, :invocation_receipts_enabled)
      else
        Application.put_env(:arbor_security, :invocation_receipts_enabled, previous)
      end
    end)

    assert {:error, :receipt_issuance_unauthorized} =
             InvocationReceiptBroker.issue(capability, identity.agent_id, resource, :read)

    assert {:error, :receipt_issuance_unauthorized} =
             GenServer.call(
               InvocationReceiptBroker,
               {:issue, capability, identity.agent_id, resource, :read}
             )

    test_pid = self()

    assert {:ok, :authorized} =
             Security.authorize(identity.agent_id, resource, :read,
               verify_identity: false,
               receipt_callback: fn receipt -> send(test_pid, {:invocation_receipt, receipt}) end
             )

    assert_receive {:invocation_receipt, %InvocationReceipt{} = receipt}, 1_000
    assert receipt.result == :granted
    assert :ok = InvocationReceipt.verify(receipt, SystemAuthority.public_key())
  end

  test "security regression: registered-name takeover cannot impersonate the receipt broker" do
    {:ok, target} = Identity.generate(name: "receipt-broker-name-takeover")

    {:ok, receipt} =
      InvocationReceipt.new(
        capability_id: "cap_" <> String.duplicate("f", 32),
        principal_id: target.agent_id,
        resource_uri: "arbor://fs/read/name-takeover",
        action: :read,
        result: :granted
      )

    real_broker = Process.whereis(InvocationReceiptBroker)
    assert is_pid(real_broker)
    assert Process.unregister(InvocationReceiptBroker)

    try do
      attacker =
        Task.async(fn ->
          true = Process.register(self(), InvocationReceiptBroker)
          SystemAuthority.sign_receipt_from_broker(receipt)
        end)

      assert {:error, :receipt_signing_unauthorized} = Task.await(attacker)
    after
      if squatter = Process.whereis(InvocationReceiptBroker) do
        Process.unregister(InvocationReceiptBroker)
        if squatter != self() and Process.alive?(squatter), do: Process.exit(squatter, :kill)
      end

      if Process.alive?(real_broker), do: Process.register(real_broker, InvocationReceiptBroker)
    end
  end

  test "security regression: registered-name takeover cannot impersonate SystemAuthority" do
    {:ok, actor} = Identity.generate(name: "system-authority-name-takeover")
    {:ok, target} = Identity.generate(name: "system-authority-name-takeover-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)
    {:ok, authority} = open_authority(actor)

    real_authority = Process.whereis(SystemAuthority)
    assert is_pid(real_authority)
    assert Process.unregister(SystemAuthority)

    test_pid = self()

    squatter =
      spawn(fn ->
        true = Process.register(self(), SystemAuthority)
        send(test_pid, :system_authority_squatter_ready)
        fake_system_authority_loop()
      end)

    assert_receive :system_authority_squatter_ready

    try do
      assert {:error, :capability_mutation_unauthorized} =
               Security.grant(
                 principal: target.agent_id,
                 resource: "arbor://fs/read/name-takeover",
                 actor_authority: authority
               )
    after
      if Process.whereis(SystemAuthority) == squatter do
        Process.unregister(SystemAuthority)
      end

      if Process.alive?(squatter), do: Process.exit(squatter, :kill)
      if Process.alive?(real_authority), do: Process.register(real_authority, SystemAuthority)
      Security.close_signing_authority(authority)
    end
  end

  test "security regression: target key possession alone cannot enroll an identity" do
    {:ok, identity} = Identity.generate(name: "unauthorized-registration")

    assert {:error, :identity_registration_unauthorized} =
             Security.register_identity(identity)

    assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)
  end

  test "security regression: identity status mutations require an authenticated actor" do
    {:ok, active} = Identity.generate(name: "status-active-target")
    {:ok, suspended} = Identity.generate(name: "status-suspended-target")
    :ok = Registry.register_fixture(active)
    :ok = Registry.register_fixture(suspended)
    :ok = Registry.suspend_fixture(suspended.agent_id, "fixture")

    assert {:error, :identity_status_mutation_unauthorized} =
             Security.deregister_identity(active.agent_id)

    assert {:error, :identity_status_mutation_unauthorized} =
             Security.suspend_identity(active.agent_id, reason: "attacker")

    assert {:error, :identity_status_mutation_unauthorized} =
             Security.resume_identity(suspended.agent_id)

    assert {:error, :identity_status_mutation_unauthorized} =
             Security.revoke_identity(active.agent_id, reason: "attacker")

    assert {:ok, :active} = Security.identity_status(active.agent_id)
    assert {:ok, :suspended} = Security.identity_status(suspended.agent_id)
  end

  test "authorized identity status receipts are target-bound and revoke capabilities" do
    {:ok, actor} = Identity.generate(name: "status-authority-actor")
    {:ok, lifecycle_target} = Identity.generate(name: "status-lifecycle-target")
    {:ok, revoke_target} = Identity.generate(name: "status-revoke-target")
    {:ok, deregister_target} = Identity.generate(name: "status-deregister-target")

    for identity <- [actor, lifecycle_target, revoke_target, deregister_target] do
      :ok = Registry.register_fixture(identity)
    end

    resources = [
      "arbor://security/identity/suspend/#{lifecycle_target.agent_id}",
      "arbor://security/identity/resume/#{lifecycle_target.agent_id}",
      "arbor://security/identity/revoke/#{revoke_target.agent_id}",
      "arbor://security/revoke/#{revoke_target.agent_id}",
      "arbor://security/identity/deregister/#{deregister_target.agent_id}"
    ]

    Enum.each(resources, fn resource ->
      assert {:ok, _capability} =
               Security.grant_fixture(principal: actor.agent_id, resource: resource)
    end)

    assert {:ok, held} =
             Security.grant_fixture(
               principal: revoke_target.agent_id,
               resource: "arbor://fs/read/status-regression"
             )

    {:ok, authority} = open_authority(actor)
    on_exit(fn -> Security.close_signing_authority(authority) end)

    assert :ok =
             Security.suspend_identity(lifecycle_target.agent_id,
               reason: "security regression",
               actor_authority: authority
             )

    assert {:ok, :suspended} = Security.identity_status(lifecycle_target.agent_id)

    assert :ok =
             Security.resume_identity(lifecycle_target.agent_id,
               actor_authority: authority
             )

    assert {:ok, :active} = Security.identity_status(lifecycle_target.agent_id)

    assert :ok =
             Security.revoke_identity(revoke_target.agent_id,
               reason: "security regression",
               actor_authority: authority
             )

    assert {:ok, :revoked} = Security.identity_status(revoke_target.agent_id)
    assert {:ok, capabilities} = Security.list_capabilities(revoke_target.agent_id)
    refute Enum.any?(capabilities, &(&1.id == held.id))

    assert :ok =
             Security.deregister_identity(deregister_target.agent_id,
               actor_authority: authority
             )

    assert {:error, :not_found} = Security.lookup_public_key(deregister_target.agent_id)
  end

  test "authorized actor can enroll, grant, assign a role, and revoke with signed attribution" do
    {:ok, actor} = Identity.generate(name: "authorized-security-actor")
    {:ok, target} = Identity.generate(name: "authorized-registration-target")
    :ok = Registry.register_fixture(actor)

    {:ok, _} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/identity/register"
      )

    {:ok, _} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/grant/#{target.agent_id}"
      )

    {:ok, _} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/revoke/#{target.agent_id}"
      )

    {:ok, _} =
      Security.grant_fixture(
        principal: actor.agent_id,
        resource: "arbor://security/identity/endorse/#{target.agent_id}"
      )

    {:ok, authority} = open_authority(actor)

    assert :ok = Security.register_identity(target, authority)
    assert {:ok, endorsement} = Security.endorse_agent(target, authority)
    assert endorsement.agent_id == target.agent_id

    assert {:ok, granted} =
             Security.grant(
               principal: target.agent_id,
               resource: "arbor://fs/read/authorized-security-regression",
               actor_authority: authority
             )

    assert granted.metadata["granter_id"] == actor.agent_id

    assert {:ok, role_caps} =
             Security.assign_role(target.agent_id, :viewer, actor_authority: authority)

    assert role_caps != []
    assert Enum.all?(role_caps, &(&1.metadata["granter_id"] == actor.agent_id))
    assert :ok = Security.revoke(granted.id, actor_authority: authority)
  end

  test "security regression: an owned authority without mutation capability cannot grant or revoke" do
    {:ok, actor} = Identity.generate(name: "unprivileged-security-actor")
    {:ok, target} = Identity.generate(name: "unprivileged-security-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)
    {:ok, authority} = open_authority(actor)

    assert {:error, :capability_mutation_unauthorized} =
             Security.grant(
               principal: target.agent_id,
               resource: "arbor://fs/read/unauthorized-security-regression",
               actor_authority: authority
             )

    {:ok, existing} =
      Security.grant_fixture(
        principal: target.agent_id,
        resource: "arbor://fs/read/revocation-security-regression"
      )

    assert {:error, :capability_revocation_unauthorized} =
             Security.revoke(existing.id, actor_authority: authority)
  end

  test "security regression: an exact signed mutation request is bound and one-use" do
    {:ok, actor} = Identity.generate(name: "signed-mutation-security-actor")
    {:ok, target} = Identity.generate(name: "signed-mutation-security-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)

    on_exit(fn ->
      Security.deregister_identity_fixture(actor.agent_id)
      Security.deregister_identity_fixture(target.agent_id)
    end)

    assert {:ok, _mutation_capability} =
             Security.grant_fixture(
               principal: actor.agent_id,
               resource: "arbor://security/grant/#{target.agent_id}"
             )

    assert {:ok, unsigned} =
             Capability.new(
               principal_id: target.agent_id,
               resource_uri: "arbor://fs/read/signed-mutation-regression",
               metadata: %{"granter_id" => actor.agent_id}
             )

    assert {:ok, payload} =
             SystemAuthority.capability_mutation_request_payload(:grant, unsigned)

    assert {:ok, actor_proof} = SignedRequest.sign(payload, actor.agent_id, actor.private_key)

    assert {:ok, capability} =
             Security.submit_signed_capability_grant(unsigned, actor_proof)

    assert capability.metadata["granter_id"] == actor.agent_id
    assert {:ok, capabilities} = Security.list_capabilities(target.agent_id)
    assert stored = Enum.find(capabilities, &(&1.id == capability.id))
    assert stored.metadata["granter_id"] == actor.agent_id

    assert {:ok, tampered} =
             Capability.new(
               principal_id: target.agent_id,
               resource_uri: "arbor://fs/write/signed-mutation-regression",
               metadata: %{"granter_id" => actor.agent_id}
             )

    assert {:ok, binding_proof} = SignedRequest.sign(payload, actor.agent_id, actor.private_key)

    assert {:error, :capability_mutation_unauthorized} =
             Security.submit_signed_capability_grant(tampered, binding_proof)

    assert {:error, :capability_mutation_unauthorized} =
             Security.submit_signed_capability_grant(unsigned, actor_proof)
  end

  test "security regression: an exact signed issuer request is bound and one-use" do
    {:ok, actor} = Identity.generate(name: "signed-issuer-mutation-actor")
    {:ok, issuer} = Identity.generate(name: "signed-issuer-mutation-target")
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(issuer)

    on_exit(fn ->
      IssuerRegistry.revoke_fixture(issuer.agent_id, "security regression cleanup")
      Security.deregister_identity_fixture(actor.agent_id)
      Security.deregister_identity_fixture(issuer.agent_id)
    end)

    assert {:ok, _mutation_capability} =
             Security.grant_fixture(
               principal: actor.agent_id,
               resource: "arbor://security/issuer/register"
             )

    assert {:ok, envelope} =
             Capability.new(
               principal_id: issuer.agent_id,
               resource_uri: "arbor://fs/read/signed-issuer-regression/**"
             )

    mutation_opts = [reason: "security regression"]

    assert {:ok, digest} =
             Security.issuer_mutation_payload_digest(
               :register,
               issuer.agent_id,
               [envelope],
               mutation_opts
             )

    assert {:ok, payload} = SystemAuthority.issuer_mutation_request_payload(:register, digest)
    assert {:ok, actor_proof} = SignedRequest.sign(payload, actor.agent_id, actor.private_key)

    assert :ok =
             Security.register_issuer(
               issuer.agent_id,
               [envelope],
               mutation_opts ++ [actor_proof: actor_proof]
             )

    assert {:ok, %{public_key: public_key}} = IssuerRegistry.lookup(issuer.agent_id)
    assert public_key == issuer.public_key

    assert {:error, :issuer_mutation_unauthorized} =
             Security.register_issuer(
               issuer.agent_id,
               [envelope],
               mutation_opts ++ [actor_proof: actor_proof]
             )

    assert {:ok, second_issuer} = Identity.generate(name: "signed-issuer-binding-target")
    :ok = Registry.register_fixture(second_issuer)

    on_exit(fn -> Security.deregister_identity_fixture(second_issuer.agent_id) end)

    assert {:ok, binding_proof} = SignedRequest.sign(payload, actor.agent_id, actor.private_key)

    assert {:error, :issuer_mutation_unauthorized} =
             Security.register_issuer(
               second_issuer.agent_id,
               [envelope],
               mutation_opts ++ [actor_proof: binding_proof]
             )

    assert {:error, :not_found} = IssuerRegistry.lookup(second_issuer.agent_id)
  end

  test "security regression: supervisor-name loss does not authorize nominated key paths" do
    {:ok, actor} = Identity.generate(name: "caller-opened-key-file")
    actor_id = actor.agent_id
    path = Path.join(scratch_dir!("arbor-offline-key"), "operator.key")
    {:ok, ^path} = Security.write_key_file(path, actor)
    supervisor = Process.whereis(Arbor.Security.Supervisor)
    assert is_pid(supervisor)
    assert Process.unregister(Arbor.Security.Supervisor)

    try do
      assert {:error, :key_file_signing_authority_required} =
               Security.sign_key_file_request(path, "security-regression")

      assert {:error, :capability_mutation_unauthorized} =
               Security.prepare_key_file_capability_grant(path,
                 principal: actor.agent_id,
                 resource: "arbor://fs/read/offline-regression"
               )

      assert {:error, :issuer_mutation_unauthorized} =
               Security.prepare_key_file_issuer_mutation(
                 path,
                 :register,
                 String.duplicate("a", 64)
               )

      {:ok, io_device} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

      try do
        assert {:ok, ^actor_id, %SignedRequest{}} =
                 Security.sign_key_file_request(io_device, "security-regression")

        assert {:ok, %Capability{}, %SignedRequest{}} =
                 Security.prepare_key_file_capability_grant(io_device,
                   principal: actor.agent_id,
                   resource: "arbor://fs/read/offline-regression"
                 )

        assert {:ok, ^actor_id, %SignedRequest{}} =
                 Security.prepare_key_file_issuer_mutation(
                   io_device,
                   :register,
                   String.duplicate("a", 64)
                 )
      after
        :file.close(io_device)
      end
    after
      if Process.whereis(Arbor.Security.Supervisor) == nil and Process.alive?(supervisor),
        do: Process.register(supervisor, Arbor.Security.Supervisor)

      File.rm(path)
    end
  end

  defp open_authority(identity) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :authority_mutation_security_regression
           ) do
      Security.open_ephemeral_signing_authority(proof, identity.private_key)
    end
  end

  defp fake_system_authority_loop do
    receive do
      {:"$gen_call", {from, tag}, {:authorize_capability_mutation, _authority, _operation, cap}} ->
        send(from, {tag, {:ok, cap, %{token: "forged"}}})
        fake_system_authority_loop()

      {:"$gen_call", {from, tag}, {:sign_capability_from_store, cap}} ->
        send(from, {tag, {:ok, cap}})
        fake_system_authority_loop()

      {:"$gen_call", {from, tag}, _request} ->
        send(from, {tag, :ok})
        fake_system_authority_loop()

      _other ->
        fake_system_authority_loop()
    end
  end

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged SystemAuthority call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

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
