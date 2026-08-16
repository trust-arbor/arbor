defmodule Arbor.Shell.TrustedBuild.HexSeed do
  @moduledoc false

  alias Arbor.Shell.RegularTreeInventory
  alias Arbor.Shell.TrustedBuild.Identity

  @readonly_dir_mode 0o555
  @readonly_file_mode 0o444
  @writable_dir_mode 0o700
  @writable_file_mode 0o600

  @doc """
  Copy `source` to `dest`, then verify and finalize to `mode`'s policy.

  Three-stage copy/verify/finalize:

    1. Copy every directory and file through uniform writable temporary modes
       (0o700/0o600) regardless of the requested final policy, so every write
       succeeds even under a `:readonly` target policy.
    2. Verify copy fidelity via mode-excluded content digests of `source` and
       `dest` — comparable even though the two trees now have different modes.
    3. Finalize `dest`'s modes to the requested policy and re-lstat every entry
       to confirm the exact finalized mode landed.

  `expected_digest` is the mode-inclusive digest of the untouched `source` tree
  (as pinned by the toolchain authority) and is only used to detect drift in
  `source` itself before copying — the returned digest is `dest`'s own
  mode-inclusive digest recomputed after finalization, which is never expected
  to equal `expected_digest` since finalize deliberately changes modes.
  """
  @spec seed_tree(String.t(), String.t(), String.t(), :readonly | :writable) ::
          {:ok, String.t()} | {:error, term()}
  def seed_tree(source, dest, expected_digest, mode)
      when is_binary(source) and is_binary(dest) and is_binary(expected_digest) and
             mode in [:readonly, :writable] do
    with {:ok, ^expected_digest} <- Identity.tree_digest(source),
         {:ok, source_content_digest} <- Identity.content_digest(source),
         :ok <- copy_tree_writable(source, dest),
         {:ok, ^source_content_digest} <- Identity.content_digest(dest),
         :ok <- finalize_tree(dest, mode),
         {:ok, final_digest} <- Identity.tree_digest(dest) do
      {:ok, final_digest}
    else
      {:ok, _other} -> {:error, :hex_seed_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def seed_tree(_source, _dest, _digest, _mode), do: {:error, :invalid_hex_seed}

  @spec seed_empty_readonly(String.t()) :: {:ok, String.t()} | {:error, term()}
  def seed_empty_readonly(dest) when is_binary(dest) do
    with :ok <- mkdir_mode(dest, @readonly_dir_mode),
         {:ok, digest} <- Identity.tree_digest(dest) do
      {:ok, digest}
    end
  end

  def seed_empty_readonly(_dest), do: {:error, :invalid_hex_seed}

  # -- Stage 1: copy through uniform writable temporary modes ----------------

  defp copy_tree_writable(source, dest) do
    case RegularTreeInventory.scan_resolved(source) do
      {:ok, facts} ->
        with :ok <- mkdir_mode(dest, @writable_dir_mode) do
          copy_facts_writable(source, dest, facts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_facts_writable(source, dest, %{directories: dirs, regular_files: files}) do
    with :ok <- copy_directories_writable(dest, dirs) do
      copy_files_writable(source, dest, files)
    end
  end

  defp copy_directories_writable(_dest, []), do: :ok

  defp copy_directories_writable(dest, [%{path: rel} | rest]) do
    cond do
      rel in ["", ".", ".."] ->
        copy_directories_writable(dest, rest)

      true ->
        case mkdir_mode(Path.join(dest, rel), @writable_dir_mode) do
          :ok -> copy_directories_writable(dest, rest)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp copy_files_writable(_source, _dest, []), do: :ok

  defp copy_files_writable(source, dest, [%{path: rel} | rest]) do
    from = Path.join(source, rel)
    to = Path.join(dest, rel)

    case File.copy(from, to) do
      {:ok, _bytes} ->
        case File.chmod(to, @writable_file_mode) do
          :ok -> copy_files_writable(source, dest, rest)
          {:error, _reason} -> {:error, :hex_seed_chmod_failed}
        end

      {:error, _reason} ->
        {:error, :hex_seed_copy_failed}
    end
  end

  # -- Stage 3: finalize modes bottom-up, then verify ------------------------

  defp finalize_tree(dest, mode) do
    dir_mode = if mode == :readonly, do: @readonly_dir_mode, else: @writable_dir_mode
    file_mode = if mode == :readonly, do: @readonly_file_mode, else: @writable_file_mode

    case RegularTreeInventory.scan_resolved(dest) do
      {:ok, %{directories: dirs, regular_files: files} = facts} ->
        with :ok <- finalize_files(dest, files, file_mode),
             :ok <- finalize_directories(dest, dirs, dir_mode),
             :ok <- File.chmod(dest, dir_mode) do
          verify_final_modes(dest, facts, dir_mode, file_mode)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_files(_dest, [], _mode), do: :ok

  defp finalize_files(dest, [%{path: rel} | rest], mode) do
    case File.chmod(Path.join(dest, rel), mode) do
      :ok -> finalize_files(dest, rest, mode)
      {:error, _reason} -> {:error, :hex_seed_finalize_failed}
    end
  end

  # Deepest-first so a directory's own mode change never precedes finalizing
  # anything nested under it, even though chmod itself does not require
  # write access to the parent to change an already-existing entry's mode.
  defp finalize_directories(dest, dirs, mode) do
    dirs
    |> Enum.reject(&(&1.path in ["", ".", ".."]))
    |> Enum.sort_by(fn %{path: rel} -> -length(Path.split(rel)) end)
    |> finalize_directory_list(dest, mode)
  end

  defp finalize_directory_list([], _dest, _mode), do: :ok

  defp finalize_directory_list([%{path: rel} | rest], dest, mode) do
    case File.chmod(Path.join(dest, rel), mode) do
      :ok -> finalize_directory_list(rest, dest, mode)
      {:error, _reason} -> {:error, :hex_seed_finalize_failed}
    end
  end

  # Defense against a concurrent write landing between copy and finalize:
  # re-lstat every entry and require the exact finalized mode, not just success.
  defp verify_final_modes(dest, %{directories: dirs, regular_files: files}, dir_mode, file_mode) do
    with :ok <- verify_entry_modes(dest, files, file_mode),
         :ok <-
           verify_entry_modes(
             dest,
             Enum.reject(dirs, &(&1.path in ["", ".", ".."])),
             dir_mode
           ) do
      verify_one_mode(dest, dir_mode)
    end
  end

  defp verify_entry_modes(_dest, [], _mode), do: :ok

  defp verify_entry_modes(dest, [%{path: rel} | rest], mode) do
    with :ok <- verify_one_mode(Path.join(dest, rel), mode) do
      verify_entry_modes(dest, rest, mode)
    end
  end

  defp verify_one_mode(path, expected_mode) do
    import Bitwise

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mode: mode}} ->
        if (mode &&& 0o777) == expected_mode do
          :ok
        else
          {:error, :hex_seed_finalize_drift}
        end

      {:error, _reason} ->
        {:error, :hex_seed_finalize_drift}
    end
  end

  defp mkdir_mode(path, mode) do
    case File.mkdir_p(path) do
      :ok ->
        case File.chmod(path, mode) do
          :ok -> :ok
          {:error, _reason} -> {:error, :hex_seed_chmod_failed}
        end

      {:error, _reason} ->
        {:error, :hex_seed_mkdir_failed}
    end
  end
end
