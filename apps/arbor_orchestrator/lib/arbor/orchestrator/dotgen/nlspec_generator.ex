defmodule Arbor.Orchestrator.Dotgen.NLSpecGenerator do
  @moduledoc """
  Generates Natural Language Specification (NLSpec) documents from analyzed source code.

  Takes SourceAnalyzer output (file_info maps) and produces structured markdown
  that describes the software's behavior, data structures, and APIs in plain
  English — precise enough for AI-assisted reimplementation.

  Unlike DotGenerator.format_file_prompt (which produces LLM implementation prompts),
  this generates human-readable specification documents following the same format
  as hand-written specs.

  The output format has these sections per subsystem:
    1. Overview (derived from moduledocs)
    2. Data Structures (structs, types)
    3. Public API (function signatures, specs, docs)
    4. Behaviours and Callbacks
    5. Configuration (module attributes)
    6. Implementation Notes (key private functions, clauses, branches)

  For a full project, it generates:
    - Table of Contents
    - Per-subsystem sections (using ManifestGenerator groupings)
    - Module Index
  """

  alias Arbor.Orchestrator.Dotgen.SourceAnalyzer

  @noise_attributes ~w(moduledoc doc spec impl behaviour derive)a

  # ── Public API ──────────────────────────────────────────────

  @doc "Generate NLSpec markdown for a single module from its file_info map."
  @spec generate_module_spec(SourceAnalyzer.file_info(), keyword()) :: String.t()
  def generate_module_spec(file_info, opts \\ []) do
    include_private = Keyword.get(opts, :include_private, false)

    [
      "### #{file_info.module}\n",
      format_overview(file_info),
      format_data_structures(file_info),
      format_public_api(file_info),
      format_behaviours(file_info),
      format_configuration(file_info),
      format_implementation_notes(file_info, include_private)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "Generate NLSpec for a subsystem (group of related modules)."
  @spec generate_subsystem_spec(String.t(), [SourceAnalyzer.file_info()], keyword()) :: String.t()
  def generate_subsystem_spec(subsystem_name, file_infos, opts \\ []) do
    goal = Keyword.get(opts, :goal)
    include_private = Keyword.get(opts, :include_private, false)

    header = "## #{subsystem_name}\n"
    goal_paragraph = if goal, do: "\n#{goal}\n"

    module_specs =
      file_infos
      |> Enum.sort_by(& &1.module)
      |> Enum.map_join("\n---\n\n", &generate_module_spec(&1, include_private: include_private))

    test_section = format_test_coverage(file_infos)

    [header, goal_paragraph, "\n", module_specs, test_section]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  @doc "Generate a full project NLSpec from a manifest and source analysis."
  @spec generate_project_spec(map(), keyword()) :: String.t()
  def generate_project_spec(manifest, opts \\ []) do
    title = Keyword.get(opts, :title, manifest["project"] || "Project")
    include_private = Keyword.get(opts, :include_private, false)
    include_toc = Keyword.get(opts, :include_toc, true)

    subsystems = manifest["subsystems"] || %{}
    sorted_names = subsystems |> Map.keys() |> Enum.sort()

    subsystem_sections =
      Enum.map(sorted_names, fn name ->
        subsystem = subsystems[name]
        files = subsystem["files"] || []
        goal = subsystem["goal"]

        file_infos =
          files
          |> Enum.map(&SourceAnalyzer.analyze_with_tests/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, info} -> info end)

        generate_subsystem_spec(name, file_infos, goal: goal, include_private: include_private)
      end)

    all_file_infos = collect_all_file_infos(subsystems)
    toc = if include_toc, do: format_toc(sorted_names)
    module_index = format_module_index(all_file_infos)

    [
      "# #{title} Specification\n",
      toc,
      "\n",
      Enum.join(subsystem_sections, "\n---\n\n"),
      "\n",
      module_index
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  @doc "Generate NLSpec from a list of file_infos without manifest grouping."
  @spec generate_from_files([SourceAnalyzer.file_info()], keyword()) :: String.t()
  def generate_from_files(file_infos, opts \\ []) do
    title = Keyword.get(opts, :title, "Source Specification")
    include_private = Keyword.get(opts, :include_private, false)
    include_toc = Keyword.get(opts, :include_toc, true)

    groups = group_by_directory(file_infos)
    sorted_names = groups |> Map.keys() |> Enum.sort()

    subsystem_sections =
      Enum.map(sorted_names, fn dir_name ->
        generate_subsystem_spec(dir_name, groups[dir_name], include_private: include_private)
      end)

    toc = if include_toc, do: format_toc(sorted_names)
    module_index = format_module_index(file_infos)

    [
      "# #{title}\n",
      toc,
      "\n",
      Enum.join(subsystem_sections, "\n---\n\n"),
      "\n",
      module_index
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  # ── Section Formatters ──────────────────────────────────────

  defp format_overview(%{moduledoc: nil}), do: nil
  defp format_overview(%{moduledoc: ""}), do: nil
  defp format_overview(%{moduledoc: doc}), do: "\n#{doc}\n"

  defp format_data_structures(file_info) do
    struct_section = format_struct_fields(file_info.struct_fields)
    types_section = format_types(file_info.types)

    case {struct_section, types_section} do
      {nil, nil} ->
        nil

      _ ->
        ["\n#### Data Structures\n", struct_section, types_section]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
    end
  end

  defp format_struct_fields([]), do: nil

  defp format_struct_fields(fields) do
    header = "| Field | Type / Default |\n| --- | --- |\n"

    rows =
      fields
      |> Enum.map_join("\n", fn {field, default} -> "| `#{field}` | `#{default}` |" end)

    header <> rows <> "\n"
  end

  defp format_types([]), do: nil

  defp format_types(types) do
    types
    |> Enum.map_join("\n\n", fn type_def -> "```elixir\n#{type_def}\n```" end)
    |> Kernel.<>("\n")
  end

  defp format_public_api(%{public_functions: []}), do: nil

  defp format_public_api(%{public_functions: functions}) do
    entries =
      functions
      |> Enum.map_join("\n", &format_function_entry/1)

    "\n#### Public API\n\n" <> entries
  end

  defp format_function_entry(func) do
    header = "##### `#{func.name}/#{func.arity}`\n"

    spec_block = if func.spec, do: "```elixir\n#{func.spec}\n```\n"
    doc_block = if func.doc && func.doc != "", do: "#{func.doc}\n"
    clauses_block = format_clauses(Map.get(func, :clauses, []))
    branches_block = format_branches(Map.get(func, :case_branches, []))

    [header, spec_block, doc_block, clauses_block, branches_block]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_clauses([]), do: nil
  defp format_clauses([_single]), do: nil

  defp format_clauses(clauses) do
    items =
      clauses
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {clause, idx} ->
        guard_part =
          case clause.guard do
            nil -> ""
            "" -> ""
            g -> " when `#{g}`"
          end

        patterns = Enum.join(clause.patterns, ", ")
        "#{idx}. `(#{patterns})`#{guard_part} — #{clause.body_summary}"
      end)

    "**Clauses:**\n\n#{items}\n"
  end

  defp format_branches([]), do: nil

  defp format_branches(branches) do
    items =
      branches
      |> Enum.map_join("\n", fn branch -> "- #{branch}" end)

    "**Branches:**\n\n#{items}\n"
  end

  defp format_behaviours(%{behaviours: [], callbacks: []}), do: nil

  defp format_behaviours(%{behaviours: behaviours, callbacks: callbacks}) do
    parts = []

    parts =
      if behaviours != [] do
        behaviour_list = Enum.map_join(behaviours, ", ", &"`#{&1}`")
        parts ++ ["**Implements:** #{behaviour_list}\n"]
      else
        parts
      end

    parts =
      if callbacks != [] do
        callback_items =
          callbacks
          |> Enum.map_join("\n", fn cb -> "- `#{cb}`" end)

        parts ++ ["\n**Callbacks:**\n\n#{callback_items}\n"]
      else
        parts
      end

    "\n#### Behaviours\n\n" <> Enum.join(parts, "\n")
  end

  defp format_configuration(file_info) do
    notable_attrs =
      Enum.reject(file_info.module_attributes, fn attr -> attr.name in @noise_attributes end)

    case notable_attrs do
      [] ->
        nil

      attrs ->
        header = "| Attribute | Value |\n| --- | --- |\n"

        rows =
          attrs
          |> Enum.map_join("\n", fn attr -> "| `@#{attr.name}` | `#{attr.value}` |" end)

        "\n#### Configuration\n\n" <> header <> rows <> "\n"
    end
  end

  defp format_implementation_notes(_file_info, false), do: nil

  defp format_implementation_notes(%{private_functions: []}, _), do: nil

  defp format_implementation_notes(%{private_functions: functions}, true) do
    entries =
      functions
      |> Enum.map_join("\n", fn func ->
        summary = "- `#{func.name}/#{func.arity}` — #{func.body_summary}"

        clauses_part =
          if Map.has_key?(func, :clauses) && length(Map.get(func, :clauses, [])) > 1 do
            func.clauses
            |> Enum.map_join("\n", fn clause ->
              patterns = Enum.join(clause.patterns, ", ")
              "  - `(#{patterns})` → #{clause.body_summary}"
            end)
          end

        branches_part =
          if Map.has_key?(func, :case_branches) && Map.get(func, :case_branches, []) != [] do
            func.case_branches
            |> Enum.map_join("\n", fn branch -> "  - #{branch}" end)
          end

        [summary, clauses_part, branches_part]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    "\n#### Implementation Notes\n\n#{entries}\n"
  end

  defp format_test_coverage(file_infos) do
    test_descriptions =
      Enum.flat_map(file_infos, fn fi ->
        case fi.test_examples do
          nil -> []
          %{descriptions: descs} -> descs
          _ -> []
        end
      end)

    case test_descriptions do
      [] ->
        nil

      descs ->
        items =
          descs
          |> Enum.map_join("\n", fn desc -> "- #{desc}" end)

        "\n### Test Coverage\n\n#{items}\n"
    end
  end

  # ── Document Structure Helpers ──────────────────────────────

  defp format_toc(section_names) do
    items =
      section_names
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {name, idx} ->
        anchor = sanitize_anchor(name)
        "#{idx}. [#{name}](##{anchor})"
      end)

    "\n## Table of Contents\n\n#{items}\n\n"
  end

  defp format_module_index(file_infos) when is_list(file_infos) do
    sorted = Enum.sort_by(file_infos, & &1.module)

    case sorted do
      [] ->
        nil

      infos ->
        header = "\n## Module Index\n\n| Module | File Path |\n| --- | --- |\n"

        rows =
          infos
          |> Enum.map_join("\n", fn fi -> "| `#{fi.module}` | `#{fi.path}` |" end)

        header <> rows <> "\n"
    end
  end

  defp format_module_index(_), do: nil

  defp sanitize_anchor(name) do
    name
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^a-z0-9\-]/, "")
  end

  defp group_by_directory(file_infos) do
    Enum.group_by(file_infos, fn fi ->
      fi.path |> Path.dirname() |> Path.basename()
    end)
  end

  defp collect_all_file_infos(subsystems) do
    subsystems
    |> Map.values()
    |> Enum.flat_map(fn subsystem ->
      (subsystem["files"] || [])
      |> Enum.map(&SourceAnalyzer.analyze_file/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, info} -> info end)
    end)
  end
end
