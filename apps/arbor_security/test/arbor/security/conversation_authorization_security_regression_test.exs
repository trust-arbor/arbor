defmodule Arbor.Security.ConversationAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :conversation_ingress
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.DeliveryReceiptBroker
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

  test "security regression: both chat receipt APIs reject finite use before spending allowance",
       c do
    capability = grant(c, max_uses: 1, constraints: %{rate_limit: 1})
    before = DeliveryReceiptBroker.stats().issued
    assert {:error, :unsupported_conversation_capability} = issue(c)

    assert {:error, :unsupported_conversation_capability} =
             Security.authorize_and_issue_delivery_receipt(c.caller, c.resource, :chat,
               session_token: c.token
             )

    assert DeliveryReceiptBroker.stats().issued == before
    assert {:ok, caps} = Security.list_capabilities(c.caller)
    assert Enum.any?(caps, &(&1.id == capability.id))

    # Ordinary authorization can still spend the exact first use/rate allowance.
    assert {:ok, :authorized} =
             Security.authorize(c.caller, c.resource, :chat, session_token: c.token)

    assert {:ok, caps} = Security.list_capabilities(c.caller)
    refute Enum.any?(caps, &(&1.id == capability.id))
  end

  test "security regression: non-chat finite-use delivery receipts retain ordinary behavior", c do
    resource = "arbor://memory/read/" <> c.caller
    cap = grant(%{c | resource: resource}, max_uses: 1)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(c.caller, resource, :read,
               session_token: c.token
             )

    assert {:ok, subject} = Security.consume_delivery_receipt(receipt, resource, :read)
    assert subject == c.caller
    assert {:ok, caps} = Security.list_capabilities(c.caller)
    refute Enum.any?(caps, &(&1.id == cap.id))
  end

  test "security regression: resolver outage cannot spend a chat rate allowance", c do
    for suffix <- ["conversation", "generic"] do
      scoped = %{c | resource: c.resource <> "_" <> suffix}
      grant(scoped, constraints: %{rate_limit: 1})

      issue_receipt = fn ->
        if suffix == "conversation",
          do: issue(scoped),
          else:
            Security.authorize_and_issue_delivery_receipt(scoped.caller, scoped.resource, :chat,
              session_token: scoped.token
            )
      end

      Application.put_env(:arbor_security, :conversation_owner_test_aliases, :offline)
      assert {:error, :unauthorized} = issue_receipt.()
      Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{})
      assert {:ok, receipt} = issue_receipt.()
      assert :ok = Security.discard_delivery_receipt(receipt)
      assert {:error, :unauthorized} = issue_receipt.()
    end
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

  test "security regression: linked owner preserves exact receipt subject and does not transfer grants",
       c do
    grant(c)
    secondary = other_human!("secondary")

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{
      secondary.caller => c.caller
    })

    linked = Map.merge(c, secondary)

    assert {:error, :unauthorized} = issue(linked)
    grant(linked)
    assert {:ok, receipt} = issue(linked)
    assert {:ok, owner} = Security.conversation_receipt_owner(receipt, secondary.caller, c.target)
    assert owner == c.caller

    assert {:error, :unauthorized} =
             Security.conversation_receipt_owner(receipt, c.caller, c.target)

    assert {:ok, subject} = Security.consume_delivery_receipt(receipt, c.resource, :chat)
    assert subject == secondary.caller

    # The primary's token cannot authenticate the linked secondary's name.
    assert {:error, :unauthorized} = issue(%{linked | token: c.token})
  end

  test "security regression: canonical resolution outage cannot mint raw-principal shadow receipts",
       c do
    grant(c)
    before = DeliveryReceiptBroker.stats().issued
    Application.put_env(:arbor_security, :conversation_owner_test_aliases, :offline)
    assert {:error, :unauthorized} = issue(c)
    assert DeliveryReceiptBroker.stats().issued == before
    Application.delete_env(:arbor_security, :identity_alias_resolver)
    assert {:error, :unauthorized} = issue(c)
    Application.put_env(:arbor_security, :identity_alias_resolver, OwnerResolver)

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{
      c.caller => "human_absent_owner"
    })

    assert {:error, :unauthorized} = issue(c)
    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{})
    assert {:ok, receipt} = issue(c)
    assert :ok = Security.discard_delivery_receipt(receipt)
  end

  test "security regression: unlink cannot rescope a pinned receipt or continuation", c do
    owner = other_human!("primary")
    grant(c)

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{
      c.caller => owner.caller
    })

    assert {:ok, receipt} = issue(c)

    assert {:ok, :authorized} =
             Security.recheck_conversation_owner(c.caller, c.target, owner.caller)

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{})

    assert {:error, :unauthorized} =
             Security.recheck_conversation_owner(c.caller, c.target, owner.caller)

    assert {:error, :unauthorized} =
             Security.conversation_receipt_owner(receipt, c.caller, c.target)

    assert {:error, :invalid_memory_admission} =
             Security.exchange_private_memory_receipt(
               receipt,
               c.target,
               c.caller,
               %{session_id: "session_pinned", turn_id: "turn_pinned"}
             )
  end

  @fence "eng_0123456789abcdef0123456789abcdef"
  @other_fence "eng_abcdef0123456789abcdef0123456789"

  test "security regression: HMAC receipt carries a private compare-only fence through exchange and activation",
       c do
    grant(c, constraints: %{rate_limit: 1})

    assert {:ok, receipt} =
             Security.authorize_and_issue_conversation_receipt(c.caller, c.resource, :chat,
               session_token: c.token,
               expected_engagement_id: @fence
             )

    assert {:ok, admission} =
             Security.exchange_private_memory_receipt(receipt, c.target, c.caller, %{
               session_id: "session_fenced",
               turn_id: "turn_fenced"
             })

    refute inspect(admission) =~ @fence

    assert {:error, :invalid_memory_admission} =
             Security.check_private_memory_engagement(admission, @other_fence)

    assert {:error, :invalid_memory_admission} =
             Security.activate_private_memory_admission(admission, @other_fence)

    for _ <- 1..3, do: assert(:ok = Security.check_private_memory_engagement(admission, @fence))

    assert {:error, :invalid_memory_admission} =
             Task.async(fn ->
               Security.check_private_memory_engagement(admission, @fence)
             end)
             |> Task.await()

    assert :ok = Security.activate_private_memory_admission(admission, @fence)
    assert :ok = Security.check_private_memory_engagement(admission, @fence)

    assert {:error, :invalid_memory_admission} =
             Security.check_private_memory_engagement(admission, @other_fence)

    assert {:error, :unauthorized} = issue(c)
    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: invalid signed ordinary and malformed fences cannot consume allowance",
       c do
    grant(c, constraints: %{rate_limit: 1})
    {:ok, signed} = SignedRequest.sign("authorize", c.caller, c.private_key)
    before = DeliveryReceiptBroker.stats().issued

    for opts <- [
          [expected_engagement_id: @fence],
          [signed_request: signed, expected_engagement_id: @fence],
          [session_token: c.token, expected_engagement_id: nil],
          [session_token: c.token, expected_engagement_id: "eng_bad"],
          [
            session_token: c.token,
            expected_engagement_id: @fence,
            expected_engagement_id: @fence
          ],
          [session_token: c.token, expected_engagement_id: @fence, unknown: true]
        ] do
      assert {:error, :unauthorized} =
               Security.authorize_and_issue_conversation_receipt(
                 c.caller,
                 c.resource,
                 :chat,
                 opts
               )

      assert {:error, :invalid_opts} =
               Security.authorize_and_issue_delivery_receipt(c.caller, c.resource, :chat, opts)
    end

    assert {:error, :invalid_opts} =
             Security.authorize_and_issue_delivery_receipt(
               c.caller,
               "arbor://memory/read/" <> c.caller,
               :read, session_token: c.token, expected_engagement_id: @fence)

    assert DeliveryReceiptBroker.stats().issued == before
    # Invalid fence options did not consume the signed proof nonce or rate allowance.
    assert {:ok, receipt} =
             Security.authorize_and_issue_conversation_receipt(c.caller, c.resource, :chat,
               signed_request: signed
             )

    assert :ok = Security.discard_delivery_receipt(receipt)
    assert {:error, :unauthorized} = issue(c)
  end

  test "security regression: session continuation binds subject expiry owner and current grant without spending rate",
       c do
    capability = grant(c, constraints: %{rate_limit: 1})
    other = other_human!("proof-other")

    for _ <- 1..4 do
      assert {:ok, :authorized} =
               Security.recheck_conversation_session(c.caller, c.target, c.caller, c.token)
    end

    assert {:error, :unauthorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, other.token)

    {:ok, expired} = SessionToken.generate(c.caller, ttl: -1)

    assert {:error, :unauthorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, expired)

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, :offline)

    assert {:error, :unauthorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, c.token)

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{
      c.caller => other.caller
    })

    assert {:error, :unauthorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, c.token)

    assert {:ok, :authorized} =
             Security.recheck_conversation_session(c.caller, c.target, other.caller, c.token)

    Application.put_env(:arbor_security, :conversation_owner_test_aliases, %{})

    assert {:error, :unauthorized} =
             Security.recheck_conversation_session(c.caller, c.target, other.caller, c.token)

    assert {:ok, receipt} = issue(c)
    assert :ok = Security.discard_delivery_receipt(receipt)

    assert {:ok, :authorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, c.token)

    assert {:error, :unauthorized} = issue(c)
    assert :ok = Security.revoke(capability.id)

    assert {:error, :unauthorized} =
             Security.recheck_conversation_session(c.caller, c.target, c.caller, c.token)
  end

  defp other_human!(name) do
    oidc =
      OIDCTestHelper.issue_identity(
        subject: "conversation-#{name}-#{System.unique_integer([:positive])}"
      )

    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    assert {:ok, token} = SessionToken.generate(oidc.identity.agent_id)

    on_exit(fn ->
      oidc.cleanup.()
      Security.deregister_identity(oidc.identity.agent_id)
    end)

    %{caller: oidc.identity.agent_id, token: token, private_key: oidc.identity.private_key}
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
