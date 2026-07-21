defmodule Arbor.Actions.Coding.WorkspaceRetentionInventory do
  @moduledoc """
  Read-only fallback inventory for coding workspace retention markers.

  This path is used by operator tooling when the live registry is not already
  running. It deliberately does not start the durable store or registry and
  never repairs stale files, arms timers, or performs cleanup.
  """

  alias Arbor.Actions.Config
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Actions.Git
  alias Arbor.Common.SafePath

  @record_mode 0o600
  @root_mode 0o700
  @max_names Core.max_records() * 4

  @spec snapshot(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def snapshot(repo_path, opts \\ [])

  def snapshot(repo_path, opts) when is_binary(repo_path) and is_list(opts) do
    journal_path = Keyword.get(opts, :journal_path, Config.workspace_retention_journal_path())

    with {:ok, root, root_stat, parent, parent_stat} <- read_only_root(journal_path),
         {:ok, keys, values} <- read_only_values(root, root_stat, parent, parent_stat),
         {:ok, records} <- Core.decode_inventory(keys, values),
         :ok <- validate_record_count(records, opts),
         {:ok, entries} <- protection_entries(repo_path, records) do
      {:ok, entries}
    end
  end

  def snapshot(_repo_path, _opts), do: {:error, :retention_inventory_unavailable}

  defp read_only_root(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      expanded = Path.expand(path)
      parent = Path.dirname(expanded)

      with {:ok, %File.Stat{type: :directory} = parent_stat} <- File.lstat(parent),
           :ok <- safe_parent_directory?(parent_stat),
           {:ok, canonical_parent} <- SafePath.resolve_real(parent),
           {:ok, %File.Stat{type: :directory} = root_stat} <- File.lstat(expanded),
           :ok <- private_root_directory?(root_stat, parent_stat.uid),
           {:ok, canonical_root} <- SafePath.resolve_real(expanded),
           true <- Path.dirname(canonical_root) == canonical_parent do
        {:ok, canonical_root, root_stat, canonical_parent, parent_stat}
      else
        {:error, :enoent} -> {:error, :retention_inventory_unavailable}
        false -> {:error, :retention_inventory_identity_changed}
        {:error, reason} -> {:error, {:retention_inventory_unavailable, reason}}
        _other -> {:error, :retention_inventory_unavailable}
      end
    else
      {:error, :retention_inventory_unavailable}
    end
  end

  defp read_only_root(_), do: {:error, :retention_inventory_unavailable}

  defp safe_parent_directory?(%File.Stat{mode: mode}) do
    if Bitwise.band(mode, 0o022) == 0,
      do: :ok,
      else: {:error, :retention_inventory_parent_permissions}
  end

  defp private_root_directory?(%File.Stat{uid: uid, mode: mode}, expected_uid) do
    mode = Bitwise.band(mode, 0o777)

    cond do
      not is_nil(expected_uid) and uid != expected_uid ->
        {:error, :retention_inventory_owner_mismatch}

      mode != @root_mode ->
        {:error, :retention_inventory_permissions}

      true ->
        :ok
    end
  end

  defp read_only_values(root, root_stat, parent, parent_stat) do
    with {:ok, names} <- File.ls(root),
         names <- Enum.sort(names),
         true <- length(names) <= @max_names,
         {:ok, keys} <- record_keys(names),
         {:ok, values, total_bytes} <- read_record_values(root, root_stat.uid, keys),
         true <- total_bytes <= Core.max_aggregate_inventory_bytes(),
         :ok <- revalidate_directory(parent, parent_stat, :parent),
         :ok <- revalidate_directory(root, root_stat, :root),
         {:ok, current_names} <- File.ls(root),
         :ok <- require_same_names(names, current_names) do
      {:ok, keys, values}
    else
      false -> {:error, :retention_inventory_oversized}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :retention_inventory_unavailable}
    end
  end

  defp record_keys(names) do
    names = Enum.sort(names)

    if Enum.all?(names, fn name -> is_binary(name) and String.ends_with?(name, ".json") end) do
      keys = Enum.map(names, &String.replace_suffix(&1, ".json", ""))

      if Enum.all?(keys, &Core.retained_key?/1),
        do: {:ok, keys},
        else: {:error, :invalid_retention_inventory_filename}
    else
      # A temp or unknown file is evidence that the durable inventory cannot be
      # interpreted completely. The live store may clean temps; this reader may not.
      {:error, :invalid_retention_inventory_filename}
    end
  end

  defp read_record_values(root, root_uid, keys) do
    Enum.reduce_while(keys, {:ok, %{}, 0}, fn key, {:ok, values, total_bytes} ->
      path = Path.join(root, key <> ".json")

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, uid: ^root_uid, mode: mode, size: size} = before} ->
          if Bitwise.band(mode, 0o777) != @record_mode or size > Core.max_snapshot_bytes() do
            {:halt, {:error, :invalid_retention_record_file}}
          else
            case File.read(path) do
              {:ok, body} when byte_size(body) == size ->
                case File.lstat(path) do
                  {:ok, %File.Stat{} = after_stat} ->
                    if file_identity(before) == file_identity(after_stat) do
                      case Core.decode_json_bytes(body) do
                        {:ok, value} ->
                          {:cont, {:ok, Map.put(values, key, value), total_bytes + size}}

                        {:error, reason} ->
                          {:halt, {:error, {:corrupt_retention_record, key, reason}}}
                      end
                    else
                      {:halt, {:error, {:retention_inventory_drift, key}}}
                    end

                  {:error, reason} ->
                    {:halt, {:error, {:retention_inventory_drift, {key, reason}}}}
                end

              {:ok, _body} ->
                {:halt, {:error, {:retention_inventory_drift, key}}}

              {:error, reason} ->
                {:halt, {:error, {:retention_inventory_read_failed, key, reason}}}
            end
          end

        {:ok, _stat} ->
          {:halt, {:error, {:invalid_retention_record_file, key}}}

        {:error, reason} ->
          {:halt, {:error, {:retention_inventory_read_failed, key, reason}}}
      end
    end)
  end

  defp file_identity(%File.Stat{} = stat),
    do:
      {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid,
       Bitwise.band(stat.mode, 0o777), stat.size, stat.mtime, stat.ctime}

  defp revalidate_directory(path, before, role) do
    with {:ok, %File.Stat{type: :directory} = after_stat} <- File.lstat(path),
         true <- directory_identity(before) == directory_identity(after_stat),
         {:ok, canonical} <- SafePath.resolve_real(path),
         true <- canonical == path do
      :ok
    else
      _other -> {:error, {:retention_inventory_drift, role}}
    end
  end

  defp directory_identity(%File.Stat{} = stat),
    do:
      {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid,
       Bitwise.band(stat.mode, 0o777)}

  defp require_same_names(before, after_names) do
    if before == Enum.sort(after_names),
      do: :ok,
      else: {:error, {:retention_inventory_drift, :root_entries}}
  end

  defp validate_record_count(records, opts) do
    max_entries = Keyword.get(opts, :max_entries, Core.max_records())

    if is_integer(max_entries) and max_entries > 0 and max_entries <= Core.max_records() and
         length(records) <= max_entries,
       do: :ok,
       else: {:error, :retention_inventory_oversized}
  end

  defp protection_entries(repo_path, records) do
    repo_path = canonical_path(repo_path)

    with :ok <- validate_record_branches(records) do
      records
      |> Enum.filter(&(canonical_path(&1.repo_path) == repo_path))
      |> Enum.reduce_while({:ok, %{}}, fn record, {:ok, entries} ->
        with {:ok, ref} <- branch_ref(record.branch),
             reason <- retention_reason(record) do
          {:cont, {:ok, Map.put(entries, ref, %{"ref" => ref, "reason" => reason})}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, entries |> Map.values() |> Enum.sort_by(& &1["ref"])}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp branch_ref(branch) when is_binary(branch) do
    case Git.validate_branch_name(branch) do
      :ok -> {:ok, "refs/heads/" <> branch}
      {:error, _reason} -> {:error, :invalid_retention_branch}
    end
  end

  defp branch_ref(_), do: {:error, :invalid_retention_branch}

  defp validate_record_branches(records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case branch_ref(record.branch) do
        {:ok, _ref} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_path(path) when is_binary(path) do
    case SafePath.resolve_real(path) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp canonical_path(path), do: Path.expand(to_string(path))

  defp retention_reason(%{lifecycle: "discarding", discard_phase: phase}),
    do: "discarding_workspace_ref:#{phase || "unknown"}"

  defp retention_reason(%{lifecycle: lifecycle, retry_count: retries})
       when is_binary(lifecycle) and is_integer(retries) do
    if retries >= Core.max_cleanup_retries(),
      do: "dormant_workspace_ref:#{lifecycle}",
      else: "#{lifecycle}_workspace_ref"
  end

  defp retention_reason(%{lifecycle: lifecycle}) when is_binary(lifecycle),
    do: "#{lifecycle}_workspace_ref"
end
