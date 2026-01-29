defmodule Arbor.Comms.ResponseRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.ResponseRouter
  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  setup do
    original_signal = Application.get_env(:arbor_comms, :signal, [])
    original_email = Application.get_env(:arbor_comms, :email, [])
    original_limitless = Application.get_env(:arbor_comms, :limitless, [])
    original_handler = Application.get_env(:arbor_comms, :handler, [])

    Application.put_env(:arbor_comms, :signal, enabled: true)
    Application.put_env(:arbor_comms, :email, enabled: true)
    Application.put_env(:arbor_comms, :limitless, enabled: true)

    on_exit(fn ->
      Application.put_env(:arbor_comms, :signal, original_signal)
      Application.put_env(:arbor_comms, :email, original_email)
      Application.put_env(:arbor_comms, :limitless, original_limitless)
      Application.put_env(:arbor_comms, :handler, original_handler)
    end)
  end

  defp signal_msg(metadata \\ %{}) do
    Message.new(
      channel: :signal,
      from: "+15551234567",
      content: "Hello",
      direction: :inbound,
      metadata: metadata
    )
  end

  defp limitless_msg(metadata \\ %{response_channel: :signal}) do
    Message.new(
      channel: :limitless,
      from: "pendant",
      content: "Transcript content",
      direction: :inbound,
      metadata: metadata
    )
  end

  # ============================================================================
  # Content Heuristics (Layer 1)
  # ============================================================================

  describe "route/2 with :auto — content heuristics" do
    test "routes short text to origin channel" do
      envelope = ResponseEnvelope.new(body: "Short reply")

      assert {:ok, :signal, ^envelope} = ResponseRouter.route(signal_msg(), envelope)
    end

    test "routes long text (>2000 bytes) to email" do
      long_body = String.duplicate("x", 2001)
      envelope = ResponseEnvelope.new(body: long_body)

      assert {:ok, :email, ^envelope} = ResponseRouter.route(signal_msg(), envelope)
    end

    test "routes attachments to email" do
      envelope =
        ResponseEnvelope.new(
          body: "See attached.",
          attachments: [{"data.csv", "a,b,c"}]
        )

      assert {:ok, :email, ^envelope} = ResponseRouter.route(signal_msg(), envelope)
    end

    test "routes HTML format to email" do
      envelope = ResponseEnvelope.new(body: "<h1>Report</h1>", format: :html)

      assert {:ok, :email, ^envelope} = ResponseRouter.route(signal_msg(), envelope)
    end

    test "attachments take priority over short body" do
      envelope =
        ResponseEnvelope.new(
          body: "Hi",
          attachments: [{"f.txt", "data"}]
        )

      assert {:ok, :email, _} = ResponseRouter.route(signal_msg(), envelope)
    end
  end

  # ============================================================================
  # Origin Metadata (Layer 2)
  # ============================================================================

  describe "route/2 with :auto — origin metadata" do
    test "limitless origin with response_channel metadata routes to signal" do
      envelope = ResponseEnvelope.new(body: "Short reply")

      assert {:ok, :signal, ^envelope} = ResponseRouter.route(limitless_msg(), envelope)
    end

    test "limitless origin without metadata falls back via capability check" do
      msg = limitless_msg(%{})
      envelope = ResponseEnvelope.new(body: "Short reply")

      # Limitless can't send, so fallback chain should find signal
      assert {:ok, :signal, ^envelope} = ResponseRouter.route(msg, envelope)
    end

    test "content heuristics still override metadata for long content" do
      envelope = ResponseEnvelope.new(body: String.duplicate("x", 2001))

      assert {:ok, :email, ^envelope} = ResponseRouter.route(limitless_msg(), envelope)
    end
  end

  # ============================================================================
  # Explicit Channel Hints
  # ============================================================================

  describe "route/2 with explicit channel" do
    test "honors explicit channel hint" do
      envelope = ResponseEnvelope.new(body: "Short", channel: :email)

      assert {:ok, :email, ^envelope} = ResponseRouter.route(signal_msg(), envelope)
    end

    test "returns error for unavailable channel" do
      envelope = ResponseEnvelope.new(body: "Hi", channel: :voice)

      assert {:error, {:channel_unavailable, :voice}} =
               ResponseRouter.route(signal_msg(), envelope)
    end

    test "explicit hint to non-sendable channel falls back" do
      envelope = ResponseEnvelope.new(body: "Hi", channel: :limitless)

      # Limitless is enabled but can't send — should fall back to signal
      assert {:ok, :signal, ^envelope} = ResponseRouter.route(signal_msg(), envelope)
    end
  end

  # ============================================================================
  # can_send?/1
  # ============================================================================

  describe "can_send?/1" do
    test "signal can send" do
      assert ResponseRouter.can_send?(:signal)
    end

    test "email can send" do
      assert ResponseRouter.can_send?(:email)
    end

    test "limitless cannot send" do
      refute ResponseRouter.can_send?(:limitless)
    end

    test "unknown channel cannot send" do
      refute ResponseRouter.can_send?(:nonexistent)
    end
  end

  # ============================================================================
  # available_channels/0
  # ============================================================================

  describe "available_channels/0" do
    test "returns configured channels" do
      channels = ResponseRouter.available_channels()
      assert :signal in channels
      assert :email in channels
    end
  end
end
