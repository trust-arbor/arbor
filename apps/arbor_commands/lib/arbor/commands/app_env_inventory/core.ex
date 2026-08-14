defmodule Arbor.Commands.AppEnvInventory.Core do
  @moduledoc """
  CRC construct/classify/show for the retired app-env inventory.

  Pure: accepts an in-memory scan bundle and returns a report map.
  """

  alias Arbor.Commands.AppEnvInventory.{Ast, Encode}

  @report_schema "arbor.packaging.app_env_inventory.v1"
  @legacy_owners [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]
  @accepted_modes MapSet.new(["100644", "100755"])
  @accepted_formats MapSet.new(["sha1", "sha256"])
  @accepted_sources MapSet.new(["git_index_blobs", "test_injection"])
  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @count_classes ["production", "test_support", "config_block"]
  @count_trusts ["literal", "resolved", "untrusted"]
  @count_owners [
    "arbor_contracts",
    "arbor_common",
    "arbor_signals",
    "arbor_monitor",
    "unresolved"
  ]

  @doc "Closed legacy owners. Duplicated here so commands does not depend on arbor_kernel."
  @spec legacy_owners() :: [atom()]
  def legacy_owners, do: @legacy_owners

  @doc false
  @spec git_blob_oid(binary(), String.t()) :: String.t()
  def git_blob_oid(bytes, "sha1") when is_binary(bytes) do
    hash_blob_oid(:sha, bytes)
  end

  def git_blob_oid(bytes, "sha256") when is_binary(bytes) do
    hash_blob_oid(:sha256, bytes)
  end

  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(bundle) when is_map(bundle) do
    with {:ok, files} <- fetch_required_files(bundle),
         {:ok, tree_oid} <- fetch_required(bundle, :tree_oid, :missing_provenance),
         {:ok, object_format} <- fetch_required(bundle, :object_format, :missing_provenance),
         {:ok, provenance_source} <-
           fetch_required(bundle, :provenance_source, :missing_provenance),
         :ok <- validate_provenance(tree_oid, object_format, provenance_source),
         :ok <- validate_files(files, object_format),
         {:ok, findings} <- extract_all(files) do
      findings = Enum.sort_by(findings, &finding_sort_key/1)
      counts = count_findings(findings)

      manifest_triples =
        files
        |> Enum.map(&{file_path(&1), file_mode(&1), file_oid(&1)})
        |> Enum.sort_by(&elem(&1, 0))

      case Encode.scan_manifest_digest(manifest_triples) do
        {:ok, digest} ->
          report = %{
            "schema" => @report_schema,
            "mode" => "report",
            "status" => if(counts["total"] == 0, do: "clean", else: "residue"),
            "output" => "human",
            "legacy_owners" => Enum.map(@legacy_owners, &Atom.to_string/1),
            "target_app" => "arbor_kernel",
            "counts" => counts,
            "findings" => findings,
            "provenance" => %{
              "tree_oid" => tree_oid,
              "scan_manifest_digest" => digest,
              "object_format" => object_format,
              "provenance_source" => provenance_source
            }
          }

          {:ok, report}

        {:error, _} = err ->
          err
      end
    end
  end

  def project(_), do: {:error, :invalid_bundle}

  @spec show(map(), keyword()) :: map()
  def show(report, opts) when is_map(report) and is_list(opts) do
    mode = Keyword.get(opts, :mode, "report")
    output = Keyword.get(opts, :output, "human")

    report
    |> Map.put("mode", mode)
    |> Map.put("output", output)
  end

  defp hash_blob_oid(algo, bytes) do
    :crypto.hash(algo, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    |> Base.encode16(case: :lower)
  end

  defp fetch_required_files(bundle) do
    case fetch_required(bundle, :files, :missing_files) do
      {:ok, files} when is_list(files) -> {:ok, files}
      {:ok, _} -> {:error, :invalid_files}
      {:error, _} = err -> err
    end
  end

  defp fetch_required(bundle, key, missing_tag) do
    cond do
      Map.has_key?(bundle, key) ->
        present_or_missing(Map.fetch!(bundle, key), key, missing_tag)

      Map.has_key?(bundle, Atom.to_string(key)) ->
        present_or_missing(Map.fetch!(bundle, Atom.to_string(key)), key, missing_tag)

      true ->
        {:error, {missing_tag, key}}
    end
  end

  defp present_or_missing(nil, key, missing_tag), do: {:error, {missing_tag, key}}
  defp present_or_missing(value, _key, _missing_tag), do: {:ok, value}

  defp validate_provenance(tree_oid, object_format, provenance_source) do
    cond do
      object_format not in @accepted_formats ->
        {:error, :invalid_object_format}

      provenance_source not in @accepted_sources ->
        {:error, :invalid_provenance_source}

      not is_binary(tree_oid) ->
        {:error, :invalid_tree_oid}

      not valid_oid?(tree_oid) ->
        {:error, {:invalid_tree_oid, tree_oid}}

      not oid_matches_format?(tree_oid, object_format) ->
        {:error, {:oid_format_mismatch, :tree}}

      true ->
        :ok
    end
  end

  defp validate_files(files, object_format) when is_list(files) do
    Enum.reduce_while(files, {:ok, MapSet.new()}, fn file, {:ok, seen} ->
      case validate_file(file, object_format, seen) do
        {:ok, path} -> {:cont, {:ok, MapSet.put(seen, path)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp validate_files(_, _), do: {:error, :invalid_files}

  defp validate_file(file, object_format, seen) when is_map(file) do
    path = file_path(file)
    oid = file_oid(file)
    bytes = file_bytes(file)
    mode = file_mode(file)

    cond do
      not is_binary(path) or not is_binary(oid) or not is_binary(bytes) ->
        {:error, :invalid_files}

      not valid_repo_path?(path) ->
        {:error, {:invalid_path, path}}

      MapSet.member?(seen, path) ->
        {:error, {:duplicate_paths, path}}

      not valid_oid?(oid) ->
        {:error, {:invalid_oid, oid}}

      not oid_matches_format?(oid, object_format) ->
        {:error, {:oid_format_mismatch, path}}

      mode not in @accepted_modes ->
        {:error, {:invalid_mode, mode, path}}

      not matching_declared_size?(file, bytes) ->
        {:error, {:invalid_byte_size, path}}

      git_blob_oid(bytes, object_format) != oid ->
        {:error, {:oid_content_mismatch, path}}

      true ->
        {:ok, path}
    end
  end

  defp validate_file(_, _, _), do: {:error, :invalid_files}

  defp valid_oid?(oid) when is_binary(oid), do: Regex.match?(@oid_re, oid)
  defp valid_oid?(_), do: false

  defp oid_matches_format?(oid, "sha1"), do: byte_size(oid) == 40
  defp oid_matches_format?(oid, "sha256"), do: byte_size(oid) == 64
  defp oid_matches_format?(_, _), do: false

  defp valid_repo_path?(path) when is_binary(path) do
    cond do
      path == "" ->
        false

      not String.valid?(path) ->
        false

      String.contains?(path, <<0>>) ->
        false

      String.starts_with?(path, "/") ->
        false

      String.contains?(path, "\\") ->
        false

      String.starts_with?(path, ":") ->
        false

      String.contains?(path, "*") ->
        false

      String.contains?(path, "?") ->
        false

      String.contains?(path, "[") ->
        false

      String.contains?(path, "]") ->
        false

      String.contains?(path, "~") ->
        false

      path |> String.split("/") |> Enum.any?(&(&1 in ["..", "", "."])) ->
        false

      true ->
        true
    end
  end

  defp valid_repo_path?(_), do: false

  defp matching_declared_size?(file, bytes) do
    case declared_byte_size(file) do
      :absent -> true
      size when is_integer(size) and size >= 0 -> size == byte_size(bytes)
      _ -> false
    end
  end

  defp extract_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      path = file_path(file)
      bytes = file_bytes(file)

      case Ast.extract(path, bytes) do
        {:ok, findings} -> {:cont, {:ok, acc ++ findings}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp file_path(%{path: path}), do: path
  defp file_path(%{"path" => path}), do: path
  defp file_path(_), do: nil

  defp file_oid(%{blob_oid: oid}), do: oid
  defp file_oid(%{"blob_oid" => oid}), do: oid
  defp file_oid(_), do: nil

  defp file_bytes(%{bytes: bytes}), do: bytes
  defp file_bytes(%{"bytes" => bytes}), do: bytes
  defp file_bytes(_), do: nil

  defp file_mode(%{mode: mode}), do: mode
  defp file_mode(%{"mode" => mode}), do: mode
  defp file_mode(_), do: nil

  defp declared_byte_size(%{byte_size: size}), do: size
  defp declared_byte_size(%{"byte_size" => size}), do: size
  defp declared_byte_size(%{size: size}), do: size
  defp declared_byte_size(%{"size" => size}), do: size
  defp declared_byte_size(_), do: :absent

  defp finding_sort_key(finding) do
    {finding["path"], finding["line"], finding["column"], finding["form"]}
  end

  defp count_findings(findings) do
    by_class = count_group(findings, & &1["class"], @count_classes)
    by_trust = count_group(findings, & &1["trust"], @count_trusts)
    by_owner = count_group(findings, &owner_count_key/1, @count_owners)

    %{
      "total" => length(findings),
      "production" => by_class["production"],
      "test_support" => by_class["test_support"],
      "config_block" => by_class["config_block"],
      "untrusted" => by_trust["untrusted"],
      "by_class" => by_class,
      "by_trust" => by_trust,
      "by_owner" => by_owner
    }
  end

  defp count_group(findings, fun, keys) do
    grouped = Enum.frequencies_by(findings, fun)

    Map.new(keys, fn key -> {key, Map.get(grouped, key, 0)} end)
  end

  defp owner_count_key(%{"legacy_app" => owner}) when is_binary(owner), do: owner
  defp owner_count_key(_), do: "unresolved"
end
