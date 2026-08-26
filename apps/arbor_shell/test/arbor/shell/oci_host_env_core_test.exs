defmodule Arbor.Shell.OciHostEnvCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.OciHostEnvCore, as: Core

  @moduletag :fast
  @moduletag :security_regression

  @home "/home/operator"
  @xdg "/run/user/1000"
  @path "/usr/bin:/bin"

  @valid_xdg_stat %{
    type: :directory,
    uid: 1000,
    mode: 0o40700,
    fstype: "tmpfs"
  }

  @valid_evidence %{
    home: @home,
    xdg_runtime_dir: @xdg,
    euid: 1000,
    home_pin: :ok,
    xdg: @valid_xdg_stat
  }

  @mountinfo """
  22 1 0:23 / / rw,relatime - overlay overlay rw
  36 22 0:25 / /run rw,nosuid,nodev - tmpfs tmpfs rw,mode=755
  55 36 0:27 / /run/user/1000 rw,nosuid,nodev,relatime - tmpfs tmpfs rw,mode=700,uid=1000
  """

  test "admits the closed rootless host env" do
    assert {:ok, env} = Core.admit(@valid_evidence)
    assert env == %{"HOME" => @home, "XDG_RUNTIME_DIR" => @xdg, "PATH" => @path}
    assert :ok = Core.require_closed(env)
  end

  test "security regression: extra evidence keys are rejected" do
    assert {:error, :unsupported_host_env_keys} =
             Core.admit(Map.put(@valid_evidence, :caller_secret, "x"))
  end

  test "security regression: HOME that failed the operator pin is refused" do
    evidence = Map.put(@valid_evidence, :home_pin, {:error, :untrusted_path})

    assert {:error, :untrusted_path} = Core.admit(evidence)
  end

  test "security regression: XDG_RUNTIME_DIR must be /run/user/<euid>" do
    evidence = Map.put(@valid_evidence, :xdg_runtime_dir, "/tmp/runtime")

    assert {:error, :untrusted_xdg_runtime_dir} = Core.admit(evidence)
  end

  test "security regression: XDG_RUNTIME_DIR must be euid-owned 0700 tmpfs" do
    assert {:error, :untrusted_xdg_runtime_dir} =
             Core.admit(put_in(@valid_evidence, [:xdg, :uid], 0))

    assert {:error, :untrusted_xdg_runtime_dir} =
             Core.admit(put_in(@valid_evidence, [:xdg, :mode], 0o40775))

    assert {:error, :untrusted_xdg_runtime_dir} =
             Core.admit(put_in(@valid_evidence, [:xdg, :type], :regular))

    assert {:error, :xdg_runtime_not_tmpfs} =
             Core.admit(put_in(@valid_evidence, [:xdg, :fstype], "overlay"))
  end

  test "security regression: closed env cannot carry extra or caller PATH" do
    {:ok, env} = Core.admit(@valid_evidence)

    assert {:error, :invalid_rootless_host_env} =
             Core.require_closed(Map.put(env, "SECRET", "1"))

    assert {:error, :invalid_rootless_host_env} =
             Core.require_closed(Map.put(env, "PATH", "/evil/bin"))

    assert {:error, :invalid_rootless_host_env} = Core.require_closed(%{})
  end

  test "fstype_at selects the longest covering tmpfs mount" do
    assert {:ok, "tmpfs"} = Core.fstype_at(@mountinfo, @xdg)
    assert {:ok, "overlay"} = Core.fstype_at(@mountinfo, "/etc/passwd")
    assert {:error, :xdg_runtime_mount_unknown} = Core.fstype_at("", @xdg)
  end
end
