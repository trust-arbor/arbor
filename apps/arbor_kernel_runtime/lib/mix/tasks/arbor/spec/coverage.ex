defmodule Mix.Tasks.Arbor.Spec.Coverage do
  @shortdoc "Report spec-statement → test traceability (conformance coverage)"

  @moduledoc """
  Maps normative spec statements to the tests that prove them.

  Tracked specifications live under `docs/arbor/specs/`. The legacy tracked
  `docs/specs/*.md` location remains supported while existing specifications
  migrate. Generated and local handoff packages under nested `docs/specs/`
  directories are intentionally not treated as conformance authority.

  Spec statements are lines of the form:

      - **TRUST-7** (MUST): A rejection MUST reset the approval streak...
      - **TRUST-14** (MUST, planned): ...

  Tests claim proof of a statement via an ExUnit tag:

      @tag spec: "TRUST-7"
      @tag spec: "TRUST-1,TRUST-2"   # multiple statements

  ## Usage

      ./bin/mix arbor.spec.coverage              # full report
      ./bin/mix arbor.spec.coverage --strict     # exit 1 on unproven non-planned MUSTs or dead refs
      ./bin/mix arbor.spec.coverage --spec TRUST # restrict to one spec area prefix

  Run from the umbrella root. See `.arbor/roadmap/1-brainstorming/executable-specs-and-conformance.md`.
  """

  use Mix.Task

  @specs_globs ["docs/specs/*.md", "docs/arbor/specs/**/*.md"]
  @test_globs ["apps/*/test/**/*.exs", "test/**/*.exs"]

  # - **TRUST-7** (MUST): ...   /   - **TRUST-14** (MUST, planned): ...
  @statement_re ~r/^\s*-\s+\*\*([A-Z][A-Z0-9]*-\d+)\*\*\s+\((MUST(?:\s+NOT)?|SHOULD(?:\s+NOT)?|MAY)(,\s*planned)?\)/

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [strict: :boolean, spec: :string])

    area_filter = opts[:spec]
    statements = parse_specs(area_filter)

    if statements == %{} do
      Mix.shell().error("No spec statements found under #{Enum.join(@specs_globs, ", ")}")
      exit({:shutdown, 1})
    end

    tags = scan_test_tags(area_filter)

    proven =
      for {id, _meta} <- statements,
          locations = Map.get(tags, id, []),
          locations != [],
          into: %{},
          do: {id, locations}

    unproven =
      statements
      |> Enum.reject(fn {id, _} -> Map.has_key?(proven, id) end)
      |> Enum.sort_by(fn {id, _} -> id end)

    dead_refs =
      tags
      |> Enum.reject(fn {id, _} -> Map.has_key?(statements, id) end)
      |> Enum.sort_by(fn {id, _} -> id end)

    print_report(statements, proven, unproven, dead_refs)

    if opts[:strict] do
      hard_failures =
        Enum.filter(unproven, fn {_id, meta} ->
          not meta.planned and String.starts_with?(meta.level, "MUST")
        end)

      if hard_failures != [] or dead_refs != [] do
        Mix.shell().error(
          "\nSTRICT: #{length(hard_failures)} unproven MUST statement(s), " <>
            "#{length(dead_refs)} dead spec ref(s)."
        )

        exit({:shutdown, 1})
      end
    end
  end

  @doc false
  @spec spec_paths(Path.t()) :: [Path.t()]
  def spec_paths(root \\ ".") do
    @specs_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec parse_specs(String.t() | nil, Path.t()) :: map()
  def parse_specs(area_filter, root \\ ".") do
    root
    |> spec_paths()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(@statement_re, line) do
          [_, id, level, planned] ->
            [{id, %{level: level, planned: planned not in [nil, ""], file: path}}]

          [_, id, level] ->
            [{id, %{level: level, planned: false, file: path}}]

          _ ->
            []
        end
      end)
    end)
    |> Enum.filter(fn {id, _} ->
      area_filter == nil or String.starts_with?(id, area_filter)
    end)
    |> ensure_unique_statement_ids!()
    |> Map.new()
  end

  @doc false
  @spec scan_test_tags(String.t() | nil, Path.t()) :: map()
  def scan_test_tags(area_filter, root \\ ".") do
    @test_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)
    |> Enum.reject(&String.contains?(&1, ["/_build/", "/.elixir_ls/", "/deps/"]))
    |> Enum.reduce(%{}, fn path, acc ->
      path
      |> read_spec_tag_ids!()
      |> Enum.reduce(acc, fn id, inner ->
        if area_filter == nil or String.starts_with?(id, area_filter) do
          Map.update(inner, id, [path], fn paths ->
            if path in paths, do: paths, else: [path | paths]
          end)
        else
          inner
        end
      end)
    end)
  end

  defp read_spec_tag_ids!(path) do
    content = File.read!(path)

    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {_ast, ids} =
          Macro.prewalk(ast, [], fn
            {:@, _meta, [{:tag, _tag_meta, args}]} = node, acc ->
              {node, literal_spec_ids(args) ++ acc}

            node, acc ->
              {node, acc}
          end)

        ids |> Enum.reverse() |> Enum.uniq()

      {:error, reason} ->
        raise Mix.Error,
          message: "Cannot parse test file while scanning spec tags: #{path}: #{inspect(reason)}"
    end
  end

  defp literal_spec_ids([tags]) when is_list(tags) do
    case Keyword.get(tags, :spec) do
      ids when is_binary(ids) -> ids |> String.split(",") |> Enum.map(&String.trim/1)
      _other -> []
    end
  end

  defp literal_spec_ids(_args), do: []

  defp ensure_unique_statement_ids!(statements) do
    duplicates =
      statements
      |> Enum.group_by(fn {id, _meta} -> id end, fn {_id, meta} -> meta.file end)
      |> Enum.filter(fn {_id, files} -> length(files) > 1 end)
      |> Enum.sort_by(&elem(&1, 0))

    if duplicates != [] do
      details =
        Enum.map_join(duplicates, "; ", fn {id, files} ->
          "#{id} in #{Enum.join(files, ", ")}"
        end)

      raise Mix.Error, message: "Duplicate normative spec statement IDs: #{details}"
    end

    statements
  end

  defp print_report(statements, proven, unproven, dead_refs) do
    total = map_size(statements)
    planned_count = Enum.count(statements, fn {_, m} -> m.planned end)
    provable = total - planned_count

    Mix.shell().info("Spec conformance coverage")
    Mix.shell().info("=========================")

    Mix.shell().info("Statements: #{total} (#{provable} normative now, #{planned_count} planned)")

    Mix.shell().info("Proven:     #{map_size(proven)}/#{provable}\n")

    if unproven != [] do
      Mix.shell().info("UNPROVEN:")

      Enum.each(unproven, fn {id, meta} ->
        suffix = if meta.planned, do: " (planned — informational)", else: " ← claim without proof"
        Mix.shell().info("  #{id} (#{meta.level})#{suffix}")
      end)

      Mix.shell().info("")
    end

    if dead_refs != [] do
      Mix.shell().info("DEAD REFS (tests citing unknown statement IDs):")

      Enum.each(dead_refs, fn {id, paths} ->
        Mix.shell().info("  #{id} ← #{Enum.join(paths, ", ")}")
      end)

      Mix.shell().info("")
    end

    if proven != %{} do
      Mix.shell().info("Proven statements:")

      proven
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.each(fn {id, paths} ->
        Mix.shell().info("  #{id}: #{length(paths)} test file(s)")
      end)
    end
  end
end
