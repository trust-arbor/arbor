defmodule Arbor.Shell.RegularTreeInventoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.SafePath
  alias Arbor.Shell
  alias Arbor.Shell.LinuxDependencyBaselineBuilder, as: Builder
  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.LinuxDependencyBaselineFilesystem, as: Filesystem
  alias Arbor.Shell.RegularTreeInventory

  @moduletag :fast
  @exclusive_mkdir_retries 16
  @max_entries 50_000
  @max_total_bytes 512 * 1024 * 1024

  @empty_sha256 :sha256 |> :crypto.hash("") |> Base.encode16(case: :lower)

  @metadata %{
    platform: "linux/arm64",
    image_index_digest: "sha256:" <> String.duplicate("a", 64),
    image_manifest_digest: "sha256:" <> String.duplicate("b", 64),
    mix_lock_digest: String.duplicate("c", 64),
    toolchain: %{erlang: "28.4.1", elixir: "1.19.5-otp-28"}
  }

  setup do
    root = exclusive_scratch_root!("regular-tree-inventory")

    on_exit(fn ->
      RegularTreeInventory.__test_set_listing_hook__(nil)
      Filesystem.__test_set_before_open_hook__(nil)
    end)

    {:ok, root: root}
  end

  test "produces deterministic independently sorted output", %{root: root} do
    File.write!(Path.join(root, "z-last"), "z")
    File.write!(Path.join(root, "a-first"), "a")
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/mid"), "m")
    File.write!(Path.join(root, "Z-upper"), "Z")

    assert {:ok, first} = RegularTreeInventory.inventory(root)
    assert {:ok, second} = RegularTreeInventory.inventory(root)
    assert first == second

    assert Enum.map(first["directories"], & &1["path"]) == ["nested"]

    assert Enum.map(first["regular_files"], & &1["path"]) == [
             "Z-upper",
             "a-first",
             "nested/mid",
             "z-last"
           ]

    assert first["regular_files"] ==
             Enum.sort_by(first["regular_files"], & &1["path"], &<=/2)
  end

  test "records exact regular bytes, mode, hash, and prefix", %{root: root} do
    payload = :binary.copy(<<0xAB>>, 300)
    File.write!(Path.join(root, "big"), payload)
    File.chmod!(Path.join(root, "big"), 0o640)
    File.write!(Path.join(root, "empty"), "")
    File.write!(Path.join(root, "exec"), "ok")
    File.chmod!(Path.join(root, "exec"), 0o755)

    assert {:ok, inventory} = RegularTreeInventory.inventory(root)
    files = Map.new(inventory["regular_files"], &{&1["path"], &1})

    assert files["big"]["size"] == 300
    assert files["big"]["mode"] == 0o640
    refute files["big"]["executable"]
    assert files["big"]["sha256"] == sha256(payload)
    assert files["big"]["prefix_hex"] == Base.encode16(binary_part(payload, 0, 256), case: :lower)
    assert byte_size(files["big"]["prefix_hex"]) == 512

    assert files["empty"]["size"] == 0
    assert files["empty"]["sha256"] == @empty_sha256
    assert files["empty"]["prefix_hex"] == ""

    assert files["exec"]["mode"] == 0o755
    assert files["exec"]["executable"]
    assert files["exec"]["size"] == 2
    assert files["exec"]["sha256"] == sha256("ok")
    assert files["exec"]["prefix_hex"] == Base.encode16("ok", case: :lower)
  end

  test "rejects a pathname replacement before descriptor open", %{root: root} do
    victim = Path.join(root, "victim")
    outside = Path.join(root, "outside")
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

    assert {:error, :source_changed} = RegularTreeInventory.inventory(root)
  end

  test "rejects an unstable root identity as source_changed", %{root: root} do
    File.write!(Path.join(root, "keep"), "keep")
    original = root <> ".original"

    on_exit(fn ->
      RegularTreeInventory.__test_set_listing_hook__(nil)
      _ = File.rm_rf(root)
      _ = File.rename(original, root)
    end)

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn path ->
               if path == root do
                 File.rename!(root, original)
                 File.mkdir!(root)
               end

               :cont
             end)

    assert {:error, :source_changed} = RegularTreeInventory.inventory(root)
  end

  test "rejects an unstable nested directory identity as source_changed", %{root: root} do
    nested = Path.join(root, "nested")
    File.mkdir!(nested)
    File.write!(Path.join(nested, "keep"), "keep")
    original = nested <> ".original"

    on_exit(fn ->
      RegularTreeInventory.__test_set_listing_hook__(nil)
      _ = File.rm_rf(nested)
      _ = File.rename(original, nested)
    end)

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn path ->
               if path == nested do
                 File.rename!(nested, original)
                 File.mkdir!(nested)
               end

               :cont
             end)

    assert {:error, :source_changed} = RegularTreeInventory.inventory(root)
  end

  test "rejects a symlink used as the source root", %{root: root} do
    link = root <> "-link"

    case File.ln_s(root, link) do
      :ok ->
        on_exit(fn -> File.rm(link) end)
        assert {:error, :symlink_rejected} = RegularTreeInventory.inventory(link)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "rejects a nested symlink without following it", %{root: root} do
    target = Path.join(root, "target")
    File.write!(target, "target")

    case File.ln_s(target, Path.join(root, "link")) do
      :ok ->
        assert {:error, :symlink_rejected} = RegularTreeInventory.inventory(root)
        assert File.read!(target) == "target"

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "rejects a caller-visible symlink ancestor that Linux still binds", %{root: root} do
    outside = Path.join(root, "outside")
    linked_parent = Path.join(root, "linked-parent")
    source = Path.join(linked_parent, "source")
    File.mkdir_p!(Path.join(outside, "source"))
    File.write!(Path.join([outside, "source", "marker"]), "bound\n")

    case File.ln_s(outside, linked_parent) do
      :ok ->
        on_exit(fn -> File.rm(linked_parent) end)
        assert {:error, :symlink_rejected} = Shell.inventory_regular_tree(source)
        assert {:ok, _document, _receipt} = Builder.build(source, @metadata)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "rejects hardlinks where the filesystem supports them", %{root: root} do
    File.write!(Path.join(root, "target"), "target")

    case File.ln(Path.join(root, "target"), Path.join(root, "hardlink")) do
      :ok ->
        assert {:error, :hardlink_rejected} = RegularTreeInventory.inventory(root)

      {:error, reason} ->
        assert reason in [:eacces, :enotsup, :eperm, :einval]
    end
  end

  test "rejects portable special files when the platform supports them", %{root: root} do
    fifo = Path.join(root, "pipe")

    if function_exported?(:file, :make_fifo, 2) do
      case apply(:file, :make_fifo, [String.to_charlist(fifo), 0o600]) do
        :ok ->
          assert {:error, :unsupported_source_entry_type} =
                   RegularTreeInventory.inventory(root)

        {:error, reason} ->
          assert reason in [:eacces, :enotsup, :eperm, :einval]
      end
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

  test "fails closed for path, duplicate, and metadata bounds", %{root: root} do
    oversized_dir =
      Enum.reduce(1..Core.limits().max_path_depth, root, fn _index, path ->
        next = Path.join(path, "d")
        File.mkdir!(next)
        next
      end)

    File.write!(Path.join(oversized_dir, "file"), "ok")
    assert {:error, :path_depth_exceeded} = RegularTreeInventory.inventory(root)
    File.rm_rf!(Path.join(root, "d"))

    File.write!(Path.join(root, "a"), "a")

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               {:names, ["a", "a"]}
             end)

    assert {:error, :duplicate_path} = RegularTreeInventory.inventory(root)

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               {:names, ["ok\n"]}
             end)

    assert {:error, :unsafe_path} = RegularTreeInventory.inventory(root)

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               {:names, [<<0xFF>>]}
             end)

    assert {:error, :invalid_utf8} = RegularTreeInventory.inventory(root)
    RegularTreeInventory.__test_set_listing_hook__(nil)

    assert {:error, :invalid_source_root} = RegularTreeInventory.inventory(root <> <<0>>)
  end

  @tag :slow
  @tag fast: false
  test "deadline kills the listing worker and returns scan_timeout", %{root: root} do
    File.write!(Path.join(root, "ok"), "ok")
    test_pid = self()

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               send(test_pid, {:listing_worker, self()})
               Process.sleep(80)
               :cont
             end)

    assert {:error, :scan_timeout} =
             RegularTreeInventory.__test_inventory__(root, %{
               timeout_ms: 20,
               listing_heap_words: 4_000_000
             })

    assert_reaped_listing_worker()
    refute_listing_mailbox_residue()
  end

  @tag :slow
  @tag fast: false
  test "a last-file hash that crosses the deadline returns scan_timeout", %{root: root} do
    File.write!(Path.join(root, "last"), "payload")

    assert :ok =
             Filesystem.__test_set_before_open_hook__(fn _path ->
               Process.sleep(400)
             end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :scan_timeout} =
             RegularTreeInventory.__test_inventory__(root, %{
               timeout_ms: 20,
               listing_heap_words: 4_000_000
             })

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 250
  end

  test "listing workers exit after a successful scan", %{root: root} do
    File.mkdir!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/ok"), "ok")
    test_pid = self()

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               send(test_pid, {:listing_worker, self()})
               :cont
             end)

    assert {:ok, _inventory} = RegularTreeInventory.inventory(root)
    workers = receive_listing_workers([])
    assert workers != []
    Enum.each(workers, fn worker -> refute Process.alive?(worker) end)
  end

  @tag :slow
  @tag fast: false
  test "listing heap ceiling fails closed and cleans up the worker", %{root: root} do
    for index <- 1..500 do
      name =
        "#{String.pad_leading(Integer.to_string(index), 4, "0")}-#{String.duplicate("x", 120)}"

      File.write!(Path.join(root, name), "n")
    end

    test_pid = self()

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               send(test_pid, {:listing_worker, self()})
               :cont
             end)

    assert {:error, :listing_memory_exceeded} =
             RegularTreeInventory.__test_inventory__(root, %{
               timeout_ms: 5_000,
               listing_heap_words: 512
             })

    assert_reaped_listing_worker()
  end

  @tag :slow
  @tag fast: false
  test "rejects a synthetic listing of 50_001 names", %{root: root} do
    File.write!(Path.join(root, "1"), "ok")

    names = Enum.map(1..(@max_entries + 1), &Integer.to_string/1)

    assert :ok =
             RegularTreeInventory.__test_set_listing_hook__(fn _path ->
               {:names, names}
             end)

    assert {:error, :too_many_entries} = RegularTreeInventory.inventory(root)
  end

  @tag :slow
  @tag fast: false
  test "rejects a sparse regular file above 512 MiB", %{root: root} do
    huge = Path.join(root, "huge")
    {:ok, io} = :file.open(String.to_charlist(huge), [:write, :raw, :binary])

    try do
      assert {:ok, @max_total_bytes} = :file.position(io, @max_total_bytes)
      assert :ok = :file.write(io, <<1>>)
    after
      _ = :file.close(io)
    end

    assert {:ok, %File.Stat{size: size}} = File.lstat(huge)
    assert size > @max_total_bytes
    assert {:error, :total_bytes_exceeded} = RegularTreeInventory.inventory(root)
  end

  test "Linux builder document and receipt stay equal on the canonical fixture", %{
    root: root
  } do
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

    entries = Map.new(document_a.entries, &{&1.path, &1})
    assert entries["README"].type == "regular"
    assert entries["lib"].type == "directory"
    assert entries["lib/native"].type == "directory"
    assert entries["lib/native/module"].type == "regular"
    refute Map.has_key?(entries["README"], :mode)
    refute Map.has_key?(entries["README"], :prefix)
  end

  test "Linux ELF policy stays in the builder after the shared scan", %{root: root} do
    wrong_architecture =
      <<0x7F, "ELF", 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3::little-unsigned-16,
        40::little-unsigned-16>>

    File.write!(Path.join(root, "vec0.so"), wrong_architecture)
    assert {:error, :native_artifact_wrong_architecture} = Builder.build(root, @metadata)

    File.rm!(Path.join(root, "vec0.so"))

    aarch64_header =
      <<0x7F, "ELF", 2, 1, 1, 0::size(72), 3::little-unsigned-16, 183::little-unsigned-16>>

    File.write!(Path.join(root, "vec0.so"), aarch64_header)
    assert {:ok, document, _receipt} = Builder.build(root, @metadata)
    assert Enum.any?(document.entries, &(&1.path == "vec0.so"))

    File.write!(Path.join(root, "libfoo.so.1"), "not an ELF")
    assert {:error, :native_artifact_wrong_architecture} = Builder.build(root, @metadata)

    assert {:error, :invalid_options} =
             Builder.build(root, @metadata, native_artifact_policy: :allow_any)
  end

  defp sha256(content) do
    :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
  end

  defp receive_listing_workers(acc) do
    receive do
      {:listing_worker, worker} when is_pid(worker) ->
        receive_listing_workers([worker | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  defp assert_reaped_listing_worker do
    assert_receive {:listing_worker, worker}, 1_000
    assert is_pid(worker)
    refute Process.alive?(worker)
    refute_receive {:listing_worker, _other}, 20
  end

  defp refute_listing_mailbox_residue do
    {_key, messages} = Process.info(self(), :messages)

    residue =
      Enum.filter(messages, fn
        {token, _payload} when is_reference(token) -> true
        _other -> false
      end)

    assert residue == []
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
