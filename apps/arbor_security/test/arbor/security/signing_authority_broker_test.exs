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

  describe "open_signing_authority/2 + sign_with_authority/2" do
    test "signs payload and verifies via SignedRequest path", ctx do
      assert {:ok, authority} =
               Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

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
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

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
    end
  end

  describe "lifecycle revocation" do
    test "owner death revokes the token", ctx do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, authority} =
            Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :worker)

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
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

      assert :ok = Security.close_signing_authority(authority)

      assert {:error, :authority_not_found} =
               Security.sign_with_authority(authority, "closed")

      assert {:error, :authority_not_found} =
               Security.close_signing_authority(authority)
    end

    test "forged and tampered references fail closed", ctx do
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

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
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

      assert :ok = Security.delete_signing_key(ctx.agent_id)

      assert {:error, :no_signing_key} =
               Security.sign_with_authority(authority, "no-key")

      assert {:error, :no_signing_key} =
               Security.derive_secret_with_authority(authority, :capability_mac)
    end

    test "identity suspension and revocation fail closed", ctx do
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

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
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

      assert {:ok, _} = Security.sign_with_authority(authority, "before-restart")

      :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, SigningAuthorityBroker)
      {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker)

      # Stale-after-broker-restart
      assert {:error, :authority_not_found} =
               Security.sign_with_authority(authority, "after-restart")

      # Fresh open works again
      assert {:ok, authority2} =
               Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

      assert {:ok, _} = Security.sign_with_authority(authority2, "fresh")
    end
  end

  describe "state hygiene" do
    test "reference and broker state contain no functions or private keys", ctx do
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

      authority_map = Map.from_struct(authority)
      refute Enum.any?(authority_map, fn {_k, v} -> is_function(v) end)
      refute Map.has_key?(authority_map, :private_key)
      refute Map.has_key?(authority_map, :owner_pid)

      snapshot = SigningAuthorityBroker.debug_state()
      assert snapshot.authority_count >= 1

      Enum.each(snapshot.entries, fn entry ->
        refute entry.has_private_key?
        refute entry.has_function?
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
      {:ok, authority} =
        Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)

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

  describe "open fail-closed" do
    test "rejects open when identity missing" do
      missing = "agent_" <> String.duplicate("ff", 32)

      assert {:error, :identity_not_found} =
               Security.open_signing_authority(missing, owner: self(), purpose: :session)
    end

    test "rejects open when signing key missing", ctx do
      :ok = Security.delete_signing_key(ctx.agent_id)

      assert {:error, :no_signing_key} =
               Security.open_signing_authority(ctx.agent_id, owner: self(), purpose: :session)
    end

    test "rejects missing owner/purpose opts", ctx do
      assert {:error, :invalid_owner} =
               Security.open_signing_authority(ctx.agent_id, purpose: :session)

      assert {:error, :invalid_purpose} =
               Security.open_signing_authority(ctx.agent_id, owner: self())
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
