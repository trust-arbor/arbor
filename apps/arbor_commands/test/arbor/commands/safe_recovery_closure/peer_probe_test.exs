defmodule Arbor.Commands.SafeRecoveryClosure.PeerProbeTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryClosure.PeerProbe
  alias Arbor.Common.SafePath

  @env "ARBOR_SECURITY_STATE_DIR"
  @prefix "arbor-e0b3-security-"

  setup do
    previous_system_env = System.fetch_env(@env)
    previous_app_env = Application.fetch_env(:arbor_security, :authority_state_root)
    previous_runtime = Application.fetch_env(:arbor_kernel, :kernel_runtime)

    on_exit(fn ->
      restore_system_env(previous_system_env)
      restore_app_env(previous_app_env)
      restore_runtime(previous_runtime)
    end)

    :ok
  end

  test "security regression: accepts an exact private manager-shaped root" do
    {path, identity} = create_owned_root!(@prefix)
    on_exit(fn -> Arbor.Shell.remove_owned_tree(identity) end)
    System.put_env(@env, path)

    assert :ok = PeerProbe.__test_install_ephemeral_authority_root__()
    assert Application.get_env(:arbor_security, :authority_state_root) == path
  end

  test "rejects a missing root without selecting a fallback" do
    System.delete_env(@env)

    assert {:error, :ephemeral_authority_root_missing} =
             PeerProbe.__test_install_ephemeral_authority_root__()
  end

  test "rejects a wrong prefix" do
    {path, identity} = create_owned_root!("wrong-prefix-")
    on_exit(fn -> Arbor.Shell.remove_owned_tree(identity) end)
    System.put_env(@env, path)

    assert {:error, :ephemeral_authority_root_unsafe} =
             PeerProbe.__test_install_ephemeral_authority_root__()
  end

  test "rejects relative and traversal paths" do
    for path <- ["relative/security", Path.join(System.tmp_dir!(), "segment/../security")] do
      System.put_env(@env, path)

      assert {:error, :ephemeral_authority_root_unsafe} =
               PeerProbe.__test_install_ephemeral_authority_root__()
    end
  end

  test "rejects a symlink with a valid-looking name" do
    {target, target_identity} = create_owned_root!("symlink-target-")
    link = valid_root_path()
    on_exit(fn -> File.rm(link) end)
    on_exit(fn -> Arbor.Shell.remove_owned_tree(target_identity) end)
    assert :ok = File.ln_s(target, link)
    System.put_env(@env, link)

    assert {:error, :ephemeral_authority_root_unsafe} =
             PeerProbe.__test_install_ephemeral_authority_root__()
  end

  test "rejects group or other permissions" do
    {path, identity} = create_owned_root!(@prefix)
    on_exit(fn -> Arbor.Shell.remove_owned_tree(identity) end)
    File.chmod!(path, 0o755)
    System.put_env(@env, path)

    assert {:error, :ephemeral_authority_root_unsafe} =
             PeerProbe.__test_install_ephemeral_authority_root__()
  end

  test "rejects an oversized absolute path" do
    System.put_env(@env, "/" <> String.duplicate("a", 4_096))

    assert {:error, :ephemeral_authority_root_unsafe} =
             PeerProbe.__test_install_ephemeral_authority_root__()
  end

  test "security regression: activation_only overlay keeps boot_profile identity" do
    boot_profile = [manifest_bytes: "m", signature_bytes: "s"]

    Application.put_env(:arbor_kernel, :kernel_runtime,
      start_profile: :full,
      boot_profile: boot_profile,
      expected_profile_id: "safe_recovery"
    )

    assert :ok = PeerProbe.__test_install_activation_only_profile__()
    runtime = Application.get_env(:arbor_kernel, :kernel_runtime)
    assert Keyword.get(runtime, :start_profile) == :activation_only
    assert Keyword.get(runtime, :boot_profile) == boot_profile
    assert Keyword.get(runtime, :expected_profile_id) == "safe_recovery"
  end

  test "security regression: activation_only overlay fails closed without boot_profile" do
    Application.put_env(:arbor_kernel, :kernel_runtime, start_profile: :full)

    assert {:error, :boot_profile_missing} =
             PeerProbe.__test_install_activation_only_profile__()
  end

  defp create_owned_root!(prefix) do
    path = root_path(prefix)
    {:ok, identity} = Arbor.Shell.create_private_owned_tree(path)
    {path, identity}
  end

  defp valid_root_path, do: root_path(@prefix)

  defp root_path(prefix) do
    {:ok, tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    Path.join(tmp, prefix <> token)
  end

  defp restore_system_env({:ok, value}), do: System.put_env(@env, value)
  defp restore_system_env(:error), do: System.delete_env(@env)

  defp restore_app_env({:ok, value}),
    do: Application.put_env(:arbor_security, :authority_state_root, value)

  defp restore_app_env(:error),
    do: Application.delete_env(:arbor_security, :authority_state_root)

  defp restore_runtime({:ok, value}),
    do: Application.put_env(:arbor_kernel, :kernel_runtime, value)

  defp restore_runtime(:error), do: Application.delete_env(:arbor_kernel, :kernel_runtime)
end
