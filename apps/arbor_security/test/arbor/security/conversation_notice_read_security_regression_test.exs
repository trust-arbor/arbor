defmodule Arbor.Security.ConversationNoticeReadSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}
  @eng "eng_" <> String.duplicate("d", 32)

  setup do
    overrides = [
      identity_alias_resolver: OIDCTestHelper.UnlinkedIdentityResolver,
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false,
      constraint_enforcement_enabled: true,
      session_token_secret: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    ]

    before = for {key, _} <- overrides, do: {key, Application.fetch_env(:arbor_security, key)}
    for {key, value} <- overrides, do: Application.put_env(:arbor_security, key, value)
    oidc = OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    {:ok, target} = Identity.generate(name: "notice-read-target")
    assert :ok = Security.register_identity_fixture(Identity.public_only(target))
    {:ok, token} = SessionToken.generate(oidc.identity.agent_id)
    subject = oidc.identity.agent_id
    resource = "arbor://chat/agent/" <> target.agent_id
    {:ok, cap} = Security.grant_fixture(principal: subject, resource: resource)

    on_exit(fn ->
      oidc.cleanup.()
      Security.deregister_identity_fixture(subject)
      Security.deregister_identity_fixture(target.agent_id)

      for {key, previous} <- before do
        case previous do
          {:ok, value} -> Application.put_env(:arbor_security, key, value)
          :error -> Application.delete_env(:arbor_security, key)
        end
      end
    end)

    %{
      subject: subject,
      target: target.agent_id,
      token: token,
      cap: cap,
      resource: resource,
      private_key: oidc.identity.private_key
    }
  end

  test "fresh human notice proof releases payload-bound hostile restricted data", c do
    assert {:ok, page} =
             read(c, fn owner, release ->
               scope = scope(c, owner)
               page = page(scope, c.subject)

               assert page.notices
                      |> hd()
                      |> get_in([:provenance, "taint", "taint", "sensitivity"]) == "restricted"

               assert :ok = release.(scope, page)
               {:ok, page}
             end)

    assert page.notices |> hd() |> Map.fetch!(:text) == "Exact private notice"
  end

  test "security regression: revoked prepared chat grant cannot fall back after a blocked read",
       c do
    assert {:error, :unauthorized} =
             read(c, fn owner, release ->
               scope = scope(c, owner)
               page = page(scope, c.subject)
               assert :ok = Security.revoke_fixture(c.cap.id)

               assert {:ok, _} =
                        Security.grant_fixture(principal: c.subject, resource: c.resource)

               release.(scope, page)
             end)
  end

  test "security regression: lease invalidation and changed scope refuse visual release", c do
    assert {:error, :unauthorized} =
             read(c, fn owner, release ->
               scope = scope(c, owner)

               Application.put_env(
                 :arbor_security,
                 :session_token_secret,
                 Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
               )

               release.(scope, page(scope, c.subject))
             end)

    {:ok, replacement} = SessionToken.generate(c.subject)
    fresh = %{c | token: replacement}

    assert {:error, :unauthorized} =
             read(fresh, fn owner, release ->
               scope = %{scope(c, owner) | engagement_id: "eng_" <> String.duplicate("e", 32)}
               release.(scope, page(scope, c.subject))
             end)
  end

  test "security regression: signed human retirement during read prevents visual release", c do
    {:ok, payload} =
      Security.conversation_notice_read_request_payload(c.subject, c.target, [], @eng)

    {:ok, proof} = SignedRequest.sign(payload, c.subject, c.private_key)

    assert {:error, :unauthorized} =
             Security.with_authenticated_conversation_notice_read(
               c.subject,
               c.target,
               payload,
               [signed_request: proof, expected_engagement_id: @eng],
               fn owner, release ->
                 scope = scope(c, owner)
                 page = page(scope, c.subject)
                 assert :ok = Security.deregister_identity_fixture(c.subject)
                 release.(scope, page)
               end
             )
  end

  test "same-scope corrupted provenance refuses only notice data; foreign page closes scope", c do
    assert {:error, :invalid_notice_response} =
             read(c, fn owner, release ->
               scope = scope(c, owner)
               page = page(scope, c.subject)
               [record] = page.notices
               forged = put_in(record.provenance["taint"]["taint"]["level"], "trusted")
               release.(scope, %{page | notices: [forged]})
             end)

    assert {:error, :conversation_scope_changed} =
             read(c, fn owner, release ->
               scope = scope(c, owner)
               page = %{page(scope, c.subject) | owner_id: "human_foreign_notice_owner"}
               release.(scope, page)
             end)
  end

  test "security regression: malformed closed producer fields are never released", c do
    for mutate <- [
          &Map.put(&1, :producer_private, "must not reach wire"),
          fn page ->
            update_in(page.notices, fn [record] -> [Map.put(record, :proof, "private")] end)
          end,
          fn page -> put_in(page.notices, [hd(page.notices), hd(page.notices)]) end,
          fn page -> put_in(page.notices, [%{hd(page.notices) | ordinal: 0}]) end,
          fn page ->
            put_in(page.notices, [%{hd(page.notices) | created_at: "not a server timestamp"}])
          end,
          fn page ->
            put_in(page.notices, [%{hd(page.notices) | created_at: "2026-10-03T00:00:00Z"}])
          end,
          fn page ->
            put_in(page.notices, [%{hd(page.notices) | created_at: "2026-10-03T00:00:00.000Z"}])
          end,
          fn page ->
            put_in(page.notices, [
              %{hd(page.notices) | created_at: "2026-10-03T00:00:00.000000+00:00"}
            ])
          end,
          &Map.put(&1, :through, 2),
          &Map.put(&1, :complete, false),
          &Map.merge(&1, %{has_older: true, next_before: nil}),
          &Map.merge(&1, %{has_older: false, next_before: 1})
        ] do
      assert {:error, :invalid_notice_response} =
               read(c, fn owner, release ->
                 scope = scope(c, owner)
                 release.(scope, mutate.(page(scope, c.subject)))
               end)
    end
  end

  test "security regression: exact admitted notice cursor and limit bind producer output", c do
    for {options, mutate} <- [
          {[before: 1], & &1},
          {[through: 2], & &1},
          {[limit: 1],
           fn page ->
             [record] = page.notices
             scope = Map.take(page, [:owner_id, :target_agent_id, :engagement_id])

             params = %{
               mailbox_id: "owner",
               notice_id: "notice_" <> String.duplicate("a", 32),
               kind: record.kind,
               text: record.text
             }

             {:ok, value} =
               Arbor.Security.ConversationNoticeCore.new(scope, c.subject, params, nil)

             newer = Map.merge(value, %{ordinal: 2, created_at: record.created_at})
             %{page | notices: [newer, record], head: 2, through: 2}
           end}
        ] do
      {:ok, payload} =
        Security.conversation_notice_read_request_payload(c.subject, c.target, options, @eng)

      assert {:error, :invalid_notice_response} =
               Security.with_authenticated_conversation_notice_read(
                 c.subject,
                 c.target,
                 payload,
                 [session_token: c.token, expected_engagement_id: @eng],
                 fn owner, release ->
                   scope = scope(c, owner)
                   release.(scope, mutate.(page(scope, c.subject)))
                 end
               )
    end
  end

  test "security regression: missing fence and extra proof fields never enter notice read", c do
    {:ok, payload} =
      Security.conversation_notice_read_request_payload(c.subject, c.target, [], @eng)

    for opts <- [
          [session_token: c.token],
          [session_token: c.token, expected_engagement_id: nil],
          [session_token: c.token, expected_engagement_id: @eng, identity_verified: true],
          [session_token: c.token, expected_engagement_id: @eng, task_id: "caller-owned"]
        ] do
      assert {:error, :unauthorized} =
               Security.with_authenticated_conversation_notice_read(
                 c.subject,
                 c.target,
                 payload,
                 opts,
                 fn _, _ -> flunk("invalid proof reached read") end
               )
    end
  end

  test "nonhuman unsupported domain requires fresh exact proof and consumes no allowance", c do
    {:ok, reader} = Identity.generate(name: "signed-notice-reader")
    assert :ok = Security.register_identity_fixture(Identity.public_only(reader))

    {:ok, _cap} =
      Security.grant_fixture(
        principal: reader.agent_id,
        resource: c.resource,
        constraints: %{rate_limit: 1}
      )

    {:ok, payload} =
      Security.conversation_notice_read_request_payload(reader.agent_id, c.target, [], @eng)

    {:ok, proof} = SignedRequest.sign(payload, reader.agent_id, reader.private_key)
    opts = [signed_request: proof, expected_engagement_id: @eng]

    assert {:error, :notice_subject_required} =
             Security.with_authenticated_conversation_notice_read(
               reader.agent_id,
               c.target,
               payload,
               opts,
               fn _, _ -> flunk("nonhuman read executed") end
             )

    assert {:error, :unauthorized} =
             Security.with_authenticated_conversation_notice_read(
               reader.agent_id,
               c.target,
               payload,
               opts,
               fn _, _ -> flunk("replayed notice proof executed") end
             )

    {:ok, ordinary} = SignedRequest.sign(c.resource, reader.agent_id, reader.private_key)

    assert {:ok, :authorized} =
             Security.authorize(reader.agent_id, c.resource, :chat,
               signed_request: ordinary,
               expected_resource: c.resource
             )

    Security.deregister_identity_fixture(reader.agent_id)
  end

  defp read(c, continuation) do
    {:ok, payload} =
      Security.conversation_notice_read_request_payload(c.subject, c.target, [], @eng)

    Security.with_authenticated_conversation_notice_read(
      c.subject,
      c.target,
      payload,
      [session_token: c.token, expected_engagement_id: @eng],
      continuation
    )
  end

  defp scope(c, owner), do: %{owner_id: owner, target_agent_id: c.target, engagement_id: @eng}

  defp page(scope, subject) do
    params = %{
      mailbox_id: "owner",
      notice_id: "notice_" <> String.duplicate("f", 32),
      kind: "notification",
      text: "Exact private notice"
    }

    # Shared pure grammar treats absent source metadata as hostile/restricted.
    {:ok, value} = Arbor.Security.ConversationNoticeCore.new(scope, subject, params, nil)
    record = Map.merge(value, %{ordinal: 1, created_at: "2026-10-03T00:00:00.000000Z"})

    Map.merge(scope, %{
      notices: [record],
      head: 1,
      through: 1,
      has_older: false,
      next_before: nil,
      complete: true
    })
  end
end
