defmodule Mix.Tasks.Arbor.Eval.GenerateCorpus do
  @moduledoc """
  Generate a padding corpus for the effective window eval.

  Two source modes:

  - **sessions** (default) — Sample from existing Claude Code session JSONL files.
    Free, instant, genuinely realistic conversation data.
  - **llm** — Generate synthetic padding via LLM API calls ($0.40/M output tokens).

  Both modes append to the same corpus file and respect existing content.

  ## Usage

      # Default: sample 2M tokens from session files
      mix arbor.eval.generate_corpus

      # Explicit session mode with custom target
      mix arbor.eval.generate_corpus --source sessions --target-tokens 500000

      # LLM generation mode
      mix arbor.eval.generate_corpus --source llm --model "openai/gpt-5-nano"

      # Custom output path
      mix arbor.eval.generate_corpus --output /tmp/test_corpus.jsonl

  ## Options

    - `--source` — "sessions" (default) or "llm"
    - `--target-tokens` — target total tokens (default: 2000000)
    - `--output` — output file path (default: priv/eval_data/padding_corpus.jsonl)
    - `--max-files` — max session files to read (default: 10, sessions mode)
    - `--model` — LLM model ID (default: openai/gpt-5-nano, llm mode)
    - `--provider` — provider name (default: openrouter, llm mode)
    - `--concurrency` — max concurrent API requests (default: 10, llm mode)
  """

  use Mix.Task

  @shortdoc "Generate padding corpus for effective window eval"

  @switches [
    source: :string,
    model: :string,
    provider: :string,
    target_tokens: :integer,
    concurrency: :integer,
    max_files: :integer,
    output: :string
  ]

  @aliases [
    s: :source,
    m: :model,
    p: :provider,
    t: :target_tokens,
    c: :concurrency,
    o: :output
  ]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:arbor_agent)

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    source = opts[:source] || "sessions"
    target = opts[:target_tokens] || 2_000_000

    case source do
      "sessions" -> run_sessions(opts, target)
      "llm" -> run_llm(opts, target)
      other -> Mix.shell().error("Unknown source: #{other}. Use 'sessions' or 'llm'.")
    end
  end

  defp run_sessions(opts, target) do
    max_files = opts[:max_files] || 10

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════╗
    ║         Corpus Generation (Session Sampling)         ║
    ╠══════════════════════════════════════════════════════╣
    ║  Source:      sessions                               ║
    ║  Target:      #{pad("#{target} tokens", 38)}║
    ║  Max files:   #{pad(to_string(max_files), 38)}║
    ╚══════════════════════════════════════════════════════╝
    """)

    gen_opts =
      [target_tokens: target, max_files: max_files]
      |> maybe_add(:output, opts[:output])

    case Arbor.Agent.Eval.CorpusGenerator.sample_sessions(gen_opts) do
      {:ok, stats} -> print_stats(stats)
      {:error, reason} -> Mix.shell().error("Corpus generation failed: #{inspect(reason)}")
    end
  end

  defp run_llm(opts, target) do
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)

    concurrency = opts[:concurrency] || 10
    model = opts[:model] || "openai/gpt-5-nano"
    provider = opts[:provider] || "openrouter"

    Mix.shell().info("""

    ╔══════════════════════════════════════════════════════╗
    ║         Corpus Generation (LLM)                      ║
    ╠══════════════════════════════════════════════════════╣
    ║  Model:       #{pad(model, 38)}║
    ║  Provider:    #{pad(provider, 38)}║
    ║  Target:      #{pad("#{target} tokens", 38)}║
    ║  Concurrency: #{pad(to_string(concurrency), 38)}║
    ╚══════════════════════════════════════════════════════╝
    """)

    gen_opts =
      [
        model: model,
        provider: provider,
        target_tokens: target,
        concurrency: concurrency,
        progress_fn: &print_progress/3
      ]
      |> maybe_add(:output, opts[:output])

    case Arbor.Agent.Eval.CorpusGenerator.generate(gen_opts) do
      {:ok, stats} -> print_stats(stats)
      {:error, reason} -> Mix.shell().error("Corpus generation failed: #{inspect(reason)}")
    end
  end

  defp print_stats(stats) do
    new_info =
      if Map.has_key?(stats, :new_messages) do
        "  New:       +#{stats.new_messages} messages, ~#{stats.new_tokens} tokens\n"
      else
        ""
      end

    Mix.shell().info("""

    ── Generation Complete ──
      Messages:  #{stats.total_messages}
      Tokens:    ~#{stats.total_tokens}
    #{new_info}  File size: #{format_bytes(stats.file_size_bytes)}
      Duration:  #{stats.duration_ms}ms
      Output:    #{stats.output_path}
    """)
  end

  defp print_progress(completed, total, tokens) do
    Mix.shell().info(
      "[#{completed}/#{total}] Generated ~#{div(tokens, 1000)}K tokens..."
    )
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)}MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)}KB"
  end

  defp format_bytes(bytes), do: "#{bytes}B"

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
