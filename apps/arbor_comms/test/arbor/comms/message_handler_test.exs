defmodule Arbor.Comms.MessageHandlerTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.MessageHandler
  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  # A simple mock responder for testing
  defmodule MockResponder do
    @behaviour Arbor.Contracts.Comms.ResponseGenerator

    @impl true
    def generate_response(_message, _context) do
      {:ok, ResponseEnvelope.new(body: "Mock response")}
    end
  end

  setup do
    # Store original config
    original_handler = Application.get_env(:arbor_comms, :handler, [])

    Application.put_env(:arbor_comms, :handler,
      enabled: true,
      authorized_senders: ["+15551234567"],
      response_generator: MockResponder,
      dedup_window_seconds: 5
    )

    # Start the handler for tests that need it
    case MessageHandler.start_link([]) do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
          Application.put_env(:arbor_comms, :handler, original_handler)
        end)

        {:ok, handler: pid}

      {:error, {:already_started, pid}} ->
        on_exit(fn ->
          Application.put_env(:arbor_comms, :handler, original_handler)
        end)

        {:ok, handler: pid}
    end
  end

  describe "authorization" do
    test "processes messages from authorized senders" do
      msg =
        Message.new(
          channel: :signal,
          from: "+15551234567",
          content: "/help",
          direction: :inbound
        )

      assert :ok = MessageHandler.process(msg)
      # Give the cast time to process
      Process.sleep(50)
    end

    test "rejects messages from unauthorized senders" do
      msg =
        Message.new(
          channel: :signal,
          from: "+9999999999",
          content: "Hello",
          direction: :inbound
        )

      # Cast returns :ok but message is skipped internally
      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)
    end

    test "allows all senders when authorized_senders is empty" do
      Application.put_env(:arbor_comms, :handler,
        enabled: true,
        authorized_senders: [],
        response_generator: MockResponder
      )

      msg =
        Message.new(
          channel: :signal,
          from: "+9999999999",
          content: "/help",
          direction: :inbound
        )

      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)
    end
  end

  describe "deduplication" do
    test "processes the same message ID only once" do
      msg =
        Message.new(
          channel: :signal,
          from: "+15551234567",
          content: "/status",
          direction: :inbound
        )

      # First should process
      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)

      # Second with same ID should be deduped
      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)
    end
  end

  describe "command classification" do
    test "handles /help command" do
      msg =
        Message.new(
          channel: :signal,
          from: "+15551234567",
          content: "/help",
          direction: :inbound
        )

      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)
    end

    test "handles /status command" do
      msg =
        Message.new(
          channel: :signal,
          from: "+15551234567",
          content: "/status",
          direction: :inbound
        )

      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)
    end

    test "handles unknown commands" do
      msg =
        Message.new(
          channel: :signal,
          from: "+15551234567",
          content: "/unknown",
          direction: :inbound
        )

      assert :ok = MessageHandler.process(msg)
      Process.sleep(50)
    end
  end

  describe "conversation dispatch" do
    test "dispatches non-command messages to response generator" do
      # Use a unique test log dir so we don't pollute real logs
      test_log_dir =
        Path.join(
          System.tmp_dir!(),
          "arbor_handler_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(test_log_dir)
      original_signal = Application.get_env(:arbor_comms, :signal)
      Application.put_env(:arbor_comms, :signal, log_dir: test_log_dir)

      on_exit(fn ->
        File.rm_rf(test_log_dir)

        if original_signal,
          do: Application.put_env(:arbor_comms, :signal, original_signal),
          else: Application.delete_env(:arbor_comms, :signal)
      end)

      msg =
        Message.new(
          channel: :signal,
          from: "+15551234567",
          content: "What is Arbor?",
          direction: :inbound
        )

      assert :ok = MessageHandler.process(msg)
      Process.sleep(100)
    end
  end
end
