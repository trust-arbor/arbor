defmodule Arbor.Commands.PlatformInventory.Core do
  @moduledoc """
  Pure construct/compare/show core for the Platform (E0A) source inventory.

  The input is the closed, in-memory result shape returned by
  `Arbor.Commands.SourceCoupling.GitInventory.load_selected_blobs/3`. No
  filesystem, Git process, configuration, or runtime state is consulted.
  """

  alias Arbor.Commands.PlatformInventory.{Ast, Encode}
  alias Arbor.Commands.SourceCoupling.GitInventory

  @report_schema "arbor.packaging.platform_inventory.v1"

  @platform_apps [
    "arbor_cartographer",
    "arbor_llm",
    "arbor_security",
    "arbor_persistence",
    "arbor_persistence_ecto",
    "arbor_shell",
    "arbor_sandbox",
    "arbor_historian",
    "arbor_trust"
  ]

  @platform_apps_set MapSet.new(@platform_apps)

  @component_classes [
    "k_primitive",
    "trusted_host",
    "system_extension",
    "optional_extension",
    "third_party_extension"
  ]

  @accepted_formats MapSet.new(["sha1", "sha256"])
  @accepted_modes MapSet.new(["100644", "100755"])
  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @digest_re ~r/\A[0-9a-f]{64}\z/

  @max_files 5_000
  @max_blob_bytes 1_048_576
  @max_total_bytes 64 * 1024 * 1024
  @max_path_bytes 4_096

  @bundle_atom_required [:files, :head_tree_oid, :object_format, :selected_index_digest]
  @bundle_string_required ["files", "head_tree_oid", "object_format", "selected_index_digest"]

  @file_atom_keys [:path, :blob_oid, :mode, :byte_size, :bytes]
  @file_string_keys ["path", "blob_oid", "mode", "byte_size", "bytes"]

  @doc "Closed nine-app Platform inventory scope."
  @spec platform_apps() :: [String.t()]
  def platform_apps, do: @platform_apps

  @doc "Closed five-way component classification vocabulary."
  @spec component_classes() :: [String.t()]
  def component_classes, do: @component_classes

  @doc false
  @spec git_blob_oid(binary(), String.t()) :: String.t()
  def git_blob_oid(bytes, "sha1") when is_binary(bytes), do: hash_blob_oid(:sha, bytes)
  def git_blob_oid(bytes, "sha256") when is_binary(bytes), do: hash_blob_oid(:sha256, bytes)

  @doc "Project an admitted selected-blob bundle into a validated report."
  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(bundle) when is_map(bundle) and not is_struct(bundle) do
    with {:ok, schema} <- admit_bundle_schema(bundle),
         {:ok, files, head_tree_oid, object_format, selected_index_digest, classifications} <-
           read_bundle(bundle, schema),
         :ok <- validate_provenance(head_tree_oid, object_format, selected_index_digest),
         {:ok, files} <- validate_files(files, object_format),
         :ok <- verify_selected_index_digest(files, selected_index_digest),
         {:ok, classifications} <- admit_classifications(classifications),
         files = Enum.sort_by(files, & &1["path"]),
         classifications = Enum.sort_by(classifications, & &1["path"]),
         {:ok, entries} <- build_entries(files),
         {:ok, entries} <- Encode.validate_entry_list(entries),
         {:ok, comparison} <- compare(entries, classifications),
         {:ok, index_manifest_digest} <- Encode.scan_manifest_digest(manifest_triples(files)),
         {:ok, entries_digest} <- Encode.entries_digest(entries),
         {:ok, review_digest} <- Encode.review_digest(classifications),
         {:ok, comparison_digest} <- Encode.comparison_digest(comparison) do
      report = %{
        "schema" => @report_schema,
        "mode" => "report",
        "status" => comparison["status"],
        "output" => "human",
        "platform_apps" => @platform_apps,
        "component_classes" => @component_classes,
        "counts" => build_counts(entries, classifications),
        "entries" => entries,
        "classifications" => classifications,
        "comparison" => comparison,
        "provenance" => %{
          "head_tree_oid" => head_tree_oid,
          "index_manifest_digest" => index_manifest_digest,
          "entries_digest" => entries_digest,
          "review_digest" => review_digest,
          "comparison_digest" => comparison_digest
        }
      }

      case Encode.validate_report(report) do
        :ok -> {:ok, report}
        {:error, _} = error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_bundle}
  end

  def project(_), do: {:error, :invalid_bundle}

  @doc "Validate a report, apply closed mode/output labels, and validate again."
  @spec show(map(), term()) :: {:ok, map()} | {:error, term()}
  def show(report, opts) when is_map(report) do
    with :ok <- Encode.validate_report(report),
         {:ok, mode, output} <- admit_show_options(opts),
         relabeled = report |> Map.put("mode", mode) |> Map.put("output", output),
         :ok <- Encode.validate_report(relabeled) do
      {:ok, relabeled}
    end
  end

  def show(_, _), do: {:error, :invalid_report}

  ## -- bundle admission -------------------------------------------------

  defp admit_bundle_schema(bundle) do
    keys = Map.keys(bundle)

    cond do
      Enum.all?(keys, &is_atom/1) -> admit_key_set(keys, @bundle_atom_required, :atom)
      Enum.all?(keys, &is_binary/1) -> admit_key_set(keys, @bundle_string_required, :string)
      true -> {:error, :invalid_bundle_keys}
    end
  end

  defp admit_key_set(keys, required, style) do
    allowed = required ++ [optional_key(style)]

    if MapSet.new(keys) in [MapSet.new(required), MapSet.new(allowed)] do
      {:ok, {style, MapSet.member?(MapSet.new(keys), optional_key(style))}}
    else
      {:error, :invalid_bundle_keys}
    end
  end

  defp optional_key(:atom), do: :classifications
  defp optional_key(:string), do: "classifications"

  defp read_bundle(bundle, {style, has_classifications}) do
    key = fn atom -> if style == :atom, do: atom, else: Atom.to_string(atom) end

    files = Map.fetch!(bundle, key.(:files))
    head_tree_oid = Map.fetch!(bundle, key.(:head_tree_oid))
    object_format = Map.fetch!(bundle, key.(:object_format))
    selected_index_digest = Map.fetch!(bundle, key.(:selected_index_digest))

    classifications =
      if has_classifications, do: Map.fetch!(bundle, key.(:classifications)), else: []

    if Enum.any?(
         [files, head_tree_oid, object_format, selected_index_digest, classifications],
         &is_nil/1
       ) do
      {:error, :nil_bundle_value}
    else
      {:ok, files, head_tree_oid, object_format, selected_index_digest, classifications}
    end
  end

  defp validate_provenance(head_tree_oid, object_format, selected_index_digest) do
    cond do
      not MapSet.member?(@accepted_formats, object_format) ->
        {:error, :invalid_object_format}

      not is_binary(head_tree_oid) or not valid_oid_shape?(head_tree_oid) ->
        {:error, :invalid_head_tree_oid}

      not oid_matches_format?(head_tree_oid, object_format) ->
        {:error, {:oid_format_mismatch, :head_tree}}

      not is_binary(selected_index_digest) or not Regex.match?(@digest_re, selected_index_digest) ->
        {:error, :invalid_selected_index_digest}

      true ->
        :ok
    end
  end

  ## -- file admission ---------------------------------------------------

  defp validate_files(files, object_format) when is_list(files) do
    Enum.reduce_while(files, {:ok, [], MapSet.new(), 0, 0}, fn file,
                                                               {:ok, admitted, seen, count,
                                                                total_bytes} ->
      if count >= @max_files do
        {:halt, {:error, :too_many_files}}
      else
        with {:ok, file} <- normalize_file(file),
             :ok <- validate_file(file, object_format, seen),
             size = file["byte_size"],
             new_total = total_bytes + size,
             :ok <- validate_total_bytes(new_total) do
          {:cont, {:ok, [file | admitted], MapSet.put(seen, file["path"]), count + 1, new_total}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, _admitted, _seen, 0, _total} -> {:error, :empty_files}
      {:ok, admitted, _seen, _count, _total} -> {:ok, admitted}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_files}
  end

  defp validate_files(_, _), do: {:error, :invalid_files}

  defp normalize_file(file) when is_map(file) and not is_struct(file) do
    keys = Map.keys(file)

    cond do
      MapSet.new(keys) == MapSet.new(@file_atom_keys) and Enum.all?(keys, &is_atom/1) ->
        {:ok,
         %{
           "path" => Map.fetch!(file, :path),
           "blob_oid" => Map.fetch!(file, :blob_oid),
           "mode" => Map.fetch!(file, :mode),
           "byte_size" => Map.fetch!(file, :byte_size),
           "bytes" => Map.fetch!(file, :bytes)
         }}

      MapSet.new(keys) == MapSet.new(@file_string_keys) and Enum.all?(keys, &is_binary/1) ->
        {:ok, file}

      true ->
        {:error, :invalid_file_keys}
    end
  end

  defp normalize_file(_), do: {:error, :invalid_file}

  defp validate_file(file, object_format, seen) do
    path = file["path"]
    oid = file["blob_oid"]
    mode = file["mode"]
    declared_size = file["byte_size"]
    bytes = file["bytes"]

    cond do
      not is_binary(path) or not String.valid?(path) ->
        {:error, :invalid_path}

      not valid_source_path?(path) ->
        {:error, {:invalid_path, path}}

      MapSet.member?(seen, path) ->
        {:error, {:duplicate_paths, path}}

      not is_binary(oid) or not valid_oid_shape?(oid) ->
        {:error, {:invalid_oid, path}}

      not oid_matches_format?(oid, object_format) ->
        {:error, {:oid_format_mismatch, path}}

      mode not in @accepted_modes ->
        {:error, {:invalid_mode, mode, path}}

      not is_integer(declared_size) or declared_size < 0 ->
        {:error, {:invalid_byte_size, path}}

      declared_size > @max_blob_bytes ->
        {:error, {:file_too_large, path}}

      not is_binary(bytes) ->
        {:error, {:invalid_bytes, path}}

      declared_size != byte_size(bytes) ->
        {:error, {:invalid_byte_size, path}}

      git_blob_oid(bytes, object_format) != oid ->
        {:error, {:oid_content_mismatch, path}}

      true ->
        :ok
    end
  end

  defp validate_total_bytes(total) when total <= @max_total_bytes, do: :ok
  defp validate_total_bytes(_), do: {:error, :total_bytes_limit}

  defp valid_source_path?(path) do
    path != "" and byte_size(path) <= @max_path_bytes and
      not String.contains?(path, <<0>>) and
      not String.starts_with?(path, "/") and
      not String.contains?(path, "\\") and
      path |> String.split("/") |> Enum.all?(&(&1 not in ["..", "", "."])) and
      case String.split(path, "/") do
        ["apps", app, "lib" | rest] when rest != [] ->
          MapSet.member?(@platform_apps_set, app) and String.ends_with?(List.last(rest), ".ex")

        _ ->
          false
      end
  end

  defp verify_selected_index_digest(files, selected_index_digest) do
    triples = Enum.map(files, &{&1["path"], &1["mode"], &1["blob_oid"]})

    case GitInventory.selected_index_digest(triples) do
      {:ok, ^selected_index_digest} -> :ok
      {:ok, _other} -> {:error, :selected_index_digest_mismatch}
      {:error, _} -> {:error, :selected_index_digest_invalid}
    end
  end

  defp valid_oid_shape?(oid) when is_binary(oid), do: Regex.match?(@oid_re, oid)
  defp valid_oid_shape?(_), do: false

  defp oid_matches_format?(oid, "sha1"), do: byte_size(oid) == 40
  defp oid_matches_format?(oid, "sha256"), do: byte_size(oid) == 64
  defp oid_matches_format?(_, _), do: false

  ## -- projection and comparison ---------------------------------------

  defp admit_classifications(classifications) when is_list(classifications) do
    Encode.validate_classification_list(classifications)
  end

  defp admit_classifications(_), do: {:error, :invalid_classifications}

  defp build_entries(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case Ast.facts(file["path"], file["bytes"]) do
        {:ok, facts} ->
          entry =
            Map.merge(facts, %{
              "path" => file["path"],
              "blob_oid" => file["blob_oid"],
              "mode" => file["mode"],
              "byte_size" => file["byte_size"],
              "app" => app_of_path(file["path"])
            })

          {:cont, {:ok, [entry | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp app_of_path(path) do
    ["apps", app | _] = String.split(path, "/")
    app
  end

  defp manifest_triples(files) do
    Enum.map(files, &{&1["path"], &1["mode"], &1["blob_oid"]})
  end

  defp compare(_entries, []) do
    {:ok, %{"status" => "unreviewed", "failures" => [], "failure_count" => 0}}
  end

  defp compare(entries, classifications) do
    entries_by_path = Map.new(entries, &{&1["path"], &1})
    classifications_by_path = Map.new(classifications, &{&1["path"], &1})

    missing =
      entries
      |> Enum.reject(&Map.has_key?(classifications_by_path, &1["path"]))
      |> Enum.map(&failure("missing_review", &1["path"]))

    extra =
      classifications
      |> Enum.reject(&Map.has_key?(entries_by_path, &1["path"]))
      |> Enum.map(&failure("extra_review", &1["path"]))

    stale =
      classifications
      |> Enum.filter(&Map.has_key?(entries_by_path, &1["path"]))
      |> Enum.filter(fn classification ->
        entries_by_path[classification["path"]]["blob_oid"] != classification["blob_oid"]
      end)
      |> Enum.map(&stale_blob_failure(&1, entries_by_path))

    failures = Enum.sort_by(missing ++ extra ++ stale, &{&1["reason"], &1["detail"]})
    status = if failures == [], do: "match", else: "mismatch"

    {:ok, %{"status" => status, "failures" => failures, "failure_count" => length(failures)}}
  end

  defp stale_blob_failure(classification, entries_by_path) do
    path = classification["path"]
    expected = entries_by_path[path]["blob_oid"]
    actual = classification["blob_oid"]
    failure("stale_blob", "#{path} expected=#{expected} actual=#{actual}")
  end

  defp failure(reason, detail), do: %{"reason" => reason, "detail" => detail}

  defp build_counts(entries, classifications) do
    by_app = Enum.frequencies_by(entries, & &1["app"])
    by_class = Enum.frequencies_by(classifications, & &1["class"])
    entry_paths = MapSet.new(entries, & &1["path"])
    reviewed_paths = MapSet.new(classifications, & &1["path"])

    %{
      "total_files" => length(entries),
      "reviewed_files" => MapSet.size(MapSet.intersection(entry_paths, reviewed_paths)),
      "unreviewed_files" =>
        length(entries) - MapSet.size(MapSet.intersection(entry_paths, reviewed_paths)),
      "by_app" => Map.new(@platform_apps, &{&1, Map.get(by_app, &1, 0)}),
      "by_class" => Map.new(@component_classes, &{&1, Map.get(by_class, &1, 0)})
    }
  end

  ## -- show -------------------------------------------------------------

  defp admit_show_options(opts) when is_list(opts) do
    Enum.reduce_while(opts, {:ok, "report", "human", MapSet.new()}, fn option,
                                                                       {:ok, mode, output, seen} ->
      case option do
        {key, value} when key in [:mode, :output] ->
          if MapSet.member?(seen, key) do
            {:halt, {:error, {:duplicate_option, key}}}
          else
            case valid_show_value(key, value) do
              :ok ->
                next = if key == :mode, do: {:ok, value, output}, else: {:ok, mode, value}
                {:cont, put_show_seen(next, seen, key)}

              {:error, _} = error ->
                {:halt, error}
            end
          end

        {key, _value} when is_atom(key) ->
          {:halt, {:error, {:unknown_option, key}}}

        _ ->
          {:halt, {:error, :invalid_options}}
      end
    end)
    |> case do
      {:ok, mode, output, _seen} -> {:ok, mode, output}
      {:error, _} = error -> error
    end
  end

  defp admit_show_options(_), do: {:error, :invalid_options}

  defp put_show_seen({:ok, mode, output}, seen, key),
    do: {:ok, mode, output, MapSet.put(seen, key)}

  defp valid_show_value(:mode, value) when value in ["report", "check"], do: :ok
  defp valid_show_value(:output, value) when value in ["human", "json"], do: :ok
  defp valid_show_value(key, _value), do: {:error, {:invalid_option, key}}

  ## -- hashing ----------------------------------------------------------

  defp hash_blob_oid(algo, bytes) do
    :crypto.hash(algo, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    |> Base.encode16(case: :lower)
  end
end
