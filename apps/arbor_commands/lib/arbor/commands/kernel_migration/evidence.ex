defmodule Arbor.Commands.KernelMigration.Evidence do
  @moduledoc """
  Pure admit/compare for PK-K0 Boundary and formatter reviewed evidence.
  """

  alias Arbor.Commands.KernelMigration.Encode
  alias Arbor.Commands.SourceCoupling.AstExtract

  @boundary_schema "arbor.packaging.kernel_migration.boundary.v1"
  @formatter_schema "arbor.packaging.kernel_migration.formatter.v1"
  @report_schema "arbor.packaging.kernel_migration.report.v1"
  @max_failures 50
  @excluded_target "Arbor.Agent.Character"

  @external_rows MapSet.new([
                   {
                     "apps/arbor_common/lib/arbor/common/model_profile.ex",
                     "Arbor.Common.ModelProfile",
                     "LLMDB",
                     "attribute",
                     344,
                     "apps/arbor_kernel/lib/arbor/common/model_profile.ex"
                   },
                   {
                     "apps/arbor_common/lib/arbor/common/agent_telemetry/store.ex",
                     "Arbor.Common.AgentTelemetry.Store",
                     "Ecto.Adapters.Postgres",
                     "expr",
                     323,
                     "apps/arbor_kernel/lib/arbor/common/agent_telemetry/store.ex"
                   }
                 ])

  @spec admit_boundary(map()) :: {:ok, map()} | {:error, term()}
  def admit_boundary(raw) when is_map(raw) do
    with :ok <- exact_schema(raw, @boundary_schema),
         :ok <- exact_version(raw),
         {:ok, entries} <- admit_list(raw["entries"], &admit_boundary_entry/1) do
      keys = Enum.map(entries, &boundary_key/1)

      if length(keys) != length(Enum.uniq(keys)) do
        {:error, :duplicate_boundary_entry}
      else
        ordered = Enum.sort_by(entries, &boundary_sort/1)

        {:ok,
         %{
           "schema" => @boundary_schema,
           "version" => 1,
           "entries" => Enum.map(ordered, &Encode.order_boundary/1),
           "entries_digest" => Encode.boundary_digest(ordered)
         }}
      end
    end
  end

  def admit_boundary(_), do: {:error, :malformed_boundary}

  @spec admit_formatter(map()) :: {:ok, map()} | {:error, term()}
  def admit_formatter(raw) when is_map(raw) do
    with :ok <- exact_schema(raw, @formatter_schema),
         :ok <- exact_version(raw),
         {:ok, files} <- admit_list(raw["files"], &admit_formatter_file/1),
         {:ok, configs} <- admit_list(raw["configs"] || [], &admit_formatter_config/1) do
      paths = Enum.map(files, & &1["current_path"])
      config_paths = Enum.map(configs, & &1["path"])

      cond do
        length(paths) != length(Enum.uniq(paths)) ->
          {:error, :duplicate_formatter_path}

        length(config_paths) != length(Enum.uniq(config_paths)) ->
          {:error, :duplicate_formatter_config}

        true ->
          files = Enum.sort_by(files, & &1["current_path"])
          configs = Enum.sort_by(configs, & &1["path"])

          {:ok,
           %{
             "schema" => @formatter_schema,
             "version" => 1,
             "files" => Enum.map(files, &Encode.order_formatter_file/1),
             "configs" => Enum.map(configs, &Encode.order_formatter_config/1),
             "entries_digest" => Encode.formatter_digest(files, configs)
           }}
      end
    end
  end

  def admit_formatter(_), do: {:error, :malformed_formatter}

  @spec admit_report(map()) :: {:ok, map()} | {:error, term()}
  def admit_report(raw) when is_map(raw) do
    identity = raw["identity"]

    cond do
      raw["schema"] != @report_schema ->
        {:error, :malformed_report}

      not is_binary(identity) or byte_size(identity) != 64 ->
        {:error, :malformed_report}

      not is_map(raw["counts"]) ->
        {:error, :malformed_report}

      true ->
        {:ok, raw}
    end
  end

  def admit_report(_), do: {:error, :malformed_report}

  @spec compare_report_bytes(binary(), binary()) :: {:ok, map()}
  def compare_report_bytes(checked, current)
      when is_binary(checked) and is_binary(current) do
    if checked == current do
      finish_failures([])
    else
      finish_failures([
        %{
          "reason" => "report_drift",
          "detail" => "checked normative report does not match current index"
        }
      ])
    end
  end

  def compare_report_bytes(_, _), do: {:error, :invalid_report_compare}

  @spec compare_boundary(map(), [map()], map()) :: {:ok, map()}
  def compare_boundary(admitted, runtime, blobs)
      when is_map(admitted) and is_list(runtime) and is_map(blobs) do
    entries = admitted["entries"] || []
    expected_runtime = Enum.reject(runtime, &(&1["target"] == @excluded_target))
    runtime_entries = Enum.filter(entries, &(&1["source"] == "census_runtime"))
    external_entries = Enum.filter(entries, &(&1["source"] == "census_ignored_external"))

    failures =
      []
      |> check_boundary_count(entries)
      |> check_runtime_set(runtime_entries, expected_runtime)
      |> check_external_set(external_entries)
      |> then(fn acc ->
        Enum.reduce(entries, acc, fn entry, inner ->
          inner
          |> reject_excluded(entry)
          |> validate_boundary_blob(entry, blobs)
          |> validate_boundary_site(entry, runtime, blobs)
        end)
      end)

    finish_failures(failures)
  end

  def compare_boundary(_, _, _), do: {:error, :invalid_boundary_compare}

  @spec compare_formatter(map(), map()) :: {:ok, map()}
  def compare_formatter(admitted, blobs) when is_map(admitted) and is_map(blobs) do
    files = admitted["files"] || []
    configs = admitted["configs"] || []

    failures =
      []
      |> then(fn acc ->
        if length(files) == 38 do
          acc
        else
          [%{"reason" => "formatter_count", "detail" => "expected 38 got #{length(files)}"} | acc]
        end
      end)
      |> then(fn acc ->
        if length(configs) == 5 do
          acc
        else
          [
            %{
              "reason" => "formatter_config_count",
              "detail" => "expected 5 got #{length(configs)}"
            }
            | acc
          ]
        end
      end)

    failures =
      Enum.reduce(files, failures, fn entry, acc ->
        path = entry["current_path"]
        dest = entry["proof_destination"]

        cond do
          not String.starts_with?(dest || "", "apps/arbor_kernel/") ->
            [%{"reason" => "formatter_destination", "detail" => path} | acc]

          not Map.has_key?(blobs, path) ->
            [%{"reason" => "formatter_blob_missing", "detail" => path} | acc]

          entry["blob_oid"] != blob_oid(blobs, path) ->
            [%{"reason" => "formatter_blob_drift", "detail" => path} | acc]

          true ->
            acc
        end
      end)

    failures =
      Enum.reduce(configs, failures, fn cfg, acc ->
        compare_config(cfg, blobs, acc)
      end)

    finish_failures(failures)
  end

  def compare_formatter(_, _), do: {:error, :invalid_formatter_compare}

  @spec compare_disposition_blobs([map()], map()) :: {:ok, map()}
  def compare_disposition_blobs(entries, blobs) when is_list(entries) and is_map(blobs) do
    failures =
      Enum.reduce(entries, [], fn entry, acc ->
        path = entry["file"]

        cond do
          map_size(blobs) == 0 ->
            acc

          not Map.has_key?(blobs, path) ->
            [%{"reason" => "disposition_blob_missing", "detail" => path} | acc]

          entry["blob_oid"] != blob_oid(blobs, path) ->
            [%{"reason" => "disposition_blob_drift", "detail" => path} | acc]

          true ->
            acc
        end
      end)

    finish_failures(failures)
  end

  def compare_disposition_blobs(_, _), do: {:error, :invalid_disposition_blob_compare}

  @spec attach_blob_oids([map()], map()) :: [map()]
  def attach_blob_oids(entries, blobs) when is_list(entries) and is_map(blobs) do
    Enum.map(entries, fn entry ->
      path = entry["current_path"] || entry["path"] || entry["file"]
      oid = blob_oid(blobs, path)
      if is_binary(oid), do: Map.put(entry, "blob_oid", oid), else: entry
    end)
  end

  def attach_blob_oids(entries, _), do: entries

  @spec extract_matches_site?(binary(), map()) :: boolean()
  def extract_matches_site?(bytes, entry) when is_binary(bytes) and is_map(entry) do
    path = entry["current_path"]

    case AstExtract.extract(path, bytes) do
      {:ok, result} ->
        Enum.any?(result.references, fn ref ->
          ref_field(ref, :file) == path and
            ref_field(ref, :from_module) == entry["from_module"] and
            ref_field(ref, :target) == entry["target"] and
            ref_field(ref, :kind) == entry["kind"] and
            ref_field(ref, :line) == entry["site_line"]
        end)

      _ ->
        false
    end
  end

  def extract_matches_site?(_, _), do: false

  defp admit_list(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp admit_list(_, _), do: {:error, :malformed_entries}

  defp admit_boundary_entry(entry) when is_map(entry) do
    required = ~w(current_path from_module target kind proof_destination source blob_oid)
    site_line = entry["site_line"]

    cond do
      not Enum.all?(required, &(is_binary(entry[&1]) and String.trim(entry[&1]) != "")) ->
        {:error, :missing_boundary_evidence}

      not Encode.blob_oid_valid?(entry["blob_oid"]) ->
        {:error, :missing_boundary_evidence}

      not is_integer(site_line) or site_line < 1 ->
        {:error, :missing_boundary_evidence}

      not String.starts_with?(entry["proof_destination"], "apps/arbor_kernel/") ->
        {:error, :malformed_boundary_entry}

      entry["source"] not in ["census_runtime", "census_ignored_external"] ->
        {:error, :malformed_boundary_entry}

      true ->
        {:ok, Encode.order_boundary(entry)}
    end
  end

  defp admit_boundary_entry(_), do: {:error, :malformed_boundary_entry}

  defp admit_formatter_file(entry) when is_map(entry) do
    path = entry["current_path"]
    dest = entry["proof_destination"]
    oid = entry["blob_oid"]

    if is_binary(path) and String.trim(path) != "" and is_binary(dest) and
         String.starts_with?(dest, "apps/arbor_kernel/") and Encode.blob_oid_valid?(oid) do
      {:ok, Encode.order_formatter_file(entry)}
    else
      {:error, :missing_formatter_evidence}
    end
  end

  defp admit_formatter_file(_), do: {:error, :malformed_formatter_file}

  defp admit_formatter_config(entry) when is_map(entry) do
    path = entry["path"]
    status = entry["status"]
    oid = entry["blob_oid"]

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :malformed_formatter_config}

      status == "present" and Encode.blob_oid_valid?(oid) ->
        {:ok, Encode.order_formatter_config(entry)}

      status == "expected_absent" and (oid in [nil, ""] or not Map.has_key?(entry, "blob_oid")) ->
        {:ok, Encode.order_formatter_config(Map.delete(entry, "blob_oid"))}

      status == "expected_absent" ->
        {:error, :unexpected_absent_blob_oid}

      status == "present" ->
        {:error, :missing_formatter_evidence}

      true ->
        {:error, :malformed_formatter_config}
    end
  end

  defp admit_formatter_config(_), do: {:error, :malformed_formatter_config}

  defp check_boundary_count(failures, entries) do
    if length(entries) == 22 do
      failures
    else
      [
        %{
          "reason" => "boundary_count",
          "detail" => "expected 22 got #{length(entries)}"
        }
        | failures
      ]
    end
  end

  defp check_runtime_set(failures, runtime_entries, expected_runtime) do
    derived = MapSet.new(expected_runtime, &runtime_site_key/1)
    reviewed = MapSet.new(runtime_entries, &boundary_runtime_key/1)

    failures =
      Enum.reduce(MapSet.difference(derived, reviewed), failures, fn key, acc ->
        [%{"reason" => "boundary_site_missing", "detail" => join_key(key)} | acc]
      end)

    Enum.reduce(MapSet.difference(reviewed, derived), failures, fn key, acc ->
      [%{"reason" => "boundary_extra_or_stale", "detail" => join_key(key)} | acc]
    end)
  end

  defp check_external_set(failures, external_entries) do
    reviewed = MapSet.new(external_entries, &external_row_key/1)

    failures =
      if MapSet.equal?(reviewed, @external_rows) do
        failures
      else
        missing = MapSet.difference(@external_rows, reviewed)
        extra = MapSet.difference(reviewed, @external_rows)

        failures
        |> then(fn acc ->
          Enum.reduce(missing, acc, fn row, inner ->
            [%{"reason" => "boundary_external_missing", "detail" => join_external(row)} | inner]
          end)
        end)
        |> then(fn acc ->
          Enum.reduce(extra, acc, fn row, inner ->
            [
              %{"reason" => "boundary_external_unexpected", "detail" => join_external(row)}
              | inner
            ]
          end)
        end)
      end

    if length(external_entries) == 2 do
      failures
    else
      [
        %{
          "reason" => "boundary_external_count",
          "detail" => "expected 2 got #{length(external_entries)}"
        }
        | failures
      ]
    end
  end

  defp reject_excluded(failures, entry) do
    target = entry["target"] || ""
    source = entry["source"] || ""

    cond do
      target == @excluded_target ->
        [
          %{"reason" => "boundary_excluded_character", "detail" => entry["current_path"]}
          | failures
        ]

      source in ["config_env", "mix_string", "process_atom"] ->
        [%{"reason" => "boundary_excluded_kind", "detail" => source} | failures]

      true ->
        failures
    end
  end

  defp validate_boundary_blob(failures, entry, blobs) do
    path = entry["current_path"]

    cond do
      map_size(blobs) == 0 ->
        failures

      not Map.has_key?(blobs, path) ->
        [%{"reason" => "boundary_blob_missing", "detail" => path} | failures]

      entry["blob_oid"] != blob_oid(blobs, path) ->
        [%{"reason" => "boundary_source_drift", "detail" => path} | failures]

      true ->
        failures
    end
  end

  defp validate_boundary_site(failures, %{"source" => "census_runtime"} = entry, runtime, _blobs) do
    found =
      Enum.any?(runtime, fn finding ->
        finding["file"] == entry["current_path"] and
          finding["from_module"] == entry["from_module"] and
          finding["target"] == entry["target"] and
          finding["kind"] == entry["kind"] and
          finding["line"] == entry["site_line"]
      end)

    if found do
      failures
    else
      [
        %{
          "reason" => "boundary_site_mismatch",
          "detail" =>
            Enum.join(
              [
                entry["current_path"],
                entry["from_module"],
                entry["target"],
                entry["kind"],
                to_string(entry["site_line"])
              ],
              "|"
            )
        }
        | failures
      ]
    end
  end

  defp validate_boundary_site(
         failures,
         %{"source" => "census_ignored_external"} = entry,
         _runtime,
         blobs
       ) do
    failures =
      if MapSet.member?(@external_rows, external_row_key(entry)) do
        failures
      else
        [
          %{
            "reason" => "boundary_external_identity",
            "detail" => join_external(external_row_key(entry))
          }
          | failures
        ]
      end

    validate_external_indexed_site(failures, entry, blobs)
  end

  defp validate_boundary_site(failures, entry, _, _) do
    [%{"reason" => "boundary_unknown_source", "detail" => entry["source"] || ""} | failures]
  end

  defp validate_external_indexed_site(failures, entry, blobs) do
    path = entry["current_path"]
    rec = Map.get(blobs, path)
    bytes = rec && (rec[:bytes] || rec["bytes"])

    cond do
      map_size(blobs) == 0 ->
        failures

      not is_binary(bytes) or bytes == "" ->
        [%{"reason" => "boundary_external_blob", "detail" => path} | failures]

      extract_matches_site?(bytes, entry) ->
        failures

      true ->
        [
          %{
            "reason" => "boundary_external_site",
            "detail" =>
              Enum.join(
                [
                  path,
                  entry["from_module"],
                  entry["target"],
                  entry["kind"],
                  to_string(entry["site_line"])
                ],
                "|"
              )
          }
          | failures
        ]
    end
  end

  defp compare_config(cfg, blobs, failures) do
    path = cfg["path"]
    present? = Map.has_key?(blobs, path)

    case cfg["status"] do
      "present" when present? ->
        if cfg["blob_oid"] != blob_oid(blobs, path) do
          [%{"reason" => "formatter_config_drift", "detail" => path} | failures]
        else
          failures
        end

      "present" ->
        [%{"reason" => "formatter_config_missing", "detail" => path} | failures]

      "expected_absent" when present? ->
        [%{"reason" => "formatter_config_unexpected", "detail" => path} | failures]

      _ ->
        failures
    end
  end

  defp blob_oid(blobs, path) do
    case Map.get(blobs, path) do
      %{blob_oid: oid} -> oid
      %{"blob_oid" => oid} -> oid
      _ -> nil
    end
  end

  defp finish_failures(failures) do
    status = if failures == [], do: "ok", else: "failed"
    bounded = Enum.take(Enum.sort_by(failures, &{&1["reason"], &1["detail"]}), @max_failures)

    {:ok,
     %{
       "status" => status,
       "failures" => bounded,
       "failure_count" => length(failures),
       "truncated" => length(failures) > @max_failures
     }}
  end

  defp exact_schema(%{"schema" => schema}, schema), do: :ok
  defp exact_schema(_, _), do: {:error, :malformed_or_stale}

  defp exact_version(%{"version" => 1}), do: :ok
  defp exact_version(_), do: {:error, :malformed_or_stale}

  defp boundary_key(entry) do
    {entry["current_path"], entry["from_module"], entry["target"], entry["kind"],
     entry["site_line"]}
  end

  defp boundary_sort(entry) do
    {entry["current_path"], entry["from_module"], entry["target"], entry["kind"],
     entry["site_line"]}
  end

  defp runtime_site_key(finding) do
    {finding["file"], finding["from_module"], finding["target"], finding["kind"], finding["line"]}
  end

  defp boundary_runtime_key(entry) do
    {entry["current_path"], entry["from_module"], entry["target"], entry["kind"],
     entry["site_line"]}
  end

  defp join_key({path, from, target, kind, line}) do
    Enum.join([path, from, target, kind, to_string(line)], "|")
  end

  defp external_row_key(entry) do
    {
      entry["current_path"],
      entry["from_module"],
      entry["target"],
      entry["kind"],
      entry["site_line"],
      entry["proof_destination"]
    }
  end

  defp join_external({path, from, target, kind, line, dest}) do
    Enum.join([path, from, target, kind, to_string(line), dest], "|")
  end

  defp ref_field(ref, key) when is_atom(key) do
    Map.get(ref, key) || Map.get(ref, Atom.to_string(key))
  end
end
