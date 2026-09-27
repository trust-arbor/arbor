Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationSignedBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Security
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.OIDCTestHelper

  @moduletag :fast
  @moduletag :conversation_ingress

  setup do
    overrides = [
      identity_alias_resolver: OIDCTestHelper.UnlinkedIdentityResolver,
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false,
      policy_enforcer_enabled: false,
      approval_guard_enabled: false
    ]

    previous =
      for {key, value} <- overrides do
        old = Application.fetch_env(:arbor_security, key)
        Application.put_env(:arbor_security, key, value)
        {key, old}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    oidc =
      OIDCTestHelper.issue_identity(
        subject: "signed-conversation-#{System.unique_integer([:positive])}"
      )

    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    caller = oidc.identity.agent_id
    target = "agent_signed_target_#{System.unique_integer([:positive])}"

    assert {:ok, cap} =
             Security.grant(principal: caller, resource: "arbor://chat/agent/" <> target)

    on_exit(fn ->
      Security.revoke(cap.id)
      Security.deregister_identity(caller)
      oidc.cleanup.()
    end)

    %{caller: caller, target: target, private_key: oidc.identity.private_key}
  end

  test "security regression: valid unrelated signature cannot mint receipt for conversation history",
       c do
    assert {:ok, proof} = SignedRequest.sign("POST\n/unrelated\n{}", c.caller, c.private_key)
    before = DeliveryReceiptBroker.stats().issued

    result = Arbor.Agent.conversation_history(c.caller, c.target, signed_request: proof)

    assert DeliveryReceiptBroker.stats().issued == before
    assert {:error, :unauthorized} = result
    # Binding rejection precedes nonce consumption; this is a real valid proof.
    assert {:ok, caller} = Security.verify_request(proof)
    assert caller == c.caller
  end

  test "security regression: public operation binding rejects altered target cursor and page",
       c do
    for payload <- [
          [
            "arbor.conversation.v2",
            "submit",
            c.caller,
            c.target,
            ["id", "text"],
            [nil, nil, nil],
            nil
          ],
          [
            "arbor.conversation.v2",
            "history",
            c.caller,
            c.target <> "_other",
            nil,
            [0, 10, 2],
            nil
          ],
          ["arbor.conversation.v2", "history", c.caller, c.target, nil, [1, 10, 2], nil],
          ["arbor.conversation.v2", "history", c.caller, c.target, nil, [0, 11, 2], nil],
          ["arbor.conversation.v2", "history", c.caller, c.target, nil, [0, 10, 3], nil],
          ["arbor.conversation.v1", "history", c.caller, c.target, nil, [0, 10, 2]],
          [
            "arbor.conversation.v2",
            "history",
            c.caller,
            c.target,
            nil,
            [0, 10, 2],
            "eng_00000000000000000000000000000001"
          ]
        ] do
      assert {:ok, proof} = SignedRequest.sign(Jason.encode!(payload), c.caller, c.private_key)
      before = DeliveryReceiptBroker.stats().issued

      result =
        Arbor.Agent.conversation_history(c.caller, c.target,
          signed_request: proof,
          after: 0,
          through: 10,
          limit: 2
        )

      assert DeliveryReceiptBroker.stats().issued == before
      assert {:error, :unauthorized} = result
      assert {:ok, _} = Security.verify_request(proof)
    end
  end

  test "security regression: unrelated valid signature cannot mint a generic message receipt",
       c do
    assert {:ok, proof} = SignedRequest.sign("POST\n/unrelated\n{}", c.caller, c.private_key)
    message = UserMessage.from_cli("private turn", "Operator", sender_id: c.caller)
    before = DeliveryReceiptBroker.stats().issued
    result = Arbor.Agent.send_message(c.caller, c.target, message, signed_request: proof)
    assert DeliveryReceiptBroker.stats().issued == before
    assert {:error, :unauthorized} = result
    assert {:ok, caller} = Security.verify_request(proof)
    assert caller == c.caller
  end

  test "security regression: generic native envelope proof binds target text timestamp and metadata",
       c do
    message = UserMessage.from_cli("signed turn", "Operator", sender_id: c.caller)
    encoded = :erlang.term_to_binary(message, [:deterministic])
    digest = Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
    payload = Jason.encode!(["arbor.message.v1", c.caller, c.target, digest])
    assert {:ok, ^payload} = Arbor.Agent.message_request_payload(c.caller, c.target, message)

    for {target, changed} <- [
          {c.target <> "_changed", message},
          {c.target, %{message | content: "altered turn"}},
          {c.target, %{message | sent_at: DateTime.add(message.sent_at, 1, :second)}},
          {c.target, %{message | transport_metadata: %{task_id: "other_task"}}},
          {c.target, %{message | sender: "Other operator"}}
        ] do
      assert {:ok, proof} = SignedRequest.sign(payload, c.caller, c.private_key)
      before = DeliveryReceiptBroker.stats().issued
      result = Arbor.Agent.send_message(c.caller, target, changed, signed_request: proof)
      assert DeliveryReceiptBroker.stats().issued == before
      assert {:error, :unauthorized} = result
      assert {:ok, _} = Security.verify_request(proof)
    end

    # The exact unchanged envelope reaches authorization and mints one receipt;
    # this fixture deliberately has no running destination Session.
    assert {:ok, proof} = SignedRequest.sign(payload, c.caller, c.private_key)
    before = DeliveryReceiptBroker.stats().issued

    assert {:error, :delivery_failed} =
             Arbor.Agent.send_message(c.caller, c.target, message, signed_request: proof)

    assert DeliveryReceiptBroker.stats().issued == before + 1
    assert {:error, _} = Security.verify_request(proof)
  end
end
