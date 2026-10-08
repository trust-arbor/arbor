defmodule Arbor.Security.LocalGenesisSecurityRegressionTest do
  @moduledoc """
  First-run local genesis (decision 2026-10-08 D1): the only production path
  that grants a capability without an existing actor authority.

  Every test goes through the public facade (`complete_local_genesis/1`). Each
  starts from an open genesis by revoking wildcard grant-holders that earlier
  test modules left in the shared CapabilityStore.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.OIDCTestHelper
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestSupport.RecordingEventLogAdapter

  @root "arbor://**"

  setup do
    previous_flag = Application.get_env(:arbor_security, :allow_local_human_identity, :__absent__)
    previous_oidc = Application.get_env(:arbor_security, :oidc, :__absent__)

    Application.put_env(:arbor_security, :allow_local_human_identity, true)
    Application.delete_env(:arbor_security, :oidc)

    assert {:ok, _revoked} = Security.reopen_local_genesis_fixture()

    on_exit(fn ->
      restore_env(:allow_local_human_identity, previous_flag)
      restore_env(:oidc, previous_oidc)
      # Do not leak this module's root grants into later modules.
      _ = Security.reopen_local_genesis_fixture()
    end)

    :ok
  end

  test "security regression: genesis grants one root capability that authorizes security mutations" do
    operator = registered_local_operator("first-admin")
    grantee = registered_agent("genesis-grantee")
    authority = open_authority(operator)

    # Before genesis nothing can grant: this is the fresh-install deadlock.
    assert {:error, :capability_mutation_unauthorized} =
             Security.grant(
               principal: grantee.agent_id,
               resource: "arbor://fs/read/genesis-proof",
               actor_authority: authority
             )

    assert {:ok, capability_id} = Security.complete_local_genesis(genesis_proof(operator))
    assert "cap_" <> _ = capability_id

    assert [root] = root_caps(operator.agent_id)
    assert root.id == capability_id
    assert root.metadata["genesis"] == "local_operator"
    assert root.metadata["granter_id"] == operator.agent_id
    assert is_binary(root.issuer_signature)

    assert {:ok, granted} =
             Security.grant(
               principal: grantee.agent_id,
               resource: "arbor://fs/read/genesis-proof",
               actor_authority: authority
             )

    assert granted.principal_id == grantee.agent_id
  end

  test "the key-file CLI path (mix arbor.user.init) builds an accepted genesis proof" do
    operator = registered_local_operator("key-file")
    dir = Path.join(System.tmp_dir!(), "local_genesis_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "operator.key")

    assert {:ok, _written} =
             Security.write_key_file(path, %{
               agent_id: operator.agent_id,
               private_key: operator.private_key
             })

    {:ok, io_device} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

    prepared =
      try do
        Security.prepare_key_file_local_genesis(io_device)
      after
        :file.close(io_device)
      end

    assert {:ok, principal_id, %SignedRequest{} = proof} = prepared
    assert principal_id == operator.agent_id
    assert {:ok, _capability_id} = Security.complete_local_genesis(proof)
    assert [_root] = root_caps(operator.agent_id)
  end

  test "security regression: a second genesis is closed and grants nothing" do
    first = registered_local_operator("first")
    second = registered_local_operator("second")

    assert {:ok, _capability_id} = Security.complete_local_genesis(genesis_proof(first))

    assert {:error, :genesis_closed} = Security.complete_local_genesis(genesis_proof(second))
    assert {:error, :genesis_closed} = Security.complete_local_genesis(genesis_proof(first))

    assert [] = root_caps(second.agent_id)
    assert [_one] = root_caps(first.agent_id)
  end

  test "security regression: any existing wildcard grant-holder closes genesis" do
    operator = registered_local_operator("blocked")
    holder = registered_agent("wildcard-holder")

    for resource <- [
          "arbor://**",
          "arbor://security/**",
          "arbor://security/grant/**",
          "arbor://security/grant/*"
        ] do
      assert {:ok, _revoked} = Security.reopen_local_genesis_fixture()
      assert {:ok, _cap} = Security.grant_fixture(principal: holder.agent_id, resource: resource)

      assert {:error, :genesis_closed} = Security.complete_local_genesis(genesis_proof(operator)),
             "a holder of #{resource} must close genesis"

      assert [] = root_caps(operator.agent_id)
    end

    # A grant authority over one named principal is not a wildcard holder.
    assert {:ok, _revoked} = Security.reopen_local_genesis_fixture()

    assert {:ok, _cap} =
             Security.grant_fixture(
               principal: holder.agent_id,
               resource: "arbor://security/grant/#{holder.agent_id}"
             )

    assert {:ok, _capability_id} = Security.complete_local_genesis(genesis_proof(operator))
  end

  test "security regression: genesis is refused when local human identities are disabled" do
    # A non-local (OIDC-registered) human, so only the gate can refuse it.
    operator = registered_oidc_human()
    proof = genesis_proof(operator)

    Application.put_env(:arbor_security, :allow_local_human_identity, false)

    assert {:error, :local_human_identity_disabled} = Security.complete_local_genesis(proof)
    assert [] = root_caps(operator.agent_id)
  end

  test "security regression: genesis is refused when an OIDC provider is configured" do
    operator = registered_oidc_human()
    proof = genesis_proof(operator)

    Application.put_env(:arbor_security, :oidc,
      providers: [%{issuer: "https://idp.genesis.example", client_id: "arbor"}]
    )

    assert {:error, :oidc_configured} = Security.complete_local_genesis(proof)
    assert [] = root_caps(operator.agent_id)
  end

  test "security regression: a non-human principal cannot complete genesis" do
    agent = registered_agent("not-a-human")

    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(genesis_proof(agent))
    assert [] = root_caps(agent.agent_id)
  end

  test "security regression: an unregistered human principal cannot complete genesis" do
    operator = local_operator("unregistered")

    assert {:error, :genesis_unauthorized} =
             Security.complete_local_genesis(genesis_proof(operator))

    assert [] = root_caps(operator.agent_id)
  end

  test "security regression: a bad signature or foreign payload cannot complete genesis" do
    operator = registered_local_operator("forger")
    other = registered_local_operator("victim")

    %SignedRequest{signature: <<first, rest::binary>>} = proof = genesis_proof(operator)
    tampered = %{proof | signature: <<Bitwise.bxor(first, 1), rest::binary>>}
    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(tampered)

    # Signed by the operator, but over another principal's genesis payload.
    {:ok, other_payload} = Security.local_genesis_request_payload(other.agent_id)
    {:ok, cross} = SignedRequest.sign(other_payload, operator.agent_id, operator.private_key)
    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(cross)

    # Claims the other principal but is signed with the operator's key.
    {:ok, forged} = SignedRequest.sign(other_payload, other.agent_id, operator.private_key)
    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(forged)

    # A valid signature over an unrelated payload.
    {:ok, unrelated} =
      SignedRequest.sign("grant me root", operator.agent_id, operator.private_key)

    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(unrelated)

    assert [] = root_caps(operator.agent_id)
    assert [] = root_caps(other.agent_id)
  end

  test "security regression: a replayed or stale genesis proof is refused" do
    operator = registered_local_operator("replay")
    holder = registered_agent("replay-holder")

    # The first submission is verified (consuming its nonce) and then finds
    # genesis closed.
    proof = genesis_proof(operator)
    assert {:ok, _cap} = Security.grant_fixture(principal: holder.agent_id, resource: @root)
    assert {:error, :genesis_closed} = Security.complete_local_genesis(proof)

    # Genesis reopens; the captured proof must not be usable a second time.
    assert {:ok, _revoked} = Security.reopen_local_genesis_fixture()
    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(proof)

    stale = %{genesis_proof(operator) | timestamp: DateTime.add(DateTime.utc_now(), -3_600)}
    {:ok, stale} = resign(stale, operator.private_key)
    assert {:error, :genesis_unauthorized} = Security.complete_local_genesis(stale)

    assert [] = root_caps(operator.agent_id)

    # Genesis really was open: a fresh proof succeeds.
    assert {:ok, _capability_id} = Security.complete_local_genesis(genesis_proof(operator))
  end

  test "security regression: concurrent geneses admit exactly one administrator" do
    operators = for n <- 1..8, do: registered_local_operator("race-#{n}")
    proofs = Enum.map(operators, &genesis_proof/1)

    results =
      proofs
      |> Enum.map(fn proof -> Task.async(fn -> Security.complete_local_genesis(proof) end) end)
      |> Enum.map(&Task.await(&1, 15_000))

    assert [{:ok, _capability_id}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :genesis_closed})) == length(operators) - 1

    assert 1 ==
             operators
             |> Enum.flat_map(&root_caps(&1.agent_id))
             |> length()
  end

  # Defense in depth below the facade (internal modules; same-VM layer): a
  # genesis receipt is redeemable only through the entry that re-decides
  # "open" inside the store, never through the ordinary put paths.
  test "security regression: a genesis receipt cannot bypass the open-check via ordinary puts" do
    operator = registered_local_operator("receipt-bypass")
    holder = registered_agent("receipt-holder")

    assert {:ok, cap, receipt} =
             SystemAuthority.authorize_local_genesis_proof(genesis_proof(operator))

    assert {:ok, _cap} = Security.grant_fixture(principal: holder.agent_id, resource: @root)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.put_authorized(cap, :genesis, receipt)

    assert {:error, :capability_mutation_unauthorized} =
             CapabilityStore.acknowledged_put_authorized(cap, :genesis, receipt)

    assert {:error, :genesis_closed} =
             CapabilityStore.put_local_genesis_authorized(cap, receipt)

    assert [] = root_caps(operator.agent_id)
  end

  test "security regression: the genesis grant is recorded by the security audit journal" do
    operator = registered_local_operator("audited")

    before = journal_operation_total()
    assert {:ok, capability_id} = Security.complete_local_genesis(genesis_proof(operator))
    assert journal_operation_total() == before + 1

    assert Enum.any?(
             RecordingEventLogAdapter.invocations(),
             &match?(
               {:persist_security_event, :local_genesis_completed,
                %{capability_id: ^capability_id, genesis: true}},
               &1
             )
           )
  end

  # -- helpers ---------------------------------------------------------------

  defp genesis_proof(%{agent_id: agent_id, private_key: private_key}) do
    {:ok, payload} = Security.local_genesis_request_payload(agent_id)
    {:ok, proof} = SignedRequest.sign(payload, agent_id, private_key)
    proof
  end

  defp resign(%SignedRequest{} = request, private_key) do
    message = SignedRequest.signing_payload(request)
    {:ok, %{request | signature: :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])}}
  end

  defp root_caps(principal_id) do
    {:ok, caps} = Security.list_capabilities(principal_id)
    Enum.filter(caps, &(&1.resource_uri == @root))
  end

  # The same derivation `Registry.register_local_human/1` verifies for an
  # `arbor://local` subject.
  defp local_operator(tag) do
    sub = "genesis-#{tag}-#{System.unique_integer([:positive])}@genesis.test"
    {:ok, base} = Identity.generate(name: "local operator #{tag}")

    agent_id =
      "human_" <>
        String.slice(
          Base.encode16(:crypto.hash(:sha256, "arbor://local:#{sub}"), case: :lower),
          0,
          40
        )

    %{
      base
      | agent_id: agent_id,
        metadata: %{
          "oidc_issuer" => "arbor://local",
          "oidc_sub" => sub,
          "identity_type" => "human"
        }
    }
  end

  defp registered_local_operator(tag) do
    operator = local_operator(tag)
    assert :ok = Registry.register_local_human(Identity.public_only(operator))
    assert {:ok, :active} = Registry.identity_status(operator.agent_id)
    operator
  end

  defp registered_oidc_human do
    oidc = OIDCTestHelper.issue_identity()
    on_exit(oidc.cleanup)
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    oidc.identity
  end

  defp registered_agent(name) do
    {:ok, identity} = Identity.generate(name: name)
    assert :ok = Registry.register_fixture(identity)
    identity
  end

  defp open_authority(%{agent_id: agent_id, private_key: private_key}) do
    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(agent_id, private_key,
        purpose: :local_genesis_test
      )

    {:ok, authority} = Security.open_ephemeral_signing_authority(proof, private_key)
    authority
  end

  defp journal_operation_total do
    {:ok, %{"capacity" => capacity}} = Security.audit_journal_status()
    (capacity["retained_operation_count"] || 0) + (capacity["retired_operation_total"] || 0)
  end

  defp restore_env(key, :__absent__), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
