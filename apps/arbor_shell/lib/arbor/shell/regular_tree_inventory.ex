defmodule Arbor.Shell.RegularTreeInventory do
  @moduledoc false

  import Bitwise

  alias Arbor.Shell.LinuxDependencyBaselineFilesystem, as: Filesystem

  @schema "arbor.shell.regular_tree_inventory.v1"
  @max_entries 50_000
  @max_total_bytes 512 * 1024 * 1024
  @max_path_bytes 4_096
  @max_component_bytes 255
  @max_path_depth 48
  # 120s covers the legal 512 MiB / 50k-entry ceiling; 10s cannot.
  @timeout_ms 120_000
  @listing_heap_words 4_000_000
  @min_listing_heap_words 512
  @cleanup_wait_ms 100
  @listing_hook_key {__MODULE__, :listing_hook}

  @type directory_fact :: %{path: String.t(), mode: non_neg_integer()}
  @type regular_fact :: %{
          path: String.t(),
          mode: non_neg_integer(),
          executable: boolean(),
          size: non_neg_integer(),
          sha256: String.t(),
          prefix: binary()
        }
  @type facts :: %{directories: [directory_fact()], regular_files: [regular_fact()]}

  @spec inventory(term()) :: {:ok, map()} | {:error, atom()}
  def inventory(source_root) do
    case scan_with_policy(source_root, :caller_visible, production_opts()) do
      {:ok, facts} -> {:ok, document(facts)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec scan_resolved(term()) :: {:ok, facts()} | {:error, atom()}
  def scan_resolved(source_root) do
    scan_with_policy(source_root, :resolved, production_opts())
  end

  @doc false
  @spec __test_inventory__(term(), term()) :: {:ok, map()} | {:error, atom()}
  def __test_inventory__(source_root, limits) do
    case test_opts(limits) do
      {:ok, opts} ->
        case scan_with_policy(source_root, :caller_visible, opts) do
          {:ok, facts} -> {:ok, document(facts)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec __test_set_listing_hook__((String.t() -> term()) | nil) :: :ok
  def __test_set_listing_hook__(fun) when is_function(fun, 1) do
    Process.put(@listing_hook_key, fun)
    :ok
  end

  def __test_set_listing_hook__(nil) do
    Process.delete(@listing_hook_key)
    :ok
  end

  defp production_opts do
    %{
      timeout_ms: @timeout_ms,
      listing_heap_words: @listing_heap_words,
      listing_hook: listing_hook()
    }
  end

  defp test_opts(%{timeout_ms: timeout_ms, listing_heap_words: heap} = limits)
       when map_size(limits) == 2 and is_integer(timeout_ms) and timeout_ms > 0 and
              timeout_ms <= @timeout_ms and is_integer(heap) and
              heap >= @min_listing_heap_words and heap <= @listing_heap_words do
    {:ok,
     %{
       timeout_ms: timeout_ms,
       listing_heap_words: heap,
       listing_hook: listing_hook()
     }}
  end

  defp test_opts(_limits), do: {:error, :invalid_test_limits}

  defp listing_hook do
    case Process.get(@listing_hook_key) do
      fun when is_function(fun, 1) -> fun
      _other -> nil
    end
  end

  # :caller_visible rejects a symlink in the caller path before resolve.
  # :resolved canonicalizes first so Linux can bind a source through a
  # symlinked ancestor, then rejects remaining symlink components.
  defp scan_with_policy(source_root, policy, opts) do
    deadline_ms = System.monotonic_time(:millisecond) + opts.timeout_ms

    with {:ok, requested} <- validate_source_root(source_root),
         {:ok, root} <- admit_root(requested, policy),
         :ok <- check_deadline(deadline_ms),
         {:ok, root_stat} <- lstat(root),
         :ok <- require_directory(root_stat),
         {:ok, facts} <- walk(root, root_stat, opts, deadline_ms),
         :ok <- unchanged(root, root_stat, :directory),
         sorted = sort_facts(facts),
         :ok <- check_deadline(deadline_ms) do
      {:ok, sorted}
    end
  end

  defp admit_root(requested, :caller_visible) do
    case Filesystem.reject_symlink_ancestors(requested) do
      :ok -> Filesystem.resolve_source_root(requested)
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_root(requested, :resolved) do
    with {:ok, root} <- Filesystem.resolve_source_root(requested),
         :ok <- Filesystem.reject_symlink_ancestors(root) do
      {:ok, root}
    end
  end

  # Portable BEAM APIs cannot hold a directory descriptor across readdir.
  # A same-UID swap that restores identity before unchanged/1 is outside the
  # guarantee; lstat/fstat identity still closes the portable replacement cases.
  defp walk(root, root_stat, opts, deadline_ms) do
    state = %{
      root_device: Filesystem.device_identity(root_stat),
      deadline_ms: deadline_ms,
      listing_heap_words: opts.listing_heap_words,
      listing_hook: opts.listing_hook,
      directories: [],
      regular_files: [],
      seen_inodes: MapSet.new(),
      seen_paths: MapSet.new(),
      total_bytes: 0,
      count: 0
    }

    case walk_directory(root, "", state) do
      {:ok, next} ->
        {:ok, %{directories: next.directories, regular_files: next.regular_files}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_directory(abs_dir, prefix, state) do
    with :ok <- check_deadline(state.deadline_ms),
         {:ok, names} <- list_names(abs_dir, state) do
      reduce_entries(names, abs_dir, prefix, state)
    end
  end

  defp reduce_entries([], _abs_dir, _prefix, state), do: {:ok, state}

  defp reduce_entries([name | rest], abs_dir, prefix, state) do
    case add_entry(abs_dir, prefix, name, state) do
      {:ok, next} -> reduce_entries(rest, abs_dir, prefix, next)
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_names(abs_dir, state) do
    remaining = @max_entries - state.count
    parent = self()
    token = make_ref()
    hook = state.listing_hook
    heap = state.listing_heap_words

    {pid, monitor_ref} =
      spawn_monitor(fn -> listing_worker(parent, token, abs_dir, heap, hook) end)

    listing = %{pid: pid, monitor_ref: monitor_ref, token: token}

    case await_listing_ready(listing, state) do
      :ok -> collect_names(listing, remaining, [], 0, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp listing_worker(parent, token, path, heap_words, hook) do
    parent_ref = Process.monitor(parent)

    Process.flag(:max_heap_size, %{
      size: heap_words,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    case listing_source(hook, path) do
      {:ok, names} ->
        send(parent, {token, :ready})
        serve_names(parent, parent_ref, token, names)

      {:error, reason} ->
        send(parent, {token, {:error, reason}})
    end
  rescue
    _error -> send(parent, {token, {:error, :listing_failed}})
  catch
    _kind, _reason -> send(parent, {token, {:error, :listing_failed}})
  end

  defp listing_source(nil, path), do: file_ls(path)

  defp listing_source(hook, path) when is_function(hook, 1) do
    case hook.(path) do
      :cont -> file_ls(path)
      {:names, names} when is_list(names) -> {:ok, names}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :listing_failed}
    end
  end

  defp file_ls(path) do
    case File.ls(path) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:error, :enoent}
      {:error, _reason} -> {:error, :listing_failed}
    end
  end

  defp serve_names(parent, parent_ref, token, [name | rest]) do
    receive do
      {^token, :next} ->
        send(parent, {token, {:entry, name}})
        serve_names(parent, parent_ref, token, rest)

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp serve_names(parent, parent_ref, token, []) do
    receive do
      {^token, :next} -> send(parent, {token, :done})
      {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
    end
  end

  defp await_listing_ready(listing, state) do
    case remaining_ms(state.deadline_ms) do
      left when left > 0 -> receive_listing_ready(listing, state, left)
      _expired -> fail_listing(listing, state, :scan_timeout)
    end
  end

  defp receive_listing_ready(listing, state, left) do
    receive do
      {token, :ready} when token == listing.token ->
        :ok

      {token, {:error, :enoent}} when token == listing.token ->
        finish_listing(listing, :source_changed)

      {token, {:error, reason}} when token == listing.token and is_atom(reason) ->
        finish_listing(listing, reason)

      {:DOWN, ref, :process, pid, reason}
      when ref == listing.monitor_ref and pid == listing.pid ->
        finish_listing_down(listing, reason)
    after
      left -> fail_listing(listing, state, :scan_timeout)
    end
  end

  # Bound names while receiving: keep at most `remaining`, stop/kill/flush at
  # remaining+1, and sort only that bounded list.
  defp collect_names(listing, remaining, acc, count, state) do
    send(listing.pid, {listing.token, :next})

    case remaining_ms(state.deadline_ms) do
      left when left > 0 ->
        receive_listed_name(listing, remaining, acc, count, state, left)

      _expired ->
        fail_listing(listing, state, :scan_timeout)
    end
  end

  defp receive_listed_name(listing, remaining, acc, count, state, left) do
    receive do
      {token, {:entry, name}} when token == listing.token ->
        admit_listed_name(listing, remaining, acc, count, state, name)

      {token, :done} when token == listing.token ->
        stop_listing(listing)
        {:ok, Enum.sort(acc)}

      {:DOWN, ref, :process, pid, reason}
      when ref == listing.monitor_ref and pid == listing.pid ->
        finish_listing_down(listing, reason)
    after
      left -> fail_listing(listing, state, :scan_timeout)
    end
  end

  defp admit_listed_name(listing, remaining, acc, count, state, name)
       when is_binary(name) and name not in ["", ".", ".."] do
    if count >= remaining do
      fail_listing(listing, state, :too_many_entries)
    else
      collect_names(listing, remaining, [name | acc], count + 1, state)
    end
  end

  defp admit_listed_name(listing, _remaining, _acc, _count, state, _name) do
    fail_listing(listing, state, :unsafe_path)
  end

  defp finish_listing_down(listing, :killed), do: finish_listing(listing, :listing_memory_exceeded)
  defp finish_listing_down(listing, _reason), do: finish_listing(listing, :listing_failed)

  defp finish_listing(listing, reason) do
    release_listing(listing)
    {:error, reason}
  end

  defp fail_listing(listing, _state, reason) do
    stop_listing(listing)
    {:error, reason}
  end

  defp release_listing(%{monitor_ref: monitor_ref, token: token}) do
    Process.demonitor(monitor_ref, [:flush])
    flush_listing(token)
    :ok
  end

  defp stop_listing(%{pid: pid, monitor_ref: monitor_ref, token: token}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      @cleanup_wait_ms -> Process.demonitor(monitor_ref, [:flush])
    end

    flush_listing(token)
    :ok
  end

  defp flush_listing(token) do
    receive do
      {^token, _message} -> flush_listing(token)
    after
      0 -> :ok
    end
  end

  defp add_entry(abs_dir, prefix, name, state) do
    with :ok <- check_deadline(state.deadline_ms),
         :ok <- validate_name(name),
         rel_path = join_path(prefix, name),
         :ok <- validate_relative_path(rel_path),
         :ok <- reject_duplicate(rel_path, state),
         abs_path = Path.join(abs_dir, name),
         :ok <- check_deadline(state.deadline_ms),
         {:ok, before} <- lstat(abs_path),
         :ok <- same_device(before, state.root_device) do
      admit_stat(abs_path, rel_path, before, state)
    end
  end

  defp admit_stat(abs_path, rel_path, before, state) do
    case before.type do
      :directory -> add_directory(abs_path, rel_path, before, state)
      :regular -> add_regular(abs_path, rel_path, before, state)
      :symlink -> {:error, :symlink_rejected}
      _other -> {:error, :unsupported_source_entry_type}
    end
  end

  defp add_directory(abs_path, rel_path, before, state) do
    if state.count >= @max_entries do
      {:error, :too_many_entries}
    else
      walk_added_directory(abs_path, rel_path, before, record_directory(rel_path, before, state))
    end
  end

  defp walk_added_directory(abs_path, rel_path, before, state) do
    with {:ok, nested} <- walk_directory(abs_path, rel_path, state),
         :ok <- unchanged(abs_path, before, :directory) do
      {:ok, nested}
    end
  end

  defp record_directory(rel_path, before, state) do
    %{
      state
      | directories: [%{path: rel_path, mode: before.mode &&& 0o7777} | state.directories],
        seen_paths: MapSet.put(state.seen_paths, rel_path),
        count: state.count + 1
    }
  end

  defp add_regular(abs_path, rel_path, before, state) do
    inode = {Filesystem.device_identity(before), before.inode}

    cond do
      state.count >= @max_entries ->
        {:error, :too_many_entries}

      before.links != 1 or MapSet.member?(state.seen_inodes, inode) ->
        {:error, :hardlink_rejected}

      not is_integer(before.size) or before.size < 0 ->
        {:error, :invalid_stat}

      overflow_bytes?(before.size, state.total_bytes) ->
        {:error, :total_bytes_exceeded}

      true ->
        hash_and_record(abs_path, rel_path, before, inode, state)
    end
  end

  defp overflow_bytes?(size, total_bytes) do
    size > @max_total_bytes or total_bytes + size > @max_total_bytes
  end

  defp hash_and_record(abs_path, rel_path, before, inode, state) do
    with :ok <- check_deadline(state.deadline_ms),
         {:ok, hashed} <- hash_regular(abs_path, before.size, state.deadline_ms),
         :ok <- check_deadline(state.deadline_ms),
         :ok <- unchanged(abs_path, before, :regular),
         :ok <- check_deadline(state.deadline_ms) do
      {:ok, record_regular(rel_path, before, hashed, inode, state)}
    end
  end

  defp hash_regular(path, expected_size, deadline_ms) do
    case remaining_ms(deadline_ms) do
      left when left > 0 -> hash_regular_bounded(path, expected_size, left)
      _expired -> {:error, :scan_timeout}
    end
  end

  defp hash_regular_bounded(path, expected_size, left) do
    parent = self()
    token = make_ref()
    hook = Process.get({Filesystem, :before_open_hook})

    {pid, monitor_ref} =
      spawn_monitor(fn -> hash_worker(parent, token, path, hook) end)

    await_hash_result(pid, monitor_ref, token, expected_size, left)
  end

  defp hash_worker(parent, token, path, hook) do
    if is_function(hook, 1) do
      Process.put({Filesystem, :before_open_hook}, hook)
    end

    send(parent, {token, Filesystem.hash_regular_file(path, @max_total_bytes)})
  end

  defp await_hash_result(pid, monitor_ref, token, expected_size, left) do
    receive do
      {^token, result} ->
        reap_hash_worker(pid, monitor_ref, token)
        decode_hash_result(result, expected_size)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        flush_listing(token)
        {:error, :source_read_failed}
    after
      left ->
        stop_hash_worker(pid, monitor_ref, token)
        {:error, :scan_timeout}
    end
  end

  defp stop_hash_worker(pid, monitor_ref, token) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    reap_hash_worker(pid, monitor_ref, token)
  end

  defp reap_hash_worker(pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      @cleanup_wait_ms ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
    end

    flush_listing(token)
    :ok
  end

  defp decode_hash_result(
         {:ok, %{sha256: digest, prefix: prefix, size: expected_size}},
         expected_size
       )
       when is_binary(digest) and is_binary(prefix) do
    {:ok, %{sha256: digest, prefix: prefix}}
  end

  defp decode_hash_result({:ok, _other}, _expected_size), do: {:error, :source_changed}
  defp decode_hash_result({:error, reason}, _expected_size), do: {:error, reason}
  defp decode_hash_result(_other, _expected_size), do: {:error, :source_read_failed}

  defp record_regular(rel_path, before, hashed, inode, state) do
    entry = %{
      path: rel_path,
      mode: before.mode &&& 0o7777,
      executable: (before.mode &&& 0o111) != 0,
      size: before.size,
      sha256: hashed.sha256,
      prefix: hashed.prefix
    }

    %{
      state
      | regular_files: [entry | state.regular_files],
        seen_inodes: MapSet.put(state.seen_inodes, inode),
        seen_paths: MapSet.put(state.seen_paths, rel_path),
        total_bytes: state.total_bytes + before.size,
        count: state.count + 1
    }
  end

  defp reject_duplicate(rel_path, state) do
    if MapSet.member?(state.seen_paths, rel_path) do
      {:error, :duplicate_path}
    else
      :ok
    end
  end

  defp unchanged(path, before, expected_type) do
    case lstat(path) do
      {:ok, after_stat} ->
        match_unchanged(before, after_stat, expected_type)

      {:error, _reason} ->
        {:error, :source_changed}
    end
  end

  defp match_unchanged(before, after_stat, expected_type) do
    if Filesystem.same_identity?(before, after_stat) and after_stat.type == expected_type do
      :ok
    else
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
    if Filesystem.device_identity(stat) == root_device do
      :ok
    else
      {:error, :device_crossing}
    end
  end

  defp same_device(_stat, _root_device), do: {:error, :device_crossing}

  defp validate_source_root(path) when is_binary(path) do
    cond do
      path in ["", "/"] ->
        {:error, :invalid_source_root}

      Path.type(path) != :absolute ->
        {:error, :relative_source_root}

      byte_size(path) > @max_path_bytes ->
        {:error, :source_root_too_long}

      not String.valid?(path) or String.contains?(path, <<0>>) ->
        {:error, :invalid_source_root}

      has_control_char?(path) ->
        {:error, :invalid_source_root}

      String.contains?(path, "//") or String.ends_with?(path, "/") ->
        {:error, :non_canonical_source_root}

      Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
        {:error, :non_canonical_source_root}

      Path.expand(path) != path ->
        {:error, :non_canonical_source_root}

      true ->
        {:ok, path}
    end
  end

  defp validate_source_root(_path), do: {:error, :invalid_source_root}

  defp validate_name(name) when is_binary(name) do
    cond do
      name in ["", ".", ".."] ->
        {:error, :unsafe_path}

      not String.valid?(name) ->
        {:error, :invalid_utf8}

      byte_size(name) > @max_component_bytes ->
        {:error, :path_component_too_long}

      String.contains?(name, "/") or String.contains?(name, <<0>>) or has_control_char?(name) ->
        {:error, :unsafe_path}

      true ->
        :ok
    end
  end

  defp validate_name(_name), do: {:error, :unsafe_path}

  defp validate_relative_path(path) do
    segments = String.split(path, "/", trim: false)

    cond do
      byte_size(path) > @max_path_bytes ->
        {:error, :path_too_long}

      length(segments) > @max_path_depth ->
        {:error, :path_depth_exceeded}

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        {:error, :unsafe_path}

      Enum.any?(segments, &(byte_size(&1) > @max_component_bytes)) ->
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

  defp remaining_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp check_deadline(deadline_ms) do
    if remaining_ms(deadline_ms) > 0, do: :ok, else: {:error, :scan_timeout}
  end

  defp sort_facts(%{directories: directories, regular_files: regular_files}) do
    %{
      directories: Enum.sort_by(directories, & &1.path, &<=/2),
      regular_files: Enum.sort_by(regular_files, & &1.path, &<=/2)
    }
  end

  defp document(%{directories: directories, regular_files: regular_files}) do
    dir_docs = Enum.map(directories, &directory_document/1)
    file_docs = Enum.map(regular_files, &regular_document/1)
    total_bytes = Enum.reduce(regular_files, 0, fn %{size: size}, acc -> acc + size end)

    %{
      "schema" => @schema,
      "directories" => dir_docs,
      "regular_files" => file_docs,
      "counts" => %{
        "directories" => length(dir_docs),
        "regular_files" => length(file_docs),
        "entries" => length(dir_docs) + length(file_docs),
        "total_regular_bytes" => total_bytes
      }
    }
  end

  defp directory_document(%{path: path, mode: mode}) do
    %{"path" => path, "mode" => mode}
  end

  defp regular_document(entry) do
    %{
      "path" => entry.path,
      "mode" => entry.mode,
      "executable" => entry.executable,
      "size" => entry.size,
      "sha256" => entry.sha256,
      "prefix_hex" => Base.encode16(entry.prefix, case: :lower)
    }
  end
end
