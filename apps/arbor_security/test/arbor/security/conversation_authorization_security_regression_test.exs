defmodule Arbor.Security.ConversationAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :conversation_ingress
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.OIDCTestHelper
  alias Arbor.Security.SessionToken

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
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false,
      constraint_enforcement_enabled: true,
      session_token_secret: "conversation-proof-#{System.unique_integer([:positive])}"
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
    oidc = OIDCTestHelper.issue_identity(subject: "conversation-auth-#{suffix}")
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    caller = oidc.identity.agent_id
    target = "agent_conversation_auth_#{suffix}"
    assert {:ok, token} = SessionToken.generate(caller)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity(caller)
    end)

    %{
      caller: caller,
      target: target,
      resource: "arbor://chat/agent/" <> target,
      token: token,
      private_key: oidc.identity.private_key
    }
  end

  test "security regression: finite-use conversation rejection does not consume its only use",
       c do
    capability = grant(c, max_uses: 1)
    assert {:error, :unsupported_conversation_capability} = issue(c)
    assert {:ok, caps} = Security.list_capabilities(c.caller)
    assert Enum.any?(caps, &(&1.id == capability.id))

    # The unchanged ordinary API can still spend that first and only use.
    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(
               c.caller,
               c.resource,
               :chat,
               session_token: c.token
             )

    assert {:ok, principal} = Security.consume_delivery_receipt(receipt, c.resource, :chat)
    assert principal == c.caller
    assert {:ok, caps} = Security.list_capabilities(c.caller)
    refute Enum.any?(caps, &(&1.id == capability.id))
  end

  test "security regression: one rate allowance survives all non-consuming continuation checks",
       c do
    grant(c, constraints: %{rate_limit: 1})
    assert {:ok, receipt} = issue(c)
    on_exit(fn -> Security.discard_delivery_receipt(receipt) end)

    for _ <- 1..10 do
      assert {:ok, :authorized} = Security.recheck_conversation_access(c.caller, c.target)
    end

    # A genuinely new authenticated admission is charged and denied.
    assert {:error, :unauthorized} = issue(c)
    assert {:ok, :authorized} = Security.recheck_conversation_access(c.caller, c.target)
  end

  test "security regression: actual signed proof is verified once and cannot admit twice", c do
    grant(c)
    assert {:ok, proof} = SignedRequest.sign("authorize", c.caller, c.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_conversation_receipt(
               c.caller,
               c.resource,
               :chat,
               signed_request: proof
             )

    on_exit(fn -> Security.discard_delivery_receipt(receipt) end)
    assert {:ok, :authorized} = Security.recheck_conversation_access(c.caller, c.target)

    assert {:error, :unauthorized} =
             Security.authorize_and_issue_conversation_receipt(
               c.caller,
               c.resource,
               :chat,
               signed_request: proof
             )
  end

  test "security regression: continuation rejects current revocation and suspended identity", c do
    capability = grant(c)
    assert {:ok, receipt} = issue(c)
    on_exit(fn -> Security.discard_delivery_receipt(receipt) end)
    assert {:ok, :authorized} = Security.recheck_conversation_access(c.caller, c.target)
    assert :ok = Security.suspend_identity(c.caller)
    assert {:error, :unauthorized} = Security.recheck_conversation_access(c.caller, c.target)
    assert :ok = Security.resume_identity(c.caller)
    assert {:ok, :authorized} = Security.recheck_conversation_access(c.caller, c.target)
    assert :ok = Security.revoke(capability.id)
    assert {:error, :unauthorized} = Security.recheck_conversation_access(c.caller, c.target)
  end

  test "security regression: unknown or malformed constraints are refused before allowance consumption",
       c do
    for constraint <- [
          %{future_constraint: true},
          %{allowed_paths: [123]},
          %{time_window: %{start_hour: 0, end_hour: 24, surprise: true}}
        ] do
      capability = grant(c, constraints: Map.put(constraint, :rate_limit, 1))
      assert {:error, :unsupported_conversation_capability} = issue(c)
      assert {:error, :unauthorized} = Security.recheck_conversation_access(c.caller, c.target)
      assert :ok = Security.revoke(capability.id)
    end

    grant(c, constraints: %{rate_limit: 1})
    assert {:ok, receipt} = issue(c)
    Security.discard_delivery_receipt(receipt)
  end

  test "security regression: stateless path and time constraints stay enforced on continuation",
       c do
    for constraints <- [
          %{allowed_paths: ["arbor://chat/agent/agent_someone_else"]},
          %{time_window: %{start_hour: 0, end_hour: 0}},
          %{requires_approval: true}
        ] do
      capability = grant(c, constraints: constraints)
      assert {:error, :unauthorized} = issue(c)
      assert {:error, :unauthorized} = Security.recheck_conversation_access(c.caller, c.target)
      assert :ok = Security.revoke(capability.id)
    end

    grant(c,
      constraints: %{allowed_paths: [c.resource], time_window: %{start_hour: 0, end_hour: 24}}
    )

    assert {:ok, receipt} = issue(c)
    Security.discard_delivery_receipt(receipt)
    assert {:ok, :authorized} = Security.recheck_conversation_access(c.caller, c.target)
  end

  test "security regression: no public proof bypass, callback, routing or action options are accepted",
       c do
    grant(c)

    for opts <- [
          [],
          [session_token: "forged"],
          [session_token: c.token, verify_identity: false],
          [session_token: c.token, identity_verified: true],
          [session_token: c.token, session_id: "override"],
          [session_token: c.token, signer: fn _ -> :ok end],
          [session_token: c.token, signed_request: %{}]
        ] do
      assert {:error, :unauthorized} =
               Security.authorize_and_issue_conversation_receipt(
                 c.caller,
                 c.resource,
                 :chat,
                 opts
               )
    end

    assert {:error, :unauthorized} =
             Security.authorize_and_issue_conversation_receipt(
               c.caller,
               c.resource,
               :execute,
               session_token: c.token
             )

    assert {:error, :unauthorized} =
             Security.recheck_conversation_access(c.caller, "../../agent_other")

    assert {:error, :unauthorized} =
             Security.recheck_conversation_access("human_unknown", c.target)
  end

  test "security regression: audited authorization failure cannot mint a conversation receipt",
       c do
    grant(c)

    previous =
      for key <- [:invocation_audit_mode, :invocation_audit_sink],
          do: {key, Application.fetch_env(:arbor_security, key)}

    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_security, :invocation_audit_sink, AuthorizationFaultSink)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:arbor_security, key, original)
          :error -> Application.delete_env(:arbor_security, key)
        end
      end
    end)

    before = DeliveryReceiptBroker.stats().issued

    assert {:error, :unauthorized} =
             Security.with_invocation_audit(
               %{principal_id: c.caller, surface: :tool, tool: "conversation.submit"},
               fn -> issue(c) end
             )

    assert DeliveryReceiptBroker.stats().issued == before
  end

  defp issue(c),
    do:
      Security.authorize_and_issue_conversation_receipt(
        c.caller,
        c.resource,
        :chat,
        session_token: c.token
      )

  defp grant(c, opts \\ []) do
    assert {:ok, cap} = Security.grant([principal: c.caller, resource: c.resource] ++ opts)
    on_exit(fn -> Security.revoke(cap.id) end)
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
