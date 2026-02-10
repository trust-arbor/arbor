defmodule Mix.Tasks.Arbor.Pipeline.Dotgen do
  @shortdoc "Generate implement_*.dot from source files"
  @moduledoc """
  Analyzes Elixir source files and generates a self-contained .dot pipeline
  that can reproduce those files from scratch via LLM prompts.

  ## Usage

      mix arbor.pipeline.dotgen lib/some/module.ex lib/some/other.ex --name graph
      mix arbor.pipeline.dotgen --dir lib/arbor/orchestrator --name graph
      mix arbor.pipeline.dotgen --dir lib/arbor/orchestrator --name graph --output specs/pipelines/implement_graph.dot
      mix arbor.pipeline.dotgen --dir lib/arbor/orchestrator --name graph --max-per-node 3
      mix arbor.pipeline.dotgen --manifest specs/meta/manifest.json
      mix arbor.pipeline.dotgen --manifest specs/meta/manifest.json --output-dir specs/pipelines/

  ## Options

      --dir           Directory to scan for .ex files (alternative to listing files)
      --name          Subsystem name for the output .dot file (required in single mode)
      --output        Output file path (default: stdout) — single-file mode
      --output-dir    Output directory for manifest mode (default: specs/pipelines/)
      --max-per-node  Max files per implementation node (default: 4)
      --goal          Custom goal string
      --no-tests      Skip generating the write_tests node
      --exclude       Comma-separated filename patterns to exclude
      --manifest      Path to a manifest JSON file (mutually exclusive with --dir and file args)
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  alias Arbor.Orchestrator.Dotgen.{SourceAnalyzer, DotGenerator, ManifestGenerator}
  alias Arbor.Orchestrator.Validation.Validator

  @impl true
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [
          dir: :string,
          name: :string,
          output: :string,
          output_dir: :string,
          max_per_node: :integer,
          goal: :string,
          no_tests: :boolean,
          exclude: :string,
          manifest: :string
        ]
      )

    if opts[:manifest] do
      validate_manifest_exclusivity!(opts, files)
      run_manifest_mode(opts)
    else
      run_single_mode(opts, files)
    end
  end

  # ── Single-File Mode (original behavior) ──────────────────────────

  defp run_single_mode(opts, files) do
    name = opts[:name]

    unless name do
      error("Missing required option: --name")
      error("Usage: mix arbor.pipeline.dotgen [files...] --name <subsystem> [options]")
      System.halt(1)
    end

    file_infos = analyze_sources(opts, files)

    if file_infos == [] do
      error("No source files found to analyze.")
      System.halt(1)
    end

    info("Analyzed #{length(file_infos)} source file(s)")

    # Display summary table
    table(
      ["Module", "Functions", "Lines"],
      Enum.map(file_infos, fn f ->
        func_count = length(f.public_functions) + length(f.private_functions)
        [f.module || Path.basename(f.path), func_count, f.line_count]
      end)
    )

    # Build generator options
    gen_opts = build_gen_opts(opts)

    dot_output =
      spinner("Generating pipeline", fn ->
        DotGenerator.generate(name, file_infos, gen_opts)
      end)

    case opts[:output] do
      nil ->
        # Print to stdout
        info("")
        info(dot_output)

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, dot_output)
        success("Written to #{path}")

        # Validate the generated output
        validate_output(path, dot_output)
    end
  end

  # ── Manifest Mode ─────────────────────────────────────────────────

  defp validate_manifest_exclusivity!(opts, files) do
    if opts[:dir] do
      error("--manifest is mutually exclusive with --dir")
      System.halt(1)
    end

    if files != [] do
      error("--manifest is mutually exclusive with positional file arguments")
      System.halt(1)
    end
  end

  defp run_manifest_mode(opts) do
    manifest_path = opts[:manifest]
    output_dir = opts[:output_dir] || opts[:output] || "specs/pipelines/"

    unless File.exists?(manifest_path) do
      error("Manifest file not found: #{manifest_path}")
      System.halt(1)
    end

    json_string = File.read!(manifest_path)

    manifest =
      case ManifestGenerator.from_json(json_string) do
        {:ok, m} ->
          m

        {:error, reason} ->
          error("Failed to parse manifest: #{reason}")
          System.halt(1)
      end

    subsystems = manifest["subsystems"] || %{}

    if map_size(subsystems) == 0 do
      error("Manifest contains no subsystems.")
      System.halt(1)
    end

    info("Loaded manifest: #{map_size(subsystems)} subsystem(s)")
    File.mkdir_p!(output_dir)

    gen_opts = build_gen_opts(opts)

    results =
      Enum.map(subsystems, fn {name, sub} ->
        generate_from_subsystem(name, sub, output_dir, gen_opts)
      end)

    # Print summary
    info("\n── Summary ──────────────────────────────────────────────")

    table(
      ["Subsystem", "Files", "Output", "Valid?"],
      Enum.map(results, fn r ->
        [r.name, r.file_count, Path.basename(r.output_path), r.valid?]
      end)
    )

    ok_count = Enum.count(results, &(&1.valid? == "yes"))
    skip_count = Enum.count(results, &(&1.valid? == "skip"))
    error_count = length(results) - ok_count - skip_count

    info(
      "Generated #{ok_count + error_count} .dot file(s): #{ok_count} valid, #{error_count} with errors, #{skip_count} skipped"
    )
  end

  defp generate_from_subsystem(name, subsystem_info, output_dir, gen_opts) do
    files = subsystem_info["files"] || []
    goal = subsystem_info["goal"]

    info("\nProcessing subsystem: #{name} (#{length(files)} files)")

    # Analyze each file listed in the subsystem
    file_infos =
      files
      |> Enum.filter(&File.exists?/1)
      |> Enum.reduce([], fn path, acc ->
        case SourceAnalyzer.analyze_with_tests(path) do
          {:ok, info} ->
            acc ++ [info]

          {:error, reason} ->
            warn("  Skipping #{path}: #{reason}")
            acc
        end
      end)

    if file_infos == [] do
      warn("  No analyzable files for subsystem '#{name}', skipping.")
      %{name: name, file_count: 0, output_path: "", valid?: "skip"}
    else
      # Merge goal from manifest into gen_opts (command-line --goal takes precedence)
      sub_gen_opts =
        if goal && !Keyword.has_key?(gen_opts, :goal) do
          Keyword.put(gen_opts, :goal, goal)
        else
          gen_opts
        end

      dot_output =
        spinner("  Generating #{name}", fn ->
          DotGenerator.generate(name, file_infos, sub_gen_opts)
        end)

      output_path = Path.join(output_dir, "implement_#{name}.dot")
      File.write!(output_path, dot_output)
      success("  Written to #{output_path}")

      valid? = validate_output(output_path, dot_output)

      %{
        name: name,
        file_count: length(file_infos),
        output_path: output_path,
        valid?: if(valid?, do: "yes", else: "no")
      }
    end
  end

  # ── Shared Helpers ──────────────────────────────────────────────────

  defp build_gen_opts(opts) do
    gen_opts = []
    gen_opts = if opts[:goal], do: Keyword.put(gen_opts, :goal, opts[:goal]), else: gen_opts

    gen_opts =
      if opts[:max_per_node],
        do: Keyword.put(gen_opts, :max_files_per_node, opts[:max_per_node]),
        else: gen_opts

    if opts[:no_tests], do: Keyword.put(gen_opts, :include_tests, false), else: gen_opts
  end

  # ── Source Analysis ──────────────────────────────────────────────────

  defp analyze_sources(opts, files) do
    exclude_patterns = parse_exclude(opts[:exclude])

    case opts[:dir] do
      nil ->
        if files == [] do
          error("Provide source files as arguments or use --dir to scan a directory.")
          System.halt(1)
        end

        files
        |> Enum.filter(&File.exists?/1)
        |> Enum.reduce([], fn path, acc ->
          case SourceAnalyzer.analyze_with_tests(path) do
            {:ok, info} ->
              acc ++ [info]

            {:error, reason} ->
              warn("Skipping #{path}: #{reason}")
              acc
          end
        end)
        |> maybe_exclude(exclude_patterns)

      dir ->
        unless File.dir?(dir) do
          error("Directory not found: #{dir}")
          System.halt(1)
        end

        analyze_opts = if exclude_patterns != [], do: [exclude: exclude_patterns], else: []

        case SourceAnalyzer.analyze_directory(dir, analyze_opts) do
          {:ok, infos} ->
            # Enrich each file with test-derived examples
            Enum.map(infos, fn info ->
              case SourceAnalyzer.find_companion_test(info.path) do
                nil ->
                  Map.put(info, :test_examples, nil)

                test_path ->
                  case SourceAnalyzer.extract_test_examples(test_path) do
                    {:ok, examples} -> Map.put(info, :test_examples, examples)
                    _ -> Map.put(info, :test_examples, nil)
                  end
              end
            end)

          {:error, reason} ->
            error("Failed to analyze directory: #{reason}")
            System.halt(1)
        end
    end
  end

  defp parse_exclude(nil), do: []

  defp parse_exclude(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp maybe_exclude(file_infos, []), do: file_infos

  defp maybe_exclude(file_infos, patterns) do
    Enum.reject(file_infos, fn %{path: path} ->
      basename = Path.basename(path)
      Enum.any?(patterns, fn pattern -> String.contains?(basename, pattern) end)
    end)
  end

  # ── Validation ───────────────────────────────────────────────────────

  defp validate_output(path, dot_source) do
    info("\nValidating generated pipeline...")

    case Arbor.Orchestrator.parse(dot_source) do
      {:ok, graph} ->
        diagnostics = Validator.validate(graph)
        errors = Enum.filter(diagnostics, &(&1.severity == :error))
        warnings = Enum.reject(diagnostics, &(&1.severity == :error))

        if warnings != [] do
          Enum.each(warnings, fn d ->
            warn("  [#{d.rule}] #{d.message}")
          end)
        end

        if errors != [] do
          Enum.each(errors, fn d ->
            error("  [#{d.rule}] #{d.message}")
          end)

          error("Generated #{path} has #{length(errors)} validation error(s).")
          false
        else
          success("Validation passed (#{length(warnings)} warning(s))")
          true
        end

      {:error, reason} ->
        error("Generated DOT failed to parse: #{reason}")
        false
    end
  end
end
