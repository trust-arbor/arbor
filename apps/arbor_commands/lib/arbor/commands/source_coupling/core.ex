defmodule Arbor.Commands.SourceCoupling.Core do
  @moduledoc """
  CRC pipeline for source-coupling census: construct → classify → compare → show.

  Pure: accepts an in-memory scan bundle (path, blob_oid, bytes) plus provenance.
  """

  alias Arbor.Commands.SourceCoupling.{
    AstExtract,
    Baseline,
    Classify,
    Encode,
    Ownership
  }

  @report_schema "arbor.packaging.source_coupling.report.v1"

  @provisional_undeclared_occurrences 234
  @provisional_app_pairs 57
  @provisional_level_upward 108
  @provisional_intra 124
  @provisional_downward 54
  @provisional_upward 56

  @doc """
  Build a census from a scan bundle.

  Bundle keys:
  - `:files` — list of `%{path, blob_oid, bytes}`
  - `:tree_oid` — provenance string
  - `:object_format` — \"sha1\" | \"sha256\"
  - optional `:include_integrations` private files already tagged
  """
  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(bundle) when is_map(bundle) do
    files = Map.get(bundle, :files) || Map.get(bundle, "files") || []
    tree_oid = Map.get(bundle, :tree_oid) || Map.get(bundle, "tree_oid") || ""
    object_format = Map.get(bundle, :object_format) || Map.get(bundle, "object_format") || "sha1"

    with :ok <- validate_files(files),
         {:ok, mix_graph, source_files, file_apps} <- partition_files(files),
         {:ok, levels} <- Ownership.compute_levels(mix_graph),
         {:ok, extracted} <- extract_all(source_files),
         {:ok, owners} <-
           Ownership.build_module_owners(attach_apps(extracted.module_defs, file_apps)),
         {:ok, classified} <-
           Classify.classify(%{
             references: extracted.references,
             unresolved: extracted.unresolved,
             module_owners: owners,
             dep_graph: mix_graph,
             levels: levels,
             file_apps: file_apps
           }) do
      manifest_pairs =
        files
        |> Enum.map(fn f -> {file_path(f), file_oid(f)} end)
        |> Enum.sort_by(&elem(&1, 0))

      scan_manifest_digest = Encode.scan_manifest_digest(manifest_pairs)

      occurrences = classified.occurrences
      gating = Enum.filter(occurrences, &Classify.gating?/1)

      provenance_source =
        Map.get(bundle, :provenance_source) || Map.get(bundle, "provenance_source") || "unknown"

      census = %{
        "provenance" => %{
          "tree_oid" => tree_oid,
          "scan_manifest_digest" => scan_manifest_digest,
          "object_format" => object_format,
          "provenance_source" => provenance_source,
          "app_count" => map_size(mix_graph),
          "tracked_file_count" => length(files),
          "source_file_count" => length(source_files)
        },
        "occurrences" => occurrences,
        "gating_occurrences" => gating,
        "samples" => classified.samples,
        "undeclared_samples" => classified.undeclared_samples,
        "unresolved" => classified.unresolved,
        "unresolved_samples" => classified.unresolved_samples,
        "dep_graph" => mix_graph,
        "levels" => levels,
        "module_owners" => owners,
        "extract_errors" => extracted.errors
      }

      {:ok, census}
    end
  end

  def new(_), do: {:error, :invalid_bundle}

  @doc """
  Non-gating compatibility projection for private integrations source.

  Scans private files (e.g. `apps/arbor_integrations/**`) while resolving
  module targets and hierarchy against the **canonical** ownership map,
  dep graph, and levels from a completed census. Results must never enter
  the canonical baseline or gating set.
  """
  @spec project_compatibility([map()], map()) :: {:ok, map()} | {:error, term()}
  def project_compatibility(private_files, census)
      when is_list(private_files) and is_map(census) do
    canonical_owners = Map.get(census, "module_owners") || %{}
    canonical_graph = Map.get(census, "dep_graph") || %{}
    canonical_levels = Map.get(census, "levels") || %{}

    with :ok <- validate_files(private_files),
         {:ok, private_graph, source_files, file_apps} <-
           partition_private_files(private_files),
         {:ok, extracted} <- extract_all(source_files),
         {:ok, private_owners} <-
           Ownership.build_module_owners(attach_apps(extracted.module_defs, file_apps)),
         owners <- Map.merge(canonical_owners, private_owners),
         dep_graph <- Map.merge(canonical_graph, private_graph),
         {:ok, classified} <-
           Classify.classify(
             %{
               references: extracted.references,
               unresolved: extracted.unresolved,
               module_owners: owners,
               dep_graph: dep_graph,
               levels: canonical_levels,
               file_apps: file_apps
             },
             compatibility: true
           ) do
      occurrences = classified.occurrences

      # Never treat compatibility edges as baseline-gating.
      {:ok,
       %{
         "source" => "private_opt_in",
         "file_count" => length(private_files),
         "source_file_count" => length(source_files),
         "occurrences" => occurrences,
         "samples" => classified.samples,
         "undeclared_samples" => classified.undeclared_samples,
         "unresolved" => classified.unresolved,
         "unresolved_samples" => classified.unresolved_samples,
         "gating" => false,
         "note" => "non_gating_projection_against_canonical_ownership"
       }}
    end
  end

  def project_compatibility(_, _), do: {:error, :invalid_compatibility_args}

  @doc "Compare census to baseline for check mode; build write plan for write mode."
  @spec compare(map(), String.t(), map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def compare(census, mode, baseline_raw, review \\ %{})

  def compare(census, "report", _baseline_raw, _review) when is_map(census) do
    {:ok, %{"mode" => "report", "baseline" => nil, "comparison" => nil, "write_plan" => nil}}
  end

  def compare(census, "check", baseline_raw, _review)
      when is_map(census) and is_map(baseline_raw) do
    with {:ok, baseline} <- Baseline.admit(baseline_raw),
         {:ok, comparison} <-
           Baseline.compare(
             baseline,
             census["gating_occurrences"],
             census["unresolved"]
           ) do
      {:ok,
       %{
         "mode" => "check",
         "baseline" => baseline,
         "comparison" => comparison,
         "write_plan" => nil
       }}
    end
  end

  def compare(census, "write_baseline", baseline_raw, review)
      when is_map(census) and is_map(review) do
    prior =
      case baseline_raw do
        raw when is_map(raw) ->
          case Baseline.admit(raw) do
            {:ok, b} -> b
            _ -> nil
          end

        nil ->
          nil

        _ ->
          nil
      end

    # Compatibility projection is never written into the canonical baseline.
    census_for_build =
      census
      |> Map.put("compatibility", nil)
      |> Map.put("counts", counts_snapshot(census))

    with {:ok, doc} <- Baseline.build(census_for_build, prior, review) do
      {:ok,
       %{
         "mode" => "write_baseline",
         "baseline" => prior,
         "comparison" => nil,
         "write_plan" => doc
       }}
    end
  end

  def compare(_, _, _, _), do: {:error, :invalid_compare_args}

  @doc "Render final report map (string keys, sorted collections)."
  @spec show(map(), map()) :: map()
  def show(census, compare_result) when is_map(census) and is_map(compare_result) do
    mode = compare_result["mode"] || "report"
    comparison = compare_result["comparison"]

    status =
      cond do
        mode == "check" and is_map(comparison) and comparison["status"] == "failed" ->
          "failed"

        mode == "check" and is_map(comparison) ->
          "ok"

        true ->
          "ok"
      end

    summaries = build_summaries(census)
    undeclared_block = build_undeclared(census)
    # Provisional series compare against the undeclared universe only; general
    # all-occurrence census metrics remain in summaries.
    provisional = build_provisional_delta(undeclared_block)

    %{
      "schema" => @report_schema,
      "mode" => mode,
      "status" => status,
      # Shell overwrites with explicit "json" | "human" from the CLI flag.
      "output" => Map.get(census, "output") || "human",
      "provenance" => census["provenance"],
      "summaries" => summaries,
      "undeclared" => undeclared_block,
      "unresolved" => %{
        "count" => length(census["unresolved"] || []),
        "items" => Enum.take(census["unresolved_samples"] || [], 200)
      },
      "baseline" => comparison,
      "provisional_delta" => provisional,
      "compatibility" => Map.get(census, "compatibility"),
      "errors" => census["extract_errors"] || [],
      "write_plan" => compare_result["write_plan"]
    }
  end

  defp validate_files(files) when is_list(files) do
    if length(files) > 50_000, do: {:error, :file_limit}, else: :ok
  end

  defp validate_files(_), do: {:error, :invalid_files}

  defp partition_files(files) do
    Enum.reduce_while(files, {:ok, %{}, [], %{}}, fn f, {:ok, graph, sources, file_apps} ->
      path = file_path(f)
      bytes = file_bytes(f)

      cond do
        # Private integrations never enter the canonical census path.
        private_integrations_path?(path) ->
          {:cont, {:ok, graph, sources, file_apps}}

        Ownership.mix_project_path?(path) ->
          with {:ok, app} <- Ownership.app_of_path(path),
               {:ok, deps} <- Ownership.in_umbrella_deps(bytes) do
            {:cont, {:ok, Map.put(graph, app, deps), sources, Map.put(file_apps, path, app)}}
          else
            {:error, reason} -> {:halt, {:error, {:mix_file, path, reason}}}
          end

        Ownership.lib_source_path?(path) ->
          with {:ok, app} <- Ownership.app_of_path(path) do
            graph = Map.put_new(graph, app, Map.get(graph, app, []))
            {:cont, {:ok, graph, [f | sources], Map.put(file_apps, path, app)}}
          else
            {:error, reason} -> {:halt, {:error, {:source_file, path, reason}}}
          end

        true ->
          {:cont, {:ok, graph, sources, file_apps}}
      end
    end)
    |> case do
      {:ok, graph, sources, file_apps} ->
        # ensure all graph apps present even without lib files
        {:ok, graph, Enum.reverse(sources), file_apps}

      err ->
        err
    end
  end

  # Compatibility-only partition: admit private integrations mix + lib sources.
  defp partition_private_files(files) do
    Enum.reduce_while(files, {:ok, %{}, [], %{}}, fn f, {:ok, graph, sources, file_apps} ->
      path = file_path(f)
      bytes = file_bytes(f)

      cond do
        not private_integrations_path?(path) ->
          {:halt, {:error, {:compatibility_path_not_private, path}}}

        private_mix_path?(path) ->
          with {:ok, app} <- Ownership.app_of_path(path),
               {:ok, deps} <- Ownership.in_umbrella_deps(bytes) do
            {:cont, {:ok, Map.put(graph, app, deps), sources, Map.put(file_apps, path, app)}}
          else
            {:error, reason} -> {:halt, {:error, {:mix_file, path, reason}}}
          end

        private_lib_path?(path) ->
          with {:ok, app} <- Ownership.app_of_path(path) do
            graph = Map.put_new(graph, app, Map.get(graph, app, []))
            {:cont, {:ok, graph, [f | sources], Map.put(file_apps, path, app)}}
          else
            {:error, reason} -> {:halt, {:error, {:source_file, path, reason}}}
          end

        true ->
          {:cont, {:ok, graph, sources, file_apps}}
      end
    end)
    |> case do
      {:ok, graph, sources, file_apps} ->
        {:ok, graph, Enum.reverse(sources), file_apps}

      err ->
        err
    end
  end

  defp private_integrations_path?(path) when is_binary(path) do
    String.starts_with?(path, "apps/arbor_integrations/")
  end

  defp private_integrations_path?(_), do: false

  defp private_mix_path?(path) do
    case Path.split(path) do
      ["apps", "arbor_integrations", "mix.exs"] -> true
      _ -> false
    end
  end

  defp private_lib_path?(path) do
    parts = Path.split(path)

    case parts do
      ["apps", "arbor_integrations", "lib" | rest] when rest != [] ->
        name = List.last(parts)
        String.ends_with?(name, ".ex") or String.ends_with?(name, ".exs")

      _ ->
        false
    end
  end

  defp extract_all(source_files) do
    Enum.reduce_while(source_files, {:ok, empty_extract()}, fn f, {:ok, acc} ->
      path = file_path(f)
      bytes = file_bytes(f)

      case AstExtract.extract(path, bytes) do
        {:ok, result} ->
          {:cont,
           {:ok,
            %{
              module_defs: acc.module_defs ++ result.module_defs,
              references: acc.references ++ result.references,
              unresolved: acc.unresolved ++ result.unresolved,
              errors: acc.errors ++ result.errors
            }}}

        {:error, reason} ->
          {:halt, {:error, {:extract_failed, path, reason}}}
      end
    end)
  end

  defp empty_extract do
    %{module_defs: [], references: [], unresolved: [], errors: []}
  end

  defp attach_apps(defs, file_apps) do
    Enum.map(defs, fn d ->
      file = Map.get(d, :file) || Map.get(d, "file")
      app = Map.get(file_apps, file)
      Map.put(d, :app, app)
    end)
  end

  defp file_path(%{path: p}), do: p
  defp file_path(%{"path" => p}), do: p
  defp file_oid(%{blob_oid: o}), do: o
  defp file_oid(%{"blob_oid" => o}), do: o
  defp file_bytes(%{bytes: b}), do: b
  defp file_bytes(%{"bytes" => b}), do: b

  defp build_summaries(census) do
    occs = census["occurrences"] || []

    sum_count = fn list -> Enum.reduce(list, 0, &(&1["occurrence_count"] + &2)) end

    total = sum_count.(occs)
    declared = occs |> Enum.filter(&(&1["declared"] == true)) |> sum_count.()
    undeclared = occs |> Enum.filter(&(&1["declared"] == false)) |> sum_count.()
    code = occs |> Enum.filter(&(&1["class"] == "code")) |> sum_count.()
    typespec_only = occs |> Enum.filter(&(&1["class"] == "typespec_only")) |> sum_count.()

    pairs =
      occs
      |> Enum.map(&{&1["from_app"], &1["to_app"]})
      |> Enum.uniq()

    undeclared_pairs =
      occs
      |> Enum.filter(&(&1["declared"] == false))
      |> Enum.map(&{&1["from_app"], &1["to_app"]})
      |> Enum.uniq()

    level = %{
      "level_downward" => sum_dir(occs, "level_direction", "level_downward"),
      "level_same" => sum_dir(occs, "level_direction", "level_same"),
      "level_upward" => sum_dir(occs, "level_direction", "level_upward")
    }

    fate = %{
      "intra_band" => sum_dir(occs, "fate", "intra_band"),
      "downward" => sum_dir(occs, "fate", "downward"),
      "upward" => sum_dir(occs, "fate", "upward")
    }

    band_pairs =
      occs
      |> Enum.group_by(& &1["band_pair"])
      |> Enum.map(fn {pair, group} -> {pair, sum_count.(group)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Map.new()

    %{
      "occurrences" => %{
        "total" => total,
        "declared" => declared,
        "undeclared" => undeclared,
        "code" => code,
        "typespec_only" => typespec_only
      },
      "app_pairs" => %{
        "total" => length(pairs),
        "undeclared" => length(undeclared_pairs)
      },
      "hierarchy_direction" => level,
      "bands" => %{"pairs" => band_pairs},
      "fate" => fate,
      "unresolved" => %{"count" => length(census["unresolved"] || [])}
    }
  end

  defp sum_dir(occs, field, value) do
    occs
    |> Enum.filter(&(&1[field] == value))
    |> Enum.reduce(0, &(&1["occurrence_count"] + &2))
  end

  defp build_undeclared(census) do
    occs = census["occurrences"] || []
    undeclared = Enum.filter(occs, &(&1["declared"] == false))

    pairs =
      undeclared
      |> Enum.group_by(&{&1["from_app"], &1["to_app"]})
      |> Enum.map(fn {{from, to}, group} ->
        %{
          "from_app" => from,
          "to_app" => to,
          "occurrence_count" => Enum.reduce(group, 0, &(&1["occurrence_count"] + &2))
        }
      end)
      |> Enum.sort_by(&{&1["from_app"], &1["to_app"]})

    # Findings come from Classify's undeclared-only sample (filter-then-bound).
    # Never re-filter a general truncated sample — declared edges would starve later undeclared ones.
    findings =
      census["undeclared_samples"]
      |> List.wrap()
      |> Enum.take(500)

    # Level-upward and band-fate for provisional series are undeclared-universe only.
    level_upward = sum_dir(undeclared, "level_direction", "level_upward")

    fate = %{
      "intra_band" => sum_dir(undeclared, "fate", "intra_band"),
      "downward" => sum_dir(undeclared, "fate", "downward"),
      "upward" => sum_dir(undeclared, "fate", "upward")
    }

    undeclared_occ_count = Enum.reduce(undeclared, 0, &(&1["occurrence_count"] + &2))

    %{
      "occurrence_count" => undeclared_occ_count,
      "app_pair_count" => length(pairs),
      "upward_occurrence_count" => level_upward,
      "fate" => fate,
      "pairs" => Enum.take(pairs, 100),
      "findings" => findings
    }
  end

  defp counts_snapshot(census) do
    summaries = build_summaries(census)
    undeclared = build_undeclared(census)

    %{
      "undeclared_occurrences" => undeclared["occurrence_count"],
      "app_pairs" => undeclared["app_pair_count"],
      "level_upward" => summaries["hierarchy_direction"]["level_upward"],
      "intra_band" => summaries["fate"]["intra_band"],
      "downward" => summaries["fate"]["downward"],
      "upward" => summaries["fate"]["upward"],
      "unresolved" => length(census["unresolved"] || [])
    }
  end

  defp build_provisional_delta(undeclared) when is_map(undeclared) do
    actual_u = undeclared["occurrence_count"] || 0
    actual_pairs = undeclared["app_pair_count"] || 0
    # Explicitly derived from the undeclared occurrence universe (not all-occurrence).
    actual_level_up = undeclared["upward_occurrence_count"] || 0
    fate = undeclared["fate"] || %{}
    actual_intra = fate["intra_band"] || 0
    actual_down = fate["downward"] || 0
    actual_up = fate["upward"] || 0

    %{
      "undeclared" => %{
        "reference" => %{
          "occurrences" => @provisional_undeclared_occurrences,
          "app_pairs" => @provisional_app_pairs
        },
        "actual" => %{"occurrences" => actual_u, "app_pairs" => actual_pairs},
        "deltas" => %{
          "occurrences" => actual_u - @provisional_undeclared_occurrences,
          "app_pairs" => actual_pairs - @provisional_app_pairs
        },
        "explanation" =>
          explain_series(
            "undeclared",
            actual_u,
            @provisional_undeclared_occurrences,
            actual_pairs,
            @provisional_app_pairs
          )
      },
      "level_hierarchy" => %{
        "reference" => %{"level_upward" => @provisional_level_upward},
        "actual" => %{"level_upward" => actual_level_up},
        "deltas" => %{"level_upward" => actual_level_up - @provisional_level_upward},
        "explanation" => explain_one("level_upward", actual_level_up, @provisional_level_upward)
      },
      "band_fate" => %{
        "reference" => %{
          "intra_band" => @provisional_intra,
          "downward" => @provisional_downward,
          "upward" => @provisional_upward
        },
        "actual" => %{
          "intra_band" => actual_intra,
          "downward" => actual_down,
          "upward" => actual_up
        },
        "deltas" => %{
          "intra_band" => actual_intra - @provisional_intra,
          "downward" => actual_down - @provisional_downward,
          "upward" => actual_up - @provisional_upward
        },
        "explanation" =>
          "band_fate actual intra=#{actual_intra} down=#{actual_down} up=#{actual_up} " <>
            "vs provisional #{@provisional_intra}/#{@provisional_downward}/#{@provisional_upward}"
      }
    }
  end

  defp explain_series(name, a1, r1, a2, r2) do
    if a1 == r1 and a2 == r2 do
      "matches provisional #{name} #{r1}/#{r2}"
    else
      "#{name} actual #{a1}/#{a2} vs provisional #{r1}/#{r2} " <>
        "(blob-exact scan, lib .ex/.exs, lexical aliases, typespec gating)"
    end
  end

  defp explain_one(name, actual, ref) do
    if actual == ref do
      "matches provisional #{name}=#{ref}"
    else
      "#{name} actual=#{actual} vs provisional=#{ref}"
    end
  end
end
