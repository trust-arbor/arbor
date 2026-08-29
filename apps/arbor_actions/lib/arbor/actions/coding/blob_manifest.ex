defmodule Arbor.Actions.Coding.BlobManifest do
  @moduledoc """
  Pure path/mode/blob snapshot primitives shared by coding validators.

  Diff and ls-tree parse are policy-free: callers decide what the changed paths
  mean. Cross-app topology and contract-change applicability stay in their cores.
  """

  @max_changed_files 2_000
  @max_entries 50_000
  @full_oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @blob_modes ["100644", "100755", "120000"]

  @type entry :: %{
          path: String.t(),
          mode: String.t(),
          oid: String.t()
        }

  @doc false
  @spec max_changed_files() :: pos_integer()
  def max_changed_files, do: @max_changed_files

  @doc false
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  Derive changed relative paths from two immutable path/mode/blob manifests.

  An entry is changed when present on only one side or when mode/oid differ.
  Paths are sorted and bounded; the full manifests are never returned.
  """
  @spec diff_blob_manifests(term(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def diff_blob_manifests(base_manifest, candidate_manifest)
      when is_list(base_manifest) and is_list(candidate_manifest) do
    with {:ok, base_map} <- manifest_to_map(base_manifest),
         {:ok, cand_map} <- manifest_to_map(candidate_manifest) do
      paths =
        MapSet.union(MapSet.new(Map.keys(base_map)), MapSet.new(Map.keys(cand_map)))
        |> MapSet.to_list()
        |> Enum.sort()

      changed =
        Enum.filter(paths, fn path ->
          Map.get(base_map, path) != Map.get(cand_map, path)
        end)

      if length(changed) > @max_changed_files do
        {:error, :too_many_changed_files}
      else
        {:ok, changed}
      end
    end
  end

  def diff_blob_manifests(_, _), do: {:error, :invalid_blob_manifest}

  @doc "Parse a `git ls-tree -r -z` listing into a sorted blob manifest."
  @spec parse_ls_tree_z(term()) :: {:ok, [entry()]} | {:error, term()}
  def parse_ls_tree_z(listing) when is_binary(listing) do
    listing
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, acc, count} ->
      next = count + 1

      cond do
        entry == "" ->
          {:cont, {:ok, acc, count}}

        next > @max_entries ->
          {:halt, {:error, :blob_manifest_too_large}}

        true ->
          case parse_ls_tree_entry(entry) do
            {:ok, compact} ->
              {:cont, {:ok, [compact | acc], next}}

            {:error, _} = error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, entries, _count} ->
        {:ok, Enum.sort_by(entries, & &1.path)}

      {:error, _} = error ->
        error
    end
  end

  def parse_ls_tree_z(_), do: {:error, :invalid_blob_manifest}

  @doc "Validate and return a canonical path-sorted blob manifest."
  @spec canonical_entries(term()) :: {:ok, [entry()]} | {:error, term()}
  def canonical_entries(entries) when is_list(entries) do
    if length(entries) > @max_entries do
      {:error, :blob_manifest_too_large}
    else
      entries
      |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
        case normalize_manifest_entry(entry) do
          {:ok, path, mode, oid} ->
            if Map.has_key?(acc, path) do
              {:halt, {:error, {:duplicate_blob_manifest_path, path}}}
            else
              {:cont, {:ok, Map.put(acc, path, %{path: path, mode: mode, oid: oid})}}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, by_path} -> {:ok, by_path |> Map.values() |> Enum.sort_by(& &1.path)}
        {:error, _} = error -> error
      end
    end
  end

  def canonical_entries(_), do: {:error, :invalid_blob_manifest}

  @doc false
  @spec paths(term()) :: {:ok, [String.t()]} | {:error, term()}
  def paths(manifest) do
    with {:ok, entries} <- canonical_entries(manifest) do
      {:ok, Enum.map(entries, & &1.path)}
    end
  end

  @doc false
  @spec infer_object_format(term(), term()) ::
          {:ok, :sha1 | :sha256} | {:error, :mixed_object_format}
  def infer_object_format(tree_oid, entries)
      when is_binary(tree_oid) and is_list(entries) do
    case valid_oid_length(tree_oid) do
      length when length in [40, 64] ->
        if Enum.any?(entries, &(valid_entry_oid_length(&1) != length)) do
          {:error, :mixed_object_format}
        else
          format_for_length(length)
        end

      _other ->
        {:error, :mixed_object_format}
    end
  end

  def infer_object_format(_tree_oid, _entries), do: {:error, :mixed_object_format}

  defp parse_ls_tree_entry(entry) when is_binary(entry) do
    case :binary.split(entry, "\t") do
      [meta, path] when path != "" ->
        case String.split(meta, " ", parts: 3) do
          [mode, "blob", oid] when mode in @blob_modes ->
            if Regex.match?(@full_oid_re, oid) do
              {:ok, %{path: path, mode: mode, oid: oid}}
            else
              {:error, {:invalid_base_blob_oid, path}}
            end

          [_mode, "commit", _oid] ->
            {:error, {:unsupported_base_gitlink, path}}

          [_mode, "tree", _oid] ->
            {:error, {:unexpected_base_tree_entry, path}}

          _ ->
            {:error, {:invalid_base_ls_tree_entry, path}}
        end

      _ ->
        {:error, :invalid_base_ls_tree_entry}
    end
  end

  defp manifest_to_map(entries) when is_list(entries) do
    with {:ok, canonical} <- canonical_entries(entries) do
      {:ok, Map.new(canonical, &{&1.path, {&1.mode, &1.oid}})}
    end
  end

  defp normalize_manifest_entry(%{path: path, mode: mode, oid: oid})
       when is_binary(path) and is_binary(mode) and is_binary(oid) do
    normalize_manifest_fields(path, mode, oid)
  end

  defp normalize_manifest_entry(%{"path" => path, "mode" => mode, "oid" => oid})
       when is_binary(path) and is_binary(mode) and is_binary(oid) do
    normalize_manifest_fields(path, mode, oid)
  end

  defp normalize_manifest_entry(_), do: {:error, :invalid_blob_manifest_entry}

  defp normalize_manifest_fields(path, mode, oid) do
    cond do
      not valid_blob_path?(path) ->
        {:error, :invalid_blob_manifest_path}

      mode not in @blob_modes ->
        {:error, {:unsupported_blob_manifest_mode, mode}}

      not Regex.match?(@full_oid_re, oid) ->
        {:error, :invalid_blob_manifest_oid}

      true ->
        {:ok, path, mode, oid}
    end
  end

  defp valid_blob_path?(path) when is_binary(path) do
    path != "" and String.valid?(path) and not String.contains?(path, <<0>>) and
      not String.contains?(path, "\\") and not String.starts_with?(path, "/") and
      valid_blob_segments?(String.split(path, "/"))
  end

  defp valid_blob_path?(_), do: false

  defp valid_blob_segments?([_ | _] = segments) do
    Enum.all?(segments, fn segment -> segment not in ["", ".", ".."] end)
  end

  defp valid_blob_segments?(_), do: false

  defp format_for_length(40), do: {:ok, :sha1}
  defp format_for_length(64), do: {:ok, :sha256}

  defp valid_oid_length(oid) when is_binary(oid) do
    if Regex.match?(@full_oid_re, oid), do: byte_size(oid), else: -1
  end

  defp valid_oid_length(_), do: -1

  defp valid_entry_oid_length(%{oid: oid}), do: valid_oid_length(oid)
  defp valid_entry_oid_length(%{"oid" => oid}), do: valid_oid_length(oid)
  defp valid_entry_oid_length(_), do: -1
end
