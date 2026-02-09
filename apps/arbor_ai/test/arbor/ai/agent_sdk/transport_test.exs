defmodule Arbor.AI.AgentSDK.TransportTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.Transport

  # These tests use a mock CLI script to avoid requiring the real Claude CLI.
  # The mock script echoes NDJSON events to stdout when it receives stdin input.

  @mock_cli_script Path.expand("../../../support/mock_claude_cli.sh", __DIR__)

  setup do
    # Create mock CLI script
    script = """
    #!/bin/bash
    # Mock Claude CLI for testing
    # Reads stdin, outputs NDJSON responses

    # Output initial system event
    echo '{"type":"system","subtype":"init","apiKey":"test"}'

    # Read stdin lines and respond
    while IFS= read -r line; do
      # Parse the user_input type
      if echo "$line" | grep -q "user_input"; then
        # Output assistant message
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Mock response"}],"model":"claude-test"}}'
        # Output result
        echo '{"type":"result","usage":{"input_tokens":10,"output_tokens":5},"session_id":"mock-session-1"}'
      fi
    done
    """

    File.write!(@mock_cli_script, script)
    File.chmod!(@mock_cli_script, 0o755)

    on_exit(fn ->
      File.rm(@mock_cli_script)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts with mock CLI and sends transport_ready" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000
      assert Transport.ready?(transport)
      Transport.close(transport)
    end

    test "fails when CLI path doesn't exist" do
      Process.flag(:trap_exit, true)

      result =
        Transport.start_link(
          cli_path: "/nonexistent/claude",
          receiver: self()
        )

      case result do
        {:error, %Error{type: :port_crashed}} ->
          :ok

        {:ok, pid} ->
          # Shouldn't happen, but clean up if it does
          Transport.close(pid)
          flunk("Expected error but got {:ok, pid}")
      end
    end
  end

  describe "send_query/3" do
    test "sends query and receives response" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000

      {:ok, ref} = Transport.send_query(transport, "test query")
      assert is_reference(ref)

      # Should receive assistant message and result
      assert_receive {:claude_message, ^ref, %{"type" => "assistant"}}, 5_000
      assert_receive {:claude_message, ^ref, %{"type" => "result"}}, 5_000

      Transport.close(transport)
    end

    test "returns not_ready error when not connected" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000

      # Close the port first
      Transport.close(transport)

      # Now it should be disconnected
      refute Transport.ready?(transport)

      result = Transport.send_query(transport, "query")
      assert {:error, %Error{type: :not_ready}} = result
    end
  end

  describe "ready?/1" do
    test "returns true when connected" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000
      assert Transport.ready?(transport)
      Transport.close(transport)
    end

    test "returns false after close" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000
      Transport.close(transport)
      refute Transport.ready?(transport)
    end
  end

  describe "close/1" do
    test "closes the port cleanly" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000
      assert :ok = Transport.close(transport)
      refute Transport.ready?(transport)
    end
  end

  describe "session_id capture" do
    test "captures session_id from result event" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @mock_cli_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000

      {:ok, ref} = Transport.send_query(transport, "test")

      assert_receive {:claude_message, ^ref, %{"type" => "result", "session_id" => session_id}},
                     5_000

      assert session_id == "mock-session-1"

      Transport.close(transport)
    end
  end

  describe "init-phase result events" do
    @init_result_script Path.expand("../../../support/mock_claude_init_result.sh", __DIR__)

    setup do
      # CLI that outputs a result event during init (before any query),
      # simulating leftover session data. Then responds normally to queries.
      script = """
      #!/bin/bash
      # Output system init event
      echo '{"type":"system","subtype":"init","apiKey":"test"}'
      # Output a stale result event from previous session (the bug trigger)
      echo '{"type":"result","usage":{"input_tokens":5,"output_tokens":3},"session_id":"old-session"}'

      # Read stdin lines and respond
      while IFS= read -r line; do
        if echo "$line" | grep -q "user_input"; then
          echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Fresh response"}],"model":"claude-test"}}'
          echo '{"type":"result","usage":{"input_tokens":10,"output_tokens":5},"session_id":"new-session"}'
        fi
      done
      """

      File.write!(@init_result_script, script)
      File.chmod!(@init_result_script, 0o755)

      on_exit(fn -> File.rm(@init_result_script) end)
      :ok
    end

    test "init-phase result does not consume query slot" do
      {:ok, transport} =
        Transport.start_link(
          cli_path: @init_result_script,
          receiver: self()
        )

      assert_receive {:transport_ready}, 2_000

      # Should NOT receive a claude_message from the init result
      refute_receive {:claude_message, _, %{"type" => "result"}}, 500

      # Now send a real query
      {:ok, ref} = Transport.send_query(transport, "hello")

      # Should receive the query's response, not the init result
      assert_receive {:claude_message, ^ref, %{"type" => "assistant"}}, 5_000
      assert_receive {:claude_message, ^ref, %{"type" => "result", "session_id" => "new-session"}}, 5_000

      Transport.close(transport)
    end
  end

  describe "CLI not found" do
    test "returns error when no CLI available" do
      result =
        Transport.start_link(
          cli_path: nil,
          receiver: self()
        )

      # find_cli will be tried; if claude is installed it'll find it,
      # if not it'll return cli_not_found
      case result do
        {:ok, transport} ->
          # CLI was found on the system
          Transport.close(transport)

        {:error, %Error{type: :cli_not_found}} ->
          :ok

        {:error, %Error{type: :port_crashed}} ->
          :ok
      end
    end
  end
end
