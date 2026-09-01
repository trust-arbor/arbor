defmodule Arbor.Shell.CandidateInodePublicationSecurityRegressionTest do
  @moduledoc """
  Security regression for the trusted-internal handle-relative inode syscall.

  Parent lacks Arbor.Shell.apply_handle_relative_inode/1. The candidate must
  fail closed on destination replace, source/destination races, traversal,
  hardlinks, and must never expose delete/rollback or production test hooks.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.API.Shell, as: ShellAPI
  alias Arbor.Shell
  alias Arbor.Shell.HandleRelativeInode
  alias Arbor.Shell.HandleRelativeInodeCore

  @moduletag :fast
  @moduletag :security_regression
  @exclusive_mkdir_retries 16
  @c_src Path.expand("../../../c_src/arbor_shell_handle_relative_inode.c", __DIR__)
  @harness_src Path.expand("../../native/handle_relative_inode_race_harness.c", __DIR__)
  @c_include Path.expand("../../../c_src", __DIR__)

  setup_all do
    %{harness: compile_harness!()}
  end

  setup do
    {:ok, root: exclusive_scratch_root!("g5b1-inode")}
  end

  test "security regression: apply_handle_relative_inode/1 is the closed facade" do
    assert function_exported?(Shell, :apply_handle_relative_inode, 1)
    refute function_exported?(Shell, :apply_handle_relative_inode, 2)
    refute function_exported?(Shell, :__test_set_handle_relative_inode_hook__, 1)
    refute function_exported?(HandleRelativeInode, :__test_set_hook__, 1)

    callbacks = ShellAPI.behaviour_info(:callbacks)
    names = Enum.map(callbacks, fn {name, _arity} -> Atom.to_string(name) end)
    refute Enum.any?(names, &String.contains?(&1, "inode"))
    refute Enum.any?(names, &String.contains?(&1, "handle_relative"))
  end

  test "security regression: production object has no race-hook symbols or control strings" do
    launcher = production_launcher()
    {strings, 0} = System.cmd("strings", [launcher], stderr_to_stdout: true)
    refute strings =~ "arbor_shell_inode_test_hook"
    refute strings =~ "ARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS"
    refute strings =~ "g5b1-hook-"
    refute strings =~ "g5b1-race"

    case System.cmd("nm", ["-a", launcher], stderr_to_stdout: true) do
      {nm, 0} ->
        refute nm =~ "arbor_shell_inode_test_hook"

      {_nm, _status} ->
        :ok
    end
  end

  test "security regression: race harness contains hook control strings", %{harness: harness} do
    {strings, 0} = System.cmd("strings", [harness], stderr_to_stdout: true)
    assert strings =~ "g5b1-hook-"
    assert strings =~ "g5b1-race"

    {symbols, 0} = System.cmd("nm", ["-a", harness], stderr_to_stdout: true)
    assert symbols =~ "arbor_shell_inode_test_hook"
  end

  test "security regression: production C has no delete/rollback and linux renameat2 is fail-closed" do
    c = File.read!(@c_src)
    refute c =~ "unlink"
    refute c =~ "unlinkat"
    refute c =~ "rmdir"
    refute c =~ ~r/\bremove\b/
    stripped = c |> String.replace("renameat2", "") |> String.replace("renameatx_np", "")
    refute stripped =~ "renameat("
    refute stripped =~ "rename("
    assert c =~ "renameat2"
    assert c =~ "RENAME_NOREPLACE"
    assert c =~ "renameatx_np"
    assert c =~ "RENAME_EXCL"
    assert c =~ "g5b1_name_matches_held"

    assert c =~
             ~r/if \(err == ENOENT\) return g5b1_emit_retained\(fds, "source_race"\);\s*if \(!g5b1_name_matches_held\(src_parent, src_name, held\)\) \{\s*return g5b1_emit_retained\(fds, "source_race"\);\s*\}\s*if \(err == ENOSYS \|\| err == EINVAL\) return G5B1_UNSUPPORTED;/
  end

  test "security regression: request bounds fail before launch" do
    assert {:error, :invalid_request} = Shell.apply_handle_relative_inode(%{operation: :nope})
    assert {:error, :invalid_request} = Shell.apply_handle_relative_inode(:not_a_map)

    assert {:error, :invalid_path} =
             HandleRelativeInodeCore.admit(observe_req("relative", "file", []))

    long_root = "/" <> String.duplicate("a", 4096)
    req = observe_req(long_root, "file", [])
    assert {:error, :invalid_path} = HandleRelativeInodeCore.admit(req)

    assert {:error, :invalid_path} =
             HandleRelativeInodeCore.admit(
               observe_req("/tmp/root", String.duplicate("a", 1025), [])
             )

    deep = Enum.join(Enum.map(1..49, &"d#{&1}"), "/")

    assert {:error, :invalid_path} =
             HandleRelativeInodeCore.admit(observe_req("/tmp/root", deep, []))

    assert {:error, :invalid_path} =
             HandleRelativeInodeCore.admit(
               observe_req("/tmp/root", String.duplicate("a", 256), [])
             )

    assert {:error, :invalid_path} =
             HandleRelativeInodeCore.admit(observe_req("/tmp/root", "../x", []))

    assert {:error, :invalid_path} =
             HandleRelativeInodeCore.admit(observe_req("/tmp/root", "/abs", []))

    assert {:error, :invalid_request} =
             HandleRelativeInodeCore.admit(observe_req("/tmp/root", "a/b", []))

    assert {:ok, _plan} = HandleRelativeInodeCore.admit(observe_req("/", "file", []))

    regular_root = %{
      path: "/tmp/root",
      type: :regular,
      device: 0,
      minor_device: 0,
      inode: 1,
      mode: 0,
      uid: 0,
      gid: 0,
      size: 0,
      nlink: 1
    }

    assert {:error, :invalid_type} =
             HandleRelativeInodeCore.admit(%{
               operation: :observe,
               root: regular_root,
               source_relative_path: "file",
               source_ancestors: [],
               source_leaf: %{
                 type: :regular,
                 device: 0,
                 minor_device: 0,
                 inode: 2,
                 mode: 0,
                 uid: 0,
                 gid: 0,
                 size: 0,
                 nlink: 1
               }
             })

    regular_anc = %{
      type: :regular,
      device: 0,
      minor_device: 0,
      inode: 3,
      mode: 0,
      uid: 0,
      gid: 0,
      size: 0,
      nlink: 1
    }

    assert {:error, :invalid_type} =
             HandleRelativeInodeCore.admit(observe_req("/tmp/root", "a/file", [regular_anc]))

    dir_leaf = %{
      type: :directory,
      device: 0,
      minor_device: 0,
      inode: 4,
      mode: 0,
      uid: 0,
      gid: 0,
      size: 0,
      nlink: 2
    }

    assert {:error, :invalid_type} =
             HandleRelativeInodeCore.admit(%{
               operation: :relocate,
               root: %{
                 path: "/tmp/root",
                 type: :directory,
                 device: 0,
                 minor_device: 0,
                 inode: 1,
                 mode: 0,
                 uid: 0,
                 gid: 0,
                 size: 0,
                 nlink: 2
               },
               source_relative_path: "src",
               source_ancestors: [],
               source_leaf: dir_leaf,
               source_name: "src",
               destination_relative_path: "dst",
               destination_ancestors: [],
               destination_name: "dst"
             })

    huge = %{
      path: "/tmp/root",
      type: :directory,
      device: 0x1_0000_0000_0000_0000,
      minor_device: 0,
      inode: 1,
      mode: 0,
      uid: 0,
      gid: 0,
      size: 0,
      nlink: 2
    }

    assert {:error, :invalid_request} =
             HandleRelativeInodeCore.admit(%{
               operation: :observe,
               root: huge,
               source_relative_path: "file",
               source_ancestors: [],
               source_leaf: %{
                 type: :regular,
                 device: 0,
                 minor_device: 0,
                 inode: 2,
                 mode: 0,
                 uid: 0,
                 gid: 0,
                 size: 0,
                 nlink: 1
               }
             })

    assert {:error, :invalid_request} =
             HandleRelativeInodeCore.admit(%{
               operation: :stage,
               root: %{
                 path: "/tmp/root",
                 type: :directory,
                 device: 0,
                 minor_device: 0,
                 inode: 1,
                 mode: 0,
                 uid: 0,
                 gid: 0,
                 size: 0,
                 nlink: 2
               },
               stage_relative_path: "n",
               stage_ancestors: [],
               stage_name: "n",
               mode: 0o777,
               payload: "x"
             })

    oversized = :binary.copy(<<1>>, 16_777_217)

    assert {:error, :invalid_request} =
             HandleRelativeInodeCore.admit(%{
               operation: :stage,
               root: %{
                 path: "/tmp/root",
                 type: :directory,
                 device: 0,
                 minor_device: 0,
                 inode: 1,
                 mode: 0,
                 uid: 0,
                 gid: 0,
                 size: 0,
                 nlink: 2
               },
               stage_relative_path: "n",
               stage_ancestors: [],
               stage_name: "n",
               mode: 0o600,
               payload: oversized
             })
  end

  test "security regression: unsupported platform is fail-closed in the shell" do
    source = File.read!(Path.expand("../../../lib/arbor/shell/handle_relative_inode.ex", __DIR__))
    assert source =~ ":unsupported_platform"
    assert source =~ "{:unix, :darwin}"
    assert source =~ "{:unix, :linux}"
  end

  test "security regression: destination no-replace never replaces", %{root: root} do
    if unix_inode_host?() do
      mkdir_tree!(root, ["src"])
      src = Path.join(root, "src/file")
      dest = Path.join(root, "taken")
      File.write!(src, "hello")
      File.chmod!(src, 0o600)
      File.write!(dest, "attacker")
      File.chmod!(dest, 0o600)
      dest_before = node_id(dest)

      assert {:error, :destination_exists} =
               Shell.apply_handle_relative_inode(
                 relocate_req(root, "src/file", "taken", node_id(src))
               )

      assert File.read!(dest) == "attacker"
      assert node_id(dest) == dest_before
      assert File.exists?(src)
    end
  end

  test "security regression: source unlink before rename is retained source_race", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      mkdir_tree!(root, ["src"])
      src = Path.join(root, "src/file")
      File.write!(src, "hello")
      File.chmod!(src, 0o600)
      req = relocate_req(root, "src/file", "dest", node_id(src))
      {:ok, plan} = HandleRelativeInodeCore.admit(req)

      {output, status} = run_harness(harness, "g5b1-hook-before-rename", plan)
      assert status == 75
      assert output =~ "source_race"
      refute status == 65
    end
  end

  test "security regression: source substitution before rename is retained", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      mkdir_tree!(root, ["src"])
      src = Path.join(root, "src/file")
      File.write!(src, "hello")
      File.chmod!(src, 0o600)
      req = relocate_req(root, "src/file", "dest", node_id(src))
      {:ok, plan} = HandleRelativeInodeCore.admit(req)

      {output, status} = run_harness(harness, "g5b1-hook-before-rename-swap", plan)
      assert status == 75
      assert output =~ "source_race" or output =~ "destination_race"
      refute status == 65
      refute status == 76
      refute status == 70
    end
  end

  test "security regression: destination substitution after rename is retained", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      mkdir_tree!(root, ["src"])
      src = Path.join(root, "src/file")
      File.write!(src, "hello")
      File.chmod!(src, 0o600)
      req = relocate_req(root, "src/file", "dest", node_id(src))
      {:ok, plan} = HandleRelativeInodeCore.admit(req)

      {output, status} = run_harness(harness, "g5b1-hook-after-rename", plan)
      assert status == 75
      assert output =~ "destination_race" or output =~ "source_race"
    end
  end

  test "security regression: full ancestor replacement during walk is identity_mismatch", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      mkdir_tree!(root, ["a", "a/b"])
      leaf = Path.join(root, "a/b/file")
      File.write!(leaf, "x")
      File.chmod!(leaf, 0o600)
      req = observe_live(root, "a/b/file")
      {:ok, plan} = HandleRelativeInodeCore.admit(req)
      {output, status} = run_harness(harness, "g5b1-hook-after-root-bind", plan)
      assert status == 69
      refute File.exists?(Path.join(root, "planted"))
      _ = output
    end
  end

  test "security regression: hardlink rejection", %{root: root} do
    if unix_inode_host?() do
      target = Path.join(root, "target")
      File.write!(target, "x")
      File.chmod!(target, 0o600)

      case File.ln(target, Path.join(root, "hard")) do
        :ok ->
          assert {:error, :hardlink_rejected} =
                   Shell.apply_handle_relative_inode(observe_live(root, "hard"))

          assert {:error, :hardlink_rejected} =
                   HandleRelativeInodeCore.admit(observe_live(root, "hard"))

        {:error, reason} ->
          assert reason in [:eacces, :enotsup, :eperm, :einval]
      end
    end
  end

  test "security regression: symlink and traversal rejection", %{root: root} do
    if unix_inode_host?() do
      real = Path.join(root, "real")
      File.write!(real, "x")
      File.chmod!(real, 0o600)
      File.ln_s("real", Path.join(root, "link"))

      req = %{
        operation: :observe,
        root: root_id(root),
        source_relative_path: "link",
        source_ancestors: [],
        source_leaf: node_id(real)
      }

      assert {:error, :symlink_rejected} = Shell.apply_handle_relative_inode(req)

      assert {:error, :invalid_path} =
               HandleRelativeInodeCore.admit(observe_req(root, "../escape", []))

      assert {:error, :invalid_path} =
               HandleRelativeInodeCore.admit(observe_req(root, "/etc/passwd", []))
    end
  end

  test "security regression: same-parent relocate publishes dest and source is absent", %{
    root: root
  } do
    if unix_inode_host?() do
      assert {:ok, staged} =
               Shell.apply_handle_relative_inode(stage_req(root, "tmp", 0o600, "hello"))

      assert {:ok, moved} =
               Shell.apply_handle_relative_inode(
                 relocate_req(root, "tmp", "final", staged.leaf |> Map.drop([:path]))
               )

      assert moved.leaf.inode == staged.leaf.inode
      assert moved.leaf.device == staged.leaf.device
      refute File.exists?(Path.join(root, "tmp"))
      assert File.read!(Path.join(root, "final")) == "hello"
      assert moved.source_parent.inode == moved.parent.inode
    end
  end

  test "security regression: distinct-parent relocate refreshes both parents", %{root: root} do
    if unix_inode_host?() do
      mkdir_tree!(root, ["a", "b"])

      assert {:ok, staged} =
               Shell.apply_handle_relative_inode(stage_req(root, "a/tmp", 0o644, "abc"))

      assert {:ok, moved} =
               Shell.apply_handle_relative_inode(
                 relocate_req(root, "a/tmp", "b/out", staged.leaf |> Map.drop([:path]))
               )

      assert moved.leaf.inode == staged.leaf.inode
      assert moved.parent.inode != moved.source_parent.inode
      refute File.exists?(Path.join(root, "a/tmp"))
      assert File.read!(Path.join(root, "b/out")) == "abc"
    end
  end

  test "security regression: staged-name substitution retains names", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      req = stage_req(root, "staged", 0o600, "payload")
      {:ok, plan} = HandleRelativeInodeCore.admit(req)
      {output, status} = run_harness(harness, "g5b1-hook-after-create", plan)
      assert status == 75
      assert output =~ "stage_name_race"
      assert Map.has_key?(plan.names, :stage_name)
    end
  end

  test "security regression: post-stage fsync failure retains names and does not clean up", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      req = stage_req(root, "staged", 0o600, "payload")
      {:ok, plan} = HandleRelativeInodeCore.admit(req)
      {output, status} = run_harness(harness, "g5b1-hook-fsync-parent-fail", plan)
      assert status == 75
      assert output =~ "fsync_failed"
      assert plan.names.stage_name == "staged"
      assert File.exists?(Path.join(root, "staged"))
    end
  end

  test "security regression: observe re-proves the held leaf before success", %{
    root: root,
    harness: harness
  } do
    if unix_inode_host?() do
      leaf = Path.join(root, "observed")
      File.write!(leaf, "expected")
      File.chmod!(leaf, 0o600)
      {:ok, plan} = HandleRelativeInodeCore.admit(observe_live(root, "observed"))

      {output, status} = run_harness(harness, "g5b1-hook-observe-swap", plan)

      assert status == 69
      refute output =~ "g5b1-1"
    end
  end

  test "root slash path rendering remains canonical" do
    c = File.read!(@c_src)

    assert c =~ "strcmp(root, \"/\") == 0"
    assert c =~ "snprintf(out, outsz, \"/%s\", rel)"
  end

  test "security regression: Darwin/Linux observe binds absolute root, ancestors, and OTP ABI", %{
    root: root
  } do
    if unix_inode_host?() do
      mkdir_tree!(root, ["one", "one/two"])
      leaf = Path.join(root, "one/two/file")
      File.write!(leaf, "body")
      File.chmod!(leaf, 0o644)
      stat = File.lstat!(leaf, time: :posix)

      assert {:ok, result} = Shell.apply_handle_relative_inode(observe_live(root, "one/two/file"))
      assert result.operation == :observe
      assert result.leaf.device == stat.major_device
      assert result.leaf.minor_device == stat.minor_device
      assert result.leaf.inode == stat.inode
      assert result.leaf.mode == stat.mode
      assert result.leaf.uid == stat.uid
      assert result.leaf.gid == stat.gid
      assert result.leaf.size == stat.size
      assert result.leaf.nlink == stat.links
      assert result.root.path == root
      assert String.ends_with?(result.parent.path, "/one/two")

      if result.leaf.inode > 0xFFFFFFFF do
        refute result.leaf.inode == (result.leaf.inode &&& 0xFFFFFFFF)
      end
    end
  end

  test "security regression: observe empty, unparseable, and timeout map to closed atoms" do
    observe_plan = %{
      mutating?: false,
      operation: :observe,
      names: %{root_path: "/r", source_relative_path: "f"}
    }

    assert {:error, :output_empty} =
             HandleRelativeInode.decode_port_result(observe_plan, 0, "")

    assert {:error, :output_unparseable} =
             HandleRelativeInode.decode_port_result(observe_plan, 0, "garbage\n")

    assert {:error, :output_incomplete} =
             HandleRelativeInode.decode_port_result(observe_plan, 0, "g5b1-1\nobserve\n")

    assert {:error, :timeout} = HandleRelativeInode.map_collect_failure(observe_plan, :timeout)

    assert {:error, :port_death} =
             HandleRelativeInode.map_collect_failure(observe_plan, :port_death)

    refute match?(
             {:error, {:retained_ambiguity, _, _}},
             HandleRelativeInode.decode_port_result(observe_plan, 0, "")
           )

    names = %{root_path: "/r", stage_relative_path: "s", stage_name: "s"}
    stage_plan = %{mutating?: true, operation: :stage, names: names}

    assert {:error, {:retained_ambiguity, :output_empty, ^names}} =
             HandleRelativeInode.decode_port_result(stage_plan, 0, "")

    assert {:error, {:retained_ambiguity, :output_unparseable, ^names}} =
             HandleRelativeInode.decode_port_result(stage_plan, 0, "garbage\n")

    assert {:error, {:retained_ambiguity, :timeout, ^names}} =
             HandleRelativeInode.map_collect_failure(stage_plan, :timeout)
  end

  defp unix_inode_host? do
    match?({:unix, :darwin}, :os.type()) or match?({:unix, :linux}, :os.type())
  end

  defp production_launcher do
    path = :code.priv_dir(:arbor_shell) |> List.to_string() |> Path.join("arbor_shell_launcher")
    assert File.exists?(path)
    path
  end

  defp compile_harness! do
    dir = exclusive_dir!("g5b1-harness")
    out = Path.join(dir, "handle_relative_inode_race_harness")

    {output, status} =
      System.cmd(
        "cc",
        [
          "-std=c11",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-DARBOR_HANDLE_RELATIVE_INODE_TEST_HOOKS",
          "-I",
          @c_include,
          Path.join(@c_include, "arbor_shell_handle_relative_inode.c"),
          @harness_src,
          "-o",
          out
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    out
  end

  defp run_harness(harness, hook, plan) do
    input_dir = exclusive_dir!("g5b1-harness-input")
    input_path = Path.join(input_dir, "stdin")
    File.write!(input_path, plan.payload, [:binary])

    System.cmd(
      "sh",
      [
        "-c",
        ~S|input=$1; shift; exec "$@" < "$input"|,
        "g5b1-harness",
        input_path,
        harness,
        "g5b1-race",
        hook | plan.argv
      ],
      stderr_to_stdout: true
    )
  end

  defp mkdir_tree!(root, rels) do
    File.chmod!(root, 0o755)

    Enum.each(rels, fn rel ->
      path = Path.join(root, rel)
      File.mkdir_p!(path)
      File.chmod!(path, 0o755)
    end)
  end

  defp node_id(path) do
    stat = File.lstat!(path, time: :posix)

    %{
      type: stat.type,
      device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      mode: stat.mode,
      uid: stat.uid,
      gid: stat.gid,
      size: stat.size,
      nlink: stat.links
    }
  end

  defp root_id(path), do: Map.put(node_id(path), :path, path)

  defp ancestors_of(root, rel) do
    comps = String.split(rel, "/")
    dirs = Enum.drop(comps, -1)

    {ids, _} =
      Enum.map_reduce(dirs, [], fn name, acc ->
        next = acc ++ [name]
        {node_id(Path.join(root, Enum.join(next, "/"))), next}
      end)

    ids
  end

  defp observe_live(root, rel) do
    %{
      operation: :observe,
      root: root_id(root),
      source_relative_path: rel,
      source_ancestors: ancestors_of(root, rel),
      source_leaf: node_id(Path.join(root, rel))
    }
  end

  defp observe_req(root_path, rel, ancestors) do
    %{
      operation: :observe,
      root: %{
        path: root_path,
        type: :directory,
        device: 0,
        minor_device: 0,
        inode: 1,
        mode: 0,
        uid: 0,
        gid: 0,
        size: 0,
        nlink: 2
      },
      source_relative_path: rel,
      source_ancestors: ancestors,
      source_leaf: %{
        type: :regular,
        device: 0,
        minor_device: 0,
        inode: 2,
        mode: 0,
        uid: 0,
        gid: 0,
        size: 0,
        nlink: 1
      }
    }
  end

  defp stage_req(root, rel, mode, payload) do
    %{
      operation: :stage,
      root: root_id(root),
      stage_relative_path: rel,
      stage_ancestors: ancestors_of(root, rel),
      stage_name: Path.basename(rel),
      mode: mode,
      payload: payload
    }
  end

  defp relocate_req(root, src, dst, src_leaf) do
    %{
      operation: :relocate,
      root: root_id(root),
      source_relative_path: src,
      source_ancestors: ancestors_of(root, src),
      source_leaf: src_leaf,
      source_name: Path.basename(src),
      destination_relative_path: dst,
      destination_ancestors: ancestors_of(root, dst),
      destination_name: Path.basename(dst)
    }
  end

  defp exclusive_scratch_root!(prefix) do
    path = exclusive_dir!(prefix)
    File.chmod!(path, 0o755)
    path
  end

  defp exclusive_dir!(prefix) do
    {:ok, tmp} = SafePath.resolve_real(System.tmp_dir!())

    Enum.reduce_while(1..@exclusive_mkdir_retries, :error, fn _, _ ->
      token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      path = Path.join(tmp, prefix <> "-" <> token)

      case File.mkdir(path) do
        :ok ->
          {:halt, {:ok, path}}

        {:error, :eexist} ->
          {:cont, :error}

        {:error, reason} ->
          {:halt, {:error, {:mkdir_failed, reason}}}
      end
    end)
    |> case do
      {:ok, path} ->
        on_exit(fn -> File.rm_rf(path) end)
        path

      other ->
        flunk("exclusive dir failed: #{inspect(other)}")
    end
  end
end
