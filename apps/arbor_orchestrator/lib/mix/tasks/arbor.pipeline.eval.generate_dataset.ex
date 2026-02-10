defmodule Mix.Tasks.Arbor.Pipeline.Eval.GenerateDataset do
  @shortdoc "Generate JSONL dataset for spec completeness evaluation"

  @moduledoc """
  Generates a JSONL evaluation dataset by reading implement_*.dot files
  as ground truth and splitting attractor-spec.md into subsystem sections.

  Each JSONL line is a sample with:
    - id: subsystem name
    - input: map with subsystem, spec text, goal, and files list
    - expected: the full content of the source-code-derived implement_*.dot file
    - metadata: has_spec boolean

  ## Usage

      mix arbor.pipeline.eval.generate_dataset
      mix arbor.pipeline.eval.generate_dataset --output custom.jsonl
      mix arbor.pipeline.eval.generate_dataset --spec specs/attractor/attractor-spec.md
      mix arbor.pipeline.eval.generate_dataset --dot-dir specs/pipelines
  """

  use Mix.Task

  alias Arbor.Orchestrator.Eval.SpecSplitter

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          spec: :string,
          dot_dir: :string
        ],
        aliases: [o: :output]
      )

    output = opts[:output] || "specs/eval/spec_completeness.jsonl"
    spec_path = opts[:spec] || "specs/attractor/attractor-spec.md"
    dot_dir = opts[:dot_dir] || "specs/pipelines"

    # Split spec into subsystem sections
    spec_map =
      case SpecSplitter.split(spec_path) do
        {:ok, map} ->
          map

        {:error, reason} ->
          Mix.shell().error("Failed to split spec: #{reason}")
          %{}
      end

    # Find all implement_*.dot files in the dot directory
    dot_files =
      dot_dir
      |> Path.join("implement_*.dot")
      |> Path.wildcard()
      |> Enum.sort()

    # Also include any .dot files that match subsystem names
    all_subsystems = SpecSplitter.all_subsystems()

    lines =
      all_subsystems
      |> Enum.sort()
      |> Enum.flat_map(fn subsystem ->
        dot_path = Path.join(dot_dir, "implement_#{subsystem}.dot")

        case File.read(dot_path) do
          {:ok, dot_content} ->
            spec_text = Map.get(spec_map, subsystem, "")

            sample = %{
              "id" => subsystem,
              "input" => %{
                "subsystem" => subsystem,
                "spec" => spec_text,
                "goal" => "Implement the #{subsystem} subsystem",
                "files" => []
              },
              "expected" => dot_content,
              "metadata" => %{
                "has_spec" => spec_text != "",
                "dot_file" => dot_path
              }
            }

            [Jason.encode!(sample)]

          {:error, _reason} ->
            []
        end
      end)

    if lines == [] and dot_files == [] do
      Mix.shell().info(
        "No implement_*.dot files found in #{dot_dir}. " <>
          "Create pipeline specs first, then generate the dataset."
      )
    else
      File.mkdir_p!(Path.dirname(output))
      File.write!(output, Enum.join(lines, "\n") <> "\n")
      Mix.shell().info("Generated #{length(lines)} samples to #{output}")
    end
  end
end
