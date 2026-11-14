defmodule Arbor.Security.LocalHumanCallerHeldKeySecurityRegressionTest do
  @moduledoc """
  The local operator's key is generated and held by the caller (the
  `mix arbor.user.init` process). The server receives only the public key and
  a possession proof (`register_local_human_identity/3`).

  Regression for the fresh-install deadlock left by security review F-002:
  once the server stopped returning private keys, `mix arbor.user.init` could
  not write `operator.key`, so genesis could never complete. And for F-002
  itself: no local-human path may return, or require the server to hold, the
  operator's private key.

  Every test goes through the public facade. Each starts from an open genesis
  by revoking wildcard grant-holders that earlier test modules left behind.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.Config

  setup do
    previous_flag =
      Application.get_env(:arbor_capabilities, :allow_local_human_identity, :__absent__)

    previous_oidc = Application.get_env(:arbor_capabilities, :oidc, :__absent__)

    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)
    Application.delete_env(:arbor_capabilities, :oidc)

    assert {:ok, _revoked} = Security.reopen_local_genesis_fixture()

    dir = private_dir!()

    on_exit(fn ->
      restore_env(:allow_local_human_identity, previous_flag)
      restore_env(:oidc, previous_oidc)
      File.rm_rf!(dir)
      # Do not leak this module's root grant into later modules.
      _ = Security.reopen_local_genesis_fixture()
    end)

    {:ok, dir: dir}
  end

  test "security regression: a caller-held key file registers, completes genesis, and no private key leaves the caller",
       %{dir: dir} do
    operator = operator("cli")
    path = Path.join(dir, "operator.key")

    assert {:ok, ^path} =
             Security.write_key_file(path, %{
               agent_id: operator.principal,
               private_key: operator.private_key
             })

    # What `mix arbor.user.init` asks the server before it writes anything.
    assert {:ok, %{principal_id: principal, public_key: nil}} =
             Security.local_human_identity_status(operator.opts)

    assert principal == operator.principal

    prepared = with_device(path, &Security.prepare_key_file_local_human_registration/1)
    assert {:ok, ^principal, public_key, %SignedRequest{} = proof} = prepared
    assert public_key == operator.public_key
    refute_contains_secret(prepared, operator.private_key)

    registered = Security.register_local_human_identity(public_key, proof, operator.opts)
    assert {:ok, identity, :created} = registered
    assert identity.agent_id == principal
    assert identity.public_key == public_key
    assert is_nil(identity.private_key)
    assert is_nil(identity.encryption_private_key)
    refute_contains_secret(registered, operator.private_key)

    # The server registered the public key and holds no private key for it.
    assert {:ok, %{public_key: ^public_key}} = Security.local_human_identity_status(operator.opts)
    assert {:error, :no_signing_key} = Security.signing_key_status(principal)

    # Genesis completes from the same key file: the deadlock is gone.
    assert {:ok, ^principal, genesis_proof} =
             with_device(path, &Security.prepare_key_file_local_genesis/1)

    assert {:ok, "cap_" <> _} = Security.complete_local_genesis(genesis_proof)
    assert [_root] = root_caps(principal)

    # A re-run with the same key file is idempotent.
    {:ok, ^principal, ^public_key, again} =
      with_device(path, &Security.prepare_key_file_local_human_registration/1)

    assert {:ok, %{agent_id: ^principal}, :existing} =
             Security.register_local_human_identity(public_key, again, operator.opts)

    # The server-held-key path must not mint a second keypair under this id.
    assert {:error, :local_human_key_held_by_caller} =
             Security.create_local_human_identity(operator.opts)

    assert {:error, :no_signing_key} = Security.signing_key_status(principal)
    assert {:ok, %{public_key: ^public_key}} = Security.local_human_identity_status(operator.opts)
  end

  test "security regression: the server-held local path never returns a private key" do
    opts = [user: "server-held-#{System.unique_integer([:positive])}", host: "regression.test"]

    assert {:ok, identity, :created} = Security.create_local_human_identity(opts)
    assert is_nil(identity.private_key)
    assert is_nil(identity.encryption_private_key)

    assert {:ok, again, :existing} = Security.create_local_human_identity(opts)
    assert again.public_key == identity.public_key
    assert is_nil(again.private_key)
    assert is_nil(again.encryption_private_key)
  end

  test "security regression: registration refuses a proof for a different key or principal" do
    operator = operator("victim")
    attacker = operator("attacker")

    # Signed by the attacker over its own key, submitted with the victim's key.
    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(
               operator.public_key,
               proof(%{attacker | principal: operator.principal}),
               operator.opts
             )

    # Payload names the victim's key but the attacker signed it.
    {:ok, payload} =
      Security.local_human_registration_request_payload(operator.principal, operator.public_key)

    {:ok, forged} = SignedRequest.sign(payload, operator.principal, attacker.private_key)

    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(operator.public_key, forged, operator.opts)

    # A valid proof for one principal cannot register another.
    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(
               attacker.public_key,
               proof(attacker),
               operator.opts
             )

    # A tampered signature.
    %SignedRequest{signature: <<first, rest::binary>>} = valid = proof(operator)
    tampered = %{valid | signature: <<Bitwise.bxor(first, 1), rest::binary>>}

    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(operator.public_key, tampered, operator.opts)

    assert {:ok, %{public_key: nil}} = Security.local_human_identity_status(operator.opts)
    assert {:ok, %{public_key: nil}} = Security.local_human_identity_status(attacker.opts)
  end

  test "security regression: registration refuses a proof signed for another purpose" do
    operator = operator("purpose")

    {:ok, genesis_payload} = Security.local_genesis_request_payload(operator.principal)

    other_resource =
      Enum.map_join(
        [
          "arbor-local-human-registration-request-v1",
          "arbor://security/identity/register",
          operator.principal,
          operator.public_key
        ],
        &<<byte_size(&1)::unsigned-big-32, &1::binary>>
      )

    for payload <- [genesis_payload, other_resource, "register me", operator.public_key] do
      {:ok, wrong} = SignedRequest.sign(payload, operator.principal, operator.private_key)

      assert {:error, :local_human_registration_unauthorized} =
               Security.register_local_human_identity(operator.public_key, wrong, operator.opts)
    end

    assert {:ok, %{public_key: nil}} = Security.local_human_identity_status(operator.opts)

    # The proof format itself is accepted, so the refusals above are about purpose.
    assert {:ok, _identity, :created} =
             Security.register_local_human_identity(
               operator.public_key,
               proof(operator),
               operator.opts
             )
  end

  test "security regression: registration refuses a stale or replayed proof" do
    operator = operator("replay")

    stale = %{proof(operator) | timestamp: DateTime.add(DateTime.utc_now(), -3_600)}
    stale = resign(stale, operator.private_key)

    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(operator.public_key, stale, operator.opts)

    future = %{proof(operator) | timestamp: DateTime.add(DateTime.utc_now(), 3_600)}
    future = resign(future, operator.private_key)

    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(operator.public_key, future, operator.opts)

    # A peer that could accept the same proof makes replay protection unsound.
    Config.inject_test_cluster_peers_present(true)

    try do
      assert {:error, :local_human_registration_unauthorized} =
               Security.register_local_human_identity(
                 operator.public_key,
                 proof(operator),
                 operator.opts
               )
    after
      Config.inject_test_cluster_peers_present(false)
    end

    assert {:ok, %{public_key: nil}} = Security.local_human_identity_status(operator.opts)

    once = proof(operator)

    assert {:ok, _identity, :created} =
             Security.register_local_human_identity(operator.public_key, once, operator.opts)

    # Replaying an accepted proof is refused, not reported as `:existing`.
    assert {:error, :local_human_registration_unauthorized} =
             Security.register_local_human_identity(operator.public_key, once, operator.opts)
  end

  test "security regression: a registered local human is never re-keyed" do
    operator = operator("rekey")
    replacement = %{operator("rekey-other") | principal: operator.principal}

    assert {:ok, _identity, :created} =
             Security.register_local_human_identity(
               operator.public_key,
               proof(operator),
               operator.opts
             )

    assert {:error, :local_human_key_mismatch} =
             Security.register_local_human_identity(
               replacement.public_key,
               proof(replacement),
               operator.opts
             )

    public_key = operator.public_key
    assert {:ok, %{public_key: ^public_key}} = Security.local_human_identity_status(operator.opts)
  end

  test "security regression: registration is refused when local human identities are disabled" do
    operator = operator("disabled")
    proof = proof(operator)

    Application.put_env(:arbor_capabilities, :allow_local_human_identity, false)

    assert {:error, :local_human_identity_disabled} =
             Security.register_local_human_identity(operator.public_key, proof, operator.opts)

    assert {:error, :local_human_identity_disabled} =
             Security.local_human_identity_status(operator.opts)

    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)

    Application.put_env(:arbor_capabilities, :oidc,
      providers: [%{issuer: "https://idp.caller-held.example", client_id: "arbor"}]
    )

    assert {:error, :oidc_configured} =
             Security.register_local_human_identity(operator.public_key, proof, operator.opts)

    assert {:error, :oidc_configured} = Security.local_human_identity_status(operator.opts)

    Application.delete_env(:arbor_capabilities, :oidc)
    assert {:ok, %{public_key: nil}} = Security.local_human_identity_status(operator.opts)

    # The gate is checked before the proof, so the refusals did not consume
    # its nonce: the same proof is accepted once the gates allow it.
    assert {:ok, _identity, :created} =
             Security.register_local_human_identity(operator.public_key, proof, operator.opts)
  end

  # -- helpers ---------------------------------------------------------------

  defp operator(tag) do
    opts = [user: "caller-held-#{tag}-#{System.unique_integer([:positive])}", host: "okey.test"]
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      opts: opts,
      principal: Security.local_human_principal_id(opts),
      public_key: public_key,
      private_key: private_key
    }
  end

  defp proof(%{principal: principal, public_key: public_key, private_key: private_key}) do
    {:ok, payload} = Security.local_human_registration_request_payload(principal, public_key)
    {:ok, proof} = SignedRequest.sign(payload, principal, private_key)
    proof
  end

  defp resign(%SignedRequest{} = request, private_key) do
    message = SignedRequest.signing_payload(request)
    %{request | signature: :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])}
  end

  defp with_device(path, fun) do
    {:ok, io_device} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

    try do
      fun.(io_device)
    after
      :file.close(io_device)
    end
  end

  defp refute_contains_secret(term, secret) do
    assert :binary.match(:erlang.term_to_binary(term), secret) == :nomatch,
           "private key material crossed the facade boundary"
  end

  defp root_caps(principal_id) do
    {:ok, caps} = Security.list_capabilities(principal_id)
    Enum.filter(caps, &(&1.resource_uri == "arbor://**"))
  end

  defp private_dir! do
    token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "caller-held-key-#{token}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp restore_env(key, :__absent__), do: Application.delete_env(:arbor_capabilities, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_capabilities, key, value)
end
