defmodule Arbor.Commands.SafeRecoveryArtifact.TrustedInventory do
  @moduledoc false

  # Pure. Structurally admits Arbor.Shell trusted-build inventory documents
  # and segment-safely rebases a closed rel/ envelope onto exactly
  # rel/arbor_trust for the accepted E0B2B core.

  import Bitwise

  alias Arbor.Commands.SafeRecoveryArtifact.Encode

  @schema "arbor.shell.trusted_build.inventory.v1"
  @regular_tree_schema "arbor.shell.regular_tree_inventory.v1"
  @root_segment "arbor_trust"
  @cookie_path "releases/COOKIE"

  @document_keys ["counts", "directories", "kind", "regular_files", "schema"]
  @directory_keys ["mode", "path"]
  @file_keys ["executable", "mode", "path", "prefix_hex", "sha256", "size"]
  @counts_keys ["directories", "entries", "regular_files", "total_regular_bytes"]

  @max_entries 50_000
  @max_total_bytes 512 * 1024 * 1024
  @prefix_bytes 256

  @spec admit_deps(term()) :: {:ok, map()} | {:error, term()}
  def admit_deps(document), do: admit(document, "deps")

  @spec admit_release(term()) :: {:ok, map()} | {:error, term()}
  def admit_release(document), do: admit(document, "release")

  @spec project_release_root(map()) :: {:ok, map()} | {:error, term()}
  def project_release_root(admitted) do
    with {:ok, dirs, dir_roots} <- strip_directory_segment(admitted["directories"]),
         {:ok, files} <- strip_file_segment(admitted["regular_files"]),
         :ok <- require_single_root(dir_roots),
         :ok <- reject_cookie(files) do
      sorted_dirs = Enum.sort_by(dirs, & &1["path"])
      sorted_files = Enum.sort_by(files, & &1["path"])

      counts = %{
        "directories" => length(sorted_dirs),
        "regular_files" => length(sorted_files),
        "entries" => length(sorted_dirs) + length(sorted_files),
        "total_regular_bytes" => Enum.reduce(sorted_files, 0, &(&1["size"] + &2))
      }

      {:ok,
       %{
         "schema" => @regular_tree_schema,
         "directories" => sorted_dirs,
         "regular_files" => sorted_files,
         "counts" => counts
       }}
    end
  end

  @spec descriptor_selectors(map()) :: [{String.t(), String.t()}]
  def descriptor_selectors(admitted_release_doc) do
    admitted_release_doc["regular_files"]
    |> Enum.filter(&term_path?/1)
    |> Enum.map(fn file ->
      selector = file["path"]
      rebased = selector |> Path.split() |> tl() |> Path.join()
      {selector, rebased}
    end)
    |> Enum.sort_by(fn {selector, _rebased} -> selector end)
  end

  defp term_path?(%{"path" => path}) do
    String.ends_with?(path, ".app") or String.ends_with?(path, ".rel")
  end

  defp admit(document, kind) do
    with {:ok, admitted} <- Encode.admit_closed_map(document, @document_keys),
         :ok <- exact(admitted["schema"], @schema),
         :ok <- exact(admitted["kind"], kind),
         {:ok, dirs} <- admit_directories(admitted["directories"]),
         {:ok, files} <- admit_files(admitted["regular_files"]),
         {:ok, counts} <- Encode.admit_closed_map(admitted["counts"], @counts_keys),
         :ok <- require_counts(dirs, files, counts),
         :ok <- require_sorted(dirs, files) do
      {:ok, %{admitted | "directories" => dirs, "regular_files" => files, "counts" => counts}}
    end
  end

  defp exact(value, value), do: :ok
  defp exact(_value, _expected), do: {:error, :invalid_field}

  defp admit_directories(list) do
    case Encode.take_proper_list(list, @max_entries) do
      {:ok, items} -> admit_dir_items(items, [])
      error -> error
    end
  end

  defp admit_dir_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp admit_dir_items([item | rest], acc) do
    with {:ok, admitted} <- Encode.admit_closed_map(item, @directory_keys),
         :ok <- Encode.valid_path?(admitted["path"]),
         :ok <- mode_ok(admitted["mode"]) do
      admit_dir_items(rest, [admitted | acc])
    end
  end

  defp admit_files(list) do
    case Encode.take_proper_list(list, @max_entries) do
      {:ok, items} -> admit_file_items(items, [])
      error -> error
    end
  end

  defp admit_file_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp admit_file_items([item | rest], acc) do
    with {:ok, admitted} <- Encode.admit_closed_map(item, @file_keys),
         :ok <- admit_file_fields(admitted) do
      admit_file_items(rest, [admitted | acc])
    end
  end

  defp admit_file_fields(file) do
    with :ok <- Encode.valid_path?(file["path"]),
         :ok <- mode_ok(file["mode"]),
         :ok <- bool_ok(file["executable"]),
         :ok <- size_ok(file["size"]),
         :ok <- Encode.valid_digest?(file["sha256"]),
         :ok <- prefix_ok(file["prefix_hex"], file["size"]) do
      executable_agrees(file)
    end
  end

  defp mode_ok(mode) when is_integer(mode) and mode >= 0 and mode <= 0o7777, do: :ok
  defp mode_ok(_mode), do: {:error, :invalid_mode}

  defp bool_ok(value) when is_boolean(value), do: :ok
  defp bool_ok(_value), do: {:error, :not_a_boolean}

  defp size_ok(size) when is_integer(size) and size >= 0 and size <= @max_total_bytes, do: :ok
  defp size_ok(_size), do: {:error, :invalid_size}

  defp prefix_ok(hex, size) when is_binary(hex) do
    expected = 2 * min(size, @prefix_bytes)

    if byte_size(hex) == expected and Regex.match?(~r/\A[0-9a-f]*\z/, hex) do
      :ok
    else
      {:error, :invalid_digest}
    end
  end

  defp prefix_ok(_hex, _size), do: {:error, :not_a_string}

  defp executable_agrees(%{"mode" => mode, "executable" => executable}) do
    if executable == ((mode &&& 0o111) != 0) do
      :ok
    else
      {:error, :executable_mode_mismatch}
    end
  end

  defp require_counts(dirs, files, counts) do
    total = Enum.reduce(files, 0, &(&1["size"] + &2))
    entries = length(dirs) + length(files)

    cond do
      entries > @max_entries -> {:error, :unbounded}
      total > @max_total_bytes -> {:error, :unbounded}
      counts["directories"] != length(dirs) -> {:error, :inventory_counts}
      counts["regular_files"] != length(files) -> {:error, :inventory_counts}
      counts["entries"] != entries -> {:error, :inventory_counts}
      counts["total_regular_bytes"] != total -> {:error, :inventory_counts}
      true -> unique_paths(dirs, files)
    end
  end

  defp unique_paths(dirs, files) do
    paths = Enum.map(dirs, & &1["path"]) ++ Enum.map(files, & &1["path"])

    if length(Enum.uniq(paths)) == length(paths) do
      :ok
    else
      {:error, :duplicate_path}
    end
  end

  defp require_sorted(dirs, files) do
    dir_paths = Enum.map(dirs, & &1["path"])
    file_paths = Enum.map(files, & &1["path"])

    if dir_paths == Enum.sort(dir_paths) and file_paths == Enum.sort(file_paths) do
      :ok
    else
      {:error, :inventory_not_sorted}
    end
  end

  # Only a directory row may legitimately BE the root: "arbor_trust" is
  # created as a directory by the trusted-build workspace layout, so this is
  # the sole place a bare [@root_segment] match is dropped-and-counted
  # rather than rejected.
  defp strip_directory_segment(rows) do
    result =
      Enum.reduce_while(rows, {:ok, [], 0}, fn row, {:ok, acc, root_count} ->
        case Path.split(row["path"]) do
          [@root_segment] ->
            {:cont, {:ok, acc, root_count + 1}}

          [@root_segment | [_ | _] = rest] ->
            {:cont, {:ok, [%{row | "path" => Path.join(rest)} | acc], root_count}}

          _other ->
            {:halt, {:error, :release_root_segment_mismatch}}
        end
      end)

    case result do
      {:ok, acc, root_count} -> {:ok, Enum.reverse(acc), root_count}
      error -> error
    end
  end

  # A regular file can never legitimately BE the root -- a bare
  # [@root_segment] here is rejected outright, never silently dropped and
  # never counted toward require_single_root/1, regardless of whether a
  # genuine directory root row is also present.
  defp strip_file_segment(rows) do
    result =
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        case Path.split(row["path"]) do
          [@root_segment] ->
            {:halt, {:error, :release_root_not_a_directory}}

          [@root_segment | [_ | _] = rest] ->
            {:cont, {:ok, [%{row | "path" => Path.join(rest)} | acc]}}

          _other ->
            {:halt, {:error, :release_root_segment_mismatch}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp require_single_root(1), do: :ok
  defp require_single_root(_other), do: {:error, :release_root_row_count}

  defp reject_cookie(files) do
    if Enum.any?(files, &(&1["path"] == @cookie_path)) do
      {:error, :cookie_present}
    else
      :ok
    end
  end
end
