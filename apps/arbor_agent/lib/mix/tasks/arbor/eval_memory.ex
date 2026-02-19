defmodule Mix.Tasks.Arbor.EvalMemory do
  @moduledoc """
  Run memory subsystem ablation evaluations.

  Tests which memory subsystems actually affect agent behavior by running
  controlled heartbeat trials with progressively richer memory context.

  Designed to be run as a standalone process (not via Task.start) so it
  survives context rollovers and session restarts.

  ## Usage

      mix arbor.eval.memory                          # All tiers, 1 run, 10 heartbeats
      mix arbor.eval.memory --tiers 0,1,5            # Specific tiers
      mix arbor.eval.memory --runs 3 --heartbeats 15 # More runs, more heartbeats
      mix arbor.eval.memory --model google/gemini-3-flash-preview
      mix arbor.eval.memory --tag v2                  # Tag runs for identification

  ## Options

    * `--tiers` - Comma-separated tier numbers (default: 0,1,2,3,4,5)
    * `--runs` - Number of runs per tier (default: 1)
    * `--heartbeats` - Heartbeats per run (default: 10)
    * `--model` - LLM model (default: google/gemini-3-flash-preview)
    * `--provider` - LLM provider (default: openrouter)
    * `--tag` - Version/experiment tag stored in metadata (default: none)

  ## Tiers (v2 design — conversation is infrastructure)

    0: Baseline    — timing + tools + format + conversation + directive
    1: Goals       — baseline + goals
    2: Identity    — baseline + self_knowledge
    3: Combined    — baseline + goals + self_knowledge
    4: Operational — + cognitive, percepts, pending
    5: Full        — all sections
  """

  use Mix.Task

  @shortdoc "Run memory subsystem ablation evaluations"

  @switches [
    tiers: :string,
    runs: :integer,
    heartbeats: :integer,
    model: :string,
    provider: :string,
    tag: :string
  ]

  @impl Mix.Task
  def run(args) do
    # Start only the apps we need, avoid port conflicts with running servers
    {:ok, _} = Application.ensure_all_started(:arbor_memory)
    {:ok, _} = Application.ensure_all_started(:arbor_ai)
    {:ok, _} = Application.ensure_all_started(:arbor_agent)

    # Ensure persistence is available for storing results
    _ = Application.ensure_all_started(:arbor_persistence_ecto)

    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    tiers = parse_tiers(opts[:tiers])
    runs = opts[:runs] || 1
    heartbeats = opts[:heartbeats] || 10
    model = opts[:model] || "google/gemini-3-flash-preview"
    provider = String.to_existing_atom(opts[:provider] || "openrouter")
    tag = opts[:tag]

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════╗
    ║          Memory Subsystem Ablation Study             ║
    ╠══════════════════════════════════════════════════════╣
    ║  Tiers:      #{pad(inspect(tiers), 38)}║
    ║  Runs/tier:  #{pad(to_string(runs), 38)}║
    ║  Heartbeats: #{pad(to_string(heartbeats), 38)}║
    ║  Model:      #{pad(model, 38)}║
    ║  Provider:   #{pad(to_string(provider), 38)}║
    ║  Tag:        #{pad(tag || "(none)", 38)}║
    ╚══════════════════════════════════════════════════════╝
    """)

    ablation_opts = [
      tiers: tiers,
      runs: runs,
      heartbeats: heartbeats,
      model: model,
      provider: provider,
      tag: tag
    ]

    result = Arbor.Agent.Eval.MemoryAblation.run(ablation_opts)

    case result do
      {:ok, summary} ->
        print_summary(summary)
        print_comparison(summary)

      other ->
        Mix.shell().error("Ablation study failed: #{inspect(other)}")
    end
  end

  defp parse_tiers(nil), do: [0, 1, 2, 3, 4, 5]

  defp parse_tiers(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
    |> Enum.filter(&(&1 in 0..5))
  end

  defp print_summary(summary) do
    Mix.shell().info("\n── Study Summary ──")
    Mix.shell().info("  Total trials: #{summary.total_trials}")
    Mix.shell().info("  Successful:   #{summary.successful_trials}")
    Mix.shell().info("  Failed:       #{summary.failed_trials}")
    Mix.shell().info("  Duration:     #{Float.round(summary.total_duration_ms / 1000, 1)}s")

    for {tier, data} <- Enum.sort(summary.tiers) do
      m = data.avg_metrics

      Mix.shell().info("""

      ── Tier #{tier}: #{data.name} (#{data.trial_count} trial(s)) ──
        Actions/hb:        #{fmt(m[:actions_per_heartbeat] || m.actions_per_heartbeat)}
        Unique actions:    #{m[:unique_action_types] || m.unique_action_types}
        Action entropy:    #{fmt(m[:action_entropy] || m.action_entropy)}
        Goals created/hb:  #{fmt(m[:new_goals_per_heartbeat] || m.new_goals_per_heartbeat)}
        Goal updates/hb:   #{fmt(m[:goal_updates_per_heartbeat] || m.goal_updates_per_heartbeat)}
        Memory notes/hb:   #{fmt(m[:memory_notes_per_heartbeat] || m.memory_notes_per_heartbeat)}
        Concerns/hb:       #{fmt(m[:concerns_per_heartbeat] || m.concerns_per_heartbeat)}
        Curiosity/hb:      #{fmt(m[:curiosity_per_heartbeat] || m.curiosity_per_heartbeat)}
        Identity ins/hb:   #{fmt(m[:identity_insights_per_heartbeat] || m.identity_insights_per_heartbeat)}
        Avg thinking len:  #{round(m[:avg_thinking_length] || m.avg_thinking_length)}
        Avg LLM time:      #{round(m[:avg_llm_duration_ms] || m.avg_llm_duration_ms)}ms
      """)
    end
  end

  defp print_comparison(summary) do
    tiers = Enum.sort(summary.tiers)
    if length(tiers) < 2, do: :ok, else: do_comparison(tiers)
  end

  defp do_comparison(tiers) do
    Mix.shell().info("\n── Behavioral Delta (vs Tier 0 baseline) ──")
    {0, baseline} = Enum.find(tiers, fn {t, _} -> t == 0 end) || {0, nil}

    if baseline == nil do
      Mix.shell().info("  (No Tier 0 baseline — skipping comparison)")
    else
      base_m = baseline.avg_metrics

      for {tier, data} <- tiers, tier > 0 do
        m = data.avg_metrics
        Mix.shell().info("  Tier #{tier} (#{data.name}):")
        print_delta("    Actions/hb", base_m, m, :actions_per_heartbeat)
        print_delta("    Entropy", base_m, m, :action_entropy)
        print_delta("    Goals/hb", base_m, m, :new_goals_per_heartbeat)
        print_delta("    Notes/hb", base_m, m, :memory_notes_per_heartbeat)
        print_delta("    Concerns/hb", base_m, m, :concerns_per_heartbeat)
        print_delta("    Curiosity/hb", base_m, m, :curiosity_per_heartbeat)
        print_delta("    Insights/hb", base_m, m, :identity_insights_per_heartbeat)
      end
    end
  end

  defp print_delta(label, base, current, key) do
    b = get_metric(base, key)
    c = get_metric(current, key)
    delta = c - b

    sign = if delta >= 0, do: "+", else: ""
    pct = if b > 0, do: " (#{sign}#{round(delta / b * 100)}%)", else: ""
    Mix.shell().info("#{label}: #{fmt(c)} (#{sign}#{fmt(delta)}#{pct})")
  end

  defp get_metric(m, key) when is_map(m) do
    Map.get(m, key) || Map.get(m, to_string(key)) || 0
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
