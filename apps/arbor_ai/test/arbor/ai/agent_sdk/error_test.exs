defmodule Arbor.AI.AgentSDK.ErrorTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Error

  describe "error constructors" do
    test "cli_not_found" do
      err = Error.cli_not_found()
      assert err.type == :cli_not_found
      assert is_binary(err.message)
      assert String.contains?(err.message, "CLI not found")
    end

    test "process_error" do
      err = Error.process_error(1, "segfault")
      assert err.type == :process_error
      assert err.details.exit_code == 1
      assert err.details.stderr == "segfault"
    end

    test "json_decode_error" do
      err = Error.json_decode_error("bad json", :unexpected_token)
      assert err.type == :json_decode_error
      assert err.details.reason == :unexpected_token
    end

    test "timeout" do
      err = Error.timeout(30_000)
      assert err.type == :timeout
      assert err.details.timeout_ms == 30_000
      assert String.contains?(err.message, "30000")
    end

    test "permission_denied" do
      err = Error.permission_denied("Bash", "dangerous command")
      assert err.type == :permission_denied
      assert err.details.tool == "Bash"
      assert err.details.reason == "dangerous command"
    end

    test "tool_error" do
      err = Error.tool_error("search", :not_found)
      assert err.type == :tool_error
      assert err.details.tool == "search"
    end

    test "hook_denied" do
      err = Error.hook_denied("Bash", "blocked by policy")
      assert err.type == :hook_denied
      assert err.details.tool == "Bash"
    end

    test "buffer_overflow" do
      err = Error.buffer_overflow()
      assert err.type == :buffer_overflow
    end

    test "prompt_required" do
      err = Error.prompt_required()
      assert err.type == :prompt_required
    end
  end

  describe "Exception behaviour" do
    test "implements Exception.message/1" do
      err = Error.cli_not_found()
      assert Exception.message(err) == err.message
    end

    test "can be raised" do
      assert_raise Error, fn ->
        raise Error.cli_not_found()
      end
    end

    test "raised error has correct message" do
      assert_raise Error, ~r/CLI not found/, fn ->
        raise Error.cli_not_found()
      end
    end
  end
end
