defmodule Arbor.Commands.KernelMigration do
  @moduledoc """
  Imperative shell for the PK-K0 kernel-migration evidence gate.

  Reuses `Arbor.Commands.SourceCoupling` Git-index census. Never rewrites
  the general source-coupling baseline or the disposition/boundary/formatter
  manifests. Write mode emits only the derived report.
  """

  alias Arbor.Commands.KernelMigration.{Core, Encode, Evidence}
  alias Arbor.Commands.SourceCoupling
  alias Arbor.Commands.SourceCoupling.GitInventory
  alias Arbor.Common.SafePath

  @default_report_rel "apps/arbor_commands/priv/packaging/kernel_migration_report.v1.json"
  @default_disposition_rel "apps/arbor_commands/priv/packaging/kernel_migration_disposition.v1.json"
  @default_boundary_rel "apps/arbor_commands/priv/packaging/kernel_migration_boundary.v1.json"
  @default_formatter_rel "apps/arbor_commands/priv/packaging/kernel_migration_formatter.v1.json"

  @production_opt_keys [
    :mode,
    :json,
    :root,
    :report,
    :disposition,
    :boundary,
    :formatter,
    :allow_write
  ]

  @synthetic_opt_keys [:inventory, :run_git, :census, :blobs]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] -> do_run(opts, allow_synthetic: false)
      unexpected -> {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, "report")

    cond do
      mode == "write_report" and Keyword.get(opts, :allow_write, false) != true ->
        {:error, :write_not_allowed}

      mode == "write_report" and synthetic_present?(opts) ->
        {:error, :write_report_requires_git_inventory}

      true ->
        do_run(opts, allow_synthetic: true)
    end
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  defp synthetic_present?(opts) do
    Enum.any?(@synthetic_opt_keys, &Keyword.has_key?(opts, &1))
  end

  defp do_run(opts, allow_synthetic: allow_synthetic) do
    mode = Keyword.get(opts, :mode, "report")
    json? = Keyword.get(opts, :json, false) == true
    output = if json?, do: "json", else: "human"

    with {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, paths} <- resolve_paths(root, opts),
         {:ok, census} <- load_census(root, opts, mode, allow_synthetic),
         {:ok, projected} <- Core.project(census),
         {:ok, disposition} <- load_json_map(paths.disposition),
         {:ok, admitted_disp} <- Core.admit_dispositions(disposition),
         opts <-
           Keyword.put(
             opts,
             :disposition_files,
             Enum.uniq(Enum.map(admitted_disp["entries"] || [], & &1["file"]))
           ),
         {:ok, boundary_raw} <- load_json_map(paths.boundary),
         {:ok, admitted_boundary} <- Evidence.admit_boundary(boundary_raw),
         {:ok, formatter_raw} <- load_json_map(paths.formatter),
         {:ok, admitted_formatter} <- Evidence.admit_formatter(formatter_raw),
         {:ok, blobs} <-
           load_evidence_blobs(root, admitted_boundary, admitted_formatter, opts, allow_synthetic),
         {:ok, disp_cmp} <- Core.compare_dispositions(projected["runtime"], admitted_disp),
         {:ok, disp_blob_cmp} <-
           Evidence.compare_disposition_blobs(admitted_disp["entries"], blobs),
         {:ok, bound_cmp} <-
           Evidence.compare_boundary(admitted_boundary, projected["runtime"], blobs),
         {:ok, fmt_cmp} <- Evidence.compare_formatter(admitted_formatter, blobs) do
      compare = merge_comparisons([disp_cmp, disp_blob_cmp, bound_cmp, fmt_cmp])

      extras = %{
        "mode" => mode,
        "output" => output,
        "boundary" => Evidence.attach_blob_oids(admitted_boundary["entries"], blobs),
        "formatter" => Evidence.attach_blob_oids(admitted_formatter["files"], blobs),
        "dispositions" => admitted_disp["entries"],
        "disposition_manifest_digest" => admitted_disp["entries_digest"],
        "boundary_manifest_digest" => admitted_boundary["entries_digest"],
        "formatter_manifest_digest" => admitted_formatter["entries_digest"]
      }

      report = Core.show(projected, compare, extras)

      with {:ok, report} <- maybe_compare_checked_report(mode, paths.report, report),
           :ok <- maybe_write_report(mode, paths.report, report, opts) do
        {:ok, report}
      end
    end
  end

  defp merge_comparisons(cmps) do
    failures = Enum.flat_map(cmps, &(&1["failures"] || []))
    count = Enum.reduce(cmps, 0, &(&1["failure_count"] + &2))
    truncated = Enum.any?(cmps, &(&1["truncated"] == true))
    status = if count == 0, do: "ok", else: "failed"

    %{
      "status" => status,
      "failures" => Enum.sort_by(failures, &{&1["reason"], &1["detail"]}),
      "failure_count" => count,
      "truncated" => truncated
    }
  end

  defp load_census(_root, opts, _mode, true = _allow_synthetic) do
    cond do
      is_map(Keyword.get(opts, :census)) ->
        {:ok, Keyword.fetch!(opts, :census)}

      Keyword.has_key?(opts, :inventory) or Keyword.has_key?(opts, :run_git) ->
        SourceCoupling.census_for_test(Keyword.take(opts, [:root, :inventory, :run_git]))

      true ->
        SourceCoupling.census(root: Keyword.get(opts, :root))
    end
  end

  defp load_census(_root, opts, _mode, false) do
    SourceCoupling.census(root: Keyword.get(opts, :root))
  end

  defp load_evidence_blobs(_root, _boundary, _formatter, opts, true) do
    case Keyword.get(opts, :blobs) do
      map when is_map(map) -> {:ok, map}
      nil -> {:ok, %{}}
      _ -> {:error, :invalid_blobs}
    end
  end

  defp load_evidence_blobs(root, boundary, formatter, opts, false) do
    paths = evidence_blob_paths(boundary, formatter, opts)
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    case GitInventory.query_indexed_blobs(root, paths, git_opts) do
      {:ok, %{present: files}} ->
        {:ok, Map.new(files, fn f -> {f.path, f} end)}

      {:error, _} = err ->
        err
    end
  end

  defp evidence_blob_paths(boundary, formatter, opts) do
    (Enum.map(boundary["entries"] || [], & &1["current_path"]) ++
       Enum.map(formatter["files"] || [], & &1["current_path"]) ++
       Enum.map(formatter["configs"] || [], & &1["path"]) ++
       disposition_file_paths(opts))
    |> Enum.uniq()
  end

  defp disposition_file_paths(opts) do
    case Keyword.get(opts, :disposition_files) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp resolve_root(nil), do: SourceCoupling.discover_root(File.cwd!())

  defp resolve_root(path) when is_binary(path) do
    case SafePath.validate(path) do
      :ok ->
        expanded = Path.expand(path)
        marker = Path.join([expanded, "apps", "arbor_contracts", "mix.exs"])

        if File.regular?(marker) do
          {:ok, expanded}
        else
          {:error, :invalid_root_marker}
        end

      {:error, reason} ->
        {:error, {:root_path, reason}}
    end
  end

  defp resolve_paths(root, opts) do
    with {:ok, report} <- resolve_within(root, Keyword.get(opts, :report), @default_report_rel),
         {:ok, disposition} <-
           resolve_within(root, Keyword.get(opts, :disposition), @default_disposition_rel),
         {:ok, boundary} <-
           resolve_within(root, Keyword.get(opts, :boundary), @default_boundary_rel),
         {:ok, formatter} <-
           resolve_within(root, Keyword.get(opts, :formatter), @default_formatter_rel) do
      {:ok,
       %{
         report: report,
         disposition: disposition,
         boundary: boundary,
         formatter: formatter
       }}
    end
  end

  defp resolve_within(root, nil, default_rel), do: SafePath.safe_join(root, default_rel)

  defp resolve_within(root, path, _default) when is_binary(path) do
    if String.starts_with?(path, "/") do
      if SafePath.within?(path, root), do: {:ok, Path.expand(path)}, else: {:error, :path_escape}
    else
      SafePath.safe_join(root, path)
    end
  end

  defp load_json_map(path) do
    cond do
      not File.regular?(path) ->
        {:error, {:manifest_missing, path}}

      true ->
        case File.read(path) do
          {:ok, bytes} ->
            case Jason.decode(bytes) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> {:error, {:manifest_invalid, path}}
            end

          {:error, reason} ->
            {:error, {:manifest_read, path, reason}}
        end
    end
  end

  defp maybe_compare_checked_report("check", path, report) do
    cond do
      not File.regular?(path) ->
        {:error, {:report_missing, path}}

      true ->
        case File.read(path) do
          {:ok, checked_bytes} ->
            compare_checked_bytes(path, checked_bytes, report)

          {:error, reason} ->
            {:error, {:report_read, path, reason}}
        end
    end
  end

  defp maybe_compare_checked_report(_mode, _path, report), do: {:ok, report}

  defp compare_checked_bytes(path, checked_bytes, report) do
    with {:ok, _admitted} <- admit_checked_report(checked_bytes, path),
         {:ok, current_bytes} <- Encode.encode_report(report),
         {:ok, cmp} <- Evidence.compare_report_bytes(checked_bytes, current_bytes) do
      {:ok, merge_report_comparison(report, cmp)}
    end
  end

  defp admit_checked_report(bytes, path) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) ->
        case Evidence.admit_report(map) do
          {:ok, admitted} -> {:ok, admitted}
          {:error, _} -> {:error, {:report_invalid, path}}
        end

      _ ->
        {:error, {:report_invalid, path}}
    end
  end

  defp merge_report_comparison(report, %{"status" => "ok"}), do: report

  defp merge_report_comparison(report, cmp) do
    existing = report["comparison"] || %{}
    merged = merge_comparisons([existing, cmp])
    %{report | "comparison" => merged, "status" => merged["status"]}
  end

  defp maybe_write_report("write_report", path, report, opts) do
    if Keyword.get(opts, :allow_write, false) do
      with {:ok, bytes} <- Encode.encode_report(report),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, bytes) do
        :ok
      else
        {:error, reason} -> {:error, {:report_write, reason}}
      end
    else
      {:error, :write_not_allowed}
    end
  end

  defp maybe_write_report(_mode, _path, _report, _opts), do: :ok
end
