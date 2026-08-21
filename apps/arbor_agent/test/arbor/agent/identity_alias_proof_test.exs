defmodule Arbor.Agent.IdentityAliasProofTest do
  @moduledoc """
  Client-side possession-proof tests for identity-alias management.

  These assert that proof is produced from a key file the caller holds —
  missing, unreadable, malformed, or mismatched files fail closed and never
  yield a SignedRequest.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.IdentityAliasProof
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.KeyFile

  setup do
    tmp = System.tmp_dir!() |> Path.join("alias_proof_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  defp write_key!(path, agent_id, private_key) do
    {:ok, written} = KeyFile.write(path, %{agent_id: agent_id, private_key: private_key})
    written
  end

  describe "prove/2" do
    test "signs a request from a key file the caller holds", %{tmp_dir: tmp_dir} do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)
      path = write_key!(Path.join(tmp_dir, "operator.key"), agent_id, private_key)

      assert {:ok, %SignedRequest{} = signed} = IdentityAliasProof.prove(path, agent_id)
      assert signed.agent_id == agent_id
      assert signed.payload == IdentityAliasProof.resource()
    end

    test "fails closed when the key file is absent", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.key")

      assert {:error, {:read_failed, :enoent}} =
               IdentityAliasProof.prove(path, "human_0123456789abcdef0123456789abcdef01234567")
    end

    test "fails closed when the key file is malformed", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.key")
      File.write!(path, "not a key file\n")
      File.chmod!(path, 0o600)

      assert {:error, {:missing_field, "agent_id"}} =
               IdentityAliasProof.prove(path, "human_0123456789abcdef0123456789abcdef01234567")
    end

    test "fails closed when --as names a different principal than the key file", %{tmp_dir: tmp_dir} do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      actual = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)
      claimed = "human_0123456789abcdef0123456789abcdef01234567"
      path = write_key!(Path.join(tmp_dir, "operator.key"), actual, private_key)

      assert {:error, {:principal_mismatch, ^claimed, ^actual}} =
               IdentityAliasProof.prove(path, claimed)
    end

    test "fails closed when group/other can read the key file", %{tmp_dir: tmp_dir} do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)
      path = write_key!(Path.join(tmp_dir, "operator.key"), agent_id, private_key)
      File.chmod!(path, 0o644)

      assert {:error, {:insecure_permissions, 0o644}} =
               IdentityAliasProof.prove(path, agent_id)
    end
  end

  describe "security regression: CLI does not sign as a stored principal" do
    test "user.link and identity aliases never load a stored private key to sign" do
      files = [
        Path.expand("../../../lib/arbor/agent/identity_aliases.ex", __DIR__),
        Path.expand("../../../lib/arbor/agent/identity_alias_proof.ex", __DIR__),
        Path.expand("../../../lib/mix/tasks/arbor/user/link.ex", __DIR__),
        Path.expand("../../../lib/mix/tasks/arbor/user/init.ex", __DIR__)
      ]

      src = Enum.map_join(files, "\n", &File.read!/1)

      refute src =~ "authorize_as_stored_principal",
             "must not reintroduce a server-signs-for-named-principal facade"

      refute src =~ "load_signing_key",
             "alias management must not load a stored private key to sign"

      refute src =~ "verify_identity: false",
             "alias management must not skip possession proof"
    end
  end
end
