defmodule Arbor.Contracts.Session.UserMessageTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Session.UserMessage

  @moduletag :fast

  describe "from_string/1" do
    test "wraps a bare string with the current time" do
      msg = UserMessage.from_string("hello")
      assert msg.content == "hello"
      assert %DateTime{} = msg.sent_at
      assert msg.transport == nil
      assert msg.sender == nil
      assert msg.sender_id == nil
      assert msg.transport_metadata == %{}
    end

    test "stamps sent_at within a reasonable window of now" do
      before = DateTime.utc_now()
      msg = UserMessage.from_string("x")
      after_time = DateTime.utc_now()

      assert DateTime.compare(msg.sent_at, before) in [:gt, :eq]
      assert DateTime.compare(msg.sent_at, after_time) in [:lt, :eq]
    end
  end

  describe "from_dashboard/2" do
    test "tags transport as :dashboard and sets sender_id" do
      msg = UserMessage.from_dashboard("hi", "human_alice")
      assert msg.content == "hi"
      assert msg.transport == :dashboard
      assert msg.sender_id == "human_alice"
      assert %DateTime{} = msg.sent_at
    end

    test "agent_id is optional" do
      msg = UserMessage.from_dashboard("hi")
      assert msg.transport == :dashboard
      assert msg.sender_id == nil
    end
  end

  describe "from_cli/2" do
    test "tags transport as :cli and sets sender display name" do
      msg = UserMessage.from_cli("hello", "Hysun")
      assert msg.transport == :cli
      assert msg.sender == "Hysun"
    end

    test "sender is optional" do
      msg = UserMessage.from_cli("hello")
      assert msg.transport == :cli
      assert msg.sender == nil
    end
  end

  describe "from_voice/2" do
    @tag spec: "VOICE-1"
    test "tags transport as :voice and enforces content" do
      msg = UserMessage.from_voice("hello")
      assert msg.content == "hello"
      assert msg.transport == :voice
      assert %DateTime{} = msg.sent_at
    end

    @tag spec: "VOICE-1"
    test "defaults sent_at to now when absent" do
      before = DateTime.utc_now()
      msg = UserMessage.from_voice("hello")
      after_time = DateTime.utc_now()

      assert DateTime.compare(msg.sent_at, before) in [:gt, :eq]
      assert DateTime.compare(msg.sent_at, after_time) in [:lt, :eq]
    end

    @tag spec: "VOICE-1"
    test "respects sent_at from opts (utterance-end time, not processing time)" do
      utterance_end = DateTime.add(DateTime.utc_now(), -5, :second)
      msg = UserMessage.from_voice("hello", sent_at: utterance_end)
      assert msg.sent_at == utterance_end
    end

    @tag spec: "VOICE-1"
    test "carries sender_id and transport_metadata through" do
      metadata = %{backend: "xai_realtime", input: :speech, device: "mac"}

      msg =
        UserMessage.from_voice("hello", sender_id: "human_alice", transport_metadata: metadata)

      assert msg.sender_id == "human_alice"
      assert msg.transport_metadata == metadata
    end

    @tag spec: "VOICE-1"
    test "transport_metadata defaults to an empty map" do
      msg = UserMessage.from_voice("hello")
      assert msg.transport_metadata == %{}
    end

    @tag spec: "VOICE-1"
    test "composes with with_engagement/2" do
      msg =
        "hello"
        |> UserMessage.from_voice(sender_id: "human_alice")
        |> UserMessage.with_engagement("engagement_123")

      assert msg.transport == :voice
      assert msg.engagement_id == "engagement_123"
    end
  end

  describe "coerce/1" do
    test "passes a UserMessage struct through unchanged" do
      original = UserMessage.from_dashboard("test", "human_x")
      assert UserMessage.coerce(original) == original
    end

    test "wraps a bare string via from_string/1" do
      coerced = UserMessage.coerce("plain text")
      assert coerced.content == "plain text"
      assert %DateTime{} = coerced.sent_at
      assert coerced.transport == nil
    end
  end

  describe "struct invariants" do
    test "content and sent_at are required" do
      # Trying to build the struct without enforced fields should fail at
      # compile time via TypedStruct's enforce: true. We assert it via
      # struct/2 which raises if required keys are missing.
      assert_raise ArgumentError, fn ->
        struct!(UserMessage, %{})
      end
    end

    test "transport_metadata defaults to an empty map" do
      msg = UserMessage.from_string("x")
      assert msg.transport_metadata == %{}
    end
  end
end
