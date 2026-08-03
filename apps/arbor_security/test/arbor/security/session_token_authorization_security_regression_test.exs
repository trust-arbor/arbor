defmodule Arbor.Security.SessionTokenAuthorizationSecurityRegressionTest.FaultyVerifierError do
  @moduledoc false
  def verify(_token), do: {:error, :boom}
end

defmodule Arbor.Security.SessionTokenAuthorizationSecurityRegressionTest.FaultyVerifierRaise do
  @moduledoc false
  def verify(_token), do: raise("verifier boom")
end

defmodule Arbor.Security.SessionTokenAuthorizationSecurityRegressionTest.FaultyVerifierThrow do
  @moduledoc false
  def verify(_token), do: throw(:verifier_throw)
end

defmodule Arbor.Security.SessionTokenAuthorizationSecurityRegressionTest.FaultyVerifierExit do
  @moduledoc false
  def verify(_token), do: exit(:verifier_exit)
end

defmodule Arbor.Security.SessionTokenAuthorizationSecurityRegressionTest do
  @moduledoc """
  Security regression: wire human session_token proof into public
  `Arbor.Security.authorize/4` under enabled identity verification.

  Prerequisite for VOICE-9 (no VOICE marker change in this slice).
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  @sentinel_prefix "SESSION_TOKEN_SENTINEL_"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)

    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    :ok
  end

  setup do
    prev = %{
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      secret: Application.get_env(:arbor_security, :session_token_secret),
      token_mod: Application.get_env(:arbor_security, :session_token_module)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "vp05a1-test-secret-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      restore(:identity_verification, prev.identity_verification)
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
      restore(:session_token_secret, prev.secret)
      restore(:session_token_module, prev.token_mod)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)

  defp register_human! do
    n = System.unique_integer([:positive])
    oidc = Arbor.Security.OIDCTestHelper.issue_identity(subject: "vp05a1-#{n}")
    human_id = oidc.identity.agent_id

    assert :ok =
             Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp attach_auth_events!(parent) do
    id = "vp05a1-auth-events-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:arbor, :security, :authorization_granted],
          [:arbor, :security, :authorization_denied]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:auth_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  defp refute_sentinel_in_term(term, sentinel) do
    refute inspect(term) =~ sentinel
  end

  describe "security regression: valid human session token under identity verification" do
    test "security regression: active human + matching token + capability authorizes" do
      human_id = register_human!()
      resource = "arbor://chat/agent/agent_vp05a1_target_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)

      assert {:ok, token} = SessionToken.generate(human_id)

      assert {:ok, :authorized} =
               Security.authorize(human_id, resource, :chat, session_token: token)
    end

    test "security regression: valid token without capability denies before effect" do
      human_id = register_human!()
      resource = "arbor://chat/agent/agent_vp05a1_nocap_#{System.unique_integer([:positive])}"
      assert {:ok, token} = SessionToken.generate(human_id)

      assert {:error, :unauthorized} =
               Security.authorize(human_id, resource, :chat, session_token: token)
    end
  end

  describe "security regression: present-value fail-closed classes" do
    test "security regression: nil empty non-binary duplicate oversized deny" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_present_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat, session_token: nil)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat, session_token: "")

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat, session_token: :not_binary)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat,
                 session_token: "a",
                 session_token: "b"
               )

      oversized = String.duplicate("x", 4097)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat, session_token: oversized)
    end

    test "security regression: wrong principal non-human expired tampered malformed deny" do
      human_a = register_human!()
      human_b = register_human!()
      resource = "arbor://test/vp05a1_bind_#{System.unique_integer([:positive])}"
      grant!(human_a, resource)
      grant!(human_b, resource)

      assert {:ok, token_b} = SessionToken.generate(human_b)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_a, resource, :chat, session_token: token_b)

      # Non-human principal with a token minted for that agent id
      {:ok, agent_identity} = Identity.generate(name: "vp05a1-agent")
      agent_id = agent_identity.agent_id
      assert :ok = Security.register_identity(agent_identity)

      on_exit(fn ->
        _ = Security.deregister_identity(agent_id)
      end)

      grant!(agent_id, resource)
      assert {:ok, agent_token} = SessionToken.generate(agent_id)

      assert {:error, :invalid_session_token} =
               Security.authorize(agent_id, resource, :chat, session_token: agent_token)

      assert {:ok, expired} = SessionToken.generate(human_a, ttl: -1)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_a, resource, :chat, session_token: expired)

      assert {:ok, good} = SessionToken.generate(human_a)
      {:ok, raw} = Base.url_decode64(good, padding: false)
      <<sig::binary-size(32), first, rest::binary>> = raw

      tampered =
        Base.url_encode64(sig <> <<Bitwise.bxor(first, 0xFF)>> <> rest, padding: false)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_a, resource, :chat, session_token: tampered)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_a, resource, :chat, session_token: "!!!not-base64!!!")
    end

    test "security regression: verifier error raise throw exit normalize to :invalid_session_token" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_seam_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)

      for mod <- [
            __MODULE__.FaultyVerifierError,
            __MODULE__.FaultyVerifierRaise,
            __MODULE__.FaultyVerifierThrow,
            __MODULE__.FaultyVerifierExit
          ] do
        Application.put_env(:arbor_security, :session_token_module, mod)

        assert {:error, :invalid_session_token} =
                 Security.authorize(human_id, resource, :chat, session_token: "any-token-value")
      end

      Application.delete_env(:arbor_security, :session_token_module)
    end

    test "security regression: simultaneous token and signed_request is ambiguous after active status" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_ambiguous_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      dummy_sr = %{
        agent_id: human_id,
        signature: <<0>>,
        nonce: "n",
        timestamp: DateTime.utc_now()
      }

      assert {:error, :ambiguous_identity_proof} =
               Security.authorize(human_id, resource, :chat,
                 session_token: token,
                 signed_request: dummy_sr
               )
    end
  end

  describe "security regression: identity status forced with token" do
    test "security regression: suspended identity denies even with identity_verified true and valid token" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_suspend_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      assert :ok = Security.suspend_identity(human_id, reason: "vp05a1")

      assert {:error, {:unauthorized, :identity_suspended}} =
               Security.authorize(human_id, resource, :chat,
                 session_token: token,
                 identity_verified: true
               )
    end

    test "security regression: revoked identity denies before capability with valid token" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_revoke_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      assert :ok = Security.revoke_identity(human_id, reason: "vp05a1")

      assert {:error, {:unauthorized, :identity_revoked}} =
               Security.authorize(human_id, resource, :chat,
                 session_token: token,
                 identity_verified: true
               )
    end

    test "security regression: active identity with identity_verified true still validates token" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_force_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)
      other = register_human!()
      assert {:ok, wrong_token} = SessionToken.generate(other)

      # identity_verified alone must not skip token validation when token present
      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat,
                 session_token: wrong_token,
                 identity_verified: true
               )

      assert {:ok, good} = SessionToken.generate(human_id)

      assert {:ok, :authorized} =
               Security.authorize(human_id, resource, :chat,
                 session_token: good,
                 identity_verified: true
               )
    end

    test "security regression: suspended + both proofs returns status not ambiguous" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_status_first_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)
      assert :ok = Security.suspend_identity(human_id, reason: "status-first")

      dummy_sr = %{
        agent_id: human_id,
        signature: <<0>>,
        nonce: "n",
        timestamp: DateTime.utc_now()
      }

      assert {:error, {:unauthorized, :identity_suspended}} =
               Security.authorize(human_id, resource, :chat,
                 session_token: token,
                 signed_request: dummy_sr
               )
    end

    test "security regression: strict mode unknown unregistered human denies before verifier/capability" do
      Application.put_env(:arbor_security, :strict_identity_mode, true)

      # Unregistered human_ id — never written to the Registry.
      unknown =
        "human_" <>
          String.slice(
            Base.encode16(:crypto.strong_rand_bytes(20), case: :lower),
            0,
            40
          )

      resource = "arbor://test/vp05a1_unknown_#{System.unique_integer([:positive])}"
      # Capability present must not matter — status fails first.
      grant!(unknown, resource)
      assert {:ok, token} = SessionToken.generate(unknown)

      # Config seam that would raise if the verifier were reached.
      Application.put_env(
        :arbor_security,
        :session_token_module,
        __MODULE__.FaultyVerifierRaise
      )

      assert {:error, {:unauthorized, :unknown_identity}} =
               Security.authorize(unknown, resource, :chat, session_token: token)

      assert {:error, {:unauthorized, :unknown_identity}} =
               Security.authorize(unknown, resource, :chat,
                 session_token: token,
                 identity_verified: true
               )

      Application.delete_env(:arbor_security, :session_token_module)
    end
  end

  describe "security regression: token redaction from events" do
    test "security regression: distinctive token sentinel absent from grant and deny events" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_redact_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)

      assert {:ok, token} = SessionToken.generate(human_id)
      # Distinctive present invalid proof for deny path (plain text, not HMAC).
      sentinel = @sentinel_prefix <> Integer.to_string(System.unique_integer([:positive]))
      assert byte_size(sentinel) > 20

      parent = self()
      attach_auth_events!(parent)

      assert {:ok, :authorized} =
               Security.authorize(human_id, resource, :chat,
                 session_token: token,
                 trace_id: "trace-keep-me"
               )

      assert_receive {:auth_event, [:arbor, :security, :authorization_granted], _, meta}
      refute_sentinel_in_term(meta, token)
      refute_sentinel_in_term(meta, sentinel)

      # Parallel non-token option remains available to event consumers.
      assert meta.data.trace_id == "trace-keep-me"

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat,
                 session_token: sentinel,
                 trace_id: "trace-deny"
               )

      assert_receive {:auth_event, [:arbor, :security, :authorization_denied], _, deny_meta}
      refute_sentinel_in_term(deny_meta, sentinel)
      refute_sentinel_in_term(deny_meta, token)
    end
  end

  describe "security regression: missing proof still required when verification on" do
    test "security regression: no proof with verification enabled is :missing_signed_request" do
      human_id = register_human!()
      resource = "arbor://test/vp05a1_missing_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)

      assert {:error, :missing_signed_request} =
               Security.authorize(human_id, resource, :chat)
    end

    test "security regression: present token validates even when identity_verification is off" do
      Application.put_env(:arbor_security, :identity_verification, false)
      human_id = register_human!()
      resource = "arbor://test/vp05a1_always_#{System.unique_integer([:positive])}"
      grant!(human_id, resource)

      assert {:error, :invalid_session_token} =
               Security.authorize(human_id, resource, :chat, session_token: "bad-token")

      assert {:ok, token} = SessionToken.generate(human_id)

      assert {:ok, :authorized} =
               Security.authorize(human_id, resource, :chat, session_token: token)
    end
  end
end
