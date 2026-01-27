defmodule Arbor.BridgeTest do
  use ExUnit.Case

  alias Arbor.Bridge.ClaudeSession

  describe "agent_id/1" do
    test "formats session ID as agent ID" do
      assert Arbor.Bridge.agent_id("test-session") == "agent_claude_test-session"
    end
  end

  describe "ClaudeSession.dangerous_command?/1" do
    test "identifies dangerous commands" do
      assert ClaudeSession.dangerous_command?("rm -rf /")
      assert ClaudeSession.dangerous_command?("sudo apt install")
      assert ClaudeSession.dangerous_command?("kill -9 1234")
    end

    test "allows safe commands" do
      refute ClaudeSession.dangerous_command?("git status")
      refute ClaudeSession.dangerous_command?("mix test")
      refute ClaudeSession.dangerous_command?("ls -la")
      refute ClaudeSession.dangerous_command?("cat file.txt")
    end
  end

  describe "ClaudeSession.to_agent_id/1" do
    test "creates proper agent ID format" do
      assert ClaudeSession.to_agent_id("abc-123") == "agent_claude_abc-123"
      assert ClaudeSession.to_agent_id("session") == "agent_claude_session"
    end
  end
end
