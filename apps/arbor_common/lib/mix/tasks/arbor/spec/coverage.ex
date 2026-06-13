defmodule Mix.Tasks.Arbor.Spec.Coverage do
  @shortdoc "Report spec-statement → test traceability (conformance coverage)"

  @moduledoc """
  Maps normative spec statements (docs/specs/*.md) to the tests that prove them.

  Spec statements are lines of the form:

      - **TRUST-7** (MUST): A rejection MUST reset the approval streak...
      - **TRUST-14** (MUST, planned): ...

  Tests claim proof of a statement via an ExUnit tag:

      @tag spec: "TRUST-7"
      @tag spec: "TRUST-1,TRUST-2"   # multiple statements

  ## Usage

      mix arbor.spec.coverage              # full report
      mix arbor.spec.coverage --strict     # exit 1 on unproven non-planned MUSTs or dead refs
      mix arbor.spec.coverage --spec TRUST # restrict to one spec area prefix

  Run from the umbrella root. See `.arbor/roadmap/1-brainstorming/executable-specs-and-conformance.md`.
  """

  use Mix.Task

  @specs_glob "docs/specs/*.md"
  @test_globs ["apps/*/test/**/*.exs", "test/**/*.exs"]

  # - **TRUST-7** (MUST): ...   /   - **TRUST-14** (MUST, planned): ...
  @statement_re ~r/^\s*-\s+\*\*([A-Z][A-Z0-9]*-\d+)\*\*\s+\((MUST(?:\s+NOT)?|SHOULD(?:\s+NOT)?|MAY)(,\s*planned)?\)/
  @tag_re ~r/@tag\s+spec:\s*"([^"]+)"/

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [strict: :boolean, spec: :string])

    statements = parse_specs(opts[:spec])

    if statements == %{} do
      Mix.shell().error("No spec statements found under #{@specs_glob}")
      exit({:shutdown, 1})
    end

    tags = scan_test_tags()

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

  defp parse_specs(area_filter) do
    @specs_glob
    |> Path.wildcard()
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
    |> Map.new()
  end

  defp scan_test_tags do
    @test_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&String.contains?(&1, ["/_build/", "/.elixir_ls/", "/deps/"]))
    |> Enum.reduce(%{}, fn path, acc ->
      content = File.read!(path)

      @tag_re
      |> Regex.scan(content)
      |> Enum.flat_map(fn [_, ids] ->
        ids |> String.split(",") |> Enum.map(&String.trim/1)
      end)
      |> Enum.reduce(acc, fn id, inner ->
        Map.update(inner, id, [path], fn paths ->
          if path in paths, do: paths, else: [path | paths]
        end)
      end)
    end)
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
