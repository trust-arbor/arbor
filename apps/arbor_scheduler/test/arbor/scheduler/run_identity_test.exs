defmodule Arbor.Scheduler.RunIdentityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, RunIdentity}
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  @envelope_uri "arbor://fs/write/reports/**"

  setup do
    {:ok, issuer} = Identity.generate()
    :ok = IdentityRegistry.register(issuer)

    {:ok, envelope} =
      Capability.new(resource_uri: @envelope_uri, principal_id: issuer.agent_id)

    :ok = IssuerRegistry.register(issuer.agent_id, envelope, reason: "run_identity_test")

    tmp_dir =
      System.tmp_dir!() |> Path.join("run_identity_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      IssuerRegistry.revoke(issuer.agent_id, "test cleanup")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, issuer: issuer, tmp_dir: tmp_dir}
  end

  test "mints only attested caps and returns the verified attestation", %{
    issuer: issuer,
    tmp_dir: tmp_dir
  } do
    attestation =
      verified_attestation(issuer, tmp_dir, [
        %{resource_uri: "arbor://fs/write/reports/narrow/**", constraints: %{}}
      ])

    assert {:ok, handle} = RunIdentity.mint(attestation)
    assert handle.attestation == attestation
    assert String.starts_with?(handle.agent_id, "agent_")
    assert is_function(handle.signer, 1)

    capabilities = Enum.map(handle.cap_ids, &fetch_cap!/1)

    assert Enum.sort(Enum.map(capabilities, & &1.resource_uri)) ==
             Enum.sort([
               "arbor://orchestrator/execute/**",
               "arbor://fs/write/reports/narrow/**"
             ])

    refute Enum.any?(capabilities, &(&1.resource_uri == @envelope_uri))

    declared = Enum.find(capabilities, &(&1.resource_uri != "arbor://orchestrator/execute/**"))
    assert declared.principal_id == handle.agent_id
    assert declared.metadata.provenance.issuer_id == issuer.agent_id
    assert declared.metadata.provenance.graph_hash == attestation.graph_hash

    assert {:ok, _public_key} = IdentityRegistry.lookup(handle.agent_id)
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
    assert :ok = RunIdentity.revoke(handle)

    for cap_id <- handle.cap_ids do
      case CapabilityStore.get(cap_id) do
        {:error, _reason} -> :ok
        {:ok, capability} -> assert Map.get(capability, :revoked, true)
      end
    end

    assert {:error, :not_found} = IdentityRegistry.lookup(handle.agent_id)
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

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
