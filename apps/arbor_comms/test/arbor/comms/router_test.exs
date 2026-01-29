defmodule Arbor.Comms.RouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Router
  alias Arbor.Contracts.Comms.Message

  describe "handle_inbound/1" do
    test "processes a message and returns :ok" do
      msg =
        Message.new(
          channel: :signal,
          from: "+1234567890",
          content: "Hello Arbor"
        )

      assert :ok = Router.handle_inbound(msg)
    end

    test "handles messages with metadata" do
      msg =
        Message.new(
          channel: :signal,
          from: "+1234567890",
          content: "Test message",
          metadata: %{source_device: 1, has_attachments: false}
        )

      assert :ok = Router.handle_inbound(msg)
    end
  end
end
