defmodule Mix.Tasks.Arbor.Pipeline.Compile do
  @shortdoc "Compile .dot pipeline to typed IR and run all validation passes"
  @moduledoc """
  Compiles one or more .dot files into typed IR and runs both structural
  and typed validation passes. Reports handler types, capabilities needed,
  data classification, taint flows, and loop bounds.

  ## Usage

      mix arbor.pipeline.compile pipeline.dot
      mix arbor.pipeline.compile specs/pipelines/*.dot
      mix arbor.pipeline.compile pipeline.dot --verbose
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: [verbose: :boolean])

    Mix.Task.run("app.start")

    if files == [] do
      error("Usage: mix arbor.pipeline.compile <file.dot> [file2.dot ...] [--verbose]")
      System.halt(1)
    end

    all_ok =
      Enum.reduce(files, true, fn file, acc ->
        acc and compile_file(file, opts)
      end)

    unless all_ok do
      System.halt(1)
    end
  end

  defp compile_file(file, opts) do
    verbose = Keyword.get(opts, :verbose, false)

    unless File.exists?(file) do
      error("File not found: #{file}")
      return_false()
    end

    case File.read(file) do
      {:ok, source} ->
        compile_source(file, source, verbose)

      {:error, reason} ->
        error("Could not read #{file}: #{inspect(reason)}")
        false
    end
  end

  defp compile_source(file, source, verbose) do
    # Phase 1: Structural validation
    struct_diags = Arbor.Orchestrator.validate(source)
    struct_errors = Enum.filter(struct_diags, &(&1.severity == :error))

    if struct_errors != [] do
      error("✗ #{file} — structural validation failed")
      Enum.each(struct_errors, fn d -> error("  ✗ [#{d.rule}] #{d.message}") end)
      false
    else
      # Phase 2: Compile to typed IR
      case Arbor.Orchestrator.compile(source) do
        {:ok, typed} ->
          # Phase 3: Typed validation passes
          typed_diags = Arbor.Orchestrator.validate_typed(typed, [])
          typed_errors = Enum.filter(typed_diags, &(&1.severity == :error))
          typed_warnings = Enum.filter(typed_diags, &(&1.severity == :warning))

          print_summary(file, typed, typed_errors, typed_warnings, verbose)
          typed_errors == []

        {:error, reason} ->
          error("✗ #{file} — IR compilation failed: #{inspect(reason)}")
          false
      end
    end
  end

  defp print_summary(file, typed, errors, warnings, verbose) do
    node_count = map_size(typed.nodes)
    edge_count = length(typed.edges)
    caps = typed.capabilities_required |> MapSet.to_list() |> Enum.sort()

    if errors == [] do
      success("✓ #{file}")
    else
      error("✗ #{file}")
    end

    info("  Nodes: #{node_count}, Edges: #{edge_count}")
    info("  Max classification: #{typed.max_data_classification}")

    if caps != [] do
      info("  Capabilities required: #{Enum.join(caps, ", ")}")
    end

    if verbose do
      info("  Handler types:")

      typed.nodes
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.each(fn {id, node} ->
        idempotency = node.idempotency
        classification = node.data_classification
        info("    #{id}: #{node.handler_type} (#{idempotency}, #{classification})")
      end)
    end

    Enum.each(errors, fn d ->
      error("  ✗ [#{d.rule}] #{d.message}")
    end)

    Enum.each(warnings, fn d ->
      warn("  ⚠ [#{d.rule}] #{d.message}")
    end)
  end

  defp return_false, do: false
end
