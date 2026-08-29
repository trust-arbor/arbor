defmodule Arbor.Actions.Coding.SnapshotDestVerify do
  @moduledoc false

  alias Arbor.Actions.Coding.GitBlobOid

  @chunk_size 65_536

  @doc false
  @spec verify(term(), term(), term(), term()) ::
          {:ok, list(), map()} | {:error, term()}
  def verify(dest, held_entries, budget, format)
      when is_binary(dest) and dest != "" and is_list(held_entries) and is_map(budget) and
             format in [:sha1, :sha256] do
    with {:ok, dest_blobs, extra_dirs?, walked} <-
           walk_destination(dest, budget, held_ancestor_dirs(held_entries), format),
         :ok <- compare_dest_to_held(dest_blobs, extra_dirs?, held_entries) do
      {:ok, held_entries,
       %{
         dest_files: map_size(dest_blobs),
         dest_entries_visited: walked.entries,
         dest_bytes: walked.bytes
       }}
    end
  end

  def verify(_dest, _held_entries, _budget, _format), do: {:error, :validation_tree_mutated}

  defp held_ancestor_dirs(entries) when is_list(entries) do
    Enum.reduce(entries, MapSet.new(), fn %{path: path}, acc ->
      MapSet.union(acc, MapSet.new(ancestor_dirs(path)))
    end)
  end

  defp ancestor_dirs(path) when is_binary(path) do
    parts = Path.split(path)

    if length(parts) < 2 do
      []
    else
      Enum.map(1..(length(parts) - 1), fn n ->
        parts |> Enum.take(n) |> Enum.join("/")
      end)
    end
  end

  defp walk_destination(dest, budget, ancestors, format)
       when is_binary(dest) and dest != "" do
    case File.lstat(dest, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        case walk_dest_dir(dest, dest, "", budget, ancestors, %{}, false, format) do
          {:ok, walked, blobs, extra_dirs?} -> {:ok, blobs, extra_dirs?, walked}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{}} ->
        {:error, :validation_tree_mutated}

      {:error, _reason} ->
        {:error, :validation_tree_mutated}
    end
  end

  defp walk_destination(_dest, _budget, _ancestors, _format),
    do: {:error, :validation_tree_mutated}

  defp walk_dest_dir(root, abs, rel, budget, ancestors, blobs, extra_dirs?, format) do
    case File.ls(abs) do
      {:ok, names} ->
        reduce_dest_entries(
          names,
          root,
          abs,
          rel,
          budget,
          ancestors,
          blobs,
          extra_dirs?,
          format
        )

      {:error, _reason} ->
        {:error, :validation_tree_mutated}
    end
  end

  defp reduce_dest_entries(
         [],
         _root,
         _abs,
         _rel,
         budget,
         _ancestors,
         blobs,
         extra_dirs?,
         _format
       ) do
    {:ok, budget, blobs, extra_dirs?}
  end

  defp reduce_dest_entries(
         [name | rest],
         root,
         abs,
         rel,
         budget,
         ancestors,
         blobs,
         extra_dirs?,
         format
       ) do
    case visit_dest_entry(
           root,
           abs,
           rel,
           name,
           budget,
           ancestors,
           blobs,
           extra_dirs?,
           format
         ) do
      {:ok, budget, blobs, extra_dirs?} ->
        reduce_dest_entries(
          rest,
          root,
          abs,
          rel,
          budget,
          ancestors,
          blobs,
          extra_dirs?,
          format
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp visit_dest_entry(root, abs, rel, name, budget, ancestors, blobs, extra_dirs?, format) do
    with true <- safe_dest_name?(name),
         child_rel = join_rel(rel, name),
         child_abs = abs <> "/" <> name,
         true <- within_dest?(root, child_abs),
         {:ok, %File.Stat{} = stat} <- File.lstat(child_abs, time: :posix),
         {:ok, budget} <- account_dest_entry(budget, child_rel, stat) do
      case stat.type do
        :directory ->
          extra_dirs? = extra_dirs? or not MapSet.member?(ancestors, child_rel)

          walk_dest_dir(
            root,
            child_abs,
            child_rel,
            budget,
            ancestors,
            blobs,
            extra_dirs?,
            format
          )

        :regular ->
          hash_dest_regular(child_abs, child_rel, budget, blobs, extra_dirs?, stat, format)

        :symlink ->
          hash_dest_symlink(child_abs, child_rel, budget, blobs, extra_dirs?, stat, format)

        _other ->
          {:error, :validation_tree_mutated}
      end
    else
      false -> {:error, :validation_tree_mutated}
      {:error, :enoent} -> {:error, :validation_tree_mutated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hash_dest_regular(abs, rel, budget, blobs, extra_dirs?, stat, format) do
    case hash_regular_file(abs, stat, format) do
      {:ok, oid} ->
        mode = if executable_mode?(stat.mode), do: "100755", else: "100644"
        {:ok, budget, Map.put(blobs, rel, {mode, oid}), extra_dirs?}

      {:error, :tree_binding_bounds_exceeded} ->
        {:error, :tree_binding_bounds_exceeded}

      {:error, _reason} ->
        {:error, :validation_tree_mutated}
    end
  end

  defp hash_dest_symlink(abs, rel, budget, blobs, extra_dirs?, stat, format) do
    case File.read_link(abs) do
      {:ok, target} when is_binary(target) ->
        next_bytes = budget.bytes + byte_size(target)

        cond do
          next_bytes > budget.max_bytes ->
            {:error, :tree_binding_bounds_exceeded}

          not symlink_target_size_matches?(stat, target) ->
            {:error, :validation_tree_mutated}

          true ->
            hash_symlink_target(
              abs,
              rel,
              target,
              %{budget | bytes: next_bytes},
              blobs,
              extra_dirs?,
              stat,
              format
            )
        end

      {:error, _reason} ->
        {:error, :validation_tree_mutated}

      _other ->
        {:error, :validation_tree_mutated}
    end
  end

  # Capture is race-stable: first target observation → optional process-local
  # test hook → re-read target → path lstat. Hash the confirmed target so a
  # post-admission swap cannot pass on the first observation's blob OID.
  defp hash_symlink_target(abs, rel, target, budget, blobs, extra_dirs?, before_stat, format) do
    with :ok <- maybe_symlink_capture_hook(abs),
         {:ok, target_after} <- File.read_link(abs),
         true <- target == target_after,
         {:ok, %File.Stat{type: :symlink} = after_stat} <- File.lstat(abs, time: :posix),
         true <- stable_file_identity(before_stat) == stable_file_identity(after_stat),
         {:ok, oid} <- GitBlobOid.hash_bytes(target_after, format) do
      {:ok, budget, Map.put(blobs, rel, {"120000", oid}), extra_dirs?}
    else
      false -> {:error, :validation_tree_mutated}
      {:error, :tree_binding_bounds_exceeded} -> {:error, :tree_binding_bounds_exceeded}
      {:error, _reason} -> {:error, :validation_tree_mutated}
      _other -> {:error, :validation_tree_mutated}
    end
  end

  # Residual limitation: no openat(2)/O_NOFOLLOW in stdlib; posix times are
  # second-resolution, so same-second metadata-preserving inode reuse is not a
  # hostile-runtime guarantee. Size+1 EOF plus identity still reject growth,
  # truncation, and type drift.
  defp hash_regular_file(abs, %File.Stat{type: :regular} = before_stat, format) do
    admitted_size = max(before_stat.size || 0, 0)
    admitted = stable_file_identity(before_stat)

    case :file.open(String.to_charlist(abs), [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          hash_opened_regular(io, abs, admitted, admitted_size, format)
        after
          _ = :file.close(io)
        end

      {:error, _reason} ->
        {:error, :validation_tree_mutated}
    end
  end

  defp hash_regular_file(_abs, _stat, _format), do: {:error, :validation_tree_mutated}

  defp hash_opened_regular(io, abs, admitted, admitted_size, format) do
    with {:ok, %File.Stat{type: :regular} = opened} <- descriptor_file_stat(io),
         true <- stable_file_identity(opened) == admitted,
         true <- opened.size == admitted_size,
         :ok <- maybe_regular_hash_hook(abs, :after_admit),
         {:ok, state} <- GitBlobOid.hash_init(format, admitted_size),
         {:ok, state} <- read_blob_body(io, state, admitted_size),
         :ok <- maybe_regular_hash_hook(abs, :after_body),
         :ok <- require_eof(io),
         :ok <- maybe_regular_hash_hook(abs, :after_read),
         {:ok, %File.Stat{type: :regular} = after_desc} <- descriptor_file_stat(io),
         true <- stable_file_identity(after_desc) == admitted,
         true <- after_desc.size == admitted_size,
         {:ok, %File.Stat{type: :regular} = after_path} <- File.lstat(abs, time: :posix),
         true <- stable_file_identity(after_path) == admitted,
         true <- after_path.size == admitted_size,
         {:ok, oid} <- GitBlobOid.hash_final(state) do
      {:ok, oid}
    else
      false -> {:error, :validation_tree_mutated}
      {:error, :tree_binding_bounds_exceeded} -> {:error, :tree_binding_bounds_exceeded}
      {:error, _reason} -> {:error, :validation_tree_mutated}
      _other -> {:error, :validation_tree_mutated}
    end
  end

  defp read_blob_body(_io, state, 0), do: {:ok, state}

  defp read_blob_body(io, state, remaining) when is_integer(remaining) and remaining > 0 do
    to_read = min(@chunk_size, remaining)

    case :file.read(io, to_read) do
      {:ok, data} when is_binary(data) and byte_size(data) > 0 and byte_size(data) <= remaining ->
        case GitBlobOid.hash_update(state, data) do
          {:ok, next} -> read_blob_body(io, next, remaining - byte_size(data))
          {:error, reason} -> {:error, reason}
        end

      :eof ->
        {:error, :validation_tree_mutated}

      _other ->
        {:error, :validation_tree_mutated}
    end
  end

  defp read_blob_body(_io, _state, _remaining), do: {:error, :validation_tree_mutated}

  defp require_eof(io) do
    case :file.read(io, 1) do
      :eof -> :ok
      {:ok, _data} -> {:error, :validation_tree_mutated}
      _other -> {:error, :validation_tree_mutated}
    end
  end

  defp descriptor_file_stat(io_device) do
    case :file.read_file_info(io_device, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_dest_to_held(dest_blobs, extra_dirs?, held_entries)
       when is_map(dest_blobs) and is_boolean(extra_dirs?) and is_list(held_entries) do
    held_map = Map.new(held_entries, &{&1.path, {&1.mode, &1.oid}})
    dest_paths = MapSet.new(Map.keys(dest_blobs))
    held_paths = MapSet.new(Map.keys(held_map))

    mismatched? =
      extra_dirs? or dest_paths != held_paths or
        Enum.any?(held_map, fn {path, held} -> Map.get(dest_blobs, path) != held end)

    if mismatched?, do: {:error, :validation_tree_mutated}, else: :ok
  end

  defp compare_dest_to_held(_dest_blobs, _extra_dirs?, _held_entries),
    do: {:error, :validation_tree_mutated}

  defp account_dest_entry(budget, rel, %File.Stat{} = stat) do
    next = budget.entries + 1
    file_bytes = if stat.type == :regular, do: max(stat.size || 0, 0), else: 0
    next_bytes = budget.bytes + file_bytes

    cond do
      next > budget.max_entries ->
        {:error, :tree_binding_bounds_exceeded}

      match?({:error, _}, check_path_depth(rel, budget.max_depth)) ->
        {:error, :tree_binding_bounds_exceeded}

      next_bytes > budget.max_bytes ->
        {:error, :tree_binding_bounds_exceeded}

      true ->
        {:ok, %{budget | entries: next, bytes: next_bytes}}
    end
  end

  defp check_path_depth(path, max_depth)
       when is_binary(path) and is_integer(max_depth) and max_depth >= 0 do
    depth =
      path
      |> :binary.split(<<"/">>, [:global])
      |> Enum.reject(&(&1 == <<>>))
      |> length()

    if depth > max_depth,
      do: {:error, :tree_binding_bounds_exceeded},
      else: :ok
  end

  defp check_path_depth(_, _), do: {:error, :tree_binding_bounds_exceeded}

  defp safe_dest_name?(name) when is_binary(name) do
    name != "" and name != "." and name != ".." and not String.contains?(name, "/") and
      not String.contains?(name, <<0>>)
  end

  defp safe_dest_name?(_), do: false

  defp join_rel("", name), do: name
  defp join_rel(rel, name) when is_binary(rel) and is_binary(name), do: rel <> "/" <> name

  defp within_dest?(root, abs) when is_binary(root) and is_binary(abs) do
    root_parts = Path.split(root)
    abs_parts = Path.split(abs)
    List.starts_with?(abs_parts, root_parts)
  end

  defp within_dest?(_, _), do: false

  defp executable_mode?(mode) when is_integer(mode), do: Bitwise.band(mode, 0o111) != 0
  defp executable_mode?(_), do: false

  defp symlink_target_size_matches?(%File.Stat{size: size}, target)
       when is_integer(size) and is_binary(target) do
    size == byte_size(target)
  end

  defp symlink_target_size_matches?(_, _), do: false

  defp stable_file_identity(%File.Stat{} = stat) do
    {
      file_device_id(stat),
      Map.get(stat, :minor_device),
      stat.inode,
      stat.size,
      stat.type,
      stat.mode,
      stat.mtime,
      stat.ctime
    }
  end

  defp file_device_id(%File.Stat{} = stat) do
    Map.get(stat, :major_device) || Map.get(stat, :device)
  end

  # Test-only deterministic seams. Process dictionary only — no Application
  # environment fallback. Production verify sees nil and is a no-op.
  defp maybe_regular_hash_hook(path, phase) when is_binary(path) and is_atom(phase) do
    case Process.get({__MODULE__, :regular_hash_hook}) do
      fun when is_function(fun, 2) ->
        _ = fun.(path, phase)
        :ok

      _other ->
        :ok
    end
  end

  defp maybe_symlink_capture_hook(path) when is_binary(path) do
    case Process.get({__MODULE__, :symlink_capture_hook}) do
      fun when is_function(fun, 1) ->
        _ = fun.(path)
        :ok

      _other ->
        :ok
    end
  end

  @doc false
  def __test_set_regular_hash_hook__(fun) when is_function(fun, 2) do
    Process.put({__MODULE__, :regular_hash_hook}, fun)
    :ok
  end

  def __test_set_regular_hash_hook__(nil) do
    Process.delete({__MODULE__, :regular_hash_hook})
    :ok
  end

  @doc false
  def __test_set_symlink_capture_hook__(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :symlink_capture_hook}, fun)
    :ok
  end

  def __test_set_symlink_capture_hook__(nil) do
    Process.delete({__MODULE__, :symlink_capture_hook})
    :ok
  end
end
