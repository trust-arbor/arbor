defmodule Arbor.Security.ReflexTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Reflex, as: ReflexContract
  alias Arbor.Security
  alias Arbor.Security.Reflex
  alias Arbor.Security.Reflex.Registry

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

    test "security regression: blocks common recursive-delete option variants" do
      for command <- [
            "rm -rfv /",
            "rm -rf -- /",
            "rm --recursive --force /",
            "rm -rf --no-preserve-root /",
            "rm --preserve-root=no -rf /",
            ~s(rm -rf "/"),
            "rm -rf $HOME",
            ~s(rm -rf "$HOME"),
            ~s(rm -rf "${HOME}"),
            "rm --force --recursive ~/work",
            "/bin/rm -R -f /"
          ] do
        assert {:blocked, reflex, _} = Reflex.check(%{command: command})
        assert reflex.id == "rm_rf_root"
      end
    end

    test "blocks sudo commands" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "sudo apt install foo"})
      assert reflex.id == "sudo_su"
    end

    test "blocks su commands" do
      assert {:blocked, reflex, _} = Reflex.check(%{command: "su - root"})
      assert reflex.id == "sudo_su"
    end

    test "security regression: blocks doas and pkexec privilege escalation" do
      for command <- ["doas sh", "pkexec /bin/sh"] do
        assert {:blocked, reflex, _} = Reflex.check(%{command: command})
        assert reflex.id == "sudo_su"
      end
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
      assert {:warned, warnings} =
               Reflex.check(%{command: "curl http://example.com/script.sh | sh"})

      assert warnings != []
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
      assert {:blocked, reflex, _} =
               Reflex.check(%{command: "curl http://169.254.169.254/latest/meta-data/"})

      assert reflex.id == "ssrf_metadata"
    end

    test "security regression: blocks alternate cloud metadata address forms" do
      for url <- [
            "http://metadata.google.internal/computeMetadata/v1/",
            "http://2852039166/latest/meta-data/",
            "http://[fe80::a9fe:a9fe]/latest/meta-data/",
            "http://[fd00:ec2::254]/latest/meta-data/"
          ] do
        assert {:blocked, reflex, _} = Reflex.check(%{url: url})
        assert reflex.id == "ssrf_metadata"
      end
    end

    test "security regression: sensitive paths are normalized before matching" do
      assert {:blocked, passwd_reflex, _} = Reflex.check(%{path: "/etc//passwd"})
      assert passwd_reflex.id == "etc_passwd"

      private_passwd =
        case Arbor.Common.SafePath.resolve_real("/etc/passwd") do
          {:ok, real} -> real
          _ -> "/etc/passwd"
        end

      assert {:blocked, canonical_reflex, _} = Reflex.check(%{path: private_passwd})
      assert canonical_reflex.id == "etc_passwd"

      assert {:blocked, ssh_reflex, _} = Reflex.check(%{path: "$HOME/.ssh/id_rsa"})
      assert ssh_reflex.id == "ssh_private_keys"
    end

    test "security regression: public authorization extracts the fs path without the operation" do
      previous = Application.get_env(:arbor_security, :reflex_checking_enabled)
      Application.put_env(:arbor_security, :reflex_checking_enabled, true)
      on_exit(fn -> restore_env(:reflex_checking_enabled, previous) end)

      assert {:error, {:reflex_blocked, "etc_passwd", _message}} =
               Security.authorize(
                 "agent_reflex_path_regression",
                 "arbor://fs/read/etc/passwd",
                 :read,
                 verify_identity: false
               )
    end

    test "warns on localhost requests" do
      assert {:warned, warnings} = Reflex.check(%{command: "curl http://localhost:8080/api"})
      {reflex, _} = hd(warnings)
      assert reflex.id == "ssrf_localhost"
    end

    test "accumulates multiple warnings" do
      # A command that triggers multiple warnings
      assert {:warned, warnings} =
               Reflex.check(%{command: "curl http://127.0.0.1/test", path: "/project/.env"})

      assert length(warnings) >= 2
    end

    test "block takes precedence over warn" do
      # A context that triggers both block and warn reflexes
      # The block should be returned, not warnings
      assert {:blocked, _, _} =
               Reflex.check(%{
                 command: "sudo rm -rf /",
                 # This would warn
                 path: "/project/.env"
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
      reflex =
        ReflexContract.custom("test", fn ctx ->
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
    test "security regression: public callers cannot mutate the reflex registry" do
      reflex = ReflexContract.pattern("custom_test", ~r/custom/, id: "custom_test_reg")
      before = Reflex.list()

      assert {:error, :reflex_mutation_unauthorized} =
               Reflex.register(:custom_test_reg, reflex)

      assert {:error, :reflex_mutation_unauthorized} = Reflex.unregister(:rm_rf_root)
      assert {:error, :not_found} = Reflex.get(:custom_test_reg)
      assert Reflex.list() == before

      assert :ets.info(:arbor_reflex_registry, :protection) == :protected

      assert_raise ArgumentError, fn ->
        :ets.insert(:arbor_reflex_registry, {:custom_test_reg, reflex})
      end
    end

    test "owner-installed fixture reflex is used in checks" do
      reflex =
        ReflexContract.pattern(
          "block_foobar",
          ~r/foobar/,
          id: "foobar_blocker",
          response: :block,
          message: "Blocked foobar"
        )

      :ok = Registry.register_fixture(:foobar_blocker, reflex)
      on_exit(fn -> Registry.unregister_fixture(:foobar_blocker) end)

      assert {:blocked, _, "Blocked foobar"} = Reflex.check(%{command: "echo foobar"})
    end
  end

  describe "set_enabled/2" do
    test "security regression: public callers cannot disable an installed reflex" do
      reflex = ReflexContract.pattern("toggle_test", ~r/toggle/, id: "toggle_test")
      :ok = Registry.register_fixture(:toggle_test, reflex)
      on_exit(fn -> Registry.unregister_fixture(:toggle_test) end)

      assert {:error, :reflex_mutation_unauthorized} =
               Reflex.set_enabled(:toggle_test, false)

      assert {:ok, still_enabled} = Reflex.get(:toggle_test)
      assert still_enabled.enabled
    end
  end

  describe "list/1" do
    test "lists all reflexes" do
      reflexes = Reflex.list()
      assert is_list(reflexes)
      assert reflexes != []
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

  describe "infrastructure protection" do
    test "blocks hot-loading of Monitor module" do
      context = %{action: :code_hot_load, module: Arbor.Monitor}

      assert {:blocked, reflex, _msg} = Reflex.check(context)
      assert reflex.id == "no_self_healing"
    end

    test "blocks hot-loading of AnomalyQueue module" do
      context = %{action: :code_hot_load, module: Arbor.Monitor.AnomalyQueue}

      assert {:blocked, reflex, _msg} = Reflex.check(context)
      assert reflex.id == "no_self_healing"
    end

    test "blocks hot-loading of Reflex module itself" do
      context = %{action: :code_hot_load, module: Arbor.Security.Reflex}

      assert {:blocked, reflex, _msg} = Reflex.check(context)
      assert reflex.id == "no_self_healing"
    end

    test "blocks code_eval on protected modules" do
      context = %{action: :code_eval, module: Arbor.Monitor.Poller}

      assert {:blocked, reflex, _msg} = Reflex.check(context)
      assert reflex.id == "no_healing_eval"
    end

    test "allows hot-loading of non-protected modules" do
      context = %{action: :code_hot_load, module: SomeOther.Module}

      assert Reflex.check(context) == :ok
    end

    test "allows other actions on protected modules" do
      context = %{action: :read, module: Arbor.Monitor}

      assert Reflex.check(context) == :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
