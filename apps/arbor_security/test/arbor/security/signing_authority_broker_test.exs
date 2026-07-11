defmodule Arbor.Security.SigningAuthorityBrokerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  setup do
    ensure_broker_started()

    {:ok, identity} = Identity.generate(name: "signing-authority-test")
    # Strip private keys before registry; store signing key separately.
    public_identity = Identity.public_only(identity)
    :ok = Security.register_identity(public_identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
      ensure_broker_started()
    end)

    {:ok,
     agent_id: identity.agent_id,
     private_key: identity.private_key,
     public_key: identity.public_key}
  end

  describe "open_signing_authority/1 + sign_with_authority/2" do
    test "signs payload and verifies via SignedRequest path", ctx do
      assert {:ok, authority} = open_authority(ctx, purpose: :session)

      assert %SigningAuthority{} = authority
      assert authority.principal_id == ctx.agent_id
      refute is_function(authority)
      refute Map.has_key?(Map.from_struct(authority), :private_key)

      assert {:ok, %SignedRequest{} = signed} =
               Security.sign_with_authority(authority, "arbor://fs/read/docs")

      assert signed.agent_id == ctx.agent_id
      assert signed.payload == "arbor://fs/read/docs"
      agent_id = ctx.agent_id
      assert {:ok, ^agent_id} = Security.verify_request(signed)
    end

    test "derive_secret_with_authority is domain-separated and non-raw", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      assert {:ok, secret_a} = Security.derive_secret_with_authority(authority, :capability_mac)
      assert {:ok, secret_b} = Security.derive_secret_with_authority(authority, "session_binding")
      assert {:ok, secret_a2} = Security.derive_secret_with_authority(authority, :capability_mac)

      assert is_binary(secret_a)
      assert byte_size(secret_a) == 32
      assert secret_a == secret_a2
      refute secret_a == secret_b
      refute secret_a == ctx.private_key

      assert {:error, :invalid_purpose} =
               Security.derive_secret_with_authority(authority, "raw")

      assert {:error, :invalid_purpose} =
               Security.derive_secret_with_authority(authority, "private_key")

      assert {:error, :invalid_purpose} =
               Security.derive_secret_with_authority(authority, "")

      assert {:error, :invalid_purpose} =
               Security.derive_secret_with_authority(authority, "   ")

      assert {:error, :invalid_purpose} =
               Security.derive_secret_with_authority(authority, true)
    end
  end

  describe "security regression: acquisition requires possession proof" do
    test "security regression: possession of only an agent_id cannot acquire a usable authority",
         ctx do
      # Historical deputy API accepted agent_id + owner/purpose without key material.
      # Acquisition invariant: agent_id alone must never yield a usable bearer lease.
      agent_id_only_attempts = [
        fn -> Security.open_signing_authority(ctx.agent_id) end,
        fn ->
          Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)
        end,
        fn -> Security.open_signing_authority(ctx.agent_id, purpose: :session) end,
        fn -> Security.open_signing_authority(ctx.agent_id, []) end
      ]

      Enum.each(agent_id_only_attempts, fn attempt ->
        result =
          try do
            attempt.()
          rescue
            FunctionClauseError -> {:error, :possession_proof_required}
            UndefinedFunctionError -> {:error, :possession_proof_required}
          end

        case result do
          {:ok, %SigningAuthority{} = authority} ->
            # Even if an authority struct were returned, it must not be usable.
            sign_result = Security.sign_with_authority(authority, "agent-id-only-attack")

            flunk(
              "agent_id-only acquisition produced usable authority: " <>
                "open=#{inspect(result)} sign=#{inspect(sign_result)}"
            )

          {:ok, other} ->
            flunk("agent_id-only acquisition unexpectedly succeeded: #{inspect(other)}")

          {:error, _reason} ->
            :ok

          other ->
            flunk("unexpected agent_id-only result: #{inspect(other)}")
        end
      end)

      # Positive control: possession proof still opens a usable authority.
      assert {:ok, authority} = open_authority(ctx, purpose: :session)
      assert {:ok, %SignedRequest{}} = Security.sign_with_authority(authority, "legitimate")
    end

    test "invalid signature and wrong principal fail closed", ctx do
      {:ok, other} = Identity.generate(name: "other-principal")
      public_other = Identity.public_only(other)
      :ok = Security.register_identity(public_other)
      :ok = Security.store_signing_key(other.agent_id, other.private_key)

      on_exit(fn ->
        _ = Security.delete_signing_key(other.agent_id)
        _ = Security.deregister_identity(other.agent_id)
      end)

      # Wrong principal: payload claims ctx.agent_id but is signed by other.
      bad_payload =
        SigningAuthorityBroker.acquisition_payload(ctx.agent_id, :session, self())

      assert {:ok, wrong_principal_proof} =
               SignedRequest.sign(bad_payload, other.agent_id, other.private_key)

      assert {:error, :principal_mismatch} =
               Security.open_signing_authority(wrong_principal_proof)

      # Invalid signature: well-formed proof then corrupt the signature bytes.
      assert {:ok, good_proof} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :session,
                 owner: self()
               )

      corrupted = %{
        good_proof
        | signature: :crypto.strong_rand_bytes(byte_size(good_proof.signature))
      }

      assert {:error, :invalid_signature} = Security.open_signing_authority(corrupted)
    end

    test "purpose tampering on the bearer reference fails closed for sign/derive/close", ctx do
      assert {:ok, authority} = open_authority(ctx, purpose: :session)

      tampered = %{authority | purpose: :evil}

      assert {:error, :purpose_mismatch} =
               Security.sign_with_authority(tampered, "tampered-purpose")

      assert {:error, :purpose_mismatch} =
               Security.derive_secret_with_authority(tampered, :capability_mac)

      assert {:error, :purpose_mismatch} =
               Security.close_signing_authority(tampered)

      # Original reference still works.
      assert {:ok, _} = Security.sign_with_authority(authority, "untampered")
    end

    test "owner substitution and cross-process proof replay fail closed", ctx do
      parent = self()

      # Build a proof bound to this test process as owner.
      assert {:ok, proof_for_parent} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :session,
                 owner: self()
               )

      # Different process cannot open using a proof bound to the parent.
      _ =
        spawn(fn ->
          result = Security.open_signing_authority(proof_for_parent)
          send(parent, {:cross_process_open, result})
        end)

      assert_receive {:cross_process_open, {:error, :owner_mismatch}}, 1_000

      # Parent can still open its own proof (one-shot — use a fresh proof).
      assert {:ok, proof2} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :worker,
                 owner: self()
               )

      assert {:ok, authority} = Security.open_signing_authority(proof2)
      assert {:ok, _} = Security.sign_with_authority(authority, "owner-ok")

      # Proof that names a foreign owner cannot be opened by this process.
      foreign = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, substituted} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :session,
                 owner: foreign
               )

      assert {:error, :owner_mismatch} = Security.open_signing_authority(substituted)

      Process.exit(foreign, :kill)
    end

    test "nonce replay of the same acquisition proof fails closed", ctx do
      assert {:ok, proof} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :session,
                 owner: self()
               )

      assert {:ok, authority} = Security.open_signing_authority(proof)
      assert {:ok, _} = Security.sign_with_authority(authority, "first-open")

      assert {:error, :replayed_nonce} = Security.open_signing_authority(proof)
    end
  end

  describe "lifecycle revocation" do
    test "owner death revokes the token", ctx do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, proof} =
            Security.build_signing_authority_acquisition_proof(
              ctx.agent_id,
              ctx.private_key,
              purpose: :worker,
              owner: self()
            )

          {:ok, authority} = Security.open_signing_authority(proof)
          send(parent, {:authority, authority})
          Process.sleep(:infinity)
        end)

      assert_receive {:authority, authority}, 1_000

      # Sanity: works while owner alive
      assert {:ok, _} = Security.sign_with_authority(authority, "alive")

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000

      # Allow broker to process DOWN
      wait_until(fn ->
        match?({:error, :authority_not_found}, Security.sign_with_authority(authority, "dead"))
      end)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(authority, "after-owner-death")
    end

    test "explicit close revokes the token", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      assert :ok = Security.close_signing_authority(authority)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(authority, "closed")

      assert {:error, :authority_not_found} =
               Security.close_signing_authority(authority)
    end

    test "forged and tampered references fail closed", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      forged_token = :crypto.strong_rand_bytes(32)

      {:ok, forged} =
        SigningAuthority.new(
          token: forged_token,
          principal_id: ctx.agent_id,
          purpose: :session
        )

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(forged, "forged")

      # Tamper principal while keeping real token
      tampered = %{authority | principal_id: "agent_" <> String.duplicate("00", 32)}

      assert {:error, :principal_mismatch} =
               Security.sign_with_authority(tampered, "tampered")
    end

    test "key deletion fails subsequent sign/derive", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      assert :ok = Security.delete_signing_key(ctx.agent_id)

      assert {:error, :no_signing_key} =
               Security.sign_with_authority(authority, "no-key")

      assert {:error, :no_signing_key} =
               Security.derive_secret_with_authority(authority, :capability_mac)
    end

    test "identity suspension and revocation fail closed", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      assert :ok = Security.suspend_identity(ctx.agent_id, reason: "test suspend")

      assert {:error, :identity_suspended} =
               Security.sign_with_authority(authority, "suspended")

      assert :ok = Security.resume_identity(ctx.agent_id)
      assert {:ok, _} = Security.sign_with_authority(authority, "resumed")

      assert :ok = Security.revoke_identity(ctx.agent_id, reason: "test revoke")

      assert {:error, :identity_revoked} =
               Security.sign_with_authority(authority, "revoked")
    end

    test "broker restart invalidates outstanding references", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      assert {:ok, _} = Security.sign_with_authority(authority, "before-restart")

      :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, SigningAuthorityBroker)
      {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker)

      # Stale-after-broker-restart
      assert {:error, :authority_not_found} =
               Security.sign_with_authority(authority, "after-restart")

      # Fresh open works again
      assert {:ok, authority2} = open_authority(ctx, purpose: :session)

      assert {:ok, _} = Security.sign_with_authority(authority2, "fresh")
    end
  end

  describe "state hygiene" do
    test "reference and broker state contain no functions or private keys", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      authority_map = Map.from_struct(authority)
      refute Enum.any?(authority_map, fn {_k, v} -> is_function(v) end)
      refute Map.has_key?(authority_map, :private_key)
      refute Map.has_key?(authority_map, :owner_pid)

      snapshot = SigningAuthorityBroker.debug_state()
      assert snapshot.authority_count >= 1

      Enum.each(snapshot.entries, fn entry ->
        refute entry.has_private_key?
        refute entry.has_function?
        refute entry.has_proof?
        assert entry.principal_id == ctx.agent_id or is_binary(entry.principal_id)
      end)

      # Inspect redacts token
      inspected = inspect(authority)
      refute inspected =~ authority.token
      assert inspected =~ "[REDACTED]"
    end
  end

  describe "reload-stable named dispatch regression" do
    test "retained reference still signs after facade module purge/reload", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)

      # Prove this is not a closure — named dispatch only.
      refute is_function(authority)
      assert {:ok, _} = Security.sign_with_authority(authority, "pre-reload")

      beam_path = :code.which(Arbor.Security)
      assert is_list(beam_path)

      # Purge and reload the facade module (simulates hot code load).
      # Named dispatch (not a closure) must still resolve after purge/reload.
      # purge/1 returns true only when old-code processes were killed — ignore the bool.
      _ = :code.purge(Arbor.Security)
      _ = :code.delete(Arbor.Security)

      abs_path =
        beam_path
        |> List.to_string()
        |> String.replace_suffix(".beam", "")
        |> String.to_charlist()

      assert {:module, Arbor.Security} = :code.load_abs(abs_path)
      assert function_exported?(Arbor.Security, :sign_with_authority, 2)

      # Retained reference still works via named dispatch after reload.
      assert {:ok, %SignedRequest{} = signed} =
               Security.sign_with_authority(authority, "post-reload")

      assert signed.agent_id == ctx.agent_id
      agent_id = ctx.agent_id
      assert {:ok, ^agent_id} = Security.verify_request(signed)
    end
  end

  describe "open fail-closed and facade invalid input" do
    test "rejects open when identity missing" do
      missing = "agent_" <> String.duplicate("ff", 32)
      {_pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:ok, proof} =
               Security.build_signing_authority_acquisition_proof(
                 missing,
                 priv,
                 purpose: :session,
                 owner: self()
               )

      # Unknown agent fails at verification (public key lookup).
      assert {:error, :unknown_agent} = Security.open_signing_authority(proof)
    end

    test "rejects open when signing key missing", ctx do
      :ok = Security.delete_signing_key(ctx.agent_id)

      assert {:ok, proof} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :session,
                 owner: self()
               )

      assert {:error, :no_signing_key} = Security.open_signing_authority(proof)
    end

    test "rejects missing purpose and invalid purpose values on proof generation", ctx do
      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 owner: self()
               )

      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: "",
                 owner: self()
               )

      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: "   ",
                 owner: self()
               )

      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: true,
                 owner: self()
               )

      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: false,
                 owner: self()
               )

      # Map opts path rejects blank/boolean purpose consistently.
      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 %{"purpose" => "\t", "owner" => self()}
               )

      assert {:error, :invalid_purpose} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 %{purpose: nil}
               )

      assert {:error, :invalid_owner} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 purpose: :session,
                 owner: "not-a-pid"
               )

      assert {:error, :invalid_principal_id} =
               Security.build_signing_authority_acquisition_proof(
                 "human_not_agent",
                 ctx.private_key,
                 purpose: :session
               )
    end

    test "rejects non-proof open arguments", ctx do
      assert {:error, :possession_proof_required} =
               Security.open_signing_authority(ctx.agent_id)

      assert {:error, :possession_proof_required} =
               Security.open_signing_authority(%{agent_id: ctx.agent_id})

      assert {:error, :possession_proof_required} =
               Security.open_signing_authority(nil)
    end
  end

  describe "legacy make_signer compatibility" do
    test "make_signer still returns a working closure", ctx do
      signer = Security.make_signer(ctx.agent_id, ctx.private_key)
      assert is_function(signer, 1)
      assert {:ok, %SignedRequest{}} = signer.("legacy-payload")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp open_authority(ctx, opts) do
    purpose = Keyword.fetch!(opts, :purpose)

    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             ctx.agent_id,
             ctx.private_key,
             purpose: purpose,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end

  defp ensure_broker_started do
    case Process.whereis(SigningAuthorityBroker) do
      nil ->
        case Supervisor.start_child(Arbor.Security.Supervisor, {SigningAuthorityBroker, []}) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, {:already_present, _}} ->
            _ = Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker)
            :ok

          other ->
            flunk("failed to start SigningAuthorityBroker: #{inspect(other)}")
        end

      pid when is_pid(pid) ->
        :ok
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
