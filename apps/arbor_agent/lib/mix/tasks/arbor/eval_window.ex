defmodule Mix.Tasks.Arbor.Eval.Window do
  @moduledoc """
  Run effective window discovery eval for LLM models.

  Discovers the effective context window per model by seeding verifiable
  facts across a conversation context at various fill levels and measuring
  fact recall accuracy.

  ## Usage

      # Single model
      mix arbor.eval.window --model "anthropic/claude-3-5-haiku-latest" --provider openrouter

      # Multiple models
      mix arbor.eval.window --models "anthropic/claude-3-5-haiku-latest,google/gemini-3-flash-preview" --provider openrouter

      # Custom fill levels
      mix arbor.eval.window --model "..." --provider "..." --fills "0.5,0.6,0.7,0.8,0.9"

      # Fewer facts for quick test
      mix arbor.eval.window --model "..." --provider "..." --facts 10

      # Override context window
      mix arbor.eval.window --model "..." --provider "..." --context-window 100000

  ## Options

    - `--model` — single model ID
    - `--models` — comma-separated model IDs
    - `--provider` — provider name (default: openrouter)
    - `--fills` — comma-separated fill levels (default: 0.1 to 1.0 by 0.1)
    - `--facts` — number of facts (default: 30)
    - `--timeout` — per-request timeout ms (default: 120000)
    - `--context-window` — override model context window (tokens)
    - `--tag` — version/experiment tag
    - `--no-persist` — skip persistence
  """

  use Mix.Task

  @shortdoc "Run effective window discovery eval"

  @switches [
    model: :string,
    models: :string,
    provider: :string,
    fills: :string,
    facts: :integer,
    timeout: :integer,
    context_window: :integer,
    tag: :string,
    persist: :boolean
  ]

  @aliases [
    m: :model,
    p: :provider,
    f: :facts,
    t: :timeout
  ]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:arbor_agent)
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)
    _ = Application.ensure_all_started(:arbor_persistence_ecto)

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    models = parse_models(opts)

    if models == [] do
      Mix.shell().error("No models specified. Use --model or --models.")
      exit(:shutdown)
    end

    provider = opts[:provider] || "openrouter"
    fill_levels = parse_fills(opts[:fills])
    num_facts = opts[:facts] || 30
    timeout = opts[:timeout] || 120_000
    context_window = opts[:context_window]
    tag = opts[:tag]
    persist = Keyword.get(opts, :persist, true)

    model_tuples = Enum.map(models, fn model -> {provider, model} end)

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════╗
    ║         Effective Window Discovery Eval              ║
    ╠══════════════════════════════════════════════════════╣
    ║  Models:      #{pad(inspect(models), 38)}║
    ║  Provider:    #{pad(provider, 38)}║
    ║  Fill levels: #{pad(inspect(fill_levels), 38)}║
    ║  Facts:       #{pad(to_string(num_facts), 38)}║
    ║  Timeout:     #{pad("#{timeout}ms", 38)}║
    ║  Tag:         #{pad(tag || "(none)", 38)}║
    ╚══════════════════════════════════════════════════════╝
    """)

    eval_opts =
      [
        models: model_tuples,
        fill_levels: fill_levels,
        num_facts: num_facts,
        timeout: timeout,
        persist: persist,
        tag: tag
      ]
      |> maybe_add(:context_window, context_window)

    {:ok, results} = Arbor.Agent.Eval.EffectiveWindowEval.run(eval_opts)
    print_summary(results)
  rescue
    e -> Mix.shell().error("Eval failed: #{Exception.message(e)}")
  end

  defp parse_models(opts) do
    cond do
      opts[:models] ->
        opts[:models] |> String.split(",") |> Enum.map(&String.trim/1)

      opts[:model] ->
        [opts[:model]]

      true ->
        []
    end
  end

  defp parse_fills(nil), do: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

  defp parse_fills(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_float/1)
    |> Enum.filter(&(&1 > 0.0 and &1 <= 1.0))
    |> Enum.sort()
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_summary(results) do
    Mix.shell().info("\n── Summary ──")

    for r <- results do
      effective =
        if r.effective_window,
          do: "#{trunc(r.effective_window * 100)}%",
          else: "none"

      recommended =
        if r.recommended_threshold,
          do: "#{r.recommended_threshold}",
          else: "n/a"

      Mix.shell().info("""
        #{r.model} (#{r.provider})
          Context window:    #{r.context_window}
          Effective window:  #{effective}
          Recommended threshold: #{recommended}
      """)
    end
  end

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
