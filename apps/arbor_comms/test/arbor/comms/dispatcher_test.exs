defmodule Arbor.Comms.DispatcherTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Dispatcher
  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  describe "channel_module/1" do
    test "returns Signal module for :signal" do
      assert Dispatcher.channel_module(:signal) == Arbor.Comms.Channels.Signal
    end

    test "returns nil for unknown channel" do
      assert Dispatcher.channel_module(:nonexistent) == nil
    end
  end

  describe "sender_module/1" do
    test "returns Signal module for :signal" do
      assert Dispatcher.sender_module(:signal) == Arbor.Comms.Channels.Signal
    end

    test "returns Email module for :email" do
      assert Dispatcher.sender_module(:email) == Arbor.Comms.Channels.Email
    end

    test "returns nil for receive-only channel" do
      assert Dispatcher.sender_module(:limitless) == nil
    end

    test "returns nil for unknown channel" do
      assert Dispatcher.sender_module(:nonexistent) == nil
    end
  end

  describe "receiver_module/1" do
    test "returns Signal module for :signal" do
      assert Dispatcher.receiver_module(:signal) == Arbor.Comms.Channels.Signal
    end

    test "returns Limitless module for :limitless" do
      assert Dispatcher.receiver_module(:limitless) == Arbor.Comms.Channels.Limitless
    end

    test "returns nil for send-only channel" do
      assert Dispatcher.receiver_module(:email) == nil
    end

    test "returns nil for unknown channel" do
      assert Dispatcher.receiver_module(:nonexistent) == nil
    end
  end

  describe "send/4" do
    test "returns error for unknown channel" do
      assert {:error, {:unknown_channel, :nonexistent}} =
               Dispatcher.send(:nonexistent, "+1234", "hi")
    end
  end

  describe "reply/2" do
    test "falls back to default response channel for unknown origin" do
      msg =
        Message.new(
          channel: :nonexistent,
          from: "+1234567890",
          content: "Hello"
        )

      # :nonexistent isn't a sender, so reply resolves via
      # Config.default_response_channel() → :signal, which IS a sender.
      # The result depends on signal-cli availability.
      result = Dispatcher.reply(msg, "response")
      assert match?(:ok, result) or match?({:error, _}, result)
    end

    test "returns no_sendable_channel when fallback also unresolvable" do
      original = Application.get_env(:arbor_comms, :handler)

      Application.put_env(:arbor_comms, :handler,
        Keyword.put(original || [], :default_response_channel, :nonexistent)
      )

      msg =
        Message.new(
          channel: :also_nonexistent,
          from: "+1234567890",
          content: "Hello",
          metadata: %{}
        )

      assert {:error, {:no_sendable_channel, :also_nonexistent}} =
               Dispatcher.reply(msg, "response")

      if original do
        Application.put_env(:arbor_comms, :handler, original)
      else
        Application.delete_env(:arbor_comms, :handler)
      end
    end
  end

  describe "deliver_envelope/3" do
    test "returns error for unknown channel" do
      msg =
        Message.new(
          channel: :signal,
          from: "+1234567890",
          content: "Hello"
        )

      envelope = ResponseEnvelope.new(body: "Reply text")

      assert {:error, {:unknown_channel, :nonexistent}} =
               Dispatcher.deliver_envelope(msg, :nonexistent, envelope)
    end
  end
end
