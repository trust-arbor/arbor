defmodule Mix.Tasks.Arbor.Eval.Task do
  @moduledoc """
  Run v3 real-bug memory ablation evaluation.

  Starts a real diagnostician agent against a real bug in a git worktree,
  using different heartbeat.dot pipeline variants to control memory persistence.
  Measures heartbeats-to-proposal, proposal quality, and behavioral metrics.

  ## Usage

      mix arbor.eval.task                                    # bare + full, glob bug
      mix arbor.eval.task --variants bare,goals,full         # specific variants
      mix arbor.eval.task --max-heartbeats 20 --reps 3       # statistical runs
      mix arbor.eval.task --model "anthropic/claude-3-5-haiku-latest"
      mix arbor.eval.task --council                          # enable council eval
      mix arbor.eval.task --tag "first-run"                  # persistence tag

  ## Options

    * `--variants` - Comma-separated variant names: bare, goals, notes, identity, full (default: bare,full)
    * `--max-heartbeats` - Max heartbeats per trial (default: 15)
    * `--reps` - Repetitions per variant (default: 1)
    * `--model` - LLM model (default: openrouter/anthropic/claude-3-5-haiku-latest)
    * `--provider` - LLM provider (default: openrouter)
    * `--bug` - Bug case ID (default: glob_wildcard)
    * `--council` - Enable council evaluation of proposals
    * `--tag` - Tag for persistence
  """

  use Mix.Task

  @shortdoc "Run v3 real-bug memory ablation eval"

  @switches [
    variants: :string,
    max_heartbeats: :integer,
    reps: :integer,
    model: :string,
    provider: :string,
    bug: :string,
    council: :boolean,
    tag: :string
  ]

  @valid_variants ~w(bare goals notes identity full)a

  @impl Mix.Task
  def run(args) do
    # Start required apps (orchestrator must come before agent — provides EventRegistry + Session)
    {:ok, _} = Application.ensure_all_started(:arbor_memory)
    {:ok, _} = Application.ensure_all_started(:arbor_ai)
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)
    {:ok, _} = Application.ensure_all_started(:arbor_agent)
    _ = Application.ensure_all_started(:arbor_persistence_ecto)

    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    variants = parse_variants(opts[:variants])
    bug = parse_bug(opts[:bug])
    max_heartbeats = opts[:max_heartbeats] || 15
    reps = opts[:reps] || 1
    model = opts[:model] || "arcee-ai/trinity-large-preview:free"
    provider = parse_provider(opts[:provider])
    council? = opts[:council] || false
    tag = opts[:tag]

    Mix.shell().info("""

    ╔═══════════════════════════════════════════════════════╗
    ║          v3 Real-Bug Memory Ablation Eval             ║
    ╠═══════════════════════════════════════════════════════╣
    ║  Bug:          #{pad(to_string(bug), 38)}║
    ║  Variants:     #{pad(inspect(variants), 38)}║
    ║  Max HB:       #{pad(to_string(max_heartbeats), 38)}║
    ║  Reps:         #{pad(to_string(reps), 38)}║
    ║  Model:        #{pad(model, 38)}║
    ║  Provider:     #{pad(to_string(provider), 38)}║
    ║  Council:      #{pad(to_string(council?), 38)}║
    ║  Tag:          #{pad(tag || "(none)", 38)}║
    ╚═══════════════════════════════════════════════════════╝
    """)

    eval_opts = [
      bug: bug,
      variants: variants,
      max_heartbeats: max_heartbeats,
      reps: reps,
      model: model,
      provider: provider,
      council: council?,
      tag: tag
    ]

    case Arbor.Agent.Eval.TaskEval.run(eval_opts) do
      {:ok, summary} ->
        print_summary(summary)
        print_comparison(summary)

      {:error, reason} ->
        Mix.shell().error("\nEval failed: #{inspect(reason)}")
    end
  end

  # -- Parsers --

  defp parse_variants(nil), do: [:bare, :full]

  defp parse_variants(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(&(&1 in @valid_variants))
  end

  defp parse_bug(nil), do: :glob_wildcard
  defp parse_bug(str), do: String.to_existing_atom(str)

  defp parse_provider(nil), do: :openrouter
  defp parse_provider(str), do: String.to_existing_atom(str)

  # -- Output --

  defp print_summary(summary) do
    Mix.shell().info("\n── Results ──")
    Mix.shell().info("  Total trials:  #{summary.total_trials}")
    Mix.shell().info("  Successful:    #{summary.successful_trials}")
    Mix.shell().info("  Failed:        #{summary.failed_trials}")

    for {variant, stats} <- Enum.sort(summary.variants) do
      Mix.shell().info("""

        ── #{variant} (#{stats.trial_count} trial(s)) ──
          Proposals submitted:  #{stats.proposals_submitted}/#{stats.trial_count}
          Avg heartbeats:       #{stats.avg_heartbeats}
          Avg quality:          #{fmt(stats.avg_quality)}
          Avg file reads:       #{stats.avg_file_reads}
          Avg unique files:     #{stats.avg_unique_files}
          Avg repeated reads:   #{stats.avg_repeated_reads}
      """)
    end
  end

  defp print_comparison(summary) do
    variants = summary.variants

    if map_size(variants) < 2 do
      :ok
    else
      Mix.shell().info("\n── Comparison Table ──")

      header =
        "  #{"Metric" |> String.pad_trailing(22)}" <>
          Enum.map_join(Enum.sort(variants), "", fn {v, _} ->
            to_string(v) |> String.pad_trailing(12)
          end)

      Mix.shell().info(header)
      Mix.shell().info("  " <> String.duplicate("─", 22 + map_size(variants) * 12))

      metrics = [
        {"Proposals", fn s -> "#{s.proposals_submitted}/#{s.trial_count}" end},
        {"Avg Heartbeats", fn s -> fmt(s.avg_heartbeats) end},
        {"Avg Quality", fn s -> fmt(s.avg_quality) end},
        {"Avg File Reads", fn s -> fmt(s.avg_file_reads) end},
        {"Avg Unique Files", fn s -> fmt(s.avg_unique_files) end},
        {"Avg Repeated Reads", fn s -> fmt(s.avg_repeated_reads) end}
      ]

      for {label, extractor} <- metrics do
        row =
          "  #{String.pad_trailing(label, 22)}" <>
            Enum.map_join(Enum.sort(variants), "", fn {_v, stats} ->
              String.pad_trailing(extractor.(stats), 12)
            end)

        Mix.shell().info(row)
      end
    end
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
