defmodule Arbor.Orchestrator.Session.SessionCheckpointTaintSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Persistence

  @moduletag :fast
  @moduletag :security_regression

  test "security regression: current checkpoint round trip preserves exact labels without a 64 KiB content ceiling" do
    large_content = String.duplicate("checkpoint-content-", 4_000)
    user_taint = taint("current_user", :hostile)
    assistant_taint = taint("current_assistant", :untrusted)

    messages = [
      labeled_message("user", large_content, user_taint),
      labeled_message("assistant", "current response", assistant_taint)
    ]

    checkpoint = Persistence.extract_checkpoint_data(session(messages, "eng-current"))

    assert is_map(checkpoint)
    assert byte_size(large_content) > TaintEnvelope.limits().max_string_bytes

    assert Enum.all?(checkpoint["messages"], fn record ->
             Enum.sort(Map.keys(record)) == ["envelope", "payload", "status"]
           end)

    Enum.each(checkpoint["messages"], fn record ->
      refute Map.has_key?(record["payload"], "taint")
      refute Map.has_key?(record["payload"], "taint_status")
    end)

    restored = Persistence.apply_checkpoint(session([], "eng-other"), checkpoint)

    assert restored.current_engagement_id == "eng-current"
    assert restored.messages == messages
  end

  test "security regression: legacy rows ignore forged caller labels and preserve order" do
    forged_trusted = taint("forged_legacy_trusted", :trusted)

    legacy_messages = [
      %{
        "role" => "user",
        "content" => "legacy first",
        "taint" => forged_trusted,
        "taint_status" => :verified
      },
      %{"role" => "assistant", "content" => "legacy second"}
    ]

    restored =
      session([], "eng-legacy")
      |> Persistence.apply_checkpoint(%{"messages" => legacy_messages})

    assert Enum.map(restored.messages, & &1["content"]) == ["legacy first", "legacy second"]

    Enum.each(restored.messages, fn message ->
      assert message["taint"] == TaintEnvelope.missing_fallback()
      assert message["taint_status"] == :legacy_unlabeled
    end)
  end

  test "security regression: payload and envelope corruption retain content only with invalid provenance" do
    checkpoint =
      [labeled_message("user", "bound payload", taint("bound_payload", :hostile))]
      |> session("eng-corrupt")
      |> Persistence.extract_checkpoint_data()

    payload_tampered =
      put_in(checkpoint, ["messages", Access.at(0), "payload", "content"], "changed payload")

    payload_restored =
      Persistence.apply_checkpoint(session([], "eng-other"), payload_tampered)

    assert [payload_message] = payload_restored.messages
    assert payload_message["content"] == "changed payload"
    assert_invalid(payload_message)

    envelope_tampered =
      update_in(checkpoint, ["messages", Access.at(0), "envelope"], fn envelope ->
        Map.delete(envelope, "payload_sha256")
      end)

    envelope_restored =
      Persistence.apply_checkpoint(session([], "eng-other"), envelope_tampered)

    assert [envelope_message] = envelope_restored.messages
    assert envelope_message["content"] == "bound payload"
    assert_invalid(envelope_message)
  end

  test "security regression: legacy and invalid checkpoint statuses cannot be flipped to verified" do
    legacy_checkpoint =
      [%{"role" => "user", "content" => "legacy labeled by encoder"}]
      |> session("eng-status")
      |> Persistence.extract_checkpoint_data()

    assert get_in(legacy_checkpoint, ["messages", Access.at(0), "status"]) ==
             "legacy_unlabeled"

    legacy_tampered =
      put_in(legacy_checkpoint, ["messages", Access.at(0), "status"], "verified")

    assert [legacy_message] =
             Persistence.apply_checkpoint(session([], "eng-status"), legacy_tampered).messages

    assert_invalid(legacy_message)

    invalid_checkpoint =
      [
        %{
          "role" => "assistant",
          "content" => "invalid labeled by encoder",
          "taint" => %{"malformed" => true},
          "taint_status" => :verified
        }
      ]
      |> session("eng-status")
      |> Persistence.extract_checkpoint_data()

    assert get_in(invalid_checkpoint, ["messages", Access.at(0), "status"]) ==
             "invalid_durable_provenance"

    invalid_tampered =
      put_in(invalid_checkpoint, ["messages", Access.at(0), "status"], "verified")

    assert [invalid_message] =
             Persistence.apply_checkpoint(session([], "eng-status"), invalid_tampered).messages

    assert_invalid(invalid_message)
  end

  test "security regression: equal-payload envelopes cannot be swapped across list positions" do
    payload = %{"role" => "user", "content" => "identical content"}

    messages = [
      Map.merge(payload, %{
        "taint" => taint("first_position", :hostile),
        "taint_status" => :verified
      }),
      Map.merge(payload, %{
        "taint" => taint("second_position", :untrusted),
        "taint_status" => :verified
      })
    ]

    checkpoint = Persistence.extract_checkpoint_data(session(messages, "eng-positions"))
    [first, second] = checkpoint["messages"]

    assert first["payload"] == second["payload"]
    refute first["envelope"] == second["envelope"]

    swapped =
      Map.put(checkpoint, "messages", [
        Map.put(first, "envelope", second["envelope"]),
        Map.put(second, "envelope", first["envelope"])
      ])

    restored = Persistence.apply_checkpoint(session([], "eng-positions"), swapped)

    assert Enum.map(restored.messages, & &1["content"]) == [
             "identical content",
             "identical content"
           ]

    Enum.each(restored.messages, &assert_invalid/1)
  end

  test "security regression: suffix truncation invalidates every remaining message label" do
    messages = [
      labeled_message("user", "first complete message", taint("complete_first", :hostile)),
      labeled_message(
        "assistant",
        "second complete message",
        taint("complete_second", :untrusted)
      ),
      labeled_message("user", "required suffix", taint("complete_suffix", :hostile))
    ]

    checkpoint = Persistence.extract_checkpoint_data(session(messages, "eng-completeness"))
    truncated = update_in(checkpoint["messages"], &Enum.drop(&1, -1))
    restored = Persistence.apply_checkpoint(session([], "eng-completeness"), truncated)

    assert Enum.map(restored.messages, & &1["content"]) == [
             "first complete message",
             "second complete message"
           ]

    Enum.each(restored.messages, &assert_invalid/1)
  end

  test "security regression: complete message-list deletion cannot retain a prior transcript" do
    checkpoint =
      [labeled_message("user", "checkpoint transcript", taint("deleted_list", :hostile))]
      |> session("eng-delete-list")
      |> Persistence.extract_checkpoint_data()

    prior = labeled_message("assistant", "must be cleared", taint("prior_transcript", :hostile))
    target = session([prior], "eng-delete-list")

    removed = Map.delete(checkpoint, "messages")
    assert Persistence.apply_checkpoint(target, removed).messages == []

    emptied = Map.put(checkpoint, "messages", [])
    assert Persistence.apply_checkpoint(target, emptied).messages == []

    stripped = Map.drop(checkpoint, ["messages", "messages_manifest"])
    assert Persistence.apply_checkpoint(target, stripped).messages == []
  end

  test "security regression: same-scope checkpoint records cannot be spliced" do
    checkpoint_a =
      [
        labeled_message("user", "checkpoint A user", taint("checkpoint_a_user", :hostile)),
        labeled_message(
          "assistant",
          "checkpoint A assistant",
          taint("checkpoint_a_assistant", :untrusted)
        )
      ]
      |> session("eng-splice")
      |> Persistence.extract_checkpoint_data()

    checkpoint_b =
      [
        labeled_message("user", "checkpoint B user", taint("checkpoint_b_user", :untrusted)),
        labeled_message(
          "assistant",
          "checkpoint B assistant",
          taint("checkpoint_b_assistant", :hostile)
        )
      ]
      |> session("eng-splice")
      |> Persistence.extract_checkpoint_data()

    [first_a, _second_a] = checkpoint_a["messages"]
    [_first_b, second_b] = checkpoint_b["messages"]
    spliced = Map.put(checkpoint_a, "messages", [first_a, second_b])
    restored = Persistence.apply_checkpoint(session([], "eng-splice"), spliced)

    assert Enum.map(restored.messages, & &1["content"]) == [
             "checkpoint A user",
             "checkpoint B assistant"
           ]

    Enum.each(restored.messages, &assert_invalid/1)
  end

  test "security regression: a valid empty transcript carries a zero-count manifest" do
    checkpoint = Persistence.extract_checkpoint_data(session([], "eng-empty"))

    assert checkpoint["messages"] == []

    assert %{
             "payload" => %{
               "domain" => "arbor.session.checkpoint.transcript.v1",
               "message_count" => 0,
               "records_digest" => %{},
               "scope_digest" => %{}
             },
             "envelope" => %{}
           } = checkpoint["messages_manifest"]

    prior = labeled_message("user", "empty replaces this", taint("empty_prior", :hostile))
    restored = Persistence.apply_checkpoint(session([prior], "eng-empty"), checkpoint)

    assert restored.messages == []
  end

  test "security regression: corrupt or removed transcript manifests invalidate current labels" do
    checkpoint =
      [labeled_message("user", "manifest-bound", taint("manifest_bound", :hostile))]
      |> session("eng-manifest")
      |> Persistence.extract_checkpoint_data()

    corrupted =
      Map.put(checkpoint, "messages_manifest", %{
        "payload" => %{"malformed" => true},
        "envelope" => %{}
      })

    removed = Map.delete(checkpoint, "messages_manifest")

    for candidate <- [corrupted, removed] do
      assert [message] =
               Persistence.apply_checkpoint(session([], "eng-manifest"), candidate).messages

      assert message["content"] == "manifest-bound"
      assert_invalid(message)
    end
  end

  test "security regression: current records are bound to their exact engagement" do
    checkpoint =
      [labeled_message("user", "engagement-bound", taint("engagement_a", :hostile))]
      |> session("eng-a")
      |> Persistence.extract_checkpoint_data()

    rebound = Map.put(checkpoint, "current_engagement_id", "eng-b")
    rebound_restored = Persistence.apply_checkpoint(session([], "eng-a"), rebound)

    assert rebound_restored.current_engagement_id == "eng-b"
    assert [rebound_message] = rebound_restored.messages
    assert rebound_message["content"] == "engagement-bound"
    assert_invalid(rebound_message)

    missing = Map.delete(checkpoint, "current_engagement_id")
    missing_restored = Persistence.apply_checkpoint(session([], "eng-a"), missing)

    assert missing_restored.current_engagement_id == "eng-a"
    assert [missing_message] = missing_restored.messages
    assert missing_message["content"] == "engagement-bound"
    assert_invalid(missing_message)
  end

  test "security regression: current records cannot be replayed across sessions or agents" do
    checkpoint =
      [labeled_message("assistant", "owner-bound", taint("owner_a", :hostile))]
      |> session("eng-owner", session_id: "session-a", agent_id: "agent-a")
      |> Persistence.extract_checkpoint_data()

    for target <- [
          session([], "eng-owner", session_id: "session-b", agent_id: "agent-a"),
          session([], "eng-owner", session_id: "session-a", agent_id: "agent-b")
        ] do
      restored = Persistence.apply_checkpoint(target, checkpoint)

      assert [message] = restored.messages
      assert message["content"] == "owner-bound"
      assert_invalid(message)
    end
  end

  test "security regression: malformed checkpoint message containers clear prior transcript state" do
    prior = labeled_message("user", "must not survive", taint("prior_state", :hostile))

    restored =
      Persistence.apply_checkpoint(session([prior], "eng-old"), %{
        "messages" => %{"malformed" => true},
        "current_engagement_id" => "eng-new"
      })

    assert restored.current_engagement_id == "eng-new"
    assert restored.messages == []
  end

  test "security regression: engagement-only checkpoint cannot retain or relabel another transcript" do
    prior = labeled_message("user", "hostile prior transcript", taint("prior_hostile", :hostile))
    state = session([prior], "eng-old")

    rebound =
      Persistence.apply_checkpoint(state, %{
        "current_engagement_id" => "eng-new",
        "turn_count" => 7
      })

    assert rebound.current_engagement_id == "eng-new"
    assert rebound.messages == []
    assert rebound.turn_count == 7

    same_engagement =
      Persistence.apply_checkpoint(state, %{
        "current_engagement_id" => "eng-old",
        "turn_count" => 8
      })

    assert same_engagement.current_engagement_id == "eng-old"
    assert same_engagement.messages == []
    assert same_engagement.turn_count == 8
  end

  defp session(messages, engagement_id, opts \\ []) do
    %Session{
      session_id: Keyword.get(opts, :session_id, "checkpoint-session"),
      agent_id: Keyword.get(opts, :agent_id, "checkpoint-agent"),
      messages: messages,
      current_engagement_id: engagement_id
    }
  end

  defp labeled_message(role, content, taint) do
    %{
      "role" => role,
      "content" => content,
      "taint" => taint,
      "taint_status" => :verified
    }
  end

  defp taint(source, level) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: source,
        chain: []
      })

    taint
  end

  defp assert_invalid(message) do
    assert message["taint"] == TaintEnvelope.invalid_fallback()
    assert message["taint_status"] == :invalid_durable_provenance
  end
end
