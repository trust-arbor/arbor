defmodule Arbor.Security.ConversationNoticeCoreSecurityRegressionTest do
  use ExUnit.Case, async: true
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Security

  @moduletag :fast
  @scope %{
    owner_id: "human_owner",
    target_agent_id: "agent_publisher",
    engagement_id: "eng_" <> String.duplicate("a", 32)
  }
  @subject "human_subject"

  test "scope validation uses the same closed grammar without asserting authority" do
    assert {:ok, @scope} == Security.validate_notice_publication_scope(@scope)

    assert {:error, :invalid_notice} ==
             Security.validate_notice_publication_scope(
               Map.put(@scope, :recipient_subject_id, @subject)
             )

    assert {:error, :invalid_notice} ==
             Security.validate_notice_publication_scope(%{
               @scope
               | engagement_id: "eng_not-canonical"
             })
  end

  test "closed payload-bound source provenance round trips and fixes the immutable digest" do
    value = notice("café 東京\nExact content")
    assert {:ok, ^value} = Security.validate_notice_publication_value(@scope, value)
    assert {:ok, digest} = Security.notice_publication_facts_digest(@scope, value)
    assert byte_size(digest) == 64
    assert {:ok, ^digest} = Security.notice_publication_facts_digest(@scope, value)

    assert {:error, :invalid_notice} =
             Security.validate_notice_publication_value(
               @scope,
               Map.put(value, :created_at, "now")
             )
  end

  test "security regression rejects changed body, source claims and promoted taint" do
    value = notice("Private retained notice")

    assert {:error, :invalid_notice} =
             Security.validate_notice_publication_value(@scope, %{value | text: "Changed body"})

    forged = put_in(value.provenance["origin"], "heartbeat")
    assert {:error, :invalid_notice} = Security.validate_notice_publication_value(@scope, forged)
    forged = put_in(value.provenance["taint"]["taint"]["level"], "trusted")
    assert {:error, :invalid_notice} = Security.validate_notice_publication_value(@scope, forged)

    foreign = %{@scope | owner_id: "human_foreign"}
    assert {:error, :invalid_notice} = Security.validate_notice_publication_value(foreign, value)
  end

  test "security regression refuses mixed keys and additional provenance before normalization" do
    value = notice("Private retained notice")
    mixed = Map.put(value, "text", "Ambiguous body")
    assert {:error, :invalid_notice} = Security.validate_notice_publication_value(@scope, mixed)

    assert {:error, :invalid_notice} =
             Security.validate_notice_publication_value(
               Map.put(@scope, "owner_id", "human_owner"),
               value
             )

    forged = put_in(value.provenance["identity_verified"], true)
    assert {:error, :invalid_notice} = Security.validate_notice_publication_value(@scope, forged)
  end

  test "raw text bound does not silently admit JSON escaping larger than one complete record" do
    assert {:ok, _} =
             Security.validate_notice_publication_value(
               @scope,
               notice(String.duplicate("a", 32_768))
             )

    assert {:error, :notice_too_large} =
             Security.validate_notice_publication_value(
               @scope,
               notice(String.duplicate(<<1>>, 32_768))
             )

    assert {:error, :invalid_notice} =
             Security.validate_notice_publication_value(
               @scope,
               notice(String.duplicate("a", 32_769))
             )
  end

  test "native source classifications are monotonic and missing metadata is restricted" do
    params = %{
      mailbox_id: "human-mailbox",
      notice_id: "notice_" <> String.duplicate("b", 32),
      kind: "notification",
      text: "Restricted source body"
    }

    {:ok, hostile} =
      Taint.new(%{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: nil,
        chain: []
      })

    {:ok, value} = Arbor.Security.ConversationNoticeCore.new(@scope, @subject, params, [hostile])
    assert {:ok, ^value} = Security.validate_notice_publication_value(@scope, value)
    assert value.provenance["taint"]["taint"]["level"] == "hostile"
    assert value.provenance["taint"]["taint"]["sensitivity"] == "restricted"

    for unknown <- [nil, [], [%{level: :trusted}], [:trusted]] do
      {:ok, restricted} =
        Arbor.Security.ConversationNoticeCore.new(@scope, @subject, params, unknown)

      assert restricted.provenance["taint"]["taint"]["level"] == "hostile"
      assert restricted.provenance["taint"]["taint"]["sensitivity"] == "restricted"
    end

    {:ok, confidential} =
      Taint.new(%{
        level: :derived,
        sensitivity: :confidential,
        sanitizations: 0,
        confidence: :unverified,
        source: "private-source-id",
        chain: ["private-agent-id"]
      })

    {:ok, retained} =
      Arbor.Security.ConversationNoticeCore.new(@scope, @subject, params, [confidential])

    assert retained.provenance["taint"]["taint"]["level"] == "untrusted"
    assert retained.provenance["taint"]["taint"]["sensitivity"] == "confidential"
    refute Jason.encode!(retained.provenance) =~ "private-source-id"
    refute Jason.encode!(retained.provenance) =~ "private-agent-id"
  end

  defp notice(text) do
    identifier = "notice_" <> String.duplicate("b", 32)

    payload = [
      "arbor.notice.provenance.v1",
      @scope.owner_id,
      @scope.target_agent_id,
      @scope.engagement_id,
      @subject,
      identifier,
      "notification",
      text
    ]

    {:ok, taint} =
      Taint.new(%{
        level: :untrusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified,
        source: "native_conversation_notice",
        chain: []
      })

    {:ok, envelope} = TaintEnvelope.new(payload, taint)
    {:ok, persisted} = TaintEnvelope.to_map(envelope)

    %{
      notice_id: identifier,
      recipient_subject_id: @subject,
      kind: "notification",
      text: text,
      provenance: %{"origin" => "native_action", "taint" => persisted}
    }
  end
end
