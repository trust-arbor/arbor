defmodule Arbor.Common.Extension.ActivationCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Extension.ActivationCore
  alias Arbor.Contracts.Extension.Envelope

  test "stages, authorizes, and commits a bound transaction" do
    {state, auth, bindings} = staged()

    assert {:ok, authorized, [{:consume_nonce, nonce}]} =
             ActivationCore.authorize(state, auth, bindings)

    assert nonce == auth["nonce"]
    assert {:ok, committed} = ActivationCore.commit(authorized, bindings)
    assert committed.status == :committed
    assert {:ok, _} = Envelope.validate(:activation_receipt, committed.receipt)
    assert committed.receipt["state"] == "committed"
  end

  test "rejects forged, replayed, stale, and expired authorizations" do
    {state, auth, bindings} = staged()

    assert {:error, "authorization_invalid"} =
             ActivationCore.authorize(state, auth, %{bindings | signature_status: :forged})

    assert {:error, "authorization_absent"} =
             ActivationCore.authorize(state, auth, %{bindings | signature_status: :absent})

    assert {:error, "authorization_revoked"} =
             ActivationCore.authorize(state, auth, %{bindings | revoked?: true})

    assert {:error, "authorization_replayed"} =
             ActivationCore.authorize(state, auth, %{
               bindings
               | consumed_nonces: MapSet.new([auth["nonce"]])
             })

    assert {:error, "authorization_expired"} =
             ActivationCore.authorize(state, auth, %{bindings | now: "2026-08-18T00:00:00Z"})

    assert {:error, "transaction_mismatch"} =
             ActivationCore.authorize(state, auth, %{
               bindings
               | transaction_digest: String.duplicate("00", 32)
             })

    assert {:error, "boot_mismatch"} =
             ActivationCore.authorize(state, auth, %{
               bindings
               | boot_profile_digest: String.duplicate("11", 32)
             })

    assert {:error, "generation_mismatch"} =
             ActivationCore.authorize(state, auth, %{bindings | boot_epoch: 2})
  end

  test "production commit stays disabled and rollback is available" do
    {state, auth, bindings} = staged()
    assert {:ok, authorized, _effects} = ActivationCore.authorize(state, auth, bindings)

    assert {:error, "not_ready"} =
             ActivationCore.commit(authorized, %{bindings | allow_commit?: false})

    assert {:ok, rolled} = ActivationCore.rollback(authorized)
    assert rolled.status == :rolled_back
    assert rolled.receipt["cleanup_disposition"] == "pending"
    assert {:error, "commit_conflict"} = ActivationCore.rollback(rolled)
  end

  defp staged do
    transaction = Envelope.fixture(:activation_transaction)
    digest = String.duplicate("ab", 32)
    auth = %{Envelope.fixture(:activation_authorization) | "transaction_sha256" => digest}

    {:ok, state} =
      ActivationCore.stage(ActivationCore.new(), transaction, "2026-08-16T00:00:00Z", digest)

    bindings = %{
      transaction_digest: digest,
      signature_status: :verified,
      now: "2026-08-16T00:00:00Z",
      consumed_nonces: MapSet.new(),
      boot_profile_digest: transaction["boot_profile_sha256"],
      boot_epoch: 1,
      revoked?: false,
      allow_commit?: true
    }

    {state, auth, bindings}
  end
end
