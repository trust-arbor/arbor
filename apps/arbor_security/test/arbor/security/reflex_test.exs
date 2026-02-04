defmodule Arbor.Security.ReflexTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Reflex, as: ReflexContract
  alias Arbor.Security.Reflex

  describe "check/1" do
    test "returns :ok when no reflexes match" do
      assert :ok = Reflex.check(%{command: "echo hello"})
    end

    test "blocks dangerous rm -rf commands" do
      assert {:blocked, reflex, message} = Reflex.check(%{command: "rm -rf /"})
      assert reflex.id == "rm_rf_root"
      assert String.contains?(message, "Blocked")
    end

    test "blocks rm -rf with home directory" do
      assert {:blocked, _, _} = Reflex.check(%{command: "rm -rf ~"})
    end

    test "blocks sudo commands" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "sudo apt install foo"})
      assert reflex.id == "sudo_su"
    end

    test "blocks su commands" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "su - root"})
      assert reflex.id == "sudo_su"
    end

    test "blocks chmod 777" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "chmod 777 /tmp/file"})
      assert reflex.id == "chmod_dangerous"
    end

    test "blocks dd to disk devices" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "dd if=/dev/zero of=/dev/sda"})
      assert reflex.id == "dd_disk"
    end

    test "blocks mkfs commands" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "mkfs.ext4 /dev/sdb1"})
      assert reflex.id == "mkfs"
    end

    test "blocks fork bomb patterns" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: ":(){:|:&};:"})
      assert reflex.id == "fork_bomb"
    end

    test "warns on curl piped to shell" do
      assert {:warned, warnings} = Reflex.check(%{command: "curl http://example.com/script.sh | sh"})
      assert length(warnings) >= 1
      {reflex, _message} = hd(warnings)
      assert reflex.id == "curl_pipe_shell"
    end

    test "blocks SSH private key access" do
      assert {:blocked, reflex, _} = Reflex.check(%{path: "~/.ssh/id_rsa"})
      assert reflex.id == "ssh_private_keys"
    end

    test "blocks etc shadow access" do
      assert {:blocked, reflex, _} = Reflex.check(%{path: "/etc/shadow"})
      assert reflex.id == "etc_shadow"
    end

    test "warns on .env file access" do
      assert {:warned, warnings} = Reflex.check(%{path: "/project/.env"})
      {reflex, _} = hd(warnings)
      assert reflex.id == "env_files"
    end

    test "blocks cloud metadata SSRF" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "curl http://169.254.169.254/latest/meta-data/"})
      assert reflex.id == "ssrf_metadata"
    end

    test "warns on localhost requests" do
      assert {:warned, warnings} = Reflex.check(%{command: "curl http://localhost:8080/api"})
      {reflex, _} = hd(warnings)
      assert reflex.id == "ssrf_localhost"
    end

    test "accumulates multiple warnings" do
      # A command that triggers multiple warnings
      assert {:warned, warnings} = Reflex.check(%{command: "curl http://127.0.0.1/test", path: "/project/.env"})
      assert length(warnings) >= 2
    end

    test "block takes precedence over warn" do
      # A context that triggers both block and warn reflexes
      # The block should be returned, not warnings
      assert {:blocked, _, _} = Reflex.check(%{
        command: "sudo rm -rf /",
        path: "/project/.env"  # This would warn
      })
    end

    test "respects reflex priority ordering" do
      # Higher priority reflexes should be checked first
      # and if they block, lower priority ones shouldn't matter
      assert {:blocked, reflex, _} = Reflex.check(%{command: "rm -rf /"})
      # rm_rf_root has priority 100, highest for shell reflexes
      assert reflex.priority == 100
    end
  end

  describe "matches?/2" do
    test "matches pattern reflexes against command" do
      reflex = ReflexContract.pattern("test", ~r/danger/)
      assert Reflex.matches?(reflex, %{command: "danger zone"})
      refute Reflex.matches?(reflex, %{command: "safe zone"})
    end

    test "matches path reflexes against path" do
      reflex = ReflexContract.path("test", "**/.secret")
      assert Reflex.matches?(reflex, %{path: "/home/user/.secret"})
      refute Reflex.matches?(reflex, %{path: "/home/user/public"})
    end

    test "matches action reflexes against action" do
      reflex = ReflexContract.action("test", :delete)
      assert Reflex.matches?(reflex, %{action: :delete})
      refute Reflex.matches?(reflex, %{action: :read})
    end

    test "matches custom reflexes with function" do
      reflex = ReflexContract.custom("test", fn ctx ->
        Map.get(ctx, :value, 0) > 100
      end)
      assert Reflex.matches?(reflex, %{value: 150})
      refute Reflex.matches?(reflex, %{value: 50})
    end

    test "disabled reflexes never match" do
      reflex = ReflexContract.pattern("test", ~r/danger/, enabled: false)
      refute Reflex.matches?(reflex, %{command: "danger zone"})
    end
  end

  describe "register/3 and unregister/1" do
    test "registers and unregisters custom reflexes" do
      reflex = ReflexContract.pattern("custom_test", ~r/custom/, id: "custom_test_reg")

      assert :ok = Reflex.register(:custom_test_reg, reflex)
      assert {:ok, ^reflex} = Reflex.get(:custom_test_reg)

      assert :ok = Reflex.unregister(:custom_test_reg)
      assert {:error, :not_found} = Reflex.get(:custom_test_reg)
    end

    test "registered reflex is used in checks" do
      reflex = ReflexContract.pattern(
        "block_foobar",
        ~r/foobar/,
        id: "foobar_blocker",
        response: :block,
        message: "Blocked foobar"
      )
      Reflex.register(:foobar_blocker, reflex)

      assert {:blocked, _, "Blocked foobar"} = Reflex.check(%{command: "echo foobar"})

      # Cleanup
      Reflex.unregister(:foobar_blocker)
    end
  end

  describe "set_enabled/2" do
    test "enables and disables reflexes" do
      # First register a test reflex
      reflex = ReflexContract.pattern("toggle_test", ~r/toggle/, id: "toggle_test")
      Reflex.register(:toggle_test, reflex)

      # Disable it
      assert :ok = Reflex.set_enabled(:toggle_test, false)
      {:ok, disabled} = Reflex.get(:toggle_test)
      refute disabled.enabled

      # Enable it
      assert :ok = Reflex.set_enabled(:toggle_test, true)
      {:ok, enabled} = Reflex.get(:toggle_test)
      assert enabled.enabled

      # Cleanup
      Reflex.unregister(:toggle_test)
    end

    test "returns error for non-existent reflex" do
      assert {:error, :not_found} = Reflex.set_enabled(:nonexistent_reflex, false)
    end
  end

  describe "list/1" do
    test "lists all reflexes" do
      reflexes = Reflex.list()
      assert is_list(reflexes)
      assert length(reflexes) > 0
    end

    test "filters by enabled" do
      enabled = Reflex.list(enabled_only: true)
      assert Enum.all?(enabled, & &1.enabled)
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      stats = Reflex.stats()
      assert is_integer(stats.total)
      assert is_integer(stats.enabled)
      assert is_map(stats.by_type)
    end
  end
end
