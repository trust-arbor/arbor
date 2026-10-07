Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationWindowSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.{DeliveryReceiptBroker, OIDCTestHelper}
  @moduletag :fast
  @moduletag :conversation_ingress

  defmodule WindowPersistence do
    def normalize_conversation_window_options(opts),
      do: Arbor.Persistence.normalize_conversation_window_options(opts)

    def read_conversation_window(agent, engagement, opts) do
      send(self(), {:window_read, agent, engagement, opts})
      if callback = Process.get(:after_window_read), do: callback.()
      {:ok, %{entries: [], head: 0, first: 0, last: 0, has_older: false, has_newer: false}}
    end
  end

  setup do
    settings = [
      {:arbor_security, :identity_alias_resolver, OIDCTestHelper.UnlinkedIdentityResolver},
      {:arbor_security, :identity_verification, true},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :capability_signing_required, true},
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :policy_enforcer_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_comms, :conversation_persistence_module, WindowPersistence}
    ]

    previous =
      for {app, key, value} <- settings do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    oidc = OIDCTestHelper.issue_identity(subject: "window-#{System.unique_integer([:positive])}")
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    caller = oidc.identity.agent_id
    target = "agent_window_#{System.unique_integer([:positive])}"

    assert {:ok, cap} =
             Security.grant_fixture(principal: caller, resource: "arbor://chat/agent/" <> target)

    on_exit(fn ->
      Security.revoke_fixture(cap.id)
      Security.deregister_identity_fixture(caller)
      oidc.cleanup.()
    end)

    %{caller: caller, target: target, key: oidc.identity.private_key, cap: cap}
  end

  test "public window resolves the authorized owner and consumes fresh proof each time", c do
    for _ <- 1..2 do
      assert {:ok, %{engagement_id: engagement, entries: [], head: 0}} = read(c, [])
      assert_receive {:window_read, target, ^engagement, []}
      assert target == c.target
    end
  end

  test "security regression window rejects a replayed nonce and a revoked grant", c do
    proof = proof(c, [])
    assert {:ok, _} = Arbor.Agent.conversation_window(c.caller, c.target, signed_request: proof)
    assert_receive {:window_read, _, _, _}

    assert {:error, :unauthorized} =
             Arbor.Agent.conversation_window(c.caller, c.target, signed_request: proof)

    refute_receive {:window_read, _, _, _}
    assert :ok = Security.revoke_fixture(c.cap.id)
    assert {:error, :unauthorized} = read(c, [])
    refute_receive {:window_read, _, _, _}
  end

  test "security regression authorization is rechecked before publishing a window", c do
    Process.put(:after_window_read, fn -> Security.revoke_fixture(c.cap.id) end)
    assert {:error, :unauthorized} = read(c, [])
    assert_receive {:window_read, _, _, _}
  end

  test "security regression window fence cannot select another owner's engagement", c do
    assert {:ok, page} = read(c, [])
    assert_receive {:window_read, _, _, _}
    foreign = "eng_00000000000000000000000000000001"
    refute page.engagement_id == foreign
    assert {:error, :conversation_scope_changed} = read(c, expected_engagement_id: foreign)
    refute_receive {:window_read, _, _, _}
  end

  test "security regression signed window binds each selector target and continuity fence", c do
    opts = [before: 20, through: 30, limit: 2]

    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(:window, c.caller, c.target, nil, opts)

    for {target, changed} <- [
          {c.target <> "_other", opts},
          {c.target, [before: 19, through: 30, limit: 2]},
          {c.target, [after: 20, through: 30, limit: 2]},
          {c.target, [before: 20, through: 31, limit: 2]},
          {c.target, [before: 20, through: 30, limit: 3]},
          {c.target, opts ++ [expected_engagement_id: "eng_00000000000000000000000000000001"]}
        ] do
      {:ok, proof} = SignedRequest.sign(payload, c.caller, c.key)
      before = DeliveryReceiptBroker.stats().issued

      assert {:error, :unauthorized} =
               Arbor.Agent.conversation_window(
                 c.caller,
                 target,
                 [signed_request: proof] ++ changed
               )

      assert DeliveryReceiptBroker.stats().issued == before
      assert {:ok, _} = Security.verify_request(proof)
    end

    refute_receive {:window_read, _, _, _}
  end

  test "security regression window rejects authority overrides and invalid bounds before authentication",
       c do
    for opts <- [
          [engagement_id: "eng_foreign"],
          [principal_id: c.caller],
          [before: 1, after: 0],
          [before: nil],
          [after: nil],
          [through: nil],
          [limit: 101],
          [limit: 0],
          [limit: 1, limit: 2],
          [before: 4, through: 3],
          [after: -1],
          [facade: WindowPersistence]
        ] do
      before = DeliveryReceiptBroker.stats().issued

      assert {:error, :invalid_opts} =
               Arbor.Agent.conversation_window(
                 c.caller,
                 c.target,
                 [session_token: "invalid-proof"] ++ opts
               )

      assert DeliveryReceiptBroker.stats().issued == before
    end

    refute_receive {:window_read, _, _, _}
  end

  test "window payload is independent and all existing v2 operations retain exact bytes", c do
    assert {:ok, payload} =
             Arbor.Agent.conversation_request_payload(:window, c.caller, c.target, nil,
               before: 2,
               limit: 1
             )

    assert Jason.decode!(payload) == [
             "arbor.conversation.window.v1",
             c.caller,
             c.target,
             [2, nil, nil, 1],
             nil
           ]

    for {operation, input, encoded} <- [
          {:history, nil, nil},
          {:events, 0, 0},
          {:command, "saved", "saved"},
          {:submit, %{id: "saved", text: "hello"}, ["saved", "hello"]}
        ] do
      assert {:ok, actual} =
               Arbor.Agent.conversation_request_payload(operation, c.caller, c.target, input)

      assert actual ==
               Jason.encode!([
                 "arbor.conversation.v2",
                 Atom.to_string(operation),
                 c.caller,
                 c.target,
                 encoded,
                 [nil, nil, nil],
                 nil
               ])
    end
  end

  defp proof(c, opts) do
    {:ok, payload} =
      Arbor.Agent.conversation_request_payload(:window, c.caller, c.target, nil, opts)

    {:ok, proof} = SignedRequest.sign(payload, c.caller, c.key)
    proof
  end

  defp read(c, opts),
    do:
      Arbor.Agent.conversation_window(
        c.caller,
        c.target,
        [signed_request: proof(c, opts)] ++ opts
      )
end
