defmodule Arbor.Security.Reflex.BuiltinTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Reflex
  alias Arbor.Security.Reflex.Builtin

  describe "all/0" do
    test "returns a non-empty list of reflexes" do
      all = Builtin.all()
      assert is_list(all)
      assert length(all) > 0
    end

    test "all reflexes have valid structure" do
      for reflex <- Builtin.all() do
        assert %Reflex{} = reflex
        assert is_binary(reflex.id)
        assert is_binary(reflex.name)
        assert reflex.type in [:pattern, :action, :path, :custom]
        assert reflex.response in [:block, :warn, :log]
        assert is_integer(reflex.priority)
        assert is_boolean(reflex.enabled)
      end
    end

    test "all reflexes have unique IDs" do
      ids = Builtin.ids()
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "shell_reflexes/0" do
    test "includes rm -rf protection" do
      reflexes = Builtin.shell_reflexes()
      rm_rf = Enum.find(reflexes, &(&1.id == "rm_rf_root"))

      assert rm_rf != nil
      assert rm_rf.type == :pattern
      assert rm_rf.response == :block
      assert rm_rf.priority == 100
    end

    test "includes sudo/su protection" do
      reflexes = Builtin.shell_reflexes()
      sudo = Enum.find(reflexes, &(&1.id == "sudo_su"))

      assert sudo != nil
      assert sudo.response == :block
      assert sudo.priority == 100
    end

    test "includes chmod protection" do
      reflexes = Builtin.shell_reflexes()
      chmod = Enum.find(reflexes, &(&1.id == "chmod_dangerous"))

      assert chmod != nil
      assert chmod.response == :block
    end

    test "includes dd disk protection" do
      reflexes = Builtin.shell_reflexes()
      dd = Enum.find(reflexes, &(&1.id == "dd_disk"))

      assert dd != nil
      assert dd.response == :block
    end

    test "includes mkfs protection" do
      reflexes = Builtin.shell_reflexes()
      mkfs = Enum.find(reflexes, &(&1.id == "mkfs"))

      assert mkfs != nil
      assert mkfs.response == :block
    end

    test "includes curl pipe shell warning" do
      reflexes = Builtin.shell_reflexes()
      curl = Enum.find(reflexes, &(&1.id == "curl_pipe_shell"))

      assert curl != nil
      # This is a warning, not a block (common pattern, may be legitimate)
      assert curl.response == :warn
    end

    test "includes fork bomb protection" do
      reflexes = Builtin.shell_reflexes()
      fork = Enum.find(reflexes, &(&1.id == "fork_bomb"))

      assert fork != nil
      assert fork.response == :block
      assert fork.priority == 100
    end
  end

  describe "file_reflexes/0" do
    test "includes SSH private key protection" do
      reflexes = Builtin.file_reflexes()
      ssh = Enum.find(reflexes, &(&1.id == "ssh_private_keys"))

      assert ssh != nil
      assert ssh.type == :path
      assert ssh.response == :block
    end

    test "includes env file warning" do
      reflexes = Builtin.file_reflexes()
      env = Enum.find(reflexes, &(&1.id == "env_files"))

      assert env != nil
      # .env access is warned, not blocked (sometimes legitimate)
      assert env.response == :warn
    end

    test "includes etc shadow protection" do
      reflexes = Builtin.file_reflexes()
      shadow = Enum.find(reflexes, &(&1.id == "etc_shadow"))

      assert shadow != nil
      assert shadow.response == :block
      assert shadow.priority == 100
    end

    test "includes AWS credentials warning" do
      reflexes = Builtin.file_reflexes()
      aws = Enum.find(reflexes, &(&1.id == "aws_credentials"))

      assert aws != nil
      assert aws.response == :warn
    end
  end

  describe "network_reflexes/0" do
    test "includes SSRF localhost warning" do
      reflexes = Builtin.network_reflexes()
      localhost = Enum.find(reflexes, &(&1.id == "ssrf_localhost"))

      assert localhost != nil
      assert localhost.type == :pattern
      assert localhost.response == :warn
    end

    test "includes cloud metadata protection" do
      reflexes = Builtin.network_reflexes()
      metadata = Enum.find(reflexes, &(&1.id == "ssrf_metadata"))

      assert metadata != nil
      # This is critical - blocks access to cloud metadata
      assert metadata.response == :block
    end

    test "includes internal network warnings" do
      reflexes = Builtin.network_reflexes()
      internal_10 = Enum.find(reflexes, &(&1.id == "ssrf_internal_10"))
      internal_192 = Enum.find(reflexes, &(&1.id == "ssrf_internal_192"))

      assert internal_10 != nil
      assert internal_192 != nil
      assert internal_10.response == :warn
      assert internal_192.response == :warn
    end
  end

  describe "by_category/1" do
    test "returns shell reflexes for :shell" do
      # Compare by IDs since Regex structs don't compare as equal
      shell_ids = Enum.map(Builtin.by_category(:shell), & &1.id)
      expected_ids = Enum.map(Builtin.shell_reflexes(), & &1.id)
      assert shell_ids == expected_ids
    end

    test "returns file reflexes for :file" do
      file_ids = Enum.map(Builtin.by_category(:file), & &1.id)
      expected_ids = Enum.map(Builtin.file_reflexes(), & &1.id)
      assert file_ids == expected_ids
    end

    test "returns network reflexes for :network" do
      network_ids = Enum.map(Builtin.by_category(:network), & &1.id)
      expected_ids = Enum.map(Builtin.network_reflexes(), & &1.id)
      assert network_ids == expected_ids
    end

    test "returns empty list for unknown category" do
      assert Builtin.by_category(:unknown) == []
    end
  end

  describe "ids/0" do
    test "returns list of all reflex IDs" do
      ids = Builtin.ids()

      assert is_list(ids)
      assert Enum.all?(ids, &is_binary/1)

      # Check for some expected IDs
      assert "rm_rf_root" in ids
      assert "sudo_su" in ids
      assert "ssh_private_keys" in ids
      assert "ssrf_metadata" in ids
    end
  end

  describe "pattern matching accuracy" do
    # Test that the regex patterns actually match what they should

    test "rm_rf_root matches dangerous patterns" do
      [rm_rf] = Enum.filter(Builtin.shell_reflexes(), &(&1.id == "rm_rf_root"))
      {:pattern, regex} = rm_rf.trigger

      # Should match
      assert Regex.match?(regex, "rm -rf /")
      assert Regex.match?(regex, "rm -rf ~")
      assert Regex.match?(regex, "rm -r /var")
      assert Regex.match?(regex, "rm -f /etc")

      # Should NOT match (safe commands)
      refute Regex.match?(regex, "rm file.txt")
      refute Regex.match?(regex, "rm -f file.txt")
    end

    test "sudo_su matches privilege escalation" do
      [sudo] = Enum.filter(Builtin.shell_reflexes(), &(&1.id == "sudo_su"))
      {:pattern, regex} = sudo.trigger

      assert Regex.match?(regex, "sudo apt install")
      assert Regex.match?(regex, "su - root")
      assert Regex.match?(regex, "sudo -i")

      refute Regex.match?(regex, "sudoku")  # Not sudo
      refute Regex.match?(regex, "resume")  # Contains 'su' but not the command
    end

    test "ssrf_metadata matches cloud metadata" do
      [meta] = Enum.filter(Builtin.network_reflexes(), &(&1.id == "ssrf_metadata"))
      {:pattern, regex} = meta.trigger

      assert Regex.match?(regex, "http://169.254.169.254/latest/meta-data/")
      assert Regex.match?(regex, "https://169.254.1.1/")

      refute Regex.match?(regex, "http://169.253.169.254/")  # Wrong IP range
    end
  end
end
