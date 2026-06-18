defmodule Mix.Tasks.Arbor.Eval.SecurityReview do
  @shortdoc "Run API-class reviewers over the Sentinel L2-review corpus (Phase 0)"

  @moduledoc """
  Run the Security Sentinel L2-review eval: for each reviewer × corpus-item ×
  strategy × run, call the model and record its raw security findings to a results
  JSON. Scoring against the corpus labels is a separate step.

  Build the corpus first with `mix arbor.eval.security_corpus`.

  ## Usage

      # First run: local models only, both strategies, k=1
      mix arbor.eval.security_review --corpus .arbor/evals/security-review-corpus

      # Enable cloud reviewers too (real token cost), 2 runs per cell
      mix arbor.eval.security_review --corpus DIR --tiers local,cloud --k 2

  ## Options

    * `--corpus`     — corpus dir (default `.arbor/evals/security-review-corpus`)
    * `--tiers`      — comma list of reviewer tiers (default `local`)
    * `--strategies` — comma list (`a`, `b_lite`; default `a,b_lite`)
    * `--k`          — runs per cell (default `1`)
    * `--output`     — results dir (default `.arbor/evals`)

  Calls real models, so the application is started. Tagged offline — never part of CI.
  """

  use Mix.Task

  alias Arbor.Agent.Eval.SecurityReview.{Report, Runner, Scorer}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          corpus: :string,
          tiers: :string,
          strategies: :string,
          k: :integer,
          output: :string
        ]
      )

    corpus = opts[:corpus] || ".arbor/evals/security-review-corpus"
    output_dir = opts[:output] || ".arbor/evals"

    run_opts = [
      tiers: csv_atoms(opts[:tiers], [:local]),
      strategies: csv_atoms(opts[:strategies], [:a, :b_lite]),
      k: opts[:k] || 1,
      output_dir: output_dir
    ]

    with {:ok, summary} <- Runner.run(corpus, run_opts),
         {:ok, labels} <- Scorer.labels_from_manifest(corpus) do
      scored = Scorer.score(summary.results, labels)
      report_path = write_report(scored, summary, labels, output_dir)

      Mix.shell().info("""
      L2-review eval complete.
        corpus:    #{summary.corpus_dir}
        cells:     #{summary.cell_count}   findings: #{summary.results |> Enum.flat_map(& &1.findings) |> length()}
        report:    #{report_path}

      #{recall_preview(scored)}
      """)
    else
      {:error, reason} -> Mix.raise("L2-review eval failed: #{inspect(reason)}")
    end
  end

  defp write_report(scored, summary, labels, output_dir) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9T]/, "")

    meta = %{
      timestamp: stamp,
      corpus_dir: summary.corpus_dir,
      reviewers: summary.reviewers,
      strategies: summary.strategies,
      k: summary.k,
      item_count: map_size(labels),
      cross_file_count: labels |> Map.values() |> Enum.count(& &1.cross_file)
    }

    Report.write(scored, meta, Path.join(output_dir, "security-review-report-#{stamp}.md"))
  end

  defp recall_preview(scored) do
    scored.by_reviewer_strategy
    |> Enum.map_join("\n", fn a ->
      "  #{a.reviewer}/#{a.strategy}: recall=#{Float.round(a.recall_any, 2)} " <>
        "cross-file=#{Float.round(a.cross_file_recall_any, 2)}"
    end)
  end

  # Allowlist, never String.to_atom on CLI input (the project's unsafe-atom rule).
  @known_values %{"local" => :local, "cloud" => :cloud, "a" => :a, "b_lite" => :b_lite}

  defp csv_atoms(nil, default), do: default

  defp csv_atoms(str, _default) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(fn s ->
      key = String.trim(s)
      Map.get(@known_values, key) || Mix.raise("unknown tier/strategy: #{key}")
    end)
  end
end
