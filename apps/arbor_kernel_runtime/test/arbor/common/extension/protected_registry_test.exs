defmodule Arbor.Common.Extension.ProtectedRegistryTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Extension.ProtectedRegistry
  alias Arbor.Contracts.Extension.Envelope

  test "owner publishes a handle after signed authorization; strangers cannot mutate" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    token = make_ref()
    registry = start_registry!(token, public_key, allow_commit: true)
    {transaction, handle, signed} = signed_activation(private_key)

    assert {:error, "no_compatible_provider"} =
             ProtectedRegistry.resolve(registry, "vector.store", now: "2026-08-16T00:00:00Z")

    assert :ok =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "no_compatible_provider"} =
             ProtectedRegistry.resolve(registry, "vector.store", now: "2026-08-16T00:00:00Z")

    assert :ok =
             ProtectedRegistry.authorize(registry, token, signed, now: "2026-08-16T00:00:00Z")

    assert :ok = ProtectedRegistry.commit(registry, token, now: "2026-08-16T00:00:00Z")

    assert {:ok, entry} =
             ProtectedRegistry.resolve(registry, "vector.store", now: "2026-08-16T00:00:00Z")

    assert entry["handle"]["transport_class"] == "local_module"

    assert {:error, "unauthorized"} =
             ProtectedRegistry.stage(
               registry,
               make_ref(),
               transaction,
               handle,
               now: "2026-08-16T00:00:00Z"
             )
  end

  test "production commit stays disabled and remote resolve fails closed" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    token = make_ref()
    registry = start_registry!(token, public_key, allow_commit: false)
    {transaction, handle, signed} = signed_activation(private_key)

    assert :ok =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )

    assert :ok =
             ProtectedRegistry.authorize(registry, token, signed, now: "2026-08-16T00:00:00Z")

    assert {:error, "not_ready"} =
             ProtectedRegistry.commit(registry, token, now: "2026-08-16T00:00:00Z")

    assert {:error, "not_ready"} =
             ProtectedRegistry.commit(registry, token,
               allow_commit: true,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "no_compatible_provider"} =
             ProtectedRegistry.resolve(registry, "vector.store", now: "2026-08-16T00:00:00Z")

    assert {:error, "unauthorized"} =
             ProtectedRegistry.resolve(registry, "vector.store",
               node: :any,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "unauthorized"} =
             ProtectedRegistry.resolve(registry, "vector.store",
               node: Node.self(),
               now: "2026-08-16T00:00:00Z"
             )
  end

  test "staged handles cannot carry module or pid identity" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    token = make_ref()
    registry = start_registry!(token, public_key, allow_commit: true)
    {transaction, handle, _signed} = signed_activation(private_key)

    assert {:error, "malformed"} =
             ProtectedRegistry.stage(
               registry,
               token,
               transaction,
               Map.put(handle, "module", __MODULE__),
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "malformed"} =
             ProtectedRegistry.stage(
               registry,
               token,
               transaction,
               Map.put(handle, "pid", self()),
               now: "2026-08-16T00:00:00Z"
             )
  end

  test "forged authorization and replayed nonce fail closed" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {other_public, _} = :crypto.generate_key(:eddsa, :ed25519)
    token = make_ref()
    registry = start_registry!(token, public_key, allow_commit: true)
    {transaction, handle, signed} = signed_activation(private_key)

    assert :ok =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "authorization_invalid"} =
             ProtectedRegistry.authorize(registry, token, signed,
               public_key: other_public,
               now: "2026-08-16T00:00:00Z"
             )

    assert :ok =
             ProtectedRegistry.authorize(registry, token, signed, now: "2026-08-16T00:00:00Z")

    assert :ok = ProtectedRegistry.rollback(registry, token)

    assert :ok =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )

    assert {:error, "authorization_replayed"} =
             ProtectedRegistry.authorize(registry, token, signed, now: "2026-08-16T00:00:00Z")
  end

  test "owner death drops unpublished work" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    token = make_ref()
    owner = spawn(fn -> Process.sleep(:infinity) end)

    registry =
      start_supervised!(
        {ProtectedRegistry,
         owner: owner,
         owner_token: token,
         owner_id: "owner.dead",
         allow_commit: true,
         public_key: public_key,
         boot_profile_digest: Envelope.fixture(:activation_transaction)["boot_profile_sha256"],
         boot_epoch: 1}
      )

    {transaction, handle, _signed} = signed_activation(private_key)

    assert :ok =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )

    Process.exit(owner, :kill)

    assert eventually(fn ->
             ProtectedRegistry.resolve(registry, "vector.store", now: "2026-08-16T00:00:00Z") ==
               {:error, "no_compatible_provider"}
           end)
  end

  test "locked core names cannot be overwritten after first publish" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    token = make_ref()
    registry = start_registry!(token, public_key, allow_commit: true)
    {transaction, handle, signed} = signed_activation(private_key)

    assert :ok = ProtectedRegistry.mark_core(registry, token, "vector.store")
    assert :ok = ProtectedRegistry.lock_core(registry, token)

    assert :ok =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )

    assert :ok = ProtectedRegistry.authorize(registry, token, signed, now: "2026-08-16T00:00:00Z")
    assert :ok = ProtectedRegistry.commit(registry, token, now: "2026-08-16T00:00:00Z")

    assert {:error, "commit_conflict"} =
             ProtectedRegistry.stage(registry, token, transaction, handle,
               now: "2026-08-16T00:00:00Z"
             )
  end

  defp start_registry!(token, public_key, opts) do
    transaction = Envelope.fixture(:activation_transaction)

    start_supervised!(
      {ProtectedRegistry,
       Keyword.merge(
         [
           owner: self(),
           owner_token: token,
           owner_id: "owner.test",
           public_key: public_key,
           boot_profile_digest: transaction["boot_profile_sha256"],
           boot_epoch: 1
         ],
         opts
       )}
    )
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp signed_activation(private_key) do
    transaction = Envelope.fixture(:activation_transaction)
    handle = Envelope.fixture(:provider_handle)
    {:ok, digest} = Envelope.digest_of(transaction)

    auth = %{
      Envelope.fixture(:activation_authorization)
      | "transaction_sha256" => digest,
        "boot_profile_sha256" => transaction["boot_profile_sha256"]
    }

    {transaction, handle, sign(auth, private_key)}
  end

  defp sign(payload, private_key) do
    {:ok, digest} = Envelope.digest_of(payload)

    envelope = %{
      "schema" => Envelope.signed_schema(),
      "version" => 1,
      "domain" => Envelope.schema(:activation_authorization),
      "payload_encoding" => "canonical_json_v1",
      "payload_sha256" => digest,
      "issuer_id" => payload["issuer_id"],
      "key_id" => payload["key_id"],
      "signature" => String.duplicate("00", 64),
      "payload" => payload
    }

    {:ok, message} = Envelope.signing_message(envelope)
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
    %{envelope | "signature" => Base.encode16(signature, case: :lower)}
  end
end
