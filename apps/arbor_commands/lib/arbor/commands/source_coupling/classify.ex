defmodule Arbor.Commands.SourceCoupling.Classify do
  @moduledoc """
  Pure classification of cross-app references into declared/undeclared edges
  with package band, fate, and level direction.
  """

  alias Arbor.Commands.SourceCoupling.{Bands, Ownership}

  @max_findings_sample 500

  @private_band "private"
  @private_apps MapSet.new(["arbor_integrations"])

  @doc """
  Classify references against ownership, deps, and levels.

  Options:
  - `:compatibility` — allow private apps (e.g. arbor_integrations) as from/to
    bands without failing; used only for the non-gating compatibility projection.
  """
  @spec classify(map()) :: {:ok, map()} | {:error, term()}
  @spec classify(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify(input, opts \\ [])

  def classify(
        %{
          references: references,
          unresolved: unresolved,
          module_owners: owners,
          dep_graph: dep_graph,
          levels: levels,
          file_apps: file_apps
        },
        opts
      )
      when is_list(references) and is_list(unresolved) and is_map(owners) and is_map(dep_graph) and
             is_map(levels) and is_map(file_apps) and is_list(opts) do
    compatibility? = Keyword.get(opts, :compatibility, false)

    with {:ok, raw_edges} <- build_edges(references, owners, file_apps),
         {:ok, classified} <-
           attach_metadata(raw_edges, dep_graph, levels, compatibility?),
         occurrences <- aggregate_occurrences(classified),
         unresolved_agg <- aggregate_unresolved(unresolved) do
      # Sample general and undeclared universes independently so declared edges
      # that sort earlier cannot starve undeclared findings past the bound.
      undeclared_edges = Enum.filter(classified, &(&1.declared == false))

      {:ok,
       %{
         occurrences: occurrences,
         samples: sample_findings(classified),
         undeclared_samples: sample_findings(undeclared_edges),
         edges: edge_maps(classified),
         unresolved: unresolved_agg,
         unresolved_samples: Enum.take(Enum.sort_by(unresolved, &unresolved_sort/1), 200),
         errors: []
       }}
    end
  end

  def classify(_, _), do: {:error, :invalid_classify_input}

  defp build_edges(references, owners, file_apps) do
    Enum.reduce_while(references, {:ok, []}, fn ref, {:ok, acc} ->
      file = Map.fetch!(ref, :file)
      target = Map.fetch!(ref, :target)
      from_app = Map.get(file_apps, file) || app_from_path(file)

      case Map.fetch(owners, target) do
        {:ok, to_app} when is_binary(from_app) and to_app == from_app ->
          {:cont, {:ok, acc}}

        {:ok, to_app} when is_binary(from_app) ->
          edge = %{
            file: file,
            line: Map.get(ref, :line, 0),
            from_module: Map.get(ref, :from_module, ""),
            target: target,
            kind: Map.get(ref, :kind, "remote"),
            class: Map.get(ref, :class, "code"),
            from_app: from_app,
            to_app: to_app
          }

          {:cont, {:ok, [edge | acc]}}

        :error ->
          # external module — ignore
          {:cont, {:ok, acc}}

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp app_from_path(path) do
    case Ownership.app_of_path(path) do
      {:ok, app} -> app
      _ -> nil
    end
  end

  defp attach_metadata(edges, dep_graph, levels, compatibility?) do
    Enum.reduce_while(edges, {:ok, []}, fn edge, {:ok, acc} ->
      from_app = edge.from_app
      to_app = edge.to_app
      deps = Map.get(dep_graph, from_app, [])
      declared = to_app in deps

      with {:ok, from_band} <- resolve_band(from_app, compatibility?),
           {:ok, to_band} <- resolve_band(to_app, compatibility?),
           {:ok, fate} <- resolve_fate(from_band, to_band) do
        level_direction = Ownership.level_direction(from_app, to_app, levels)

        full = %{
          file: edge.file,
          line: edge.line,
          from_module: edge.from_module,
          target: edge.target,
          kind: edge.kind,
          class: edge.class,
          from_app: from_app,
          to_app: to_app,
          from_band: from_band,
          to_band: to_band,
          band_pair: band_pair_label(from_band, to_band),
          fate: fate,
          level_direction: level_direction,
          declared: declared
        }

        {:cont, {:ok, [full | acc]}}
      else
        {:error, :unknown_package_band} ->
          {:halt, {:error, {:unknown_package_band, from_app, to_app}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_band(app, compatibility?) do
    case Bands.band_of(app) do
      {:ok, band} ->
        {:ok, band}

      {:error, :unknown_package_band} ->
        if compatibility? and MapSet.member?(@private_apps, app) do
          {:ok, @private_band}
        else
          {:error, :unknown_package_band}
        end
    end
  end

  defp resolve_fate(@private_band, @private_band), do: {:ok, "intra_private"}
  defp resolve_fate(@private_band, _to), do: {:ok, "private_to_tracked"}
  defp resolve_fate(_from, @private_band), do: {:ok, "tracked_to_private"}
  defp resolve_fate(from_band, to_band), do: Bands.fate(from_band, to_band)

  defp band_pair_label(@private_band, to_band), do: @private_band <> "->" <> to_band
  defp band_pair_label(from_band, @private_band), do: from_band <> "->" <> @private_band
  defp band_pair_label(from_band, to_band), do: Bands.band_pair(from_band, to_band)

  defp aggregate_occurrences(classified) do
    classified
    |> Enum.group_by(&occurrence_key/1)
    |> Enum.map(fn {key, group} ->
      sample = hd(group)

      %{
        "file" => key.file,
        "from_module" => key.from_module,
        "target" => key.target,
        "kind" => key.kind,
        "class" => key.class,
        "from_app" => sample.from_app,
        "to_app" => sample.to_app,
        "from_band" => sample.from_band,
        "to_band" => sample.to_band,
        "fate" => sample.fate,
        "level_direction" => sample.level_direction,
        "declared" => sample.declared,
        "band_pair" => sample.band_pair,
        "occurrence_count" => length(group)
      }
    end)
    |> Enum.sort_by(&occurrence_sort/1)
  end

  defp occurrence_key(edge) do
    %{
      file: edge.file,
      from_module: edge.from_module,
      target: edge.target,
      kind: edge.kind,
      class: edge.class
    }
  end

  defp occurrence_sort(occ) do
    {occ["file"], occ["from_module"], occ["target"], occ["kind"], occ["class"]}
  end

  defp sample_findings(classified) do
    classified
    |> Enum.sort_by(fn e -> {e.file, e.line, e.from_module, e.target, e.kind} end)
    |> Enum.take(@max_findings_sample)
    |> Enum.map(&edge_map/1)
  end

  # attach_metadata/4 prepends over the already-reversed build_edges/3
  # accumulator, so `classified` is encounter order.
  defp edge_maps(classified) when is_list(classified) do
    classified
    |> Enum.with_index(1)
    |> Enum.map(fn {edge, seq} -> Map.put(edge_map(edge), "extract_seq", seq) end)
  end

  defp edge_map(e) do
    %{
      "file" => e.file,
      "line" => e.line,
      "from_module" => e.from_module,
      "target" => e.target,
      "kind" => e.kind,
      "class" => e.class,
      "from_app" => e.from_app,
      "to_app" => e.to_app,
      "from_band" => e.from_band,
      "to_band" => e.to_band,
      "band_pair" => e.band_pair,
      "fate" => e.fate,
      "level_direction" => e.level_direction,
      "declared" => e.declared,
      "occurrence_key_count" => 1
    }
  end

  defp aggregate_unresolved(items) when is_list(items) do
    items
    |> Enum.group_by(fn u ->
      {
        Map.get(u, :file) || Map.get(u, "file"),
        Map.get(u, :from_module) || Map.get(u, "from_module") || "",
        Map.get(u, :reason) || Map.get(u, "reason"),
        Map.get(u, :kind) || Map.get(u, "kind"),
        Map.get(u, :expression_digest) || Map.get(u, "expression_digest")
      }
    end)
    |> Enum.map(fn {{file, from_module, reason, kind, digest}, group} ->
      sample = hd(group)

      %{
        "file" => file,
        "from_module" => from_module,
        "reason" => reason,
        "kind" => kind,
        "expression_digest" => digest,
        "normalized_expression" =>
          Map.get(sample, :normalized_expression) || Map.get(sample, "normalized_expression") ||
            "",
        "occurrence_count" => length(group)
      }
    end)
    |> Enum.sort_by(fn u ->
      {u["file"], u["from_module"], u["reason"], u["kind"], u["expression_digest"]}
    end)
  end

  defp unresolved_sort(u) do
    {
      Map.get(u, :file) || "",
      Map.get(u, :line) || 0,
      Map.get(u, :expression_digest) || ""
    }
  end

  @doc "True if occurrence must be baselined (gating)."
  @spec gating?(map()) :: boolean()
  def gating?(occ) when is_map(occ) do
    declared = Map.get(occ, "declared", Map.get(occ, :declared, true))
    fate = Map.get(occ, "fate", Map.get(occ, :fate))
    undeclared = declared == false
    upward = fate == "upward"
    undeclared or upward
  end

  def gating?(_), do: false
end
