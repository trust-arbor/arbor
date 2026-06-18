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

  alias Arbor.Agent.Eval.SecurityReview.Runner

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

    run_opts =
      [
        tiers: csv_atoms(opts[:tiers], [:local]),
        strategies: csv_atoms(opts[:strategies], [:a, :b_lite]),
        k: opts[:k] || 1
      ]
      |> maybe_put(:output_dir, opts[:output])

    case Runner.run(corpus, run_opts) do
      {:ok, summary} ->
        Mix.shell().info("""
        L2-review eval run complete.
          corpus:     #{summary.corpus_dir}
          reviewers:  #{Enum.join(summary.reviewers, ", ")}
          strategies: #{Enum.join(summary.strategies, ", ")}
          k:          #{summary.k}
          cells:      #{summary.cell_count}
          findings:   #{summary.results |> Enum.flat_map(& &1.findings) |> length()}
        """)

      {:error, reason} ->
        Mix.raise("L2-review eval failed: #{inspect(reason)}")
    end
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

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)
end
