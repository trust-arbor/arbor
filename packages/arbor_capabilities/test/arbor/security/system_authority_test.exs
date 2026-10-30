defmodule Arbor.Security.SystemAuthorityTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.SystemAuthority

  describe "lifecycle" do
    test "system authority starts and has an agent_id" do
      agent_id = SystemAuthority.agent_id()
      assert is_binary(agent_id)
      assert String.starts_with?(agent_id, "agent_")
    end

    test "public_key returns a 32-byte binary" do
      pk = SystemAuthority.public_key()
      assert is_binary(pk)
      assert byte_size(pk) == 32
    end

    test "system authority is registered in Identity.Registry" do
      agent_id = SystemAuthority.agent_id()
      assert {:ok, pk} = Registry.lookup(agent_id)
      assert pk == SystemAuthority.public_key()
    end
  end

  describe "sign_capability/1" do
    test "adds issuer_id and issuer_signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)

      assert signed.issuer_id == SystemAuthority.agent_id()
      assert is_binary(signed.issuer_signature)
      assert byte_size(signed.issuer_signature) > 0
    end

    test "preserves all original capability fields" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          constraints: %{max_size: 100},
          delegation_depth: 5
        )

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)

      assert signed.id == cap.id
      assert signed.resource_uri == cap.resource_uri
      assert signed.principal_id == cap.principal_id
      assert signed.constraints == cap.constraints
      assert signed.delegation_depth == cap.delegation_depth
    end
  end

  describe "verify_capability_signature/1" do
    test "accepts valid signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)
      assert :ok = SystemAuthority.verify_capability_signature(signed)
    end

    test "rejects tampered capability" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)

      # Tamper with the resource URI
      tampered = %{signed | resource_uri: "arbor://fs/write/evil"}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(tampered)
    end

    test "rejects capability with random signature" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001",
          issuer_id: SystemAuthority.agent_id()
        )

      cap = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(cap)
    end

    @tag spec: "VP-05D2A0"
    test "security regression: a nil/non-binary issuer_id fails closed instead of crashing the authority" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_test001"
        )

      # issuer_id left nil (never signed) plus a garbage signature — the shape
      # a forged capability could plausibly take. Pre-fix, the `else` branch
      # called Registry.lookup(cap.issuer_id) unconditionally, and
      # Registry.lookup/1 has a `when is_binary(agent_id)` guard — nil raised
      # a FunctionClauseError INSIDE this GenServer's handle_call, crashing
      # the shared SystemAuthority process for every other in-flight
      # capability verification, not just this one request.
      forged = %{cap | issuer_signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(forged)

      # The authority must still be alive and answering afterward.
      assert is_binary(SystemAuthority.agent_id())
    end

    @tag spec: "VP-05D2A0"
    test "security regression: a non-binary signature fails closed without restarting the authority" do
      authority_pid = Process.whereis(SystemAuthority)

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/malformed_signature",
          principal_id: "agent_test001",
          issuer_id: SystemAuthority.agent_id()
        )

      malformed = %{cap | issuer_signature: {:not, :binary}}

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(malformed)

      assert Process.whereis(SystemAuthority) == authority_pid
      assert Process.alive?(authority_pid)
      assert is_binary(SystemAuthority.agent_id())
    end

    @tag spec: "VP-05D2A0"
    test "batch verification returns only valid capability ids" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/batch_verification",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)
      forged = %{signed | id: "cap_" <> String.duplicate("f", 32)}

      assert {:ok, [valid_id]} =
               SystemAuthority.verify_capability_signatures([signed, forged])

      assert valid_id == signed.id
    end

    test "security regression: a registered identity is not automatically a capability issuer" do
      {:ok, other_identity} = Identity.generate()
      :ok = Registry.register_fixture(Identity.public_only(other_identity))

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/other_signed",
          principal_id: other_identity.agent_id
        )

      signed =
        cap
        |> Map.put(:issuer_id, other_identity.agent_id)
        |> Signer.sign(other_identity.private_key)

      assert {:ok, :stored} = CapabilityStore.put_fixture(signed)

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(signed)

      # Exercise the public authorization boundary too: merely registering an
      # identity must not let that identity mint its own root capabilities.
      assert {:error, :unauthorized} =
               Security.authorize(
                 other_identity.agent_id,
                 signed.resource_uri,
                 :read,
                 identity_verified: true
               )
    end

    test "an enrolled issuer verifies only capabilities inside its envelope" do
      {:ok, issuer} = Identity.generate()
      :ok = Registry.register_fixture(Identity.public_only(issuer))

      {:ok, envelope} =
        Capability.new(
          resource_uri: "arbor://fs/read/enrolled-issuer/**",
          principal_id: issuer.agent_id
        )

      :ok = IssuerRegistry.register_fixture(issuer.agent_id, [envelope])
      on_exit(fn -> IssuerRegistry.revoke_fixture(issuer.agent_id, "test cleanup") end)

      {:ok, inside} =
        Capability.new(
          resource_uri: "arbor://fs/read/enrolled-issuer/report.txt",
          principal_id: "agent_test001",
          issuer_id: issuer.agent_id
        )

      signed_inside = Signer.sign(inside, issuer.private_key)
      assert :ok = SystemAuthority.verify_capability_signature(signed_inside)

      {:ok, outside} =
        Capability.new(
          resource_uri: "arbor://fs/write/enrolled-issuer/report.txt",
          principal_id: "agent_test001",
          issuer_id: issuer.agent_id
        )

      signed_outside = Signer.sign(outside, issuer.private_key)

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(signed_outside)
    end

    test "rejects capability with unknown issuer_id" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/unknown_issuer",
          principal_id: "agent_test001"
        )

      # Set issuer to an unregistered agent
      cap = %{
        cap
        | issuer_id: "agent_not_registered",
          issuer_signature: :crypto.strong_rand_bytes(64)
      }

      assert {:error, :invalid_capability_signature} =
               SystemAuthority.verify_capability_signature(cap)
    end
  end

  describe "rotate/0 (L1 regression)" do
    test "security regression (L1): rotate/0 changes the authority keypair" do
      # L1: the SystemAuthority keypair was generated once at startup and never
      # rotatable — a long-lived cluster kept the same root-of-trust key
      # indefinitely. The fix exposes rotate/0, which mints a fresh identity,
      # registers it, and swaps it into GenServer state. This asserts the
      # observable post-rotation behavior differs from pre-rotation: a NEW
      # agent_id and a NEW public key, with the new key actually registered.
      old_agent_id = SystemAuthority.agent_id()
      old_public_key = SystemAuthority.public_key()

      assert {:ok, %{old_agent_id: ^old_agent_id, new_agent_id: new_agent_id}} =
               SystemAuthority.rotate_for_test()

      assert new_agent_id != old_agent_id,
             "rotate/0 did not change the agent_id — L1 regression"

      new_public_key = SystemAuthority.public_key()

      assert new_public_key != old_public_key,
             "rotate/0 did not change the public key — L1 regression"

      assert SystemAuthority.agent_id() == new_agent_id

      # The rotated key is the live identity now registered for verification.
      assert {:ok, ^new_public_key} = Registry.lookup(new_agent_id)
    end

    test "security regression (L1): capabilities signed after rotation use the new key" do
      # Behavioral consequence of rotation: a capability signed AFTER rotate/0
      # carries the new issuer_id and verifies under the current authority. A
      # no-op rotate (the pre-fix state, where the key never changed) would not
      # produce a distinct new issuer_id.
      old_agent_id = SystemAuthority.agent_id()

      {:ok, %{new_agent_id: new_agent_id}} = SystemAuthority.rotate_for_test()
      assert new_agent_id != old_agent_id

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/post_rotate",
          principal_id: "agent_test001"
        )

      {:ok, signed} = SystemAuthority.sign_capability_for_test(cap)

      assert signed.issuer_id == new_agent_id
      assert :ok = SystemAuthority.verify_capability_signature(signed)
    end
  end
end
