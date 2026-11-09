defmodule Arbor.KernelRuntime.ProviderGateSDKPathValidationSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.SafePath
  alias Arbor.KernelRuntime.ProviderGate.SDKPath

  @moduletag :fast
  @moduletag :tmp_dir

  test "security regression: one curated SDK component is selected from actual directory entries",
       %{tmp_dir: root} do
    File.mkdir!(Path.join(root, "os_mon-2.11.2"))
    File.mkdir!(Path.join(root, "stdlib-7.3"))
    assert {:ok, "os_mon-2.11.2"} = SDKPath.one_component(File.ls!(root))
    assert :ok = SDKPath.validate_root(root, Path.join(root, "lib"))
  end

  test "security regression: missing and ambiguous SDK components are refused", %{tmp_dir: root} do
    assert {:error, :missing} = SDKPath.one_component(File.ls!(root))
    File.mkdir!(Path.join(root, "os_mon-2.11.2"))
    File.mkdir!(Path.join(root, "os_mon-2.12"))
    assert {:error, :ambiguous} = SDKPath.one_component(File.ls!(root))
  end

  test "security regression: archive or invalid version guesses are not selected", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "os_mon-2.11.2.ez"), "fixture")
    assert {:error, :unsafe} = SDKPath.one_component(File.ls!(root))
  end

  test "security regression: canonical owned regular observations are accepted", %{tmp_dir: root} do
    app = app_fixture!(root)
    uid = File.stat!(root).uid
    assert :ok = observe(app, :regular, uid)
  end

  test "security regression: symlink and outside SDK resolutions are refused", %{tmp_dir: root} do
    app = app_fixture!(root)
    link = Path.join(root, "os_mon-link.app")
    File.ln_s!(app, link)
    uid = File.stat!(root).uid
    assert {:error, :unsafe} = observe(link, :regular, uid)
    assert {:error, :unsafe} = SDKPath.validate_root(root, Path.join(root, "elsewhere/lib"))
  end

  test "security regression: wrong owner and type are refused", %{tmp_dir: root} do
    app = app_fixture!(root)
    uid = File.stat!(root).uid
    assert {:error, :unsafe} = observe(app, :regular, uid + 1)
    assert {:error, :unsafe} = observe(app, :directory, uid)
  end

  test "security regression: writable and hardlinked app observations are refused", %{
    tmp_dir: root
  } do
    app = app_fixture!(root)
    uid = File.stat!(root).uid
    File.chmod!(app, 0o666)
    assert {:error, :unsafe} = observe(app, :regular, uid)
    File.chmod!(app, 0o644)
    File.ln!(app, Path.join(root, "os_mon-hardlink.app"))
    assert {:error, :unsafe} = observe(app, :regular, uid)
  end

  defp app_fixture!(root) do
    app = Path.join(root, "os_mon.app")
    File.write!(app, "fixture observations only; not an application resource")
    File.chmod!(app, 0o644)
    {:ok, canonical_app} = SafePath.resolve_real(app)
    canonical_app
  end

  defp observe(path, type, uid),
    do: SDKPath.validate_entry(path, SafePath.resolve_real(path), File.lstat(path), type, uid)
end
