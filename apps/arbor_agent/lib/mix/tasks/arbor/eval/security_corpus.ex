defmodule Mix.Tasks.Arbor.Eval.SecurityCorpus do
  @shortdoc "Reconstruct the Security Sentinel L2-review eval corpus from git fix-history"

  @moduledoc """
  Build the labeled corpus for the Security Sentinel L2 deep-review eval.

  Reconstructs, for each manifest item (`Arbor.Agent.Eval.SecurityReview.Manifest`),
  the buggy "before" snapshot (`git show <fix_commit>^:<path>`) and the fixed
  "after" snapshot, writing them under the output dir plus a `manifest.json`.

  ## Usage

      # Default: write to .arbor/evals/security-review-corpus
      mix arbor.eval.security_corpus

      # Custom output dir
      mix arbor.eval.security_corpus --output /tmp/sec-corpus

  No application boot required — this is pure git + file IO.

  ## Options

    * `--output` — corpus output directory
      (default `.arbor/evals/security-review-corpus`)
  """

  use Mix.Task

  alias Arbor.Agent.Eval.SecurityReview.Corpus

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [output: :string])

    build_opts = if opts[:output], do: [output_dir: opts[:output]], else: []
    {:ok, summary} = Corpus.build(nil, build_opts)

    Mix.shell().info("""
    Security-review corpus built → #{summary.output_dir}
      items:   #{summary.item_count}  (#{Enum.join(summary.built, ", ")})
      files:   #{summary.file_count}
      skipped: #{length(summary.skipped)}#{format_skipped(summary.skipped)}
    """)
  end

  defp format_skipped([]), do: ""

  defp format_skipped(skipped) do
    "\n" <> Enum.map_join(skipped, "\n", fn s -> "    - #{s.id}: #{inspect(s.reason)}" end)
  end
end
