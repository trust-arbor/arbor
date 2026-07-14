defmodule Arbor.Shell.LinuxDependencyBaselineSourceTest do
  @moduledoc """
  Focused tests for the imperative Linux dependency-baseline SOURCE verifier.

  Slice 2B2B1 only: pins/verifies an offline source tree + manifest through
  TrustedPath and LinuxDependencyBaselineCore. Does not wire GenServer
  authority, materialization/copying, admission, or the spawn backend.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.LinuxDependencyBaselineSource, as: Source
  alias Arbor.Shell.LinuxDependencyBaselineSource.Binding
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  @domain "arbor-linux-dependency-baseline-v1\0"
  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"
  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"

  # ---------------------------------------------------------------------------
  # Same-test-library FakeTrustedPath: real File/:file identity without root
  # ownership. Process-local overrides only (no global persistent state).
  # ---------------------------------------------------------------------------

  defmodule FakeTrustedPath do
    @moduledoc false

    import Bitwise

    alias Arbor.Shell.TrustedPath.Identity

    @chunk_size 65_536
    @max_file_bytes 512 * 1024 * 1024

    def pin_root_owned_directory(path) when is_binary(path) do
      case Process.get({__MODULE__, :pin_error}) do
        reason when reason != nil ->
          {:error, reason}

        nil ->
          with {:ok, path} <- require_absolute(path),
               {:ok, stat} <- File.stat(path, time: :posix),
               :ok <- require_type(stat, :directory) do
            {:ok, apply_overrides(build_identity(path, stat, nil, false))}
          end
      end
    end

    def pin_root_owned_directory(_path), do: {:error, :invalid_path}

    def pin_root_owned_regular_file(path, opts \\ [])

    def pin_root_owned_regular_file(path, opts) when is_binary(path) do
      case Process.get({__MODULE__, :pin_error}) do
        reason when reason != nil ->
          {:error, reason}

        nil ->
          executable_required = Keyword.get(opts, :executable, false)

          if not is_boolean(executable_required) do
            {:error, :malformed_options}
          else
            with {:ok, path} <- require_absolute(path),
                 {:ok, before_stat} <- File.stat(path, time: :posix),
                 :ok <- require_type(before_stat, :regular),
                 :ok <- enforce_max_file_size(before_stat.size),
                 :ok <- maybe_require_executable(before_stat, executable_required),
                 {:ok, digest} <- hash_regular_file(path, before_stat.size),
                 {:ok, after_stat} <- File.stat(path, time: :posix),
                 true <- stable?(before_stat, after_stat) do
              identity = build_identity(path, before_stat, digest, executable_required)
              {:ok, apply_overrides(identity)}
            else
              false -> {:error, :identity_changed}
              {:error, reason} -> {:error, reason}
            end
          end
      end
    end

    def pin_root_owned_regular_file(_path, _opts), do: {:error, :invalid_path}

    def verify_pinned(%Identity{type: :directory} = pinned) do
      case pin_root_owned_directory(pinned.path) do
        {:ok, current} ->
          if same_identity?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def verify_pinned(
          %Identity{type: :regular, executable_required: executable_required} = pinned
        ) do
      case pin_root_owned_regular_file(pinned.path, executable: executable_required) do
        {:ok, current} ->
          if same_identity?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def verify_pinned(_identity), do: {:error, :invalid_identity}

    def canonicalize_absolute(path) when is_binary(path) do
      if Path.type(path) == :absolute, do: {:ok, path}, else: {:error, :relative_path}
    end

    def canonicalize_absolute(_path), do: {:error, :invalid_path}

    def set_size_override(path, size) when is_binary(path) and is_integer(size) and size >= 0 do
      overrides = Process.get({__MODULE__, :size_overrides}, %{})
      Process.put({__MODULE__, :size_overrides}, Map.put(overrides, path, size))
      :ok
    end

    def clear_overrides do
      Process.delete({__MODULE__, :size_overrides})
      Process.delete({__MODULE__, :path_rewrite})
      Process.delete({__MODULE__, :pin_error})
      Process.delete({__MODULE__, :verify_mode})
      :ok
    end

    def set_path_rewrite(from, to) when is_binary(from) and is_binary(to) do
      Process.put({__MODULE__, :path_rewrite}, {from, to})
      :ok
    end

    def set_pin_error(reason) do
      Process.put({__MODULE__, :pin_error}, reason)
      :ok
    end

    def set_verify_mode(mode) do
      Process.put({__MODULE__, :verify_mode}, mode)
      :ok
    end

    defp apply_overrides(%Identity{} = identity) do
      identity =
        case Process.get({__MODULE__, :path_rewrite}) do
          {from, to} when identity.path == from ->
            %{identity | path: to}

          _ ->
            identity
        end

      overrides = Process.get({__MODULE__, :size_overrides}, %{})

      case Map.get(overrides, identity.path) do
        size when is_integer(size) ->
          %{identity | size: size}

        nil ->
          case Process.get({__MODULE__, :path_rewrite}) do
            {from, to} when identity.path == to ->
              case Map.get(overrides, from) do
                size when is_integer(size) -> %{identity | size: size}
                _ -> identity
              end

            _ ->
              identity
          end
      end
    end

    defp require_absolute(path) do
      if Path.type(path) == :absolute, do: {:ok, path}, else: {:error, :relative_path}
    end

    defp require_type(%File.Stat{type: type}, type), do: :ok
    defp require_type(%File.Stat{type: :directory}, :regular), do: {:error, :not_a_regular_file}
    defp require_type(%File.Stat{type: :regular}, :directory), do: {:error, :not_a_directory}
    defp require_type(%File.Stat{}, :regular), do: {:error, :not_a_regular_file}
    defp require_type(%File.Stat{}, :directory), do: {:error, :not_a_directory}

    defp maybe_require_executable(_stat, false), do: :ok

    defp maybe_require_executable(%File.Stat{mode: mode}, true) do
      if (mode &&& 0o111) != 0, do: :ok, else: {:error, :not_executable}
    end

    defp enforce_max_file_size(size) when is_integer(size) and size > @max_file_bytes do
      {:error, :file_too_large}
    end

    defp enforce_max_file_size(_size), do: :ok

    defp hash_regular_file(path, expected_size) do
      case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
        {:ok, io} ->
          try do
            hash_chunks(io, :crypto.hash_init(:sha256), 0, expected_size)
          after
            :file.close(io)
          end

        {:error, _} ->
          {:error, :path_not_found}
      end
    end

    defp hash_chunks(io, acc, read_so_far, expected_size) do
      case :file.read(io, @chunk_size) do
        :eof ->
          if read_so_far == expected_size do
            digest = acc |> :crypto.hash_final() |> Base.encode16(case: :lower)
            {:ok, digest}
          else
            {:error, :identity_changed}
          end

        {:ok, data} ->
          new_size = read_so_far + byte_size(data)

          cond do
            new_size > @max_file_bytes ->
              {:error, :file_too_large}

            new_size > expected_size ->
              {:error, :identity_changed}

            true ->
              hash_chunks(io, :crypto.hash_update(acc, data), new_size, expected_size)
          end

        {:error, _} ->
          {:error, :identity_changed}
      end
    end

    defp stable?(left, right) do
      {left.type, left.size, left.mode, left.uid, left.gid, left.major_device, left.inode,
       left.mtime, left.ctime} ==
        {right.type, right.size, right.mode, right.uid, right.gid, right.major_device,
         right.inode, right.mtime, right.ctime}
    end

    defp build_identity(path, %File.Stat{} = stat, sha256, executable_required) do
      %Identity{
        path: path,
        type: stat.type,
        device: stat.major_device,
        inode: stat.inode,
        size: stat.size,
        mtime: stat.mtime,
        ctime: stat.ctime,
        mode: stat.mode,
        uid: stat.uid,
        gid: stat.gid,
        sha256: sha256,
        executable_required: executable_required
      }
    end

    defp same_identity?(%Identity{} = left, %Identity{} = right) do
      case Process.get({__MODULE__, :verify_mode}, :ok) do
        :ok ->
          identity_tuple(left) == identity_tuple(right)

        :drift ->
          false

        {:error, _reason} ->
          false
      end
    end

    defp identity_tuple(%Identity{} = identity) do
      {
        identity.path,
        identity.type,
        identity.device,
        identity.inode,
        identity.size,
        identity.mtime,
        identity.ctime,
        identity.mode,
        identity.uid,
        identity.gid,
        identity.sha256,
        identity.executable_required
      }
    end
  end

  defmodule RejectingTrustedPath do
    @moduledoc false

    def pin_root_owned_directory(_path), do: {:error, :untrusted_path}
    def pin_root_owned_regular_file(_path, _opts \\ []), do: {:error, :untrusted_path}
    def verify_pinned(_identity), do: {:error, :untrusted_path}
    def canonicalize_absolute(path) when is_binary(path), do: {:ok, path}
    def canonicalize_absolute(_), do: {:error, :invalid_path}
  end

  defmodule PathRewritingTrustedPath do
    @moduledoc false

    def pin_root_owned_directory(path) do
      case FakeTrustedPath.pin_root_owned_directory(path) do
        {:ok, identity} -> {:ok, %{identity | path: path <> "-rewritten"}}
        other -> other
      end
    end

    def pin_root_owned_regular_file(path, opts \\ []) do
      case FakeTrustedPath.pin_root_owned_regular_file(path, opts) do
        {:ok, identity} -> {:ok, %{identity | path: path <> "-rewritten"}}
        other -> other
      end
    end

    def verify_pinned(identity), do: FakeTrustedPath.verify_pinned(identity)
    def canonicalize_absolute(path), do: FakeTrustedPath.canonicalize_absolute(path)
  end

  defmodule InflatingSizeTrustedPath do
    @moduledoc false

    def pin_root_owned_directory(path), do: FakeTrustedPath.pin_root_owned_directory(path)

    def pin_root_owned_regular_file(path, opts \\ []) do
      case FakeTrustedPath.pin_root_owned_regular_file(path, opts) do
        {:ok, identity} ->
          # Inflate only source inventory files (not the manifest) so two small
          # inventory files exceed max_total_bytes during the walk.
          if Path.basename(path) in ["a", "b"] do
            half = div(Core.limits().max_total_bytes, 2) + 1
            {:ok, %{identity | size: half}}
          else
            {:ok, identity}
          end

        other ->
          other
      end
    end

    def verify_pinned(identity), do: FakeTrustedPath.verify_pinned(identity)
    def canonicalize_absolute(path), do: FakeTrustedPath.canonicalize_absolute(path)
  end

  # Records TrustedPath regular-file pin invocations so security regressions can
  # prove preflight rejects without hashing through pin_root_owned_regular_file.
  defmodule PinCountingTrustedPath do
    @moduledoc false

    def pin_root_owned_directory(path) do
      Process.put(
        {__MODULE__, :dir_pins},
        [path | Process.get({__MODULE__, :dir_pins}, [])]
      )

      FakeTrustedPath.pin_root_owned_directory(path)
    end

    def pin_root_owned_regular_file(path, opts \\ []) do
      Process.put(
        {__MODULE__, :file_pins},
        [path | Process.get({__MODULE__, :file_pins}, [])]
      )

      FakeTrustedPath.pin_root_owned_regular_file(path, opts)
    end

    def verify_pinned(identity), do: FakeTrustedPath.verify_pinned(identity)
    def canonicalize_absolute(path), do: FakeTrustedPath.canonicalize_absolute(path)

    def clear do
      Process.delete({__MODULE__, :dir_pins})
      Process.delete({__MODULE__, :file_pins})
      :ok
    end

    def file_pins, do: Process.get({__MODULE__, :file_pins}, []) |> Enum.reverse()
  end

  # Substitutes device/inode after a successful pin so post-pin identity
  # consistency is exercised without filesystem races.
  defmodule DeviceSubstitutingTrustedPath do
    @moduledoc false

    def pin_root_owned_directory(path) do
      case FakeTrustedPath.pin_root_owned_directory(path) do
        {:ok, identity} ->
          # Keep the source root stable so walk root_device is real; corrupt
          # only discovered child directories under the source tree.
          if String.contains?(path, "/source/") do
            {:ok, %{identity | device: identity.device + 9_001, inode: identity.inode + 9_001}}
          else
            {:ok, identity}
          end

        other ->
          other
      end
    end

    def pin_root_owned_regular_file(path, opts \\ []) do
      FakeTrustedPath.pin_root_owned_regular_file(path, opts)
    end

    def verify_pinned(identity), do: FakeTrustedPath.verify_pinned(identity)
    def canonicalize_absolute(path), do: FakeTrustedPath.canonicalize_absolute(path)
  end

  defmodule RegularIdentitySubstitutingTrustedPath do
    @moduledoc false

    def pin_root_owned_directory(path), do: FakeTrustedPath.pin_root_owned_directory(path)

    def pin_root_owned_regular_file(path, opts \\ []) do
      case FakeTrustedPath.pin_root_owned_regular_file(path, opts) do
        {:ok, identity} ->
          # Corrupt source inventory regular files only (not the manifest).
          if String.contains?(path, "/source/") do
            {:ok, %{identity | device: identity.device + 7_001, inode: identity.inode + 7_001}}
          else
            {:ok, identity}
          end

        other ->
          other
      end
    end

    def verify_pinned(identity), do: FakeTrustedPath.verify_pinned(identity)
    def canonicalize_absolute(path), do: FakeTrustedPath.canonicalize_absolute(path)
  end

  setup do
    FakeTrustedPath.clear_overrides()
    PinCountingTrustedPath.clear()

    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-linux-dep-src-#{System.unique_integer([:positive])}"
      )
      |> then(&Path.expand/1)

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn ->
      FakeTrustedPath.clear_overrides()
      PinCountingTrustedPath.clear()
      File.rm_rf(root)
    end)

    %{root: root}
  end

  # --- Helpers ---

  defp frame_entry(%{type: "directory", path: path}) do
    <<0, byte_size(path)::unsigned-32, path::binary>>
  end

  defp frame_entry(%{
         type: "regular",
         path: path,
         size: size,
         sha256: sha256_hex,
         executable: executable
       }) do
    flag = if executable, do: 1, else: 0
    raw = Base.decode16!(sha256_hex, case: :lower)

    <<1, byte_size(path)::unsigned-32, path::binary, flag::unsigned-8, size::unsigned-64,
      raw::binary-size(32)>>
  end

  defp tree_digest(entries) do
    sorted = Enum.sort_by(entries, & &1.path)

    binary =
      Enum.reduce(sorted, @domain, fn entry, acc ->
        acc <> frame_entry(entry)
      end)

    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp total_bytes(entries) do
    entries
    |> Enum.filter(&(&1.type == "regular"))
    |> Enum.reduce(0, fn e, acc -> acc + e.size end)
  end

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_file!(path, content, mode) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, mode)
    path
  end

  defp build_document(entries) do
    digest = tree_digest(entries)

    %{
      "manifest" => %{
        "schema" => "1",
        "platform" => "linux/arm64",
        "image_index_digest" => @index_digest,
        "image_manifest_digest" => @manifest_digest,
        "mix_lock_digest" => @mix_lock_hex,
        "baseline_tree_digest" => digest,
        "toolchain" => %{
          "erlang" => @erlang_version,
          "elixir" => @elixir_version
        },
        "entry_count" => length(entries),
        "total_bytes" => total_bytes(entries)
      },
      "entries" =>
        Enum.map(entries, fn
          %{path: path, type: "directory"} ->
            %{"path" => path, "type" => "directory"}

          %{path: path, type: "regular", size: size, sha256: sha, executable: exec} ->
            %{
              "path" => path,
              "type" => "regular",
              "size" => size,
              "sha256" => sha,
              "executable" => exec
            }
        end)
    }
  end

  defp write_manifest!(path, document) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(document))
    File.chmod!(path, 0o644)
    path
  end

  # Sparse-ish oversized regular file: extend via position+truncate so the test
  # does not allocate/hash 32 MiB of content. File.lstat reports the logical size.
  defp write_sparse_oversized!(path, size) when is_integer(size) and size > 0 do
    File.mkdir_p!(Path.dirname(path))
    charlist = String.to_charlist(path)

    {:ok, io} = :file.open(charlist, [:write, :raw, :binary])

    try do
      {:ok, _} = :file.position(io, size)
      :ok = :file.truncate(io)
    after
      :file.close(io)
    end

    File.chmod!(path, 0o644)

    {:ok, %File.Stat{size: reported, type: :regular}} = File.lstat(path, time: :posix)
    assert reported == size

    path
  end

  defp sample_identity(path, type) do
    %Identity{
      path: path,
      type: type,
      device: 1,
      inode: 2,
      size: if(type == :regular, do: 1, else: 0),
      mtime: 1,
      ctime: 1,
      mode: 0o100644,
      uid: 0,
      gid: 0,
      sha256: if(type == :regular, do: String.duplicate("a", 64), else: nil),
      executable_required: false
    }
  end

  defp fixture_tree!(root) do
    source = Path.join(root, "source")
    File.mkdir_p!(source)

    write_file!(Path.join(source, "hex/mix.exs"), "defmodule Hex do\nend\n", 0o644)
    write_file!(Path.join(source, "hex_core/priv/native.so"), <<1, 2, 3, 4, 5>>, 0o755)

    mix_sha = sha256_file(Path.join(source, "hex/mix.exs"))
    so_sha = sha256_file(Path.join(source, "hex_core/priv/native.so"))
    mix_size = byte_size(File.read!(Path.join(source, "hex/mix.exs")))
    so_size = byte_size(File.read!(Path.join(source, "hex_core/priv/native.so")))

    entries = [
      %{path: "hex", type: "directory"},
      %{path: "hex/mix.exs", type: "regular", size: mix_size, sha256: mix_sha, executable: false},
      %{path: "hex_core", type: "directory"},
      %{path: "hex_core/priv", type: "directory"},
      %{
        path: "hex_core/priv/native.so",
        type: "regular",
        size: so_size,
        sha256: so_sha,
        executable: true
      }
    ]

    manifest_path = Path.join(root, "baseline.manifest.json")
    write_manifest!(manifest_path, build_document(entries))

    %{source: source, manifest: manifest_path, entries: entries}
  end

  defp exported_functions do
    Source.__info__(:functions)
  end

  # --- Positive path ---

  describe "positive pin/verify/plan" do
    test "pins nested source matching declared inventory and derives executable bit", %{
      root: root
    } do
      %{source: source, manifest: manifest, entries: expected} = fixture_tree!(root)

      assert {:ok, %Binding{} = binding} = Source.pin(source, manifest, FakeTrustedPath)

      assert binding.source_identity.path == source
      assert binding.manifest_identity.path == manifest
      assert binding.source_identity.type == :directory
      assert binding.manifest_identity.type == :regular

      assert Map.keys(binding.entry_identities) |> Enum.sort() ==
               Enum.map(expected, & &1.path) |> Enum.sort()

      assert binding.entry_identities["hex"].type == :directory
      assert binding.entry_identities["hex/mix.exs"].type == :regular
      assert binding.entry_identities["hex_core/priv/native.so"].type == :regular

      assert (binding.entry_identities["hex_core/priv/native.so"].mode &&& 0o111) != 0
      assert (binding.entry_identities["hex/mix.exs"].mode &&& 0o111) == 0

      materialized = Core.materialization_entries(binding.state)

      assert Enum.map(materialized, & &1.path) ==
               Enum.map(Enum.sort_by(expected, & &1.path), & &1.path)

      native = Enum.find(materialized, &(&1.path == "hex_core/priv/native.so"))
      mix = Enum.find(materialized, &(&1.path == "hex/mix.exs"))
      assert native.executable == true
      assert mix.executable == false

      # Receipt is compact attestation — inventory omitted.
      assert binding.receipt == Core.show(binding.state)
      refute Map.has_key?(binding.receipt, "entries")
      refute Map.has_key?(binding.receipt, :entries)
      assert is_binary(binding.receipt["baseline_tree_digest"])
      assert Jason.encode!(binding.receipt)

      plan = Source.plan(binding)
      assert plan["kind"] == "linux_dependency_baseline_source"
      assert plan["evidence_only"] == true
      assert plan["source_root"] == source
      assert plan["manifest_path"] == manifest
      assert plan["receipt"] == binding.receipt
      assert is_list(plan["materialization_entries"])
      assert length(plan["materialization_entries"]) == 5
      refute plan["status"] == "ready"
      refute Map.has_key?(plan, "destination")
      refute Map.has_key?(plan, "copy")

      assert :ok = Source.verify(binding, FakeTrustedPath)
    end

    test "exported API is pin/verify/plan only — no copy or destination write", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)
      assert {:ok, binding} = Source.pin(source, manifest, FakeTrustedPath)

      functions = exported_functions()
      assert {:pin, 2} in functions or {:pin, 3} in functions
      assert {:verify, 1} in functions or {:verify, 2} in functions
      assert {:plan, 1} in functions

      refute Enum.any?(functions, fn {name, _arity} ->
               name in [
                 :copy,
                 :materialize,
                 :mkdir,
                 :chmod,
                 :write,
                 :provision,
                 :execute_spawn_capable
               ]
             end)

      # plan does not mutate the filesystem
      before = File.ls!(root)
      _ = Source.plan(binding)
      assert File.ls!(root) == before
    end
  end

  # --- Locator / TrustedPath rejection ---

  describe "locator and TrustedPath rejection" do
    test "rejects relative and non-canonical locators", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:error, :relative_path} =
               Source.pin("relative/source", manifest, FakeTrustedPath)

      assert {:error, :relative_path} =
               Source.pin(source, "relative/manifest.json", FakeTrustedPath)

      assert {:error, :dot_segment} =
               Source.pin(source <> "/.", manifest, FakeTrustedPath)

      assert {:error, :trailing_slash} =
               Source.pin(source <> "/", manifest, FakeTrustedPath)
    end

    test "rejects manifest path inside the source tree", %{root: root} do
      %{source: source} = fixture_tree!(root)
      inside = Path.join(source, "baseline.manifest.json")
      File.cp!(Path.join(root, "baseline.manifest.json"), inside)

      assert {:error, :locator_overlap} =
               Source.pin(source, inside, FakeTrustedPath)
    end

    test "rejects equal source and manifest paths", %{root: root} do
      source = Path.join(root, "same")
      File.mkdir_p!(source)

      assert {:error, :locator_overlap} =
               Source.pin(source, source, FakeTrustedPath)
    end

    test "accepts sibling path prefixes that are not segment-overlapping", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "hi", 0o644)

      entries = [
        %{path: "pkg", type: "directory"},
        %{
          path: "pkg/a",
          type: "regular",
          size: 2,
          sha256: sha256_file(Path.join(source, "pkg/a")),
          executable: false
        }
      ]

      # Sibling directory named source-manifest (not under source/)
      manifest = Path.join(root, "source-manifest/baseline.json")
      write_manifest!(manifest, build_document(entries))

      assert {:ok, %Binding{}} = Source.pin(source, manifest, FakeTrustedPath)
    end

    test "propagates TrustedPath root/manifest rejection", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:error, :untrusted_path} =
               Source.pin(source, manifest, RejectingTrustedPath)
    end

    test "rejects exact-path substitution from TrustedPath", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:error, :identity_path_mismatch} =
               Source.pin(source, manifest, PathRewritingTrustedPath)
    end
  end

  # --- Manifest document failures ---

  describe "manifest document failures" do
    test "rejects malformed JSON", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "x", 0o644)

      manifest = Path.join(root, "bad.json")
      File.write!(manifest, "{not-json")

      assert {:error, :invalid_manifest_json} =
               Source.pin(source, manifest, FakeTrustedPath)
    end

    test "rejects post-pin inflated manifest size that diverges from preflight lstat", %{
      root: root
    } do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      # Real file is small; FakeTrustedPath size override diverges from the
      # preflight lstat observation and must fail closed as identity_mismatch.
      # The true oversized-before-pin gate is covered by the security regression
      # sparse-file test (no 32 MiB allocate/hash).
      FakeTrustedPath.set_size_override(manifest, 32 * 1024 * 1024 + 1)

      assert {:error, :identity_mismatch} =
               Source.pin(source, manifest, FakeTrustedPath)
    end

    test "rejects declared document that fails Core validation", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "x", 0o644)

      manifest = Path.join(root, "invalid.json")

      write_manifest!(manifest, %{
        "manifest" => %{"schema" => "1"},
        "entries" => []
      })

      assert {:error, reason} = Source.pin(source, manifest, FakeTrustedPath)

      assert reason in [
               :missing_platform,
               :missing_image_index_digest,
               :empty_inventory,
               :missing_entries
             ] or
               is_atom(reason) or is_tuple(reason)
    end
  end

  # --- Declared vs actual mismatches ---

  describe "declared versus actual inventory" do
    test "rejects path mismatch when extra file is present", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)
      write_file!(Path.join(source, "hex/extra.ex"), "oops", 0o644)

      assert {:error, reason} = Source.pin(source, manifest, FakeTrustedPath)

      assert reason in [
               :entry_count_mismatch,
               :baseline_tree_digest_mismatch,
               :total_bytes_mismatch,
               :inventory_mismatch
             ]
    end

    test "rejects missing entry", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)
      File.rm!(Path.join(source, "hex/mix.exs"))

      assert {:error, reason} = Source.pin(source, manifest, FakeTrustedPath)

      assert reason in [
               :entry_count_mismatch,
               :baseline_tree_digest_mismatch,
               :total_bytes_mismatch,
               :inventory_mismatch,
               :missing_parent_directory
             ]
    end

    test "rejects content digest mismatch", %{root: root} do
      %{source: source, manifest: manifest, entries: entries} = fixture_tree!(root)

      # Rewrite file content after writing matching manifest.
      write_file!(Path.join(source, "hex/mix.exs"), "changed content!!!", 0o644)

      # Rebuild document is not rewritten — declared still has old digest.
      _ = entries

      assert {:error, reason} = Source.pin(source, manifest, FakeTrustedPath)

      assert reason in [
               :baseline_tree_digest_mismatch,
               :inventory_mismatch,
               :entry_count_mismatch,
               :total_bytes_mismatch
             ]
    end

    test "rejects executable bit mismatch", %{root: root} do
      %{source: source, entries: entries} = fixture_tree!(root)

      # Declared says native.so is non-executable while mode is 0755.
      flipped =
        Enum.map(entries, fn
          %{path: "hex_core/priv/native.so"} = e -> %{e | executable: false}
          e -> e
        end)

      manifest = Path.join(root, "flipped.json")
      write_manifest!(manifest, build_document(flipped))

      assert {:error, reason} = Source.pin(source, manifest, FakeTrustedPath)

      assert reason in [:baseline_tree_digest_mismatch, :inventory_mismatch]
    end

    test "rejects size mismatch via declared size", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "ab", 0o644)

      entries = [
        %{path: "pkg", type: "directory"},
        %{
          path: "pkg/a",
          type: "regular",
          size: 99,
          sha256: sha256_file(Path.join(source, "pkg/a")),
          executable: false
        }
      ]

      manifest = Path.join(root, "size-mismatch.json")
      # build_document recomputes total_bytes from declared sizes
      write_manifest!(manifest, build_document(entries))

      assert {:error, reason} = Source.pin(source, manifest, FakeTrustedPath)

      assert reason in [
               :total_bytes_mismatch,
               :baseline_tree_digest_mismatch,
               :inventory_mismatch,
               :entry_count_mismatch
             ]
    end
  end

  # --- Filesystem anomalies ---

  describe "filesystem anomalies" do
    test "rejects symlink entries", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "x", 0o644)
      File.ln_s!("a", Path.join(source, "pkg/link"))

      entries = [
        %{path: "pkg", type: "directory"},
        %{
          path: "pkg/a",
          type: "regular",
          size: 1,
          sha256: sha256_file(Path.join(source, "pkg/a")),
          executable: false
        }
      ]

      manifest = Path.join(root, "symlink.json")
      write_manifest!(manifest, build_document(entries))

      assert {:error, :symlink_rejected} =
               Source.pin(source, manifest, FakeTrustedPath)
    end

    test "rejects hardlinked regular files", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(Path.join(source, "pkg"))
      target = Path.join(source, "pkg/a")
      write_file!(target, "shared", 0o644)
      link = Path.join(source, "pkg/b")

      case File.ln(target, link) do
        :ok ->
          a_sha = sha256_file(target)

          entries = [
            %{path: "pkg", type: "directory"},
            %{path: "pkg/a", type: "regular", size: 6, sha256: a_sha, executable: false},
            %{path: "pkg/b", type: "regular", size: 6, sha256: a_sha, executable: false}
          ]

          manifest = Path.join(root, "hardlink.json")
          write_manifest!(manifest, build_document(entries))

          assert {:error, :hardlink_rejected} =
                   Source.pin(source, manifest, FakeTrustedPath)

        {:error, reason} ->
          # Hardlinks may be unavailable on some filesystems; skip portably.
          flunk("hardlink fixture unavailable: #{inspect(reason)}")
      end
    end

    test "rejects FIFO special files when portable", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(Path.join(source, "pkg"))
      write_file!(Path.join(source, "pkg/a"), "x", 0o644)
      fifo = Path.join(source, "pkg/fifo")

      # OTP has no :file.make_fifo/1; mkfifo(1) is fine for a test-only fixture.
      case System.cmd("mkfifo", [fifo], stderr_to_stdout: true) do
        {_out, 0} ->
          entries = [
            %{path: "pkg", type: "directory"},
            %{
              path: "pkg/a",
              type: "regular",
              size: 1,
              sha256: sha256_file(Path.join(source, "pkg/a")),
              executable: false
            }
          ]

          manifest = Path.join(root, "fifo.json")
          write_manifest!(manifest, build_document(entries))

          assert {:error, :unsupported_source_entry_type} =
                   Source.pin(source, manifest, FakeTrustedPath)

        {out, status} ->
          flunk("fifo fixture unavailable: status=#{status} out=#{inspect(out)}")
      end
    end
  end

  # --- Bounds ---

  describe "inventory bounds during walk" do
    test "rejects cumulative sizes over max_total_bytes before hashing the oversized file", %{
      root: root
    } do
      source = Path.join(root, "source")
      File.mkdir_p!(Path.join(source, "pkg"))
      write_file!(Path.join(source, "pkg/a"), "aa", 0o644)

      # Actual logical size exceeds remaining budget; declared inventory stays
      # Core-valid and small so Core.new succeeds and the walk preflight fires.
      oversized_size = Core.limits().max_total_bytes
      write_sparse_oversized!(Path.join(source, "pkg/b"), oversized_size)

      a_sha = sha256_file(Path.join(source, "pkg/a"))
      # Placeholder declared digest for b — walk must fail before content compare.
      b_sha = String.duplicate("d", 64)

      entries = [
        %{path: "pkg", type: "directory"},
        %{path: "pkg/a", type: "regular", size: 2, sha256: a_sha, executable: false},
        %{path: "pkg/b", type: "regular", size: 2, sha256: b_sha, executable: false}
      ]

      manifest = Path.join(root, "bytes.json")
      write_manifest!(manifest, build_document(entries))

      PinCountingTrustedPath.clear()

      assert {:error, :total_bytes_exceeded} =
               Source.pin(source, manifest, PinCountingTrustedPath)

      refute Path.join(source, "pkg/b") in PinCountingTrustedPath.file_pins()
    end

    test "rejects pin size inflation that diverges from preflight lstat", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "aa", 0o644)
      write_file!(Path.join(source, "pkg/b"), "bb", 0o644)

      a_sha = sha256_file(Path.join(source, "pkg/a"))
      b_sha = sha256_file(Path.join(source, "pkg/b"))

      entries = [
        %{path: "pkg", type: "directory"},
        %{path: "pkg/a", type: "regular", size: 2, sha256: a_sha, executable: false},
        %{path: "pkg/b", type: "regular", size: 2, sha256: b_sha, executable: false}
      ]

      manifest = Path.join(root, "inflated.json")
      write_manifest!(manifest, build_document(entries))

      assert {:error, :identity_mismatch} =
               Source.pin(source, manifest, InflatingSizeTrustedPath)
    end
  end

  # --- verify/2 drift ---

  describe "verify/2 drift detection" do
    test "fails closed when a retained entry drifts after pin", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:ok, binding} = Source.pin(source, manifest, FakeTrustedPath)
      assert :ok = Source.verify(binding, FakeTrustedPath)

      # Mutate a pinned regular file after successful pin.
      write_file!(Path.join(source, "hex/mix.exs"), "mutated-after-pin", 0o644)

      assert {:error, :identity_mismatch} =
               Source.verify(binding, FakeTrustedPath)
    end

    test "fails closed when verify_mode forces drift without filesystem mutation", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:ok, binding} = Source.pin(source, manifest, FakeTrustedPath)

      FakeTrustedPath.set_verify_mode(:drift)

      assert {:error, :identity_mismatch} =
               Source.verify(binding, FakeTrustedPath)
    end
  end

  # --- API surface guarantees ---

  describe "non-authority surface" do
    test "Binding and plan are evidence maps, not spawn backend authority", %{root: root} do
      %{source: source, manifest: manifest} = fixture_tree!(root)
      assert {:ok, binding} = Source.pin(source, manifest, FakeTrustedPath)

      plan = Source.plan(binding)
      refute Map.has_key?(plan, "authority")
      refute Map.has_key?(plan, "capability")
      refute Map.has_key?(plan, "signing")
      assert plan["evidence_only"] == true

      # Receipt never includes inventory entries.
      assert map_size(binding.receipt) == 9
      assert binding.receipt["entry_count"] == 5
    end
  end

  # --- Security regressions (parent review corrections) ---

  describe "security regression" do
    test "security regression: rejects oversized manifest before TrustedPath pin", %{
      root: root
    } do
      source = Path.join(root, "source")
      File.mkdir_p!(source)

      oversized = 32 * 1024 * 1024 + 1
      manifest = Path.join(root, "oversized.manifest.json")
      write_sparse_oversized!(manifest, oversized)

      PinCountingTrustedPath.clear()

      assert {:error, :manifest_too_large} =
               Source.pin(source, manifest, PinCountingTrustedPath)

      # Source root may pin as a directory; the oversized manifest must never
      # reach pin_root_owned_regular_file (no 512 MiB TrustedPath hash path).
      refute manifest in PinCountingTrustedPath.file_pins()
    end

    test "security regression: rejects executable manifest before use", %{root: root} do
      source = Path.join(root, "source")
      File.mkdir_p!(source)
      write_file!(Path.join(source, "pkg/a"), "x", 0o644)

      entries = [
        %{path: "pkg", type: "directory"},
        %{
          path: "pkg/a",
          type: "regular",
          size: 1,
          sha256: sha256_file(Path.join(source, "pkg/a")),
          executable: false
        }
      ]

      manifest = Path.join(root, "exec-manifest.json")
      write_manifest!(manifest, build_document(entries))
      File.chmod!(manifest, 0o755)

      PinCountingTrustedPath.clear()

      assert {:error, :executable_manifest} =
               Source.pin(source, manifest, PinCountingTrustedPath)

      refute manifest in PinCountingTrustedPath.file_pins()
    end

    test "security regression: rejects external hardlink on source regular file", %{
      root: root
    } do
      source = Path.join(root, "source")
      File.mkdir_p!(Path.join(source, "pkg"))
      target = Path.join(source, "pkg/a")
      write_file!(target, "shared-bytes", 0o644)

      # Second hardlink lives outside source_root so device/inode de-dup alone
      # cannot see it; link-count must reject.
      external = Path.join(root, "outside-hardlink")

      case File.ln(target, external) do
        :ok ->
          {:ok, %File.Stat{links: links}} = File.lstat(target, time: :posix)
          assert links == 2

          a_sha = sha256_file(target)

          entries = [
            %{path: "pkg", type: "directory"},
            %{path: "pkg/a", type: "regular", size: 12, sha256: a_sha, executable: false}
          ]

          manifest = Path.join(root, "external-hardlink.json")
          write_manifest!(manifest, build_document(entries))

          assert {:error, :hardlink_rejected} =
                   Source.pin(source, manifest, FakeTrustedPath)

        {:error, reason} ->
          flunk("hardlink fixture unavailable: #{inspect(reason)}")
      end
    end

    test "security regression: rejects post-pin device/identity substitution on directories",
         %{
           root: root
         } do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:error, reason} =
               Source.pin(source, manifest, DeviceSubstitutingTrustedPath)

      assert reason in [:identity_mismatch, :device_crossing]
    end

    test "security regression: rejects post-pin device/identity substitution on regular files",
         %{
           root: root
         } do
      %{source: source, manifest: manifest} = fixture_tree!(root)

      assert {:error, reason} =
               Source.pin(source, manifest, RegularIdentitySubstitutingTrustedPath)

      assert reason in [:identity_mismatch, :device_crossing]
    end
  end

  describe "plan/1 and verify/2 malformed Binding shapes" do
    test "return typed errors instead of raising on malformed Binding fields" do
      shape_invalid = [
        :not_a_binding,
        %Binding{
          source_identity: sample_identity("/tmp/src", :directory),
          manifest_identity: sample_identity("/tmp/m.json", :regular),
          entry_identities: "not-a-map",
          state: %{},
          receipt: %{}
        },
        %Binding{
          source_identity: sample_identity("/tmp/src", :directory),
          manifest_identity: sample_identity("/tmp/m.json", :regular),
          entry_identities: %{1 => sample_identity("/tmp/src/a", :regular)},
          state: %{},
          receipt: %{}
        },
        %Binding{
          source_identity: %{path: "/tmp/src", type: :directory},
          manifest_identity: sample_identity("/tmp/m.json", :regular),
          entry_identities: %{},
          state: %{},
          receipt: %{}
        },
        %Binding{
          source_identity: %{sample_identity("/tmp/src", :directory) | path: nil},
          manifest_identity: sample_identity("/tmp/m.json", :regular),
          entry_identities: %{},
          state: %{entries: []},
          receipt: %{}
        },
        %Binding{
          source_identity: sample_identity("/tmp/src", :regular),
          manifest_identity: sample_identity("/tmp/m.json", :regular),
          entry_identities: %{},
          state: %{entries: []},
          receipt: %{}
        }
      ]

      for binding <- shape_invalid do
        assert {:error, :invalid_binding} = Source.plan(binding)
        assert {:error, :invalid_binding} = Source.verify(binding, FakeTrustedPath)
      end

      # Shape-valid identities with unusable state must still not raise from plan/1.
      plan_only_invalid = %Binding{
        source_identity: sample_identity("/tmp/src", :directory),
        manifest_identity: sample_identity("/tmp/m.json", :regular),
        entry_identities: %{},
        state: %{entries: :not_a_list},
        receipt: %{}
      }

      assert {:error, :invalid_binding} = Source.plan(plan_only_invalid)
    end
  end
end
