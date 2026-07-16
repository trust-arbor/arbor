defmodule Arbor.Shell.OwnedTree do
  @moduledoc false

  @max_path_bytes 4_096
  @identity_capture_attempts 5
  @default_max_entries 100_000
  @default_timeout_ms 5_000
  @default_listing_heap_words 2_000_000
  @max_entries 1_000_000
  @max_timeout_ms 10_000
  @min_listing_heap_words 512
  @max_listing_heap_words 8_000_000
  @listing_depth_shift_cap 12

  @type identity :: %{
          path: String.t(),
          type: :directory,
          device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer()
        }

  @type retained_cleanup :: %{
          path: String.t(),
          identity: identity() | nil
        }

  @spec create_private(String.t(), keyword()) ::
          {:ok, identity()}
          | {:error, :root_exists | :invalid_owned_tree_path | term()}
          | {:error, {:owned_tree_cleanup_retained, term(), retained_cleanup()}}
  def create_private(path, opts \\ [])

  def create_private(path, opts) when is_binary(path) and is_list(opts) do
    with :ok <- validate_path(path) do
      case File.mkdir(path) do
        :ok -> finish_private_create(path, opts)
        {:error, :eexist} -> {:error, :root_exists}
        {:error, _reason} -> {:error, :owned_tree_create_failed}
      end
    end
  rescue
    _error -> {:error, :owned_tree_create_failed}
  catch
    _kind, _reason -> {:error, :owned_tree_create_failed}
  end

  def create_private(_path, _opts), do: {:error, :invalid_owned_tree_path}

  @spec remove(identity(), keyword()) :: :ok | {:error, term()}
  def remove(identity, opts \\ [])

  # Portable BEAM filesystem APIs cannot hold an inode handle across recursive
  # removal. This binds the root immediately before traversal, never follows
  # symlinks, and bounds each progressive attempt; a same-UID double swap during
  # traversal remains outside the guarantee.
  def remove(
        %{
          path: path,
          type: :directory,
          device: device,
          minor_device: minor_device,
          inode: inode
        },
        opts
      )
      when is_binary(path) and is_integer(device) and device >= 0 and
             is_integer(minor_device) and minor_device >= 0 and is_integer(inode) and inode >= 0 and
             is_list(opts) do
    with {:ok, budget} <- cleanup_budget(opts) do
      case File.lstat(path, time: :posix) do
        {:error, :enoent} ->
          :ok

        {:ok,
         %File.Stat{
           type: :directory,
           major_device: ^device,
           minor_device: ^minor_device,
           inode: ^inode
         }} ->
          with :ok <- run_before_remove(opts),
               {:ok, _budget} <- delete_dir_contents(path, 0, budget),
               :ok <- prove_absence(path) do
            :ok
          end

        {:ok, %File.Stat{}} ->
          {:error, :cleanup_identity_mismatch}

        {:error, _reason} ->
          {:error, :cleanup_stat_failed}
      end
    end
  rescue
    _error -> {:error, :cleanup_failed}
  catch
    _kind, _reason -> {:error, :cleanup_failed}
  end

  def remove(_identity, _opts), do: {:error, :cleanup_identity_mismatch}

  defp finish_private_create(path, opts) do
    identity_result =
      if Keyword.get(opts, :force_identity_capture_failure, false) do
        {:error, :root_identity_capture_failed}
      else
        capture_identity_with_retry(path, @identity_capture_attempts)
      end

    case identity_result do
      {:ok, identity} ->
        with :ok <- chmod_private(path),
             :ok <- verify_identity(identity) do
          {:ok, identity}
        else
          {:error, reason} -> cleanup_failed_create(identity, reason)
        end

      {:error, reason} ->
        {:error,
         {:owned_tree_cleanup_retained, reason,
          %{
            path: path,
            identity: nil
          }}}
    end
  end

  defp cleanup_failed_create(identity, reason) do
    case remove(identity) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error,
         {:owned_tree_cleanup_retained, {reason, cleanup_reason},
          %{
            path: identity.path,
            identity: identity
          }}}
    end
  end

  defp validate_path(path) do
    cond do
      path == "" -> {:error, :invalid_owned_tree_path}
      byte_size(path) > @max_path_bytes -> {:error, :invalid_owned_tree_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_owned_tree_path}
      Path.type(path) != :absolute -> {:error, :invalid_owned_tree_path}
      true -> :ok
    end
  end

  defp capture_identity_with_retry(_path, attempts_left) when attempts_left <= 0,
    do: {:error, :root_identity_capture_failed}

  defp capture_identity_with_retry(path, attempts_left) do
    case capture_identity(path) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, :stat_failed} when attempts_left > 1 ->
        Process.sleep(1)
        capture_identity_with_retry(path, attempts_left - 1)

      {:error, :stat_failed} ->
        {:error, :root_identity_capture_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: device,
         minor_device: minor_device,
         inode: inode
       }}
      when is_integer(device) and device >= 0 and is_integer(minor_device) and
             minor_device >= 0 and is_integer(inode) and inode >= 0 ->
        {:ok,
         %{
           path: path,
           type: :directory,
           device: device,
           minor_device: minor_device,
           inode: inode
         }}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_directory}

      {:error, _reason} ->
        {:error, :stat_failed}
    end
  end

  defp chmod_private(path) do
    case File.chmod(path, 0o700) do
      :ok -> :ok
      {:error, _reason} -> {:error, :owned_tree_chmod_failed}
    end
  end

  defp verify_identity(%{
         path: path,
         type: :directory,
         device: device,
         minor_device: minor_device,
         inode: inode
       }) do
    case File.lstat(path, time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: ^device,
         minor_device: ^minor_device,
         inode: ^inode
       }} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :cleanup_identity_mismatch}

      {:error, _reason} ->
        {:error, :cleanup_stat_failed}
    end
  end

  defp run_before_remove(opts) do
    case Keyword.get(opts, :before_remove) do
      nil -> :ok
      callback when is_function(callback, 0) -> callback.()
      _other -> {:error, :invalid_cleanup_callback}
    end
  end

  defp cleanup_budget(opts) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    listing_heap_words =
      Keyword.get(opts, :listing_heap_words, @default_listing_heap_words)

    if is_integer(max_entries) and max_entries > 0 and max_entries <= @max_entries and
         is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms and
         is_integer(listing_heap_words) and listing_heap_words >= @min_listing_heap_words and
         listing_heap_words <= @max_listing_heap_words do
      {:ok,
       %{
         remaining_entries: max_entries,
         listing_heap_words: listing_heap_words,
         deadline_ms: System.monotonic_time(:millisecond) + timeout_ms
       }}
    else
      {:error, :invalid_cleanup_budget}
    end
  end

  defp delete_dir_contents(path, depth, budget) do
    with :ok <- check_cleanup_deadline(budget) do
      do_delete_dir_contents(path, depth, budget)
    end
  end

  defp do_delete_dir_contents(path, depth, budget) do
    case start_directory_listing(path, depth, budget) do
      {:ok, listing} ->
        consume_directory_listing(listing, path, depth, budget)

      {:error, :cleanup_directory_absent} ->
        {:ok, budget}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_entry(path, depth, budget) do
    with :ok <- check_cleanup_deadline(budget),
         :ok <- validate_cleanup_child_path(path) do
      do_delete_entry(path, depth, budget)
    end
  end

  defp do_delete_entry(path, depth, budget) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        delete_dir_contents(path, depth, budget)

      {:ok, %File.Stat{}} ->
        case unlink_path(path) do
          :ok -> {:ok, budget}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, budget}

      {:error, _reason} ->
        {:error, :cleanup_stat_failed}
    end
  end

  defp consume_cleanup_entry(%{remaining_entries: remaining} = budget) when remaining > 0 do
    with :ok <- check_cleanup_deadline(budget) do
      {:ok, %{budget | remaining_entries: remaining - 1}}
    end
  end

  defp consume_cleanup_entry(_budget), do: {:error, :cleanup_entry_budget_exceeded}

  defp consume_directory_listing(listing, path, depth, budget) do
    case next_directory_entry(listing, budget) do
      {:ok, :done} ->
        with :ok <- check_cleanup_deadline(budget),
             :ok <- rmdir(path) do
          {:ok, budget}
        end

      {:ok, {:entry, name}} ->
        child_path = Path.join(path, name)

        with {:ok, next_budget} <- consume_cleanup_entry(budget),
             {:ok, next_budget} <- delete_entry(child_path, depth + 1, next_budget) do
          consume_directory_listing(listing, path, depth, next_budget)
        else
          {:error, reason} ->
            stop_directory_listing(listing, budget)
            {:error, reason}
        end

      {:error, reason} ->
        stop_directory_listing(listing, budget)
        {:error, reason}
    end
  end

  defp start_directory_listing(path, depth, budget) do
    parent = self()
    token = make_ref()
    heap_words = listing_heap_words(budget.listing_heap_words, depth)

    {pid, monitor_ref} =
      spawn_monitor(fn -> directory_listing_worker(parent, token, path, heap_words) end)

    receive_listing_ready(pid, monitor_ref, token, budget)
  end

  defp receive_listing_ready(pid, monitor_ref, token, budget) do
    case remaining_cleanup_ms(budget) do
      remaining when remaining > 0 ->
        receive do
          {^token, :ready} ->
            {:ok, %{pid: pid, monitor_ref: monitor_ref, token: token}}

          {^token, {:error, :enoent}} ->
            Process.demonitor(monitor_ref, [:flush])
            {:error, :cleanup_directory_absent}

          {^token, {:error, _reason}} ->
            Process.demonitor(monitor_ref, [:flush])
            {:error, :cleanup_list_failed}

          {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
            {:error, :cleanup_listing_memory_budget_exceeded}

          {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
            {:error, :cleanup_listing_worker_failed}
        after
          remaining ->
            stop_directory_listing(
              %{pid: pid, monitor_ref: monitor_ref, token: token},
              budget
            )

            {:error, :cleanup_time_budget_exceeded}
        end

      _expired ->
        stop_directory_listing(%{pid: pid, monitor_ref: monitor_ref, token: token}, budget)
        {:error, :cleanup_time_budget_exceeded}
    end
  end

  defp next_directory_entry(listing, budget) do
    send(listing.pid, {listing.token, :next})

    case remaining_cleanup_ms(budget) do
      remaining when remaining > 0 ->
        receive do
          {token, {:entry, name}}
          when token == listing.token and is_binary(name) and name not in ["", ".", ".."] ->
            {:ok, {:entry, name}}

          {token, :done} when token == listing.token ->
            Process.demonitor(listing.monitor_ref, [:flush])
            {:ok, :done}

          {:DOWN, ref, :process, pid, :killed}
          when ref == listing.monitor_ref and pid == listing.pid ->
            {:error, :cleanup_listing_memory_budget_exceeded}

          {:DOWN, ref, :process, pid, _reason}
          when ref == listing.monitor_ref and pid == listing.pid ->
            {:error, :cleanup_listing_worker_failed}
        after
          remaining -> {:error, :cleanup_time_budget_exceeded}
        end

      _expired ->
        {:error, :cleanup_time_budget_exceeded}
    end
  end

  defp directory_listing_worker(parent, token, path, heap_words) do
    parent_ref = Process.monitor(parent)

    Process.flag(:max_heap_size, %{
      size: heap_words,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    case File.ls(path) do
      {:ok, names} ->
        send(parent, {token, :ready})
        serve_directory_entries(parent, parent_ref, token, names)

      {:error, reason} ->
        send(parent, {token, {:error, reason}})
    end
  rescue
    _error -> send(parent, {token, {:error, :listing_failed}})
  catch
    _kind, _reason -> send(parent, {token, {:error, :listing_failed}})
  end

  defp serve_directory_entries(parent, parent_ref, token, [name | rest]) do
    receive do
      {^token, :next} ->
        send(parent, {token, {:entry, name}})
        serve_directory_entries(parent, parent_ref, token, rest)

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp serve_directory_entries(parent, parent_ref, token, []) do
    receive do
      {^token, :next} -> send(parent, {token, :done})
      {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
    end
  end

  defp stop_directory_listing(%{pid: pid, monitor_ref: monitor_ref, token: token}, budget) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    wait_ms = min(remaining_cleanup_ms(budget), 100)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      wait_ms -> Process.demonitor(monitor_ref, [:flush])
    end

    flush_directory_listing_messages(token)
    :ok
  end

  defp flush_directory_listing_messages(token) do
    receive do
      {^token, _message} -> flush_directory_listing_messages(token)
    after
      0 -> :ok
    end
  end

  defp listing_heap_words(total, depth) do
    shift = min(depth, @listing_depth_shift_cap)
    max(@min_listing_heap_words, div(total, :erlang.bsl(1, shift)))
  end

  defp validate_cleanup_child_path(path) when is_binary(path) do
    if byte_size(path) <= @max_path_bytes,
      do: :ok,
      else: {:error, :cleanup_path_budget_exceeded}
  end

  defp remaining_cleanup_ms(budget) do
    max(budget.deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp check_cleanup_deadline(budget) do
    if remaining_cleanup_ms(budget) > 0,
      do: :ok,
      else: {:error, :cleanup_time_budget_exceeded}
  end

  defp unlink_path(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :cleanup_rm_failed}
    end
  end

  defp rmdir(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :cleanup_rmdir_failed}
    end
  end

  defp prove_absence(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :cleanup_path_remains}
      {:error, _reason} -> {:error, :cleanup_status_unknown}
    end
  end
end
