defmodule Arbor.Shell.LinuxDependencyBaselineBuilderTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.LinuxDependencyBaselineBuilder, as: Builder
  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.LinuxDependencyBaselineFilesystem, as: Filesystem

  @moduletag :fast

  @metadata %{
    platform: "linux/arm64",
    image_index_digest: "sha256:" <> String.duplicate("a", 64),
    image_manifest_digest: "sha256:" <> String.duplicate("b", 64),
    mix_lock_digest: String.duplicate("c", 64),
    toolchain: %{erlang: "28.4.1", elixir: "1.19.5-otp-28"}
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "linux-baseline-builder-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "produces deterministic canonical documents and receipts", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib/native"))
    File.write!(Path.join(root, "README"), "hello")
    File.write!(Path.join(root, "lib/native/module"), "module")

    assert {:ok, document_a, receipt_a} = Builder.build(root, @metadata)
    assert {:ok, document_b, receipt_b} = Builder.build(root, @metadata)

    assert document_a == document_b
    assert receipt_a == receipt_b
    assert document_a.manifest.entry_count == length(document_a.entries)
    assert {:ok, state} = Core.new(document_a)
    assert receipt_a == Core.show(state)
  end

  test "records nested directories, regular files, and executable mode", %{root: root} do
    nested = Path.join(root, "bin/tools")
    executable = Path.join(nested, "runner")
    File.mkdir_p!(nested)
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(executable, 0o755)

    assert {:ok, document, _receipt} = Shell.build_linux_dependency_baseline(root, @metadata)
    entries = Map.new(document.entries, &{&1.path, &1})

    assert entries["bin"].type == "directory"
    assert entries["bin/tools"].type == "directory"
    assert entries["bin/tools/runner"].type == "regular"
    assert entries["bin/tools/runner"].executable
    assert entries["bin/tools/runner"].size == 10
  end

  test "rejects symlinks without following them", %{root: root} do
    target = Path.join(root, "target")
    link = Path.join(root, "link")
    File.write!(target, "target")

    case File.ln_s(target, link) do
      :ok ->
        assert {:error, :symlink_rejected} = Builder.build(root, @metadata)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "rejects a symlink used as the source root", %{root: root} do
    root_link = root <> "-link"

    case File.ln_s(root, root_link) do
      :ok ->
        on_exit(fn -> File.rm(root_link) end)
        assert {:error, :symlink_rejected} = Builder.build(root_link, @metadata)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "binds a source root through a symlinked ancestor", %{root: root} do
    outside = Path.join(root, "outside")
    linked_parent = Path.join(root, "linked-parent")
    source = Path.join(linked_parent, "source")
    File.mkdir_p!(Path.join(outside, "source"))
    File.write!(Path.join([outside, "source", "marker"]), "bound\n")

    case File.ln_s(outside, linked_parent) do
      :ok ->
        on_exit(fn -> File.rm(linked_parent) end)
        assert {:ok, resolved} = Filesystem.resolve_source_root(source)
        assert {:ok, expected} = Filesystem.resolve_source_root(Path.join(outside, "source"))
        assert resolved == expected
        assert {:ok, _document, _receipt} = Builder.build(source, @metadata)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "uses the complete major and minor device identity" do
    left = %File.Stat{major_device: 7, minor_device: 1}
    same = %File.Stat{major_device: 7, minor_device: 1}
    different_minor = %File.Stat{major_device: 7, minor_device: 2}
    different_major = %File.Stat{major_device: 8, minor_device: 1}

    assert Filesystem.same_device?(left, same)
    refute Filesystem.same_device?(left, different_minor)
    refute Filesystem.same_device?(left, different_major)
  end

  test "rejects a pathname replacement before descriptor open", %{root: root} do
    assert {:ok, resolved_root} = Filesystem.resolve_source_root(root)
    victim = Path.join(resolved_root, "victim")
    outside = Path.join(resolved_root, "outside")
    File.write!(victim, "trusted")
    File.write!(outside, "untrusted")

    original = victim <> ".original"

    on_exit(fn ->
      Filesystem.__test_set_before_open_hook__(nil)
      _ = File.rm(victim)
      _ = File.rename(original, victim)
    end)

    assert :ok =
             Filesystem.__test_set_before_open_hook__(fn path ->
               if path == victim do
                 File.rename!(victim, original)
                 File.ln_s!(outside, victim)
               end
             end)

    assert {:error, :source_changed} = Builder.build(root, @metadata)
  end

  test "rejects hardlinks where the filesystem supports them", %{root: root} do
    target = Path.join(root, "target")
    hardlink = Path.join(root, "hardlink")
    File.write!(target, "target")

    case File.ln(target, hardlink) do
      :ok ->
        assert {:error, :hardlink_rejected} = Builder.build(root, @metadata)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "rejects portable special files when the platform supports them", %{root: root} do
    fifo = Path.join(root, "pipe")

    if function_exported?(:file, :make_fifo, 2) do
      case apply(:file, :make_fifo, [String.to_charlist(fifo), 0o600]) do
        :ok -> assert {:error, :unsupported_source_entry_type} = Builder.build(root, @metadata)
        {:error, reason} -> assert reason in [:eacces, :enotsup, :eperm, :einval]
      end
    end
  end

  test "fails closed for path and metadata bounds", %{root: root} do
    oversized_dir =
      Enum.reduce(1..Core.limits().max_path_depth, root, fn _index, path ->
        next = Path.join(path, "d")
        File.mkdir!(next)
        next
      end)

    File.write!(Path.join(oversized_dir, "file"), "ok")

    assert {:error, :path_depth_exceeded} =
             Builder.build(root, @metadata)

    assert {:error, {:unsupported_keys, :metadata}} =
             Builder.build(root, Map.put(@metadata, :unexpected, true))

    File.write!(Path.join(root, "ok"), "ok")
    assert {:error, :invalid_source_root} = Builder.build(Path.join(root, "ok"), @metadata)
    assert {:error, :invalid_source_root} = Builder.build("/", @metadata)
    assert {:error, :non_canonical_source_root} = Builder.build(root <> "/.", @metadata)
    assert {:error, :non_canonical_source_root} = Builder.build(root <> "/", @metadata)
  end

  test "rejects a platform other than linux/arm64 before walking", %{root: root} do
    assert {:error, :unsupported_platform} =
             Builder.build(root, Map.put(@metadata, :platform, "linux/amd64"))
  end

  test "rejects a wrong-architecture native artifact by default", %{root: root} do
    wrong_architecture =
      <<0x7F, "ELF", 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3::little-unsigned-16,
        40::little-unsigned-16>>

    File.write!(Path.join(root, "vec0.so"), wrong_architecture)

    assert {:error, :native_artifact_wrong_architecture} = Builder.build(root, @metadata)
  end

  test "accepts a bounded ELF64 little-endian AArch64 native artifact", %{root: root} do
    aarch64_header =
      <<0x7F, "ELF", 2, 1, 1, 0::size(72), 3::little-unsigned-16, 183::little-unsigned-16>>

    File.write!(Path.join(root, "vec0.so"), aarch64_header)

    assert {:ok, document, _receipt} = Builder.build(root, @metadata)
    assert Enum.any?(document.entries, &(&1.path == "vec0.so"))
  end

  test "rejects the removed native-artifact bypass and unknown options", %{root: root} do
    File.write!(Path.join(root, "compat.so"), "not an ELF")

    assert {:error, :invalid_options} =
             Builder.build(root, @metadata, native_artifact_policy: :allow_any)

    assert {:error, :invalid_options} = Builder.build(root, @metadata, [:malformed])
  end

  test "treats versioned shared objects as native artifacts", %{root: root} do
    File.write!(Path.join(root, "libfoo.so.1"), "not an ELF")

    assert {:error, :native_artifact_wrong_architecture} = Builder.build(root, @metadata)
  end
end
