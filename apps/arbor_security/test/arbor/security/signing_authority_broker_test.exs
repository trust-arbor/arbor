defmodule Arbor.Security.SigningAuthorityBrokerTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Contracts.Security.SigningAuthorityBootstrap
  alias Arbor.Security
  alias Arbor.Security.Config, as: SecurityConfig
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SigningAuthorityStateOwner

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

    test "security regression: malformed stored key never signs, derives, issues, or crashes broker",
         ctx do
      {:ok, authority} = open_authority(ctx, purpose: :malformed_persistent_key)
      broker_pid = Process.whereis(SigningAuthorityBroker)

      # Correct length, structurally invalid Ed25519 material.
      malformed_key = <<0::size(64 * 8)>>
      assert :ok = Security.store_signing_key(ctx.agent_id, malformed_key)

      assert {:error, :signing_key_invalid} =
               Security.sign_with_authority(authority, "must-not-sign")

      assert {:error, :signing_key_invalid} =
               Security.derive_secret_with_authority(authority, :must_not_derive)

      assert {:ok, proof} = acquisition_proof(ctx, :must_not_issue, self())

      assert {:error, :signing_key_invalid} =
               Security.issue_signing_authority_bootstrap(proof)

      assert Process.whereis(SigningAuthorityBroker) == broker_pid
      assert Process.alive?(broker_pid)

      snapshot = SigningAuthorityBroker.debug_state()
      refute Enum.any?(snapshot.bootstrap_entries, &(&1.purpose == :must_not_issue))

      assert {:error, :signing_key_invalid} =
               Security.sign_with_authority(authority, "still-must-not-sign")

      {:ok, other_identity} = Identity.generate(name: "wrong-persistent-key")
      assert :ok = Security.store_signing_key(ctx.agent_id, other_identity.private_key)

      assert {:error, :signing_key_mismatch} =
               Security.sign_with_authority(authority, "wrong-identity-key")

      assert {:error, :signing_key_mismatch} =
               Security.derive_secret_with_authority(authority, :wrong_identity_key)

      assert Process.whereis(SigningAuthorityBroker) == broker_pid
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

    test "security regression: broker restart preserves persistent authorities and restart slots",
         ctx do
      {:ok, authority} = open_authority(ctx, purpose: :session)
      {:ok, bootstrap} = issue_bootstrap(ctx, :restart_slot_survives, grace_ms: 5_000)

      assert {:ok, _} = Security.sign_with_authority(authority, "before-restart")

      :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, SigningAuthorityBroker)
      {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker)

      assert {:ok, _} = Security.sign_with_authority(authority, "after-restart")

      assert {:ok, claimed} = Security.claim_signing_authority(bootstrap)
      assert {:ok, _} = Security.sign_with_authority(claimed, "claimed-after-restart")

      assert {:ok, authority2} = open_authority(ctx, purpose: :session)
      assert {:ok, _} = Security.sign_with_authority(authority2, "fresh")
    end
  end

  describe "state hygiene" do
    test "security regression: only the registered broker can load or replace owner state", ctx do
      {:ok, authority} = open_authority(ctx, purpose: :owner_api_authorization)

      assert {:error, :unauthorized} = SigningAuthorityStateOwner.load()

      assert {:error, :unauthorized} =
               SigningAuthorityStateOwner.replace(%{
                 authorities: %{},
                 bootstraps: %{},
                 open_requests: %{}
               })

      assert {:ok, _signed} = Security.sign_with_authority(authority, "state-intact")
    end

    test "security regression: state-owner crash restarts broker fail closed", ctx do
      {:ok, persistent} = open_authority(ctx, purpose: :owner_crash_persistent)
      {:ok, bootstrap} = issue_bootstrap(ctx, :owner_crash_bootstrap, grace_ms: 5_000)
      ephemeral = register_ephemeral_identity("owner-crash-ephemeral")
      {:ok, proof} = acquisition_proof(ephemeral, :owner_crash_ephemeral, self())

      assert {:ok, ephemeral_authority} =
               Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)

      owner_pid = Process.whereis(SigningAuthorityStateOwner)
      broker_pid = Process.whereis(SigningAuthorityBroker)
      owner_ref = Process.monitor(owner_pid)
      broker_ref = Process.monitor(broker_pid)

      Process.exit(owner_pid, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 1_000
      assert_receive {:DOWN, ^broker_ref, :process, ^broker_pid, _reason}, 1_000

      wait_until(fn ->
        new_owner = Process.whereis(SigningAuthorityStateOwner)
        new_broker = Process.whereis(SigningAuthorityBroker)

        is_pid(new_owner) and new_owner != owner_pid and is_pid(new_broker) and
          new_broker != broker_pid
      end)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(persistent, "must-not-survive")

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(ephemeral_authority, "must-not-survive")

      assert {:error, :bootstrap_not_found} = Security.claim_signing_authority(bootstrap)
      assert {:ok, fresh} = open_authority(ctx, purpose: :after_owner_crash)
      assert {:ok, _signed} = Security.sign_with_authority(fresh, "fresh-state")
    end

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

      state_owner_status = :sys.get_status(SigningAuthorityStateOwner)
      refute contains_value?(state_owner_status, authority.token)
      refute contains_value?(state_owner_status, ctx.private_key)
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

      assert {:error, :duplicate_attribute} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 ctx.private_key,
                 %{
                   "purpose" => :other_session,
                   purpose: :session,
                   owner: self()
                 }
               )

      assert {:ok, %SignedRequest{agent_id: "human_not_agent"}} =
               Security.build_signing_authority_acquisition_proof(
                 "human_not_agent",
                 ctx.private_key,
                 purpose: :session
               )
    end

    # Security regression: malformed private keys must return a typed error,
    # never raise from :crypto.sign/5 (ErlangError "Couldn't get EDDSA private key").
    test "rejects malformed private key lengths and non-binary input (security regression)",
         ctx do
      # One-byte key: accepted by the old byte_size > 0 guard, then crashed in crypto.
      assert {:error, :invalid_private_key} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 <<1>>,
                 purpose: :session
               )

      # Other wrong lengths (including empty).
      for bad <- [
            <<>>,
            :crypto.strong_rand_bytes(16),
            :crypto.strong_rand_bytes(33),
            :crypto.strong_rand_bytes(63),
            :crypto.strong_rand_bytes(65)
          ] do
        assert {:error, :invalid_private_key} =
                 Security.build_signing_authority_acquisition_proof(
                   ctx.agent_id,
                   bad,
                   purpose: :session
                 )
      end

      # Structurally invalid 64-byte material that passes size checks must not raise.
      assert {:error, :invalid_private_key} =
               Security.build_signing_authority_acquisition_proof(
                 ctx.agent_id,
                 :crypto.strong_rand_bytes(64),
                 purpose: :session
               )

      # Non-binary private key input.
      for bad <- [nil, :atom, 123, %{key: <<1>>}, [1, 2, 3]] do
        assert {:error, :invalid_private_key} =
                 Security.build_signing_authority_acquisition_proof(
                   ctx.agent_id,
                   bad,
                   purpose: :session
                 )
      end
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

  describe "hostile partial struct-tagged authority maps" do
    test "security regression: partial struct-tagged maps fail closed without crashing broker or exiting caller",
         ctx do
      # Parent 5a0768f9: `%SigningAuthority{}` matches partial maps; field access
      # (authority.token / principal_id / purpose) raises KeyError inside the
      # broker GenServer, exits the caller, and drops live authority leases.
      assert {:ok, authority} = open_authority(ctx, purpose: :session)

      broker_pid = Process.whereis(SigningAuthorityBroker)
      assert is_pid(broker_pid)
      assert Process.alive?(broker_pid)

      # Keep a monitor so a silent broker death is observed as a DOWN message.
      broker_mon = Process.monitor(broker_pid)

      # Valid lease must remain usable across the hostile calls below.
      assert {:ok, %SignedRequest{}} =
               Security.sign_with_authority(authority, "pre-hostile-baseline")

      partial_missing = %{__struct__: SigningAuthority}
      partial_short = %{__struct__: SigningAuthority, token: "too-short"}

      partial_token_only = %{
        __struct__: SigningAuthority,
        token: :crypto.strong_rand_bytes(32)
      }

      for hostile <- [partial_missing, partial_short, partial_token_only, nil, :not_authority] do
        sign_result =
          try do
            Security.sign_with_authority(hostile, "hostile-payload")
          catch
            kind, reason -> flunk("sign_with_authority exited: #{inspect({kind, reason})}")
          end

        assert match?({:error, _}, sign_result),
               "expected shaped error for #{inspect(hostile)}, got #{inspect(sign_result)}"

        derive_result =
          try do
            Security.derive_secret_with_authority(hostile, :capability_mac)
          catch
            kind, reason ->
              flunk("derive_secret_with_authority exited: #{inspect({kind, reason})}")
          end

        assert match?({:error, _}, derive_result)

        close_result =
          try do
            Security.close_signing_authority(hostile)
          catch
            kind, reason -> flunk("close_signing_authority exited: #{inspect({kind, reason})}")
          end

        assert match?({:error, _}, close_result)
      end

      # Broker identity preserved — not restarted after a crash.
      assert Process.whereis(SigningAuthorityBroker) == broker_pid
      assert Process.alive?(broker_pid)
      refute_received {:DOWN, ^broker_mon, :process, ^broker_pid, _}

      # Pre-existing valid lease still signs after the hostile barrage.
      assert {:ok, %SignedRequest{}} =
               Security.sign_with_authority(authority, "post-hostile-still-valid")

      assert {:ok, secret} =
               Security.derive_secret_with_authority(authority, :capability_mac)

      assert is_binary(secret) and byte_size(secret) == 32
    end
  end

  describe "signing-authority bootstrap security regressions" do
    test "security regression: id-only bootstrap issuance is impossible", ctx do
      assert {:error, :possession_proof_required} =
               Security.issue_signing_authority_bootstrap(ctx.agent_id)

      assert {:error, :possession_proof_required} =
               Security.issue_signing_authority_bootstrap(ctx.agent_id, [])

      assert {:error, :possession_proof_required} =
               Security.open_ephemeral_signing_authority(ctx.agent_id, ctx.private_key)
    end

    test "security regression: replay and wrong-owner issuance fail closed", ctx do
      assert {:ok, proof} = acquisition_proof(ctx, :restart_slot, self())

      assert {:ok, %SigningAuthorityBootstrap{} = bootstrap} =
               Security.issue_signing_authority_bootstrap(proof)

      assert {:error, :replayed_nonce} =
               Security.issue_signing_authority_bootstrap(proof)

      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)

      assert {:ok, foreign_proof} = acquisition_proof(ctx, :wrong_owner, self())
      parent = self()

      spawn(fn ->
        send(parent, {:foreign_issue, Security.issue_signing_authority_bootstrap(foreign_proof)})
      end)

      assert_receive {:foreign_issue, {:error, :owner_mismatch}}, 1_000

      # Owner mismatch is rejected before Verifier consumes the nonce. The
      # rightful owner can use the exact same proof afterward.
      assert {:ok, recovered} = Security.issue_signing_authority_bootstrap(foreign_proof)
      assert :ok = Security.close_signing_authority_bootstrap(recovered)
    end

    test "security regression: issuance options are strict, bounded, and do not consume proof on rejection",
         ctx do
      max_grace_ms = SecurityConfig.signing_authority_bootstrap_max_grace_ms()
      assert {:ok, proof} = acquisition_proof(ctx, :strict_options, self())

      assert {:error, :unknown_option} =
               Security.issue_signing_authority_bootstrap(proof, unknown: true)

      assert {:error, :duplicate_option} =
               Security.issue_signing_authority_bootstrap(
                 proof,
                 grace_ms: 100,
                 grace_ms: 200
               )

      assert {:error, :mixed_option_keys} =
               Security.issue_signing_authority_bootstrap(proof, %{"grace_ms" => 100})

      assert {:error, :invalid_grace_ms} =
               Security.issue_signing_authority_bootstrap(proof, grace_ms: 0)

      assert {:error, :invalid_grace_ms} =
               Security.issue_signing_authority_bootstrap(
                 proof,
                 grace_ms: max_grace_ms + 1
               )

      assert {:ok, bootstrap} =
               Security.issue_signing_authority_bootstrap(proof, grace_ms: max_grace_ms)

      snapshot = SigningAuthorityBroker.debug_state()

      assert Enum.any?(
               snapshot.bootstrap_entries,
               &(&1.principal_id == ctx.agent_id and &1.grace_ms == max_grace_ms)
             )

      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)

      assert {:ok, minimum_proof} = acquisition_proof(ctx, :minimum_grace, self())

      assert {:ok, _minimum_bootstrap} =
               Security.issue_signing_authority_bootstrap(minimum_proof, grace_ms: 1)
    end

    test "configured grace is capped before being stored on a slot", ctx do
      max_grace_ms = SecurityConfig.signing_authority_bootstrap_max_grace_ms()
      previous = Application.get_env(:arbor_security, :signing_authority_bootstrap_grace_ms)

      Application.put_env(
        :arbor_security,
        :signing_authority_bootstrap_grace_ms,
        max_grace_ms + 10_000
      )

      on_exit(fn ->
        restore_env(:signing_authority_bootstrap_grace_ms, previous)
      end)

      assert {:ok, bootstrap} = issue_bootstrap(ctx, :capped_config)
      snapshot = SigningAuthorityBroker.debug_state()

      assert Enum.any?(
               snapshot.bootstrap_entries,
               &(&1.principal_id == ctx.agent_id and &1.grace_ms == max_grace_ms)
             )

      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)
    end

    test "security regression: tampered and partial bootstraps fail without broker crash", ctx do
      assert {:ok, bootstrap} = issue_bootstrap(ctx, :tamper_test)
      broker_pid = Process.whereis(SigningAuthorityBroker)

      assert {:error, :purpose_mismatch} =
               bootstrap
               |> Map.put(:purpose, :tampered)
               |> Security.claim_signing_authority()

      assert {:error, :principal_mismatch} =
               bootstrap
               |> Map.put(:principal_id, "human_attacker")
               |> Security.claim_signing_authority()

      partial = %{__struct__: SigningAuthorityBootstrap}
      assert {:error, _} = Security.claim_signing_authority(partial)
      assert {:error, _} = Security.close_signing_authority_bootstrap(partial)

      partial_proof = %{__struct__: SignedRequest}

      assert {:error, :invalid_acquisition_proof} =
               Security.issue_signing_authority_bootstrap(partial_proof)

      {:ok, forged} =
        SigningAuthorityBootstrap.new(
          token: :crypto.strong_rand_bytes(32),
          principal_id: ctx.agent_id,
          purpose: :tamper_test
        )

      assert {:error, :bootstrap_not_found} = Security.claim_signing_authority(forged)
      assert Process.whereis(SigningAuthorityBroker) == broker_pid

      assert {:ok, authority} = Security.claim_signing_authority(bootstrap)
      assert {:ok, %SignedRequest{}} = Security.sign_with_authority(authority, "still-live")
      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)
    end

    test "security regression: concurrent claim permits exactly one live owner", ctx do
      assert {:ok, bootstrap} = issue_bootstrap(ctx, :concurrent_claim)
      parent = self()

      claimers =
        for id <- 1..2 do
          spawn(fn ->
            receive do
              :claim ->
                result = Security.claim_signing_authority(bootstrap)
                send(parent, {:claim_result, id, self(), result})

                if match?({:ok, _}, result) do
                  receive do
                    :stop -> :ok
                  end
                end
            end
          end)
        end

      Enum.each(claimers, &send(&1, :claim))

      results =
        for _ <- 1..2 do
          assert_receive {:claim_result, id, pid, result}, 1_000
          {id, pid, result}
        end

      assert [{_id, winner, {:ok, authority}}] =
               Enum.filter(results, fn {_id, _pid, result} -> match?({:ok, _}, result) end)

      assert [{_id, _loser, {:error, :authority_already_claimed}}] =
               Enum.filter(results, fn {_id, _pid, result} -> match?({:error, _}, result) end)

      assert {:ok, %SignedRequest{}} =
               Security.sign_with_authority(authority, "engine-helper-bearer-use")

      send(winner, :stop)

      wait_until(fn ->
        match?(
          {:error, :authority_not_found},
          Security.sign_with_authority(authority, "owner-gone")
        )
      end)

      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)
    end

    test "security regression: owner death revokes and reclaim rotates authority token", ctx do
      assert {:ok, bootstrap} = issue_bootstrap(ctx, :restart_reclaim)
      parent = self()

      owner =
        spawn(fn ->
          send(parent, {:first_claim, Security.claim_signing_authority(bootstrap)})
          Process.sleep(:infinity)
        end)

      assert_receive {:first_claim, {:ok, first_authority}}, 1_000
      assert {:ok, _} = Security.sign_with_authority(first_authority, "before-owner-down")

      Process.exit(owner, :kill)

      wait_until(fn ->
        match?(
          {:error, :authority_not_found},
          Security.sign_with_authority(first_authority, "after-owner-down")
        )
      end)

      assert {:ok, second_authority} = Security.claim_signing_authority(bootstrap)
      refute second_authority.token == first_authority.token
      assert {:ok, _} = Security.sign_with_authority(second_authority, "after-reclaim")

      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(second_authority, "closed-slot")
    end

    test "closing a claimed authority releases the slot; closing bootstrap is permanent", ctx do
      assert {:ok, bootstrap} = issue_bootstrap(ctx, :explicit_close_reclaim, grace_ms: 1_000)
      assert {:ok, first_authority} = Security.claim_signing_authority(bootstrap)

      assert :ok = Security.close_signing_authority(first_authority)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(first_authority, "closed-claim")

      assert {:ok, second_authority} = Security.claim_signing_authority(bootstrap)
      refute second_authority.token == first_authority.token

      assert :ok = Security.close_signing_authority_bootstrap(bootstrap)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(second_authority, "permanently-closed")

      assert {:error, :bootstrap_not_found} = Security.claim_signing_authority(bootstrap)
    end

    test "security regression: unclaimed and reclaimable bootstrap slots expire", ctx do
      previous = Application.get_env(:arbor_security, :signing_authority_bootstrap_grace_ms)

      on_exit(fn ->
        restore_env(:signing_authority_bootstrap_grace_ms, previous)
      end)

      assert {:ok, unclaimed} = issue_bootstrap(ctx, :expiring_unclaimed, grace_ms: 25)
      assert {:ok, reclaimable} = issue_bootstrap(ctx, :expiring_reclaimable, grace_ms: 25)
      parent = self()

      owner =
        spawn(fn ->
          send(parent, {:expiring_claim, Security.claim_signing_authority(reclaimable)})
          Process.sleep(:infinity)
        end)

      assert_receive {:expiring_claim, {:ok, authority}}, 1_000

      # Reclaim must use the slot's own grace, not mutable application config.
      Application.put_env(:arbor_security, :signing_authority_bootstrap_grace_ms, 60_000)
      Process.exit(owner, :kill)

      wait_until(fn ->
        match?(
          {:error, :authority_not_found},
          Security.sign_with_authority(authority, "reclaim-grace-started")
        )
      end)

      Process.sleep(60)

      for bootstrap <- [unclaimed, reclaimable] do
        assert {:error, reason} = Security.claim_signing_authority(bootstrap)
        assert reason in [:bootstrap_expired, :bootstrap_not_found]
      end
    end

    test "human principals can issue and claim a persistent bootstrap" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      human_id = oidc.identity.agent_id

      :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
      :ok = Security.store_signing_key(human_id, oidc.identity.private_key)

      on_exit(fn ->
        oidc.cleanup.()
        _ = Security.delete_signing_key(human_id)
        _ = Security.deregister_identity(human_id)
      end)

      human_ctx = %{agent_id: human_id, private_key: oidc.identity.private_key}
      assert {:ok, bootstrap} = issue_bootstrap(human_ctx, :human_session)
      assert {:ok, authority} = Security.claim_signing_authority(bootstrap)
      assert authority.principal_id == human_id

      assert {:ok, %SignedRequest{agent_id: ^human_id}} =
               Security.sign_with_authority(authority, "human-authority")
    end
  end

  describe "ephemeral signing-authority security regressions" do
    test "security regression: mismatched supplied private key is rejected" do
      ephemeral = register_ephemeral_identity("ephemeral-mismatch")
      {:ok, other} = Identity.generate(name: "other-ephemeral-key")

      assert {:ok, proof} = acquisition_proof(ephemeral, :ephemeral, self())

      assert {:error, :private_key_mismatch} =
               Security.open_ephemeral_signing_authority(proof, other.private_key)

      assert {:error, :no_signing_key} = Security.load_signing_key(ephemeral.agent_id)
    end

    test "security regression: ephemeral proof owner must be the caller" do
      ephemeral = register_ephemeral_identity("ephemeral-owner-mismatch")
      assert {:ok, proof} = acquisition_proof(ephemeral, :ephemeral_wrong_owner, self())
      parent = self()

      spawn(fn ->
        result = Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)
        send(parent, {:ephemeral_wrong_owner, result})
      end)

      assert_receive {:ephemeral_wrong_owner, {:error, :owner_mismatch}}, 1_000
      assert {:error, :no_signing_key} = Security.load_signing_key(ephemeral.agent_id)
    end

    test "security regression: ephemeral key is wrapped in memory and never persisted" do
      ephemeral = register_ephemeral_identity("ephemeral-success")
      assert {:error, :no_signing_key} = Security.load_signing_key(ephemeral.agent_id)
      assert {:ok, proof} = acquisition_proof(ephemeral, :ephemeral, self())

      assert {:ok, authority} =
               Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)

      assert {:ok, %SignedRequest{agent_id: agent_id} = signed} =
               Security.sign_with_authority(authority, "ephemeral-sign")

      assert agent_id == ephemeral.agent_id
      expected_id = ephemeral.agent_id
      assert {:ok, ^expected_id} = Security.verify_request(signed)

      assert {:ok, secret} =
               Security.derive_secret_with_authority(authority, :ephemeral_session)

      assert byte_size(secret) == 32
      assert {:error, :no_signing_key} = Security.load_signing_key(ephemeral.agent_id)

      snapshot = SigningAuthorityBroker.debug_state()
      assert snapshot.wrapping_key_present?
      assert snapshot.ephemeral_open_request_count == 0
      assert Enum.any?(snapshot.entries, &(&1.key_source == :ephemeral))
      refute contains_value?(snapshot, ephemeral.private_key)
      refute contains_matching?(snapshot, &is_function/1)
      refute contains_key?(snapshot, :proof)
      refute contains_key?(snapshot, :signed_request)
      refute contains_key?(snapshot, :private_key)

      status = :sys.get_status(SigningAuthorityBroker)
      refute contains_value?(status, ephemeral.private_key)
      refute contains_value?(status, authority.token)

      state_owner_status = :sys.get_status(SigningAuthorityStateOwner)
      refute contains_value?(state_owner_status, ephemeral.private_key)
      refute contains_value?(state_owner_status, authority.token)
    end

    test "security regression: post-commit persistent open timeout cancels hidden authority",
         ctx do
      previous_timeout =
        Application.get_env(:arbor_security, :signing_authority_broker_call_timeout_ms)

      previous_seam =
        Application.get_env(:arbor_security, :signing_authority_persistent_open_test_seam)

      Application.put_env(:arbor_security, :signing_authority_broker_call_timeout_ms, 25)

      Application.put_env(:arbor_security, :signing_authority_persistent_open_test_seam, %{
        delay_ms: 100,
        notify_pid: self()
      })

      on_exit(fn ->
        restore_env(:signing_authority_broker_call_timeout_ms, previous_timeout)
        restore_env(:signing_authority_persistent_open_test_seam, previous_seam)
        ensure_broker_started()
      end)

      parent = self()

      owner =
        spawn(fn ->
          {:ok, proof} = acquisition_proof(ctx, :persistent_post_commit_timeout, self())
          result = Security.open_signing_authority(proof)
          send(parent, {:persistent_timeout_result, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:persistent_open_committed, request_id}, 1_000
      assert is_reference(request_id)
      assert_receive {:persistent_timeout_result, {:error, :broker_timeout}}, 1_000
      assert Process.alive?(owner)

      wait_until(fn ->
        case SigningAuthorityBroker.debug_state() do
          %{persistent_open_request_count: 0, entries: entries} ->
            not Enum.any?(entries, &(&1.purpose == :persistent_post_commit_timeout))

          _temporary_timeout ->
            false
        end
      end)

      send(owner, :stop)
    end

    test "security regression: finalization timeout cannot commit a hidden authority", ctx do
      previous_timeout =
        Application.get_env(:arbor_security, :signing_authority_broker_call_timeout_ms)

      previous_seam =
        Application.get_env(:arbor_security, :signing_authority_persistent_finalize_test_seam)

      Application.put_env(:arbor_security, :signing_authority_broker_call_timeout_ms, 25)

      Application.put_env(:arbor_security, :signing_authority_persistent_finalize_test_seam, %{
        delay_ms: 100,
        notify_pid: self()
      })

      on_exit(fn ->
        restore_env(:signing_authority_broker_call_timeout_ms, previous_timeout)
        restore_env(:signing_authority_persistent_finalize_test_seam, previous_seam)
        ensure_broker_started()
      end)

      parent = self()

      owner =
        spawn(fn ->
          {:ok, proof} = acquisition_proof(ctx, :persistent_finalize_timeout, self())
          result = Security.open_signing_authority(proof)
          send(parent, {:persistent_finalize_result, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:persistent_finalize_prepared, request_id}, 1_000
      assert is_reference(request_id)
      assert_receive {:persistent_finalize_result, {:error, :broker_timeout}}, 1_000
      assert Process.alive?(owner)

      wait_until(fn ->
        case SigningAuthorityBroker.debug_state() do
          %{persistent_open_request_count: 0, entries: entries} ->
            not Enum.any?(entries, &(&1.purpose == :persistent_finalize_timeout))

          _temporary_timeout ->
            false
        end
      end)

      send(owner, :stop)
    end

    test "security regression: timed-out persistent claim releases restart slot", ctx do
      {:ok, bootstrap} = issue_bootstrap(ctx, :claim_post_commit_timeout, grace_ms: 5_000)

      previous_timeout =
        Application.get_env(:arbor_security, :signing_authority_broker_call_timeout_ms)

      previous_seam =
        Application.get_env(:arbor_security, :signing_authority_persistent_open_test_seam)

      Application.put_env(:arbor_security, :signing_authority_broker_call_timeout_ms, 25)

      Application.put_env(:arbor_security, :signing_authority_persistent_open_test_seam, %{
        delay_ms: 100,
        notify_pid: self()
      })

      on_exit(fn ->
        restore_env(:signing_authority_broker_call_timeout_ms, previous_timeout)
        restore_env(:signing_authority_persistent_open_test_seam, previous_seam)
        ensure_broker_started()
      end)

      parent = self()

      owner =
        spawn(fn ->
          result = Security.claim_signing_authority(bootstrap)
          send(parent, {:persistent_claim_timeout_result, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:persistent_open_committed, request_id}, 1_000
      assert is_reference(request_id)
      assert_receive {:persistent_claim_timeout_result, {:error, :broker_timeout}}, 1_000
      assert Process.alive?(owner)

      wait_until(fn ->
        case SigningAuthorityBroker.debug_state() do
          %{entries: entries, bootstrap_entries: bootstrap_entries} ->
            not Enum.any?(entries, &(&1.purpose == :claim_post_commit_timeout)) and
              Enum.any?(
                bootstrap_entries,
                &(&1.purpose == :claim_post_commit_timeout and &1.status == :reclaimable)
              )

          _temporary_timeout ->
            false
        end
      end)

      restore_env(:signing_authority_persistent_open_test_seam, previous_seam)
      assert {:ok, reclaimed} = Security.claim_signing_authority(bootstrap)
      assert {:ok, _} = Security.sign_with_authority(reclaimed, "reclaimed-after-timeout")

      send(owner, :stop)
    end

    test "security regression: broker restart revokes unfinalized persistent open", ctx do
      previous_seam =
        Application.get_env(:arbor_security, :signing_authority_persistent_open_test_seam)

      Application.put_env(:arbor_security, :signing_authority_persistent_open_test_seam, %{
        delay_ms: 500,
        notify_pid: self()
      })

      on_exit(fn ->
        restore_env(:signing_authority_persistent_open_test_seam, previous_seam)
        ensure_broker_started()
      end)

      parent = self()

      owner =
        spawn(fn ->
          {:ok, proof} = acquisition_proof(ctx, :persistent_restart_during_commit, self())
          result = Security.open_signing_authority(proof)
          send(parent, {:persistent_restart_result, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:persistent_open_committed, request_id}, 1_000
      assert is_reference(request_id)
      restart_broker()

      assert_receive {:persistent_restart_result, {:error, :broker_unavailable}}, 1_000
      assert Process.alive?(owner)

      snapshot = SigningAuthorityBroker.debug_state()
      assert snapshot.persistent_open_request_count == 0
      refute Enum.any?(snapshot.entries, &(&1.purpose == :persistent_restart_during_commit))

      send(owner, :stop)
    end

    test "security regression: broker timeout carries no plaintext key and stale handoff cannot execute" do
      ephemeral = register_ephemeral_identity("ephemeral-timeout")
      broker_pid = Process.whereis(SigningAuthorityBroker)

      previous_timeout =
        Application.get_env(:arbor_security, :signing_authority_broker_call_timeout_ms)

      Application.put_env(:arbor_security, :signing_authority_broker_call_timeout_ms, 25)
      :ok = :sys.suspend(broker_pid)

      on_exit(fn ->
        safe_resume(broker_pid)
        restore_env(:signing_authority_broker_call_timeout_ms, previous_timeout)
        ensure_broker_started()
      end)

      parent = self()

      task =
        Task.async(fn ->
          {:ok, proof} = acquisition_proof(ephemeral, :ephemeral_timeout, self())
          send(parent, :ephemeral_timeout_calling)
          Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)
        end)

      assert_receive :ephemeral_timeout_calling, 1_000

      wait_until(fn ->
        {:messages, messages} = Process.info(broker_pid, :messages)

        Enum.any?(messages, fn
          {:"$gen_call", _from,
           {:open_ephemeral, request_id, %SignedRequest{}, holder_pid, transfer_ref}} ->
            is_reference(request_id) and is_pid(holder_pid) and is_reference(transfer_ref)

          _ ->
            false
        end)
      end)

      {:messages, messages} = Process.info(broker_pid, :messages)
      refute contains_value?(messages, ephemeral.private_key)

      assert {:error, :broker_timeout} = Task.await(task, 1_000)
      safe_resume(broker_pid)

      wait_until(fn ->
        snapshot = SigningAuthorityBroker.debug_state()
        not Enum.any?(snapshot.entries, &(&1.principal_id == ephemeral.agent_id))
      end)

      assert Process.whereis(SigningAuthorityBroker) == broker_pid
    end

    test "security regression: post-commit open timeout cancels hidden ephemeral authority" do
      ephemeral = register_ephemeral_identity("ephemeral-post-commit-timeout")
      broker_pid = Process.whereis(SigningAuthorityBroker)

      previous_timeout =
        Application.get_env(:arbor_security, :signing_authority_broker_call_timeout_ms)

      previous_seam =
        Application.get_env(:arbor_security, :signing_authority_ephemeral_open_test_seam)

      Application.put_env(:arbor_security, :signing_authority_broker_call_timeout_ms, 25)

      Application.put_env(:arbor_security, :signing_authority_ephemeral_open_test_seam, %{
        delay_ms: 100,
        notify_pid: self()
      })

      on_exit(fn ->
        restore_env(:signing_authority_broker_call_timeout_ms, previous_timeout)
        restore_env(:signing_authority_ephemeral_open_test_seam, previous_seam)
        ensure_broker_started()
      end)

      task =
        Task.async(fn ->
          {:ok, proof} = acquisition_proof(ephemeral, :post_commit_timeout, self())
          Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)
        end)

      assert_receive {:ephemeral_open_committed, request_id}, 1_000
      assert is_reference(request_id)
      assert {:error, :broker_timeout} = Task.await(task, 1_000)

      wait_until(fn ->
        case SigningAuthorityBroker.debug_state() do
          %{ephemeral_open_request_count: 0, entries: entries} ->
            not Enum.any?(entries, &(&1.principal_id == ephemeral.agent_id))

          _temporary_timeout ->
            false
        end
      end)

      assert Process.whereis(SigningAuthorityBroker) == broker_pid
      assert {:error, :no_signing_key} = Security.load_signing_key(ephemeral.agent_id)
    end

    test "security regression: format_status redacts messages and all sensitive state" do
      private_key = :crypto.strong_rand_bytes(32)
      wrapping_key = :crypto.strong_rand_bytes(32)
      bearer_token = :crypto.strong_rand_bytes(32)
      ciphertext = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(12)
      tag = :crypto.strong_rand_bytes(16)

      status = %{
        message: {:open_ephemeral, private_key},
        reason: {:handler_failed, wrapping_key},
        log: [{:previous_message, bearer_token, ciphertext}],
        state: %{
          wrapping_key: wrapping_key,
          authorities: %{
            bearer_token => %{
              key_source: %{kind: :ephemeral, ciphertext: ciphertext, iv: iv, tag: tag}
            }
          },
          bootstraps: %{bearer_token => %{token: bearer_token}},
          monitors: %{}
        }
      }

      redacted = SigningAuthorityBroker.format_status(status)
      assert redacted.message == :redacted
      assert redacted.reason == :redacted
      assert redacted.log == :redacted

      for secret <- [private_key, wrapping_key, bearer_token, ciphertext, iv, tag] do
        refute contains_value?(redacted, secret)
      end

      holder_redacted =
        Arbor.Security.SigningAuthorityBroker.KeyHolder.format_status(status)

      refute contains_value?(holder_redacted, private_key)
      assert holder_redacted.message == :redacted
      assert holder_redacted.reason == :redacted
      assert holder_redacted.log == :redacted
    end

    test "security regression: corrupted wrapping state returns typed errors without broker crash" do
      ephemeral = register_ephemeral_identity("ephemeral-corrupt-wrapping")
      assert {:ok, proof} = acquisition_proof(ephemeral, :ephemeral_corrupt, self())

      assert {:ok, authority} =
               Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)

      broker_pid = Process.whereis(SigningAuthorityBroker)
      :sys.replace_state(broker_pid, &Map.put(&1, :wrapping_key, <<0>>))

      assert {:error, :key_decryption_failed} =
               Security.sign_with_authority(authority, "must-not-sign")

      assert {:error, :key_decryption_failed} =
               Security.derive_secret_with_authority(authority, :must_not_derive)

      assert Process.whereis(SigningAuthorityBroker) == broker_pid
      restart_broker()
    end

    test "security regression: owner death removes ephemeral authority and wrapped data" do
      ephemeral = register_ephemeral_identity("ephemeral-owner-down")
      parent = self()

      owner =
        spawn(fn ->
          {:ok, proof} = acquisition_proof(ephemeral, :ephemeral_owner, self())
          result = Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)
          send(parent, {:ephemeral_authority, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:ephemeral_authority, {:ok, authority}}, 1_000
      assert {:ok, _} = Security.sign_with_authority(authority, "owner-live")

      Process.exit(owner, :kill)

      wait_until(fn ->
        match?(
          {:error, :authority_not_found},
          Security.sign_with_authority(authority, "owner-dead")
        )
      end)

      snapshot = SigningAuthorityBroker.debug_state()

      refute Enum.any?(
               snapshot.entries,
               &(&1.principal_id == ephemeral.agent_id and &1.key_source == :ephemeral)
             )
    end

    test "security regression: broker restart invalidates ephemeral authority", ctx do
      ephemeral = register_ephemeral_identity("ephemeral-restart")
      assert {:ok, proof} = acquisition_proof(ephemeral, :ephemeral_restart, self())

      assert {:ok, authority} =
               Security.open_ephemeral_signing_authority(proof, ephemeral.private_key)

      assert {:ok, _} = Security.sign_with_authority(authority, "before-restart")
      restart_broker()

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(authority, "after-restart")

      assert {:error, :no_signing_key} = Security.load_signing_key(ephemeral.agent_id)

      # Persistent acquisition remains available after restart.
      assert {:ok, persistent} = open_authority(ctx, purpose: :persistent_after_restart)
      assert {:ok, _} = Security.sign_with_authority(persistent, "persistent")
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

  defp acquisition_proof(ctx, purpose, owner) do
    Security.build_signing_authority_acquisition_proof(
      ctx.agent_id,
      ctx.private_key,
      purpose: purpose,
      owner: owner
    )
  end

  defp issue_bootstrap(ctx, purpose, opts \\ []) do
    with {:ok, proof} <- acquisition_proof(ctx, purpose, self()) do
      Security.issue_signing_authority_bootstrap(proof, opts)
    end
  end

  defp register_ephemeral_identity(name) do
    {:ok, identity} = Identity.generate(name: name)
    :ok = Security.register_identity(Identity.public_only(identity))

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{
      agent_id: identity.agent_id,
      private_key: identity.private_key,
      public_key: identity.public_key
    }
  end

  defp restart_broker do
    :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, SigningAuthorityBroker)
    {:ok, _pid} = Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)

  defp safe_resume(pid) do
    try do
      :sys.resume(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp contains_value?(%{__struct__: _} = term, target), do: term == target

  defp contains_value?(term, target) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      key == target or value == target or contains_value?(value, target)
    end)
  end

  defp contains_value?(term, target) when is_list(term),
    do: Enum.any?(term, &(&1 == target or contains_value?(&1, target)))

  defp contains_value?(_term, _target), do: false

  defp contains_matching?(%{__struct__: _} = term, predicate), do: predicate.(term)

  defp contains_matching?(term, predicate) when is_map(term) do
    predicate.(term) or
      Enum.any?(term, fn {key, value} ->
        predicate.(key) or predicate.(value) or contains_matching?(value, predicate)
      end)
  end

  defp contains_matching?(term, predicate) when is_list(term) do
    predicate.(term) or Enum.any?(term, &contains_matching?(&1, predicate))
  end

  defp contains_matching?(term, predicate), do: predicate.(term)

  defp contains_key?(%{__struct__: _}, _target), do: false

  defp contains_key?(term, target) when is_map(term) do
    Map.has_key?(term, target) or Enum.any?(Map.values(term), &contains_key?(&1, target))
  end

  defp contains_key?(term, target) when is_list(term),
    do: Enum.any?(term, &contains_key?(&1, target))

  defp contains_key?(_term, _target), do: false

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
