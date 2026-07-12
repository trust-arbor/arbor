defmodule Arbor.Scheduler.RunIdentityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, RunIdentity}
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

  setup do
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
    assert Map.keys(handle) |> Enum.sort() == [:agent_id, :cap_ids, :signing_authority]
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

  defp authorize_as(handle, resource) do
    assert {:ok, signed_request} =
             Security.sign_with_authority(handle.signing_authority, resource)

    Security.authorize(handle.agent_id, resource, :execute, signed_request: signed_request)
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
