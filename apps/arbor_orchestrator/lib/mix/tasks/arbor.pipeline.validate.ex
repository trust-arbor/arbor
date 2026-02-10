defmodule Mix.Tasks.Arbor.Pipeline.Validate do
  @shortdoc "Parse and lint a .dot pipeline file"
  @moduledoc """
  Validates one or more .dot files, reporting errors and warnings.

  ## Usage

      mix arbor.pipeline.validate pipeline.dot
      mix arbor.pipeline.validate *.dot
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @impl true
  def run(args) do
    {_opts, files, _} = OptionParser.parse(args, strict: [])

    Mix.Task.run("app.start")

    if files == [] do
      error("Usage: mix arbor.pipeline.validate <file.dot> [file2.dot ...]")
      System.halt(1)
    end

    all_ok =
      Enum.reduce(files, true, fn file, acc ->
        acc and validate_file(file)
      end)

    unless all_ok do
      System.halt(1)
    end
  end

  defp validate_file(file) do
    unless File.exists?(file) do
      error("File not found: #{file}")
      return_false()
    end

    case File.read(file) do
      {:ok, source} ->
        diagnostics = Arbor.Orchestrator.validate(source)
        errors = Enum.filter(diagnostics, &(&1.severity == :error))
        warnings = Enum.filter(diagnostics, &(&1.severity == :warning))

        if errors == [] do
          success("✓ #{file} (#{length(warnings)} warnings)")

          Enum.each(warnings, fn d ->
            warn("  ⚠ [#{d.rule}] #{d.message}")
          end)

          true
        else
          error("✗ #{file}")

          Enum.each(errors, fn d ->
            error("  ✗ [#{d.rule}] #{d.message}")
          end)

          Enum.each(warnings, fn d ->
            warn("  ⚠ [#{d.rule}] #{d.message}")
          end)

          false
        end

      {:error, reason} ->
        error("Could not read #{file}: #{inspect(reason)}")
        false
    end
  end

  defp return_false, do: false
end
