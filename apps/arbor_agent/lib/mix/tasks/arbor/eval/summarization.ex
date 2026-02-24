defmodule Mix.Tasks.Arbor.Eval.Summarization do
  @moduledoc """
  Compare LLM models for context summarization quality.

  Tests each model's ability to compress conversation batches while
  preserving key information (file paths, modules, person names, etc).

  ## Usage

      # Quick test with one model
      mix arbor.eval.summarization --model "sambanova/trinity-large"

      # Multiple models
      mix arbor.eval.summarization \\
        --models "anthropic/claude-3-5-haiku-latest,google/gemini-3-flash-preview"

      # Specific transcript types and batch sizes
      mix arbor.eval.summarization \\
        --model "sambanova/trinity-large" \\
        --transcripts "coding,relational" \\
        --batch-sizes "4,8"

      # Tag for experiment tracking
      mix arbor.eval.summarization \\
        --models "anthropic/claude-3-5-haiku-latest,sambanova/trinity-large" \\
        --tag "v1"

  ## Options

    - `--model` — single model ID
    - `--models` — comma-separated model IDs
    - `--provider` — provider name (default: openrouter)
    - `--transcripts` — comma-separated types: coding, relational, mixed (default: all)
    - `--batch-sizes` — comma-separated batch sizes (default: 4,8,16)
    - `--timeout` — per-request timeout in ms (default: 60000)
    - `--tag` — experiment tag
    - `--strategies` — comma-separated prompt strategies: narrative, structured, extractive (default: all)
    - `--no-persist` — skip database persistence
  """

  use Mix.Task

  @shortdoc "Compare LLM models for summarization quality"

  @switches [
    model: :string,
    models: :string,
    provider: :string,
    transcripts: :string,
    batch_sizes: :string,
    strategies: :string,
    timeout: :integer,
    tag: :string,
    persist: :boolean
  ]

  @aliases [
    m: :model,
    p: :provider,
    t: :timeout,
    s: :strategies
  ]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:arbor_agent)
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)

    # Try to start persistence for result storage
    _ = Application.ensure_all_started(:arbor_persistence_ecto)

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    models = parse_models(opts)
    provider = opts[:provider] || "openrouter"
    model_tuples = Enum.map(models, &{provider, &1})

    transcripts = parse_transcripts(opts[:transcripts])
    batch_sizes = parse_batch_sizes(opts[:batch_sizes])
    strategies = parse_strategies(opts[:strategies])
    timeout = opts[:timeout] || 60_000
    persist = Keyword.get(opts, :persist, true)
    tag = opts[:tag]

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════════╗
    ║           Summarization LLM Comparison                   ║
    ╠══════════════════════════════════════════════════════════╣
    ║  Models:      #{pad(Enum.join(models, ", "), 42)}║
    ║  Provider:    #{pad(provider, 42)}║
    ║  Transcripts: #{pad(Enum.join(Enum.map(transcripts, &to_string/1), ", "), 42)}║
    ║  Batch sizes: #{pad(Enum.join(Enum.map(batch_sizes, &to_string/1), ", "), 42)}║
    ║  Strategies:  #{pad(Enum.join(Enum.map(strategies, &to_string/1), ", "), 42)}║
    ║  Timeout:     #{pad("#{timeout}ms", 42)}║
    ║  Persist:     #{pad(to_string(persist), 42)}║
    ╚══════════════════════════════════════════════════════════╝
    """)

    {:ok, _results} =
      Arbor.Agent.Eval.SummarizationEval.run(
        models: model_tuples,
        transcripts: transcripts,
        batch_sizes: batch_sizes,
        prompt_strategies: strategies,
        timeout: timeout,
        persist: persist,
        tag: tag
      )

    Mix.shell().info("Summarization eval complete.")
  end

  defp parse_models(opts) do
    cond do
      opts[:models] ->
        opts[:models] |> String.split(",") |> Enum.map(&String.trim/1)

      opts[:model] ->
        [opts[:model]]

      true ->
        Mix.shell().error("Must specify --model or --models")
        System.halt(1)
    end
  end

  defp parse_transcripts(nil), do: [:coding, :relational, :mixed]

  defp parse_transcripts(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp parse_batch_sizes(nil), do: [4, 8, 16]

  defp parse_batch_sizes(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  end

  defp parse_strategies(nil), do: [:narrative, :structured, :extractive]

  defp parse_strategies(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
