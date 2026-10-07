defmodule Arbor.Security.ConversationSessionSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :conversation_ingress
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.OIDCTestHelper
  alias Arbor.Security.SessionToken

  defmodule OwnerResolver do
    def resolve(id) do
      case Application.get_env(:arbor_security, :conversation_owner_test_aliases, %{}) do
        aliases when is_map(aliases) -> {:ok, Map.get(aliases, id, id)}
        _ -> {:error, :alias_store_unavailable}
      end
    end
  end

  defmodule AuthorizationFaultSink do
    def persist_security_invocation(%{"stage" => "authorization"}), do: {:error, :offline}
    def persist_security_invocation(event), do: {:ok, event["id"]}
  end

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
          {Arbor.Security.AuthorityStore, name: name, backend: backend, namespace: collection},
          id: name
        )

      ensure_child(child)
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ],
        do: ensure_child(child)

    :ok
  end

  setup do
    overrides = [
      identity_alias_resolver: OwnerResolver,
      conversation_owner_test_aliases: %{},
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false,
      constraint_enforcement_enabled: true,
      session_token_secret: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    ]

    before =
      Enum.map(overrides, fn {key, _} -> {key, Application.fetch_env(:arbor_security, key)} end)

    for {key, value} <- overrides, do: Application.put_env(:arbor_security, key, value)

    on_exit(fn ->
      for {key, previous} <- before do
        case previous do
          {:ok, value} -> Application.put_env(:arbor_security, key, value)
          :error -> Application.delete_env(:arbor_security, key)
        end
      end
    end)

    suffix = System.unique_integer([:positive])
    oidc = OIDCTestHelper.issue_identity(subject: "conversation-session-#{suffix}")
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    caller = oidc.identity.agent_id
    target = "agent_conversation_auth_#{suffix}"
    assert {:ok, token} = SessionToken.generate(caller)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity_fixture(caller)
    end)

    %{
      caller: caller,
      target: target,
      resource: "arbor://chat/agent/" <> target,
      token: token,
      private_key: oidc.identity.private_key
    }
  end

  test "security regression: exact signed session request issues a short-lived human proof", c do
    grant(c)
    signed = sign(c)
    assert {:ok, token} = Security.issue_signed_conversation_session(c.caller, c.target, signed)

    assert {:ok, :authorized} =
             Security.authorize(c.caller, c.resource, :chat, session_token: token)

    {:ok, <<_mac::binary-size(32), payload::binary>>} = Base.url_decode64(token, padding: false)
    claims = :erlang.binary_to_term(payload, [:safe])
    assert claims.exp - claims.iat == 90

    assert {:ok, :authorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, token)
  end

  test "security regression: exchanged conversation token is rejected by the generic verifier",
       c do
    grant(c)
    assert {:ok, token} = Security.issue_signed_conversation_session(c.caller, c.target, sign(c))
    assert {:error, _} = SessionToken.verify(token)
  end

  test "security regression: exchanged token cannot authenticate another chat target with a grant",
       c do
    grant(c)
    other = %{c | target: c.target <> "_other", resource: c.resource <> "_other"}
    grant(other)
    assert {:ok, token} = Security.issue_signed_conversation_session(c.caller, c.target, sign(c))
    assert {:error, _} = Security.authorize(c.caller, other.resource, :chat, session_token: token)

    assert {:error, _} =
             Security.recheck_conversation_session(c.caller, other.target, c.caller, token)
  end

  test "security regression: exchanged token cannot authenticate unrelated granted resources",
       c do
    grant(c)
    resource = "arbor://test/conversation_scope_#{System.unique_integer([:positive])}"
    grant(%{c | resource: resource})
    assert {:ok, token} = Security.issue_signed_conversation_session(c.caller, c.target, sign(c))

    assert {:ok, :authorized} =
             Security.authorize(c.caller, resource, :execute, session_token: c.token)

    assert {:error, _} = Security.authorize(c.caller, resource, :execute, session_token: token)
  end

  test "security regression: exchanged token requires chat action even on the exact resource",
       c do
    grant(c)
    assert {:ok, token} = Security.issue_signed_conversation_session(c.caller, c.target, sign(c))
    assert {:error, _} = Security.authorize(c.caller, c.resource, :execute, session_token: token)
  end

  test "security regression: session exchange cannot replay a consumed signed nonce", c do
    grant(c)
    signed = sign(c)
    assert {:ok, _} = Security.issue_signed_conversation_session(c.caller, c.target, signed)

    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, c.target, signed)
  end

  test "security regression: ordinary signed chat payload cannot become a reusable session", c do
    grant(c)
    {:ok, signed} = SignedRequest.sign("ordinary-chat-payload", c.caller, c.private_key)

    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, c.target, signed)
  end

  test "security regression: signed session target cannot be changed", c do
    grant(c)
    other = %{c | target: c.target <> "_other", resource: c.resource <> "_other"}
    grant(other)

    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, other.target, sign(c))
  end

  test "security regression: signature forgery is denied even when ordinary verification defaults off",
       c do
    grant(c)
    Application.put_env(:arbor_security, :identity_verification, false)
    signed = %{sign(c) | signature: :binary.copy(<<0>>, 64)}

    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, c.target, signed)
  end

  test "security regression: signature alone cannot grant conversation permission", c do
    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, c.target, sign(c))
  end

  test "security regression: finite-use capability cannot become a reusable session", c do
    grant(c, max_uses: 1)

    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, c.target, sign(c))
  end

  test "security regression: suspended signer cannot exchange a session", c do
    grant(c)
    signed = sign(c)
    assert :ok = Security.suspend_identity_fixture(c.caller)

    assert {:error, :unauthorized} =
             Security.issue_signed_conversation_session(c.caller, c.target, signed)
  end

  test "security regression: existing session cannot bypass later capability revocation", c do
    cap = grant(c)
    assert {:ok, token} = Security.issue_signed_conversation_session(c.caller, c.target, sign(c))
    assert :ok = Security.revoke_fixture(cap.id)

    assert {:error, _} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, token)
  end

  test "security regression: subject mismatch and malformed proof fail closed", c do
    grant(c)
    signed = %{sign(c) | agent_id: c.caller <> "_other"}

    for proof <- [signed, nil, %{}, %{__struct__: SignedRequest}, c.token, [payload: "private"]] do
      assert {:error, :unauthorized} =
               Security.issue_signed_conversation_session(c.caller, c.target, proof)
    end
  end

  test "session request payload has a closed bounded namespace", c do
    for target <- ["", "agent_../other", "agent_bad/resource", :agent, String.duplicate("a", 257)] do
      assert {:error, :unauthorized} =
               Security.conversation_session_request_payload(c.caller, target)
    end

    assert {:error, :unauthorized} =
             Security.conversation_session_request_payload(c.target, c.target)

    assert {:ok, payload} = Security.conversation_session_request_payload(c.caller, c.target)
    assert Jason.decode!(payload) == ["arbor.conversation.session", 1, c.caller, c.target, 90]
  end

  defp sign(c) do
    assert {:ok, payload} = Security.conversation_session_request_payload(c.caller, c.target)
    assert {:ok, signed} = SignedRequest.sign(payload, c.caller, c.private_key)
    signed
  end

  defp grant(c, opts \\ []) do
    assert {:ok, cap} =
             Security.grant_fixture([principal: c.caller, resource: c.resource] ++ opts)

    on_exit(fn -> Security.revoke_fixture(cap.id) end)
    cap
  end

  defp ensure_child(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
    end
  end
end
