defmodule Arbor.Shell.LinuxDependencyBaselineBuilder do
  @moduledoc """
  Bounded operator-facing builder for Linux dependency-baseline documents.

  The builder only reads an explicitly supplied source root. It does not install
  files, alter runtime configuration, invoke processes, or infer image
  authority. Symlinks, special files, hardlinks, device crossings, and unstable
  entries are rejected before the resulting document is admitted by
  `LinuxDependencyBaselineCore`.

  The fixed `linux/arm64` platform requires regular files whose names identify
  shared objects (`.so` or versioned `.so.N` forms) to be ELF64, little-endian,
  and identify AArch64 (`e_machine` 183). There is no compatibility bypass:
  the manifest format cannot record one.
  """

  import Bitwise

  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.LinuxDependencyBaselineFilesystem, as: Filesystem

  @schema "1"
  @metadata_keys [
    :platform,
    :image_index_digest,
    :image_manifest_digest,
    :mix_lock_digest,
    :toolchain
  ]
  @toolchain_keys [:erlang, :elixir]

  @spec build(term(), term()) ::
          {:ok, %{manifest: map(), entries: [map()]}, map()} | {:error, term()}
  def build(source_root, metadata), do: build(source_root, metadata, [])

  @spec build(term(), term(), keyword()) ::
          {:ok, %{manifest: map(), entries: [map()]}, map()} | {:error, term()}
  def build(source_root, metadata, []) do
    limits = Core.limits()

    with {:ok, normalized_metadata} <- normalize_metadata(metadata),
         {:ok, requested_root} <- validate_source_root(source_root, limits),
         {:ok, root} <- Filesystem.resolve_source_root(requested_root),
         :ok <- Filesystem.reject_symlink_ancestors(root),
         {:ok, root_stat} <- lstat(root),
         :ok <- require_directory(root_stat),
         {:ok, entries, _total_bytes} <- walk(root, Filesystem.device_identity(root_stat), limits),
         :ok <- unchanged(root, root_stat, :directory),
         {:ok, baseline_tree_digest} <- Core.tree_digest(entries),
         document <- build_document(normalized_metadata, baseline_tree_digest, entries),
         {:ok, state} <- Core.new(document) do
      canonical_document = document_from_state(state)
      {:ok, canonical_document, Core.show(state)}
    end
  end

  def build(_source_root, _metadata, _opts), do: {:error, :invalid_options}

  defp validate_source_root(path, limits) when is_binary(path) do
    cond do
      path in ["", "/"] ->
        {:error, :invalid_source_root}

      Path.type(path) != :absolute ->
        {:error, :relative_source_root}

      byte_size(path) > limits.max_path_bytes ->
        {:error, :source_root_too_long}

      not String.valid?(path) or String.contains?(path, <<0>>) ->
        {:error, :invalid_source_root}

      has_control_char?(path) ->
        {:error, :invalid_source_root}

      String.contains?(path, "//") or (path != "/" and String.ends_with?(path, "/")) ->
        {:error, :non_canonical_source_root}

      Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
        {:error, :non_canonical_source_root}

      Path.expand(path) != path ->
        {:error, :non_canonical_source_root}

      true ->
        {:ok, path}
    end
  end

  defp validate_source_root(_path, _limits), do: {:error, :invalid_source_root}

  defp normalize_metadata(metadata) when is_map(metadata) do
    with :ok <- validate_closed_keys(metadata, @metadata_keys, :metadata),
         {:ok, platform} <- fetch_required(metadata, :platform, :missing_platform),
         :ok <- require_platform(platform),
         {:ok, image_index_digest} <-
           fetch_required(metadata, :image_index_digest, :missing_image_index_digest),
         {:ok, image_manifest_digest} <-
           fetch_required(metadata, :image_manifest_digest, :missing_image_manifest_digest),
         {:ok, mix_lock_digest} <-
           fetch_required(metadata, :mix_lock_digest, :missing_mix_lock_digest),
         {:ok, toolchain} <- fetch_required(metadata, :toolchain, :missing_toolchain),
         {:ok, toolchain} <- normalize_toolchain(toolchain) do
      {:ok,
       %{
         schema: @schema,
         platform: platform,
         image_index_digest: image_index_digest,
         image_manifest_digest: image_manifest_digest,
         mix_lock_digest: mix_lock_digest,
         toolchain: toolchain
       }}
    end
  end

  defp normalize_metadata(_metadata), do: {:error, :invalid_metadata}

  defp require_platform("linux/arm64"), do: :ok
  defp require_platform(_platform), do: {:error, :unsupported_platform}

  defp normalize_toolchain(toolchain) when is_map(toolchain) do
    with :ok <- validate_closed_keys(toolchain, @toolchain_keys, :toolchain),
         {:ok, erlang} <- fetch_required(toolchain, :erlang, :missing_toolchain_erlang),
         {:ok, elixir} <- fetch_required(toolchain, :elixir, :missing_toolchain_elixir) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  defp normalize_toolchain(_toolchain), do: {:error, :invalid_toolchain}

  defp validate_closed_keys(map, keys, scope) do
    allowed = MapSet.new(keys ++ Enum.map(keys, &Atom.to_string/1))

    cond do
      map_size(map) > length(keys) ->
        {:error, {:unsupported_keys, scope}}

      Enum.any?(map, fn {key, _value} -> not MapSet.member?(allowed, key) end) ->
        {:error, {:unsupported_keys, scope}}

      Enum.any?(keys, &(Map.has_key?(map, &1) and Map.has_key?(map, Atom.to_string(&1)))) ->
        {:error, {:duplicate_key_alias, scope}}

      true ->
        :ok
    end
  end

  defp fetch_required(map, key, missing) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, _value}, {:ok, _other}} -> {:error, {:duplicate_key_alias, key}}
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> {:error, missing}
    end
  end

  defp build_document(metadata, digest, entries) do
    total_bytes =
      Enum.reduce(entries, 0, fn
        %{type: "regular", size: size}, total -> total + size
        %{type: "directory"}, total -> total
      end)

    %{
      manifest:
        Map.merge(metadata, %{
          baseline_tree_digest: digest,
          entry_count: length(entries),
          total_bytes: total_bytes
        }),
      entries: entries
    }
  end

  defp document_from_state(state) do
    %{
      manifest: %{
        schema: state.schema,
        platform: state.platform,
        image_index_digest: state.image_index_digest,
        image_manifest_digest: state.image_manifest_digest,
        mix_lock_digest: state.mix_lock_digest,
        baseline_tree_digest: state.baseline_tree_digest,
        toolchain: state.toolchain,
        entry_count: state.entry_count,
        total_bytes: state.total_bytes
      },
      entries: state.entries
    }
  end

  defp walk(root, root_device, limits) do
    case walk_directory(
           root,
           "",
           root_device,
           limits,
           [],
           MapSet.new(),
           0,
           0
         ) do
      {:ok, entries, _seen_inodes, total_bytes, _count} ->
        {:ok, Enum.reverse(entries), total_bytes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_directory(
         abs_dir,
         prefix,
         root_device,
         limits,
         entries,
         seen_inodes,
         total_bytes,
         count
       ) do
    remaining = limits.max_entries - count

    with {:ok, names} <- list_names(abs_dir, remaining) do
      Enum.reduce_while(
        names,
        {:ok, entries, seen_inodes, total_bytes, count},
        fn name, {:ok, acc_entries, acc_seen, acc_bytes, acc_count} ->
          case add_entry(
                 abs_dir,
                 prefix,
                 name,
                 root_device,
                 limits,
                 acc_entries,
                 acc_seen,
                 acc_bytes,
                 acc_count
               ) do
            {:ok, result} ->
              {:cont, {:ok, result.entries, result.seen_inodes, result.total_bytes, result.count}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      )
    end
  end

  defp list_names(abs_dir, remaining) when remaining >= 0 do
    case File.ls(abs_dir) do
      {:ok, names} ->
        if length(names) > remaining do
          {:error, :too_many_entries}
        else
          {:ok, Enum.sort(names)}
        end

      {:error, :enoent} ->
        {:error, :source_changed}

      {:error, _reason} ->
        {:error, :source_list_failed}
    end
  end

  defp list_names(_abs_dir, _remaining), do: {:error, :too_many_entries}

  defp add_entry(
         abs_dir,
         prefix,
         name,
         root_device,
         limits,
         entries,
         seen_inodes,
         total_bytes,
         count
       ) do
    with :ok <- validate_name(name, limits),
         rel_path <- join_path(prefix, name),
         :ok <- validate_relative_path(rel_path, limits),
         abs_path <- Path.join(abs_dir, name),
         {:ok, before} <- lstat(abs_path),
         :ok <- same_device(before, root_device) do
      case before.type do
        :directory ->
          add_directory(
            abs_path,
            rel_path,
            before,
            root_device,
            limits,
            entries,
            seen_inodes,
            total_bytes,
            count
          )

        :regular ->
          add_regular(
            abs_path,
            rel_path,
            before,
            limits,
            entries,
            seen_inodes,
            total_bytes,
            count
          )

        :symlink ->
          {:error, :symlink_rejected}

        _other ->
          {:error, :unsupported_source_entry_type}
      end
    end
  end

  defp add_directory(
         abs_path,
         rel_path,
         before,
         root_device,
         limits,
         entries,
         seen_inodes,
         total_bytes,
         count
       ) do
    if count >= limits.max_entries do
      {:error, :too_many_entries}
    else
      with {:ok, nested_entries, nested_seen, nested_bytes, nested_count} <-
             walk_directory(
               abs_path,
               rel_path,
               root_device,
               limits,
               [%{path: rel_path, type: "directory"} | entries],
               seen_inodes,
               total_bytes,
               count + 1
             ),
           :ok <- unchanged(abs_path, before, :directory) do
        {:ok,
         %{
           entries: nested_entries,
           seen_inodes: nested_seen,
           total_bytes: nested_bytes,
           count: nested_count
         }}
      end
    end
  end

  defp add_regular(
         abs_path,
         rel_path,
         before,
         limits,
         entries,
         seen_inodes,
         total_bytes,
         count
       ) do
    inode = {Filesystem.device_identity(before), before.inode}

    cond do
      count >= limits.max_entries ->
        {:error, :too_many_entries}

      before.links != 1 or MapSet.member?(seen_inodes, inode) ->
        {:error, :hardlink_rejected}

      not is_integer(before.size) or before.size < 0 ->
        {:error, :invalid_stat}

      before.size > limits.max_total_bytes or total_bytes + before.size > limits.max_total_bytes ->
        {:error, :total_bytes_exceeded}

      true ->
        with {:ok, digest} <- hash_file(abs_path, limits.max_total_bytes, rel_path),
             :ok <- unchanged(abs_path, before, :regular) do
          entry = %{
            path: rel_path,
            type: "regular",
            size: before.size,
            sha256: digest,
            executable: (before.mode &&& 0o111) != 0
          }

          {:ok,
           %{
             entries: [entry | entries],
             seen_inodes: MapSet.put(seen_inodes, inode),
             total_bytes: total_bytes + before.size,
             count: count + 1
           }}
        end
    end
  end

  defp hash_file(path, max_bytes, rel_path) do
    case Filesystem.hash_regular_file(path, max_bytes) do
      {:ok, %{sha256: digest, prefix: prefix, size: size}} when is_binary(digest) ->
        with true <- size >= 0,
             :ok <- validate_native_artifact(prefix, rel_path) do
          {:ok, digest}
        else
          false -> {:error, :source_changed}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_native_artifact(prefix, path) do
    if native_artifact_path?(path) do
      case prefix do
        <<0x7F, "ELF", 2, 1, _version, _osabi, _abiversion, _padding::binary-size(7),
          _type::little-unsigned-16, 183::little-unsigned-16, _rest::binary>> ->
          :ok

        _other ->
          {:error, :native_artifact_wrong_architecture}
      end
    else
      :ok
    end
  end

  defp native_artifact_path?(path) do
    filename = Path.basename(path)
    String.ends_with?(filename, ".so") or String.contains?(filename, ".so.")
  end

  defp unchanged(path, before, expected_type) do
    case lstat(path) do
      {:ok, after_stat} ->
        if Filesystem.same_identity?(before, after_stat) and after_stat.type == expected_type do
          :ok
        else
          {:error, :source_changed}
        end

      {:error, _reason} ->
        {:error, :source_changed}
    end
  end

  defp lstat(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :source_not_found}
      {:error, _reason} -> {:error, :source_stat_failed}
    end
  end

  defp require_directory(%File.Stat{type: :directory}), do: :ok
  defp require_directory(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  defp require_directory(%File.Stat{}), do: {:error, :invalid_source_root}

  defp same_device(%File.Stat{} = stat, root_device) do
    if Filesystem.device_identity(stat) == root_device,
      do: :ok,
      else: {:error, :device_crossing}
  end

  defp same_device(_stat, _root_device), do: {:error, :device_crossing}

  defp validate_name(name, limits) when is_binary(name) do
    cond do
      name in ["", ".", ".."] ->
        {:error, :unsafe_path}

      not String.valid?(name) ->
        {:error, :invalid_utf8}

      byte_size(name) > limits.max_component_bytes ->
        {:error, :path_component_too_long}

      String.contains?(name, "/") or String.contains?(name, <<0>>) or has_control_char?(name) ->
        {:error, :unsafe_path}

      true ->
        :ok
    end
  end

  defp validate_name(_name, _limits), do: {:error, :unsafe_path}

  defp validate_relative_path(path, limits) do
    segments = String.split(path, "/", trim: false)

    cond do
      byte_size(path) > limits.max_path_bytes ->
        {:error, :path_too_long}

      length(segments) > limits.max_path_depth ->
        {:error, :path_depth_exceeded}

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        {:error, :unsafe_path}

      Enum.any?(segments, &(byte_size(&1) > limits.max_component_bytes)) ->
        {:error, :path_component_too_long}

      true ->
        :ok
    end
  end

  defp join_path("", name), do: name
  defp join_path(prefix, name), do: prefix <> "/" <> name

  defp has_control_char?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 32 or &1 == 127))
  end
end
