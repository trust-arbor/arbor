defmodule Arbor.Shell.TrustedBuild.HexSeed do
  @moduledoc false

  alias Arbor.Shell.RegularTreeInventory
  alias Arbor.Shell.TrustedBuild.Identity

  @spec seed_tree(String.t(), String.t(), String.t(), :readonly | :writable) ::
          {:ok, String.t()} | {:error, term()}
  def seed_tree(source, dest, expected_digest, mode)
      when is_binary(source) and is_binary(dest) and is_binary(expected_digest) and
             mode in [:readonly, :writable] do
    with {:ok, ^expected_digest} <- Identity.tree_digest(source),
         :ok <- copy_tree(source, dest, mode),
         {:ok, ^expected_digest} <- Identity.tree_digest(dest) do
      {:ok, expected_digest}
    else
      {:ok, _other} -> {:error, :hex_seed_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def seed_tree(_source, _dest, _digest, _mode), do: {:error, :invalid_hex_seed}

  @spec seed_empty_readonly(String.t()) :: {:ok, String.t()} | {:error, term()}
  def seed_empty_readonly(dest) when is_binary(dest) do
    with :ok <- mkdir_mode(dest, 0o555),
         {:ok, digest} <- Identity.tree_digest(dest) do
      {:ok, digest}
    end
  end

  def seed_empty_readonly(_dest), do: {:error, :invalid_hex_seed}

  defp copy_tree(source, dest, mode) do
    case RegularTreeInventory.scan_resolved(source) do
      {:ok, facts} ->
        dest_mode = if mode == :readonly, do: 0o555, else: 0o700
        file_mode = if mode == :readonly, do: 0o444, else: 0o600

        with :ok <- mkdir_mode(dest, dest_mode) do
          copy_facts(source, dest, facts, dest_mode, file_mode)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_facts(source, dest, %{directories: dirs, regular_files: files}, dest_mode, file_mode) do
    with :ok <- copy_directories(source, dest, dirs, dest_mode) do
      copy_files(source, dest, files, file_mode)
    end
  end

  defp copy_directories(_source, _dest, [], _mode), do: :ok

  defp copy_directories(source, dest, [%{path: rel} | rest], mode) do
    cond do
      rel in ["", ".", ".."] ->
        copy_directories(source, dest, rest, mode)

      true ->
        case mkdir_mode(Path.join(dest, rel), mode) do
          :ok -> copy_directories(source, dest, rest, mode)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp copy_files(_source, _dest, [], _mode), do: :ok

  defp copy_files(source, dest, [%{path: rel} | rest], mode) do
    from = Path.join(source, rel)
    to = Path.join(dest, rel)

    case File.copy(from, to) do
      {:ok, _bytes} ->
        case File.chmod(to, mode) do
          :ok -> copy_files(source, dest, rest, mode)
          {:error, _reason} -> {:error, :hex_seed_chmod_failed}
        end

      {:error, _reason} ->
        {:error, :hex_seed_copy_failed}
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
