defmodule Arbor.Contracts.Comms.ResponseEnvelopeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Comms.ResponseEnvelope

  describe "new/1" do
    test "creates envelope with body" do
      env = ResponseEnvelope.new(body: "Got it!")
      assert %ResponseEnvelope{} = env
      assert env.body == "Got it!"
      assert env.channel == :auto
      assert env.format == :text
      assert env.attachments == []
      assert env.metadata == %{}
    end

    test "accepts all options" do
      env =
        ResponseEnvelope.new(
          body: "Report here",
          channel: :email,
          format: :markdown,
          subject: "Weekly Report",
          attachments: [{"data.csv", "a,b,c"}],
          in_reply_to: "q_123",
          metadata: %{priority: :high}
        )

      assert env.channel == :email
      assert env.format == :markdown
      assert env.subject == "Weekly Report"
      assert length(env.attachments) == 1
      assert env.in_reply_to == "q_123"
    end

    test "raises on missing body" do
      assert_raise ArgumentError, fn ->
        ResponseEnvelope.new(channel: :email)
      end
    end
  end

  describe "has_attachments?/1" do
    test "true with attachments" do
      env = ResponseEnvelope.new(body: "here", attachments: [{"f.txt", "data"}])
      assert ResponseEnvelope.has_attachments?(env) == true
    end

    test "false without attachments" do
      env = ResponseEnvelope.new(body: "here")
      assert ResponseEnvelope.has_attachments?(env) == false
    end
  end

  describe "content_size/1" do
    test "counts body size" do
      env = ResponseEnvelope.new(body: "hello")
      assert ResponseEnvelope.content_size(env) == 5
    end

    test "includes inline attachment data" do
      env =
        ResponseEnvelope.new(
          body: "hi",
          attachments: [{"f.txt", "data123"}]
        )

      # "hi" = 2 bytes, "data123" = 7 bytes
      assert ResponseEnvelope.content_size(env) == 9
    end
  end
end
