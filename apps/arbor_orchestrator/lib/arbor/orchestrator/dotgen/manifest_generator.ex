defmodule Arbor.Orchestrator.Dotgen.ManifestGenerator do
  @moduledoc """
  Analyzes a codebase and generates a subsystem manifest for dotgen.

  Scans Elixir source files, groups them into logical subsystems based on module
  namespace patterns and functional affinity, and outputs a manifest map that
  drives `.dot` pipeline generation.

  Generic — works for any Elixir codebase. Affinity mappings can be passed
  as options to customize grouping for specific projects.
  """

  alias Arbor.Orchestrator.Dotgen.SourceAnalyzer

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Scans `source_dir` recursively for .ex files, analyzes each with SourceAnalyzer,
  groups them into subsystems, and returns a manifest map.

  ## Options

    * `:exclude_dirs` — list of directory name patterns to skip
      (default: `["deps", "_build", "test"]`)
    * `:base_namespace` — the root module namespace
      (default: auto-detected from source files)
    * `:output` — if given, writes manifest JSON to this path
    * `:affinity_map` — map of module name (short) to subsystem name for
      top-level modules that should be grouped by functional affinity
      rather than namespace. Example: `%{"Node" => "graph", "Edge" => "graph"}`
    * `:merge_rules` — list of `{source_key, target_key}` tuples for merging
      small subsystems into larger ones. Example: `[{"transforms", "graph"}]`
    * `:handler_split` — whether to split a "handlers" group into sub-groups
      (default: false)
    * `:handler_categories` — when `:handler_split` is true, a map of
      category name to list of module name prefixes.
      Example: `%{"eval" => ["Eval"], "meta_handlers" => ["FileWrite", "PipelineRun"]}`

  ## Returns

      {:ok, %{
        "project" => "my_project",
        "base_namespace" => "MyProject",
        "generated_at" => "2026-02-09T...",
        "subsystems" => %{
          "graph" => %{
            "files" => ["lib/my_project/node.ex", ...],
            "goal" => "Implement the graph data model...",
            "module_count" => 10
          },
          ...
        }
      }}
  """
  @spec generate(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def generate(source_dir, opts \\ []) do
    exclude_dirs = Keyword.get(opts, :exclude_dirs, ["deps", "_build", "test"])
    base_namespace = Keyword.get(opts, :base_namespace, nil)
    output_path = Keyword.get(opts, :output, nil)

    with {:ok, file_infos} <- scan_files(source_dir, exclude_dirs),
         {:ok, file_infos} <- ensure_non_empty(file_infos) do
      base_ns = base_namespace || detect_base_namespace(file_infos)
      project_name = base_ns |> String.split(".") |> List.first() |> Macro.underscore()

      subsystems =
        file_infos
        |> group_into_subsystems(base_ns, opts)
        |> Map.new(fn {name, infos} ->
          {name,
           %{
             "files" => Enum.map(infos, & &1.path),
             "goal" => generate_goal(name, infos),
             "module_count" => length(infos)
           }}
        end)

      manifest = %{
        "project" => project_name,
        "base_namespace" => base_ns,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "subsystems" => subsystems
      }

      if output_path do
        File.mkdir_p!(Path.dirname(output_path))
        File.write!(output_path, to_json(manifest))
      end

      {:ok, manifest}
    end
  end

  @doc """
  Groups analyzed file info maps into logical subsystems.

  Applies namespace grouping, optional affinity mapping, optional handler
  splitting, configurable merge rules, and dotgen exclusion.
  """
  @spec group_into_subsystems([SourceAnalyzer.file_info()], String.t(), keyword()) :: %{
          String.t() => [SourceAnalyzer.file_info()]
        }
  def group_into_subsystems(file_infos, base_namespace, opts \\ []) do
    affinity_map = Keyword.get(opts, :affinity_map, %{})
    merge_rules = Keyword.get(opts, :merge_rules, [])
    handler_split = Keyword.get(opts, :handler_split, false)
    handler_categories = Keyword.get(opts, :handler_categories, %{})

    groups =
      file_infos
      |> exclude_dotgen(base_namespace)
      |> initial_grouping(base_namespace, affinity_map)

    groups =
      if handler_split do
        split_handlers(groups, handler_categories)
      else
        groups
      end

    groups =
      Enum.reduce(merge_rules, groups, fn {source, target}, acc ->
        merge_key_into(acc, source, target)
      end)

    reject_empty(groups)
  end

  @doc """
  Generates a descriptive goal string for a subsystem based on its name and contents.
  """
  @spec generate_goal(String.t(), [SourceAnalyzer.file_info()]) :: String.t()
  def generate_goal(subsystem_name, file_infos) do
    module_names =
      file_infos
      |> Enum.map(fn %{module: m} -> m |> String.split(".") |> List.last() end)
      |> Enum.uniq()

    base_description = "Implement the #{subsystem_name |> String.replace("_", " ")} subsystem"
    module_list = Enum.join(module_names, ", ")

    case length(module_names) do
      0 ->
        base_description

      n when n <= 5 ->
        "#{base_description}: #{module_list}"

      n ->
        sample = module_names |> Enum.take(5) |> Enum.join(", ")
        "#{base_description}: #{sample} and #{n - 5} more modules"
    end
  end

  @doc """
  Serializes the manifest to pretty-printed JSON.
  """
  @spec to_json(map()) :: String.t()
  def to_json(manifest) do
    Jason.encode!(manifest, pretty: true)
  end

  @doc """
  Deserializes a manifest from JSON.
  """
  @spec from_json(String.t()) :: {:ok, map()} | {:error, String.t()}
  def from_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, reason} -> {:error, "JSON parse error: #{inspect(reason)}"}
    end
  end

  # ── File Scanning ───────────────────────────────────────────────────

  defp scan_files(source_dir, exclude_dirs) do
    if File.dir?(source_dir) do
      files =
        Path.wildcard(Path.join(source_dir, "**/*.ex"))
        |> Enum.reject(fn path ->
          path_parts = Path.split(path)
          Enum.any?(exclude_dirs, fn dir -> dir in path_parts end)
        end)
        |> Enum.sort()

      analyze_files(files)
    else
      {:error, "Directory not found: #{source_dir}"}
    end
  end

  defp analyze_files(paths) do
    results =
      Enum.reduce(paths, {:ok, []}, fn path, acc ->
        case acc do
          {:ok, infos} ->
            case SourceAnalyzer.analyze_file(path) do
              {:ok, info} -> {:ok, [info | infos]}
              {:error, _reason} -> {:ok, infos}
            end

          error ->
            error
        end
      end)

    case results do
      {:ok, infos} -> {:ok, Enum.reverse(infos)}
      error -> error
    end
  end

  defp ensure_non_empty([]), do: {:error, "No .ex files found in source directory"}
  defp ensure_non_empty(file_infos), do: {:ok, file_infos}

  # ── Namespace Detection ─────────────────────────────────────────────

  defp detect_base_namespace(file_infos) do
    modules =
      file_infos
      |> Enum.map(fn %{module: m} -> m end)
      |> Enum.reject(&(is_nil(&1) or String.starts_with?(&1, "Mix.Tasks.")))

    case modules do
      [] ->
        "Unknown"

      [single] ->
        single |> String.split(".") |> Enum.take(2) |> Enum.join(".")

      multiple ->
        segments_list = Enum.map(multiple, &String.split(&1, "."))

        common =
          segments_list
          |> Enum.reduce(fn segs, acc ->
            Enum.zip(acc, segs)
            |> Enum.take_while(fn {a, b} -> a == b end)
            |> Enum.map(fn {a, _} -> a end)
          end)

        # Use the longest common prefix, but at least 2 segments if available
        prefix =
          case length(common) do
            0 -> segments_list |> List.first() |> Enum.take(1)
            1 -> common
            _ -> common
          end

        Enum.join(prefix, ".")
    end
  end

  # ── Initial Grouping ────────────────────────────────────────────────

  defp exclude_dotgen(file_infos, base_namespace) do
    dotgen_prefix = base_namespace <> ".Dotgen"

    Enum.reject(file_infos, fn %{module: module} ->
      module != nil and
        (String.starts_with?(module, dotgen_prefix <> ".") or module == dotgen_prefix)
    end)
  end

  defp initial_grouping(file_infos, base_namespace, affinity_map) do
    Enum.group_by(file_infos, fn %{module: module} ->
      cond do
        module == nil ->
          "unknown"

        String.starts_with?(module, "Mix.Tasks.") ->
          "mix_tasks"

        true ->
          namespace_segment(module, base_namespace, affinity_map)
      end
    end)
  end

  defp namespace_segment(module, base_namespace, affinity_map) do
    base_prefix = base_namespace <> "."

    cond do
      String.starts_with?(module, base_prefix) ->
        suffix = String.replace_prefix(module, base_prefix, "")
        parts = String.split(suffix, ".")

        case parts do
          [single] ->
            # Top-level module directly under base namespace — check affinity
            Map.get(affinity_map, single, Macro.underscore(single))

          [first | _rest] ->
            # Has sub-namespace — group by first segment
            Macro.underscore(first)
        end

      module == base_namespace ->
        # The base module itself
        base_namespace |> String.split(".") |> List.last() |> Macro.underscore()

      true ->
        # Module outside the base namespace
        module |> String.split(".") |> List.last() |> Macro.underscore()
    end
  end

  # ── Handler Splitting ───────────────────────────────────────────────

  defp split_handlers(groups, categories) do
    case Map.pop(groups, "handlers") do
      {nil, groups} ->
        groups

      {handler_files, groups} ->
        if map_size(categories) == 0 do
          Map.put(groups, "handlers", handler_files)
        else
          categorize_handlers(groups, handler_files, categories)
        end
    end
  end

  defp categorize_handlers(groups, handler_files, categories) do
    {categorized, remaining} =
      Enum.reduce(categories, {%{}, handler_files}, fn {cat_name, prefixes}, {cats, rest} ->
        {matched, unmatched} = split_by_prefixes(rest, prefixes)
        {Map.put(cats, cat_name, matched), unmatched}
      end)

    groups =
      Enum.reduce(categorized, groups, fn {cat_name, files}, acc ->
        merge_into(acc, cat_name, files)
      end)

    merge_into(groups, "core_handlers", remaining)
  end

  defp split_by_prefixes(files, prefixes) do
    Enum.split_with(files, fn %{module: m} ->
      last = m |> String.split(".") |> List.last()
      Enum.any?(prefixes, fn prefix -> String.starts_with?(last, prefix) end)
    end)
  end

  # ── Group Merging ───────────────────────────────────────────────────

  defp merge_key_into(groups, source_key, target_key) do
    case Map.pop(groups, source_key) do
      {nil, groups} -> groups
      {files, groups} -> merge_into(groups, target_key, files)
    end
  end

  defp merge_into(groups, _key, []), do: groups

  defp merge_into(groups, key, files) do
    Map.update(groups, key, files, fn existing -> existing ++ files end)
  end

  defp reject_empty(groups) do
    groups
    |> Enum.reject(fn {_key, files} -> files == [] end)
    |> Map.new()
  end
end
