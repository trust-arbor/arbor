defmodule Arbor.Gateway.Bridge.ClaudeSessionTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.Bridge.ClaudeSession

  @moduletag :fast

  # ===========================================================================
  # to_agent_id/1
  # ===========================================================================

  describe "to_agent_id/1" do
    test "prefixes session ID with agent_claude_" do
      assert ClaudeSession.to_agent_id("abc-123") == "agent_claude_abc-123"
    end

    test "handles UUID-style session IDs" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert ClaudeSession.to_agent_id(uuid) == "agent_claude_#{uuid}"
    end

    test "handles empty string" do
      assert ClaudeSession.to_agent_id("") == "agent_claude_"
    end

    test "preserves special characters in session ID" do
      assert ClaudeSession.to_agent_id("test/session:1") == "agent_claude_test/session:1"
    end
  end

  # ===========================================================================
  # dangerous_command?/1 — comprehensive command classification
  # ===========================================================================

  describe "dangerous_command?/1" do
    test "detects rm as dangerous" do
      assert ClaudeSession.dangerous_command?("rm -rf /")
      assert ClaudeSession.dangerous_command?("rm file.txt")
      assert ClaudeSession.dangerous_command?("rm")
    end

    test "detects sudo as dangerous" do
      assert ClaudeSession.dangerous_command?("sudo apt install")
      assert ClaudeSession.dangerous_command?("sudo rm -rf /")
    end

    test "detects su as dangerous" do
      assert ClaudeSession.dangerous_command?("su root")
      assert ClaudeSession.dangerous_command?("su -")
    end

    test "detects chmod as dangerous" do
      assert ClaudeSession.dangerous_command?("chmod 777 /etc/passwd")
    end

    test "detects chown as dangerous" do
      assert ClaudeSession.dangerous_command?("chown root:root file")
    end

    test "detects kill as dangerous" do
      assert ClaudeSession.dangerous_command?("kill -9 1234")
    end

    test "detects pkill as dangerous" do
      assert ClaudeSession.dangerous_command?("pkill -f process")
    end

    test "detects dd as dangerous" do
      assert ClaudeSession.dangerous_command?("dd if=/dev/zero of=/dev/sda")
    end

    test "detects mkfs as dangerous" do
      # Note: "mkfs" must be the exact base command, not "mkfs.ext4"
      assert ClaudeSession.dangerous_command?("mkfs /dev/sda1")
    end

    test "detects fdisk as dangerous" do
      assert ClaudeSession.dangerous_command?("fdisk /dev/sda")
    end

    test "allows safe commands used by default capabilities" do
      refute ClaudeSession.dangerous_command?("git status")
      refute ClaudeSession.dangerous_command?("mix test")
      refute ClaudeSession.dangerous_command?("elixir -e '1+1'")
      refute ClaudeSession.dangerous_command?("iex -S mix")
      refute ClaudeSession.dangerous_command?("ls -la")
      refute ClaudeSession.dangerous_command?("cat file.txt")
      refute ClaudeSession.dangerous_command?("head -n 10 file")
      refute ClaudeSession.dangerous_command?("tail -f file")
      refute ClaudeSession.dangerous_command?("grep pattern file")
      refute ClaudeSession.dangerous_command?("find . -name '*.ex'")
      refute ClaudeSession.dangerous_command?("wc -l file")
      refute ClaudeSession.dangerous_command?("curl https://example.com")
      refute ClaudeSession.dangerous_command?("echo hello")
      refute ClaudeSession.dangerous_command?("mkdir -p dir")
      refute ClaudeSession.dangerous_command?("cp source dest")
      refute ClaudeSession.dangerous_command?("mv source dest")
    end

    test "handles empty command string" do
      refute ClaudeSession.dangerous_command?("")
    end

    test "only checks the base command, not arguments" do
      # "git rm" should be safe because git is the base command
      refute ClaudeSession.dangerous_command?("git rm file.txt")
      # "rm" as base command is dangerous even with innocent args
      assert ClaudeSession.dangerous_command?("rm innocuous.txt")
    end

    test "handles command with multiple spaces between arguments" do
      assert ClaudeSession.dangerous_command?("rm   -rf  /")
      refute ClaudeSession.dangerous_command?("git   status  --short")
    end

    test "all dangerous commands are checked" do
      # Verify the complete list of dangerous commands
      dangerous = ~w(rm sudo su chmod chown kill pkill dd mkfs fdisk)

      for cmd <- dangerous do
        assert ClaudeSession.dangerous_command?(cmd),
               "Expected '#{cmd}' to be classified as dangerous"
      end
    end

    test "dangerous command with subcommand variant (mkfs.ext4) is not detected" do
      # mkfs.ext4 is a different base command than mkfs — this is a known limitation
      # The check uses exact base command match, not prefix match
      refute ClaudeSession.dangerous_command?("mkfs.ext4 /dev/sda1")
    end
  end

  # ===========================================================================
  # authorize_tool/4 — exits when services unavailable (fail-closed)
  # ===========================================================================

  describe "authorize_tool/4 fail-closed behavior" do
    test "raises exit when trust service is unavailable" do
      # authorize_tool calls Arbor.Trust.get_trust_profile via GenServer.call,
      # which exits when the process doesn't exist. This verifies fail-closed behavior.
      # The Bridge Router catches this exit and returns a deny decision.
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Read",
                 %{"file_path" => "/tmp/test"},
                 "."
               )
             )
    end

    test "exits for Bash tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Bash",
                 %{"command" => "git status"},
                 "."
               )
             )
    end

    test "exits for Write tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Write",
                 %{"file_path" => "/tmp/out.txt"},
                 "."
               )
             )
    end

    test "exits for Edit tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Edit",
                 %{"file_path" => "/tmp/edit.txt"},
                 "."
               )
             )
    end

    test "exits for WebFetch tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "WebFetch",
                 %{"url" => "https://example.com"},
                 "."
               )
             )
    end

    test "exits for WebSearch tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "WebSearch",
                 %{"query" => "test"},
                 "."
               )
             )
    end

    test "exits for Task (agent spawn) tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Task",
                 %{"description" => "spawn"},
                 "."
               )
             )
    end

    test "exits for Grep tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Grep",
                 %{"pattern" => "foo"},
                 "."
               )
             )
    end

    test "exits for Glob tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "Glob",
                 %{"pattern" => "*.ex"},
                 "."
               )
             )
    end

    test "exits for unknown/generic tool authorization" do
      assert catch_exit(
               ClaudeSession.authorize_tool(
                 "test-session",
                 "SomeCustomTool",
                 %{"input" => "test"},
                 "."
               )
             )
    end
  end

  # ===========================================================================
  # ensure_registered/2 — exits when trust service unavailable
  # ===========================================================================

  describe "ensure_registered/2" do
    test "exits when trust service is unavailable" do
      assert catch_exit(ClaudeSession.ensure_registered("test-session", "/tmp"))
    end
  end
end
