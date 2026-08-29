defmodule Arbor.Actions.Coding.SnapshotDestVerifyTest do
  use ExUnit.Case, async: true

  require Logger

  alias Arbor.Actions.Coding.GitBlobOid
  alias Arbor.Actions.Coding.SnapshotDestVerify

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "snapshot-dest-verify-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  describe "dest verify" do
    @describetag :fast

    test "source does not call Shell or git hash-object" do
      source = File.read!(List.to_string(SnapshotDestVerify.module_info(:compile)[:source]))

      refute source =~ "Arbor.Shell"
      refute source =~ "hash-object"
      refute source =~ "execute_direct"
    end

    test "happy path matches held path/mode/oid including newline names", %{tmp: tmp} do
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      newline_name = "line\nbreak.txt"
      File.write!(Path.join(dest, "ordinary.txt"), "hello\n")
      File.write!(Path.join(dest, newline_name), "newline-bytes\n")
      File.write!(Path.join(dest, "tool.sh"), "#!/bin/sh\n")
      File.chmod!(Path.join(dest, "tool.sh"), 0o755)
      File.ln_s("ordinary.txt", Path.join(dest, "held_link"))

      held = [
        entry("ordinary.txt", "100644", "hello\n"),
        entry(newline_name, "100644", "newline-bytes\n"),
        entry("tool.sh", "100755", "#!/bin/sh\n"),
        entry("held_link", "120000", "ordinary.txt")
      ]

      assert {:ok, ^held, stats} = SnapshotDestVerify.verify(dest, held, budget(), :sha1)
      assert stats.dest_files == 4
      assert stats.dest_entries_visited == 4
      assert is_integer(stats.dest_bytes) and stats.dest_bytes >= 0
    end

    test "content mutation is rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      File.write!(Path.join(dest, "file.txt"), "mutated\n")

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "regular to symlink replacement is rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      path = Path.join(dest, "file.txt")
      File.rm!(path)
      File.ln_s("other", path)

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "truncation is rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held-bytes\n")
      held = [entry("file.txt", "100644", "held-bytes\n")]
      File.write!(Path.join(dest, "file.txt"), "held")

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "growth is rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      File.write!(Path.join(dest, "file.txt"), "held\n!")

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "extra path is rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      File.write!(Path.join(dest, "extra.txt"), "extra\n")

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "extra empty directory is rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      File.mkdir_p!(Path.join(dest, "empty_extra"))

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "over-budget bytes are rejected", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "0123456789")
      held = [entry("file.txt", "100644", "0123456789")]

      assert {:error, :tree_binding_bounds_exceeded} =
               SnapshotDestVerify.verify(dest, held, budget(max_bytes: 5), :sha1)
    end

    test "over-budget entries and depth are rejected", %{tmp: tmp} do
      dest = Path.join(tmp, "dest")
      nested = dest <> "/a/b/c"
      File.mkdir_p!(nested)
      File.write!(nested <> "/file.txt", "x")
      held = [entry("a/b/c/file.txt", "100644", "x")]

      assert {:error, :tree_binding_bounds_exceeded} =
               SnapshotDestVerify.verify(dest, held, budget(max_entries: 1), :sha1)

      assert {:error, :tree_binding_bounds_exceeded} =
               SnapshotDestVerify.verify(dest, held, budget(max_depth: 2), :sha1)
    end

    test "changed symlink target is rejected", %{tmp: tmp} do
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "ordinary.txt"), "hello\n")
      File.ln_s("ordinary.txt", Path.join(dest, "held_link"))

      held = [
        entry("ordinary.txt", "100644", "hello\n"),
        entry("held_link", "120000", "ordinary.txt")
      ]

      File.rm!(Path.join(dest, "held_link"))
      File.ln_s("missing", Path.join(dest, "held_link"))

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end
  end

  describe "capture-boundary races" do
    @describetag :fast

    setup do
      on_exit(fn ->
        SnapshotDestVerify.__test_set_regular_hash_hook__(nil)
        SnapshotDestVerify.__test_set_symlink_capture_hook__(nil)
      end)

      :ok
    end

    test "inert process-local hooks do not change a matching dest", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      File.ln_s("file.txt", Path.join(dest, "held_link"))

      held = [
        entry("file.txt", "100644", "held\n"),
        entry("held_link", "120000", "file.txt")
      ]

      SnapshotDestVerify.__test_set_regular_hash_hook__(fn _path, _phase -> :ok end)
      SnapshotDestVerify.__test_set_symlink_capture_hook__(fn _path -> :ok end)

      assert {:ok, ^held, stats} = SnapshotDestVerify.verify(dest, held, budget(), :sha1)
      assert stats.dest_files == 2
    end

    test "truncate after admit is rejected by exact EOF", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held-bytes\n")
      held = [entry("file.txt", "100644", "held-bytes\n")]
      path = Path.join(dest, "file.txt")

      SnapshotDestVerify.__test_set_regular_hash_hook__(fn hooked, phase ->
        if hooked == path and phase == :after_admit do
          File.write!(path, "held")
        end
      end)

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "append after admitted body is rejected by the extra-byte EOF probe", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      path = Path.join(dest, "file.txt")

      SnapshotDestVerify.__test_set_regular_hash_hook__(fn hooked, phase ->
        if hooked == path and phase == :after_body do
          File.open!(path, [:append, :binary], fn io -> IO.binwrite(io, "!") end)
        end
      end)

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "same-path replacement after read is rejected by post-lstat identity", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      path = Path.join(dest, "file.txt")

      SnapshotDestVerify.__test_set_regular_hash_hook__(fn hooked, phase ->
        if hooked == path and phase == :after_read do
          swap = path <> ".swap"
          File.write!(swap, "held\n")
          File.rm!(path)
          File.rename!(swap, path)
        end
      end)

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "type drift after read is rejected by post-lstat identity", %{tmp: tmp} do
      dest = write_regular_dest(tmp, "file.txt", "held\n")
      held = [entry("file.txt", "100644", "held\n")]
      path = Path.join(dest, "file.txt")

      SnapshotDestVerify.__test_set_regular_hash_hook__(fn hooked, phase ->
        if hooked == path and phase == :after_read do
          File.rm!(path)
          File.ln_s("other", path)
        end
      end)

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end

    test "symlink target swap after first read is rejected by re-read", %{tmp: tmp} do
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "ordinary.txt"), "hello\n")
      link = Path.join(dest, "held_link")
      File.ln_s("ordinary.txt", link)

      held = [
        entry("ordinary.txt", "100644", "hello\n"),
        entry("held_link", "120000", "ordinary.txt")
      ]

      SnapshotDestVerify.__test_set_symlink_capture_hook__(fn hooked ->
        if hooked == link do
          File.rm!(link)
          File.ln_s("missing", link)
        end
      end)

      assert {:error, :validation_tree_mutated} =
               SnapshotDestVerify.verify(dest, held, budget(), :sha1)
    end
  end

  describe "multi-thousand-file dest walk" do
    @describetag :slow

    test "in-process walk hashes 4100 regular files without git", %{tmp: tmp} do
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      count = 4100

      held =
        Enum.map(1..count, fn index ->
          name = "f-#{index}.txt"
          content = Integer.to_string(index)
          File.write!(Path.join(dest, name), content)
          entry(name, "100644", content)
        end)

      started = System.monotonic_time(:millisecond)
      assert {:ok, _entries, stats} = SnapshotDestVerify.verify(dest, held, budget(), :sha1)
      walk_ms = max(System.monotonic_time(:millisecond) - started, 0)

      assert stats.dest_files == count

      Logger.info(
        "snapshot_dest_verify 4100-file walk_ms=#{walk_ms} dest_files=#{stats.dest_files}"
      )
    end
  end

  defp write_regular_dest(tmp, name, content) do
    dest = Path.join(tmp, "dest")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, name), content)
    dest
  end

  defp entry(path, mode, content) do
    {:ok, oid} = GitBlobOid.hash_bytes(content, :sha1)
    %{path: path, mode: mode, oid: oid}
  end

  defp budget(opts \\ []) do
    %{
      entries: 0,
      bytes: 0,
      max_entries: Keyword.get(opts, :max_entries, 50_000),
      max_bytes: Keyword.get(opts, :max_bytes, 512 * 1024 * 1024),
      max_depth: Keyword.get(opts, :max_depth, 48)
    }
  end
end
