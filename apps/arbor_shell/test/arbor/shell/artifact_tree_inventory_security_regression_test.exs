defmodule Arbor.Shell.ArtifactTreeInventorySecurityRegressionTest do
  @moduledoc """
  Public-API security regression for Arbor.Shell.inventory_regular_tree/1.

  Parent 3f79b2f lacks the facade; the candidate must fail closed on symlink,
  hardlink, special, and non-canonical roots without following or admitting them.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.Common.SafePath
  alias Arbor.Shell

  @moduletag :fast
  @moduletag :security_regression
  @exclusive_mkdir_retries 16

  @forbidden_keys MapSet.new([
                    :inode,
                    :uid,
                    :gid,
                    :major_device,
                    :minor_device,
                    :mtime,
                    :ctime,
                    :atime,
                    :descriptor,
                    :pid,
                    :ref,
                    :callback,
                    :authority,
                    "inode",
                    "uid",
                    "gid",
                    "major_device",
                    "minor_device",
                    "mtime",
                    "ctime",
                    "atime",
                    "descriptor",
                    "pid",
                    "ref",
                    "callback",
                    "authority"
                  ])

  setup do
    {:ok, root: exclusive_scratch_root!("artifact-inventory-sec")}
  end

  test "security regression: inventory_regular_tree/1 returns the closed document", %{
    root: root
  } do
    nested = Path.join(root, "bin")
    File.mkdir_p!(nested)
    File.chmod!(nested, 0o755)
    File.write!(Path.join(root, "README"), "hello")
    File.chmod!(Path.join(root, "README"), 0o644)
    File.write!(Path.join(nested, "runner"), "#!/bin/sh\n")
    File.chmod!(Path.join(nested, "runner"), 0o755)
    File.write!(Path.join(root, "secret"), "x")
    File.chmod!(Path.join(root, "secret"), 0o640)

    dir_mode = File.lstat!(nested).mode &&& 0o7777
    readme_mode = File.lstat!(Path.join(root, "README")).mode &&& 0o7777
    runner_mode = File.lstat!(Path.join(nested, "runner")).mode &&& 0o7777
    secret_mode = File.lstat!(Path.join(root, "secret")).mode &&& 0o7777

    assert {:ok, inventory} = Shell.inventory_regular_tree(root)

    assert Enum.sort(Map.keys(inventory)) == [
             "counts",
             "directories",
             "regular_files",
             "schema"
           ]
    assert inventory["schema"] == "arbor.shell.regular_tree_inventory.v1"

    assert inventory["directories"] == [%{"path" => "bin", "mode" => dir_mode}]
    assert dir_mode == 0o755

    files = inventory["regular_files"]
    assert Enum.map(files, & &1["path"]) == ["README", "bin/runner", "secret"]
    assert files == Enum.sort_by(files, & &1["path"], &<=/2)

    readme = Enum.find(files, &(&1["path"] == "README"))
    assert readme["mode"] == readme_mode
    assert readme_mode == 0o644
    refute readme["executable"]
    assert readme["size"] == 5
    assert readme["sha256"] == sha256("hello")
    assert readme["prefix_hex"] == Base.encode16("hello", case: :lower)

    runner = Enum.find(files, &(&1["path"] == "bin/runner"))
    assert runner["mode"] == runner_mode
    assert runner_mode == 0o755
    assert runner["executable"]
    assert runner["size"] == 10
    assert runner["sha256"] == sha256("#!/bin/sh\n")

    secret = Enum.find(files, &(&1["path"] == "secret"))
    assert secret["mode"] == secret_mode
    assert secret_mode == 0o640
    refute secret["executable"]
    assert secret["size"] == 1

    assert inventory["counts"] == %{
             "directories" => 1,
             "regular_files" => 3,
             "entries" => 4,
             "total_regular_bytes" => 16
           }

    refute_forbidden(inventory, root)
  end

  test "security regression: inventory never returns authority or identity fields", %{
    root: root
  } do
    File.write!(Path.join(root, "ok"), "ok")
    assert {:ok, inventory} = Shell.inventory_regular_tree(root)
    refute_forbidden(inventory, root)
  end

  test "security regression: non-canonical and non-directory roots fail closed", %{
    root: root
  } do
    File.write!(Path.join(root, "ok"), "ok")

    assert {:error, :invalid_source_root} = Shell.inventory_regular_tree("/")
    assert {:error, :relative_source_root} = Shell.inventory_regular_tree("relative/path")
    assert {:error, :non_canonical_source_root} = Shell.inventory_regular_tree(root <> "/")
    assert {:error, :non_canonical_source_root} = Shell.inventory_regular_tree(root <> "/.")
    assert {:error, :invalid_source_root} = Shell.inventory_regular_tree(Path.join(root, "ok"))
  end

  test "security regression: symlink root is rejected without following", %{root: root} do
    File.write!(Path.join(root, "keep"), "keep")
    link = root <> "-link"

    case File.ln_s(root, link) do
      :ok ->
        on_exit(fn -> File.rm(link) end)
        assert {:error, :symlink_rejected} = Shell.inventory_regular_tree(link)
        assert File.read!(Path.join(root, "keep")) == "keep"

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "security regression: in-tree symlink is rejected without following", %{root: root} do
    target = Path.join(root, "target")
    File.write!(target, "target")

    case File.ln_s(target, Path.join(root, "link")) do
      :ok ->
        assert {:error, :symlink_rejected} = Shell.inventory_regular_tree(root)
        assert File.read!(target) == "target"

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "security regression: hardlink is rejected where supported", %{root: root} do
    target = Path.join(root, "target")
    File.write!(target, "target")

    case File.ln(target, Path.join(root, "hardlink")) do
      :ok ->
        assert {:error, :hardlink_rejected} = Shell.inventory_regular_tree(root)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "security regression: special files are rejected where supported", %{root: root} do
    fifo = Path.join(root, "pipe")

    if function_exported?(:file, :make_fifo, 2) do
      case apply(:file, :make_fifo, [String.to_charlist(fifo), 0o600]) do
        :ok ->
          assert {:error, :unsupported_source_entry_type} = Shell.inventory_regular_tree(root)

        {:error, reason} ->
          assert reason in [:eacces, :enotsup, :eperm, :einval]
      end
    end
  end

  test "security regression: inventory_regular_tree/2 is not exported" do
    refute function_exported?(Shell, :inventory_regular_tree, 2)
  end

  defp sha256(content) do
    :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
  end

  defp refute_forbidden(value, root) do
    refute_forbidden_value(value, root, [])
  end

  defp refute_forbidden_value(map, root, trail) when is_map(map) do
    Enum.each(map, fn {key, nested} ->
      refute MapSet.member?(@forbidden_keys, key),
             "forbidden key #{inspect(key)} at #{inspect(trail)}"

      refute_forbidden_value(nested, root, [key | trail])
    end)
  end

  defp refute_forbidden_value(list, root, trail) when is_list(list) do
    Enum.each(list, &refute_forbidden_value(&1, root, trail))
  end

  defp refute_forbidden_value(value, _root, trail) when is_binary(value) do
    refute Path.type(value) == :absolute, "absolute path #{inspect(value)} at #{inspect(trail)}"
  end

  defp refute_forbidden_value(value, _root, trail) do
    refute is_pid(value), "pid at #{inspect(trail)}"
    refute is_reference(value), "reference at #{inspect(trail)}"
    refute is_function(value), "callback at #{inspect(trail)}"
  end

  defp exclusive_scratch_root!(prefix) do
    {:ok, tmp} = SafePath.resolve_real(System.tmp_dir!())

    Enum.reduce_while(1..@exclusive_mkdir_retries, :error, fn _, _ ->
      token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      path = Path.join(tmp, prefix <> "-" <> token)

      case File.mkdir(path) do
        :ok ->
          finalize_scratch_root(path)

        {:error, :eexist} ->
          {:cont, :error}

        {:error, reason} ->
          {:halt, {:error, {:mkdir_failed, reason}}}
      end
    end)
    |> case do
      {:ok, root} -> root
      other -> flunk("exclusive scratch root failed: #{inspect(other)}")
    end
  end

  defp finalize_scratch_root(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} ->
        on_exit(fn -> File.rm_rf(real) end)
        {:halt, {:ok, real}}

      {:error, reason} ->
        _ = File.rmdir(path)
        {:halt, {:error, {:canonicalize_failed, reason}}}
    end
  end
end
