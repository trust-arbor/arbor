defmodule Mix.Tasks.Arbor.Consult do
  @shortdoc "Consult the advisory council about a design question"
  @moduledoc """
  Consult the advisory evaluator council about a design question.

      $ mix arbor.consult "Should evaluator agents be persistent GenServers?"
      $ mix arbor.consult "Should we use Redis or ETS?" --perspective brainstorming
      $ mix arbor.consult "Persistent agents?" -p stability --docs .arbor/roadmap/3-in-progress/consensus-redesign.md
      $ mix arbor.consult "Full review" --all --docs design.md --context "budget:low,timeline:2 weeks"

  ## Options

    * `--perspective` / `-p`  — Ask a single perspective (default: brainstorming)
    * `--all` / `-a`          — Ask all 12 perspectives (expensive: 12 LLM calls)
    * `--docs` / `-d`         — Reference doc paths (comma-separated or repeated)
    * `--context` / `-c`      — Extra context as key:value pairs (comma-separated)
    * `--provider`            — Override CLI provider (anthropic, gemini, openai, opencode)
    * `--timeout`             — Per-perspective timeout in seconds (default: 120)

  ## Examples

  Quick brainstorm (one perspective, ~$0.02-0.05):

      $ mix arbor.consult "How should the TopicMatcher route proposals?"

  Targeted question with docs:

      $ mix arbor.consult "Persistent agents vs spawned?" -p stability \\
        --docs .arbor/roadmap/3-in-progress/consensus-redesign.md

  Full council (12 perspectives, ~$0.50-1.00):

      $ mix arbor.consult "Should we redesign the Coordinator?" --all
  """
  use Mix.Task

  alias Arbor.Common.SafeAtom
  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Consensus.Evaluators.Consult

  @perspectives AdvisoryLLM.perspectives()

  @switches [
    perspective: :string,
    all: :boolean,
    docs: [:string],
    context: :string,
    provider: :string,
    timeout: :integer
  ]

  @aliases [
    p: :perspective,
    a: :all,
    d: :docs,
    c: :context
  ]

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("""
    Usage: mix arbor.consult "your question" [options]

    Options:
      -p, --perspective NAME   Ask one perspective (default: brainstorming)
      -a, --all                Ask all 12 perspectives
      -d, --docs PATH          Reference doc paths
      -c, --context KV         Context as key:value pairs
          --provider NAME      Override CLI provider
          --timeout SECONDS    Timeout per perspective (default: 120)

    Perspectives: #{Enum.join(@perspectives, ", ")}
    """)

    exit({:shutdown, 1})
  end

  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    question = Enum.join(positional, " ")

    if question == "" do
      Mix.shell().error("Error: no question provided")
      exit({:shutdown, 1})
    end

    # Start dependencies for AI calls
    Mix.Task.run("app.start")

    context = build_context(opts)
    eval_opts = build_eval_opts(opts)

    if opts[:all] do
      ask_all(question, context, eval_opts)
    else
      perspective = parse_perspective(opts[:perspective] || "brainstorming")
      ask_one(question, perspective, context, eval_opts)
    end
  end

  # ============================================================================
  # Single Perspective
  # ============================================================================

  defp ask_one(question, perspective, context, eval_opts) do
    Mix.shell().info("Consulting :#{perspective}...\n")

    case Consult.ask_one(AdvisoryLLM, question, perspective, [context: context] ++ eval_opts) do
      {:ok, eval} ->
        print_evaluation(perspective, eval)

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # ============================================================================
  # All Perspectives
  # ============================================================================

  defp ask_all(question, context, eval_opts) do
    count = length(@perspectives)
    Mix.shell().info("Consulting all #{count} perspectives in parallel...\n")

    case Consult.ask(AdvisoryLLM, question, [context: context] ++ eval_opts) do
      {:ok, results} ->
        Enum.each(results, fn
          {perspective, {:error, reason}} ->
            Mix.shell().error("=== #{perspective} === ERROR: #{inspect(reason)}\n")

          {perspective, eval} ->
            print_evaluation(perspective, eval)
        end)

        Mix.shell().info("--- Done: #{count} perspectives consulted ---")

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # ============================================================================
  # Output
  # ============================================================================

  defp print_evaluation(perspective, eval) do
    provider = AdvisoryLLM.provider_map()[perspective] || :unknown

    Mix.shell().info("""
    ╔══════════════════════════════════════════════════════════════╗
    ║  #{String.pad_trailing(to_string(perspective), 20)} (#{provider})#{String.duplicate(" ", max(0, 33 - String.length(to_string(provider))))}║
    ╚══════════════════════════════════════════════════════════════╝

    #{eval.reasoning}
    """)
  end

  # ============================================================================
  # Argument Parsing
  # ============================================================================

  defp parse_perspective(name) do
    atom =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> nil
      end

    if atom in @perspectives do
      atom
    else
      Mix.shell().error("""
      Unknown perspective: #{name}

      Available: #{Enum.join(@perspectives, ", ")}
      """)

      exit({:shutdown, 1})
    end
  end

  defp build_context(opts) do
    base =
      case Keyword.get_values(opts, :docs) do
        [] -> %{}
        doc_paths -> %{reference_docs: Enum.flat_map(doc_paths, &split_paths/1)}
      end

    case opts[:context] do
      nil ->
        base

      context_str ->
        extra =
          context_str
          |> String.split(",")
          |> Enum.map(fn pair ->
            case String.split(pair, ":", parts: 2) do
              [k, v] -> {String.trim(k), String.trim(v)}
              [k] -> {String.trim(k), "true"}
            end
          end)
          |> Map.new(fn {k, v} ->
            case SafeAtom.to_existing(k) do
              {:ok, atom} -> {atom, v}
              {:error, _} -> {k, v}
            end
          end)

        Map.merge(base, extra)
    end
  end

  defp build_eval_opts(opts) do
    eval_opts = []

    eval_opts =
      case opts[:provider] do
        nil -> eval_opts
        p ->
          allowed = [:anthropic, :gemini, :openai, :opencode]

          provider =
            case SafeAtom.to_allowed(p, allowed) do
              {:ok, atom} -> atom
              {:error, _} -> :anthropic
            end

          Keyword.put(eval_opts, :provider, provider)
      end

    case opts[:timeout] do
      nil -> eval_opts
      t -> Keyword.put(eval_opts, :timeout, t * 1_000)
    end
  end

  defp split_paths(str), do: String.split(str, ",", trim: true)
end
