defmodule Mix.Tasks.Arbor.Consult do
  @shortdoc "Consult the advisory council about a design question"
  @moduledoc """
  Consult the advisory evaluator council about a design question.

      $ mix arbor.consult "Should evaluator agents be persistent GenServers?"
      $ mix arbor.consult "Should we use Redis or ETS?" --perspective brainstorming
      $ mix arbor.consult "Persistent agents?" -p stability --docs .arbor/roadmap/3-in-progress/consensus-redesign.md
      $ mix arbor.consult "Full review" --all --docs design.md --context "budget:low,timeline:2 weeks"
      $ mix arbor.consult "Build order?" --all --save --docs design.md
      $ mix arbor.consult "What is consciousness?" --multi-model --save

  ## Options

    * `--perspective` / `-p`  — Ask a single perspective (default: brainstorming)
    * `--all` / `-a`          — Ask all 12 perspectives (expensive: 12 LLM calls)
    * `--multi-model` / `-m`  — Same perspective across all 4 providers (4 LLM calls)
    * `--save` / `-s`         — Save results to .arbor/council/<slug>/
    * `--docs` / `-d`         — Reference doc paths (comma-separated or repeated)
    * `--context` / `-c`      — Extra context as key:value pairs (comma-separated)
    * `--provider`            — Override CLI provider (anthropic, gemini, openai, opencode)
    * `--timeout`             — Per-perspective timeout in seconds (default: 180)

  ## Saving Results

  With `--save`, results are persisted to `.arbor/council/<date>-<slug>/`:

      .arbor/council/2026-02-02-consensus-build-order/
        question.md          # Original question, options, metadata
        perspectives.md      # All perspective responses

  This creates a reviewable audit trail. Follow up with a `synthesis.md`
  after reviewing the perspectives.

  ## Examples

  Quick brainstorm (one perspective, ~$0.02-0.05):

      $ mix arbor.consult "How should the TopicMatcher route proposals?"

  Targeted question with docs:

      $ mix arbor.consult "Persistent agents vs spawned?" -p stability \\
        --docs .arbor/roadmap/3-in-progress/consensus-redesign.md

  Full council with save (12 perspectives, ~$0.50-1.00):

      $ mix arbor.consult "Should we redesign the Coordinator?" --all --save
  """
  use Mix.Task

  alias Arbor.Common.SafeAtom
  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Consensus.Evaluators.Consult

  @perspectives AdvisoryLLM.perspectives()

  @switches [
    perspective: :string,
    all: :boolean,
    multi_model: :boolean,
    save: :boolean,
    docs: [:string],
    context: :string,
    provider: :string,
    timeout: :integer
  ]

  @aliases [
    p: :perspective,
    a: :all,
    m: :multi_model,
    s: :save,
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
      -m, --multi-model        Same perspective, all 4 providers (use with -p)
      -s, --save               Save results to .arbor/council/
      -d, --docs PATH          Reference doc paths
      -c, --context KV         Context as key:value pairs
          --provider NAME      Override CLI provider
          --timeout SECONDS    Timeout per perspective (default: 180)

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

    # Start only what the council needs: AI backends, consensus config, and logger.
    # Using app.start boots the entire application tree including gateway/dashboard
    # HTTP servers, which fails with :eaddrinuse if they're already running.
    ensure_minimal_deps()

    context = build_context(opts)
    eval_opts = build_eval_opts(opts)
    provider_override = eval_opts[:provider]
    save? = opts[:save] || false

    {results, mode} = dispatch_consultation(opts, question, context, eval_opts, provider_override)

    if save? and results != :error do
      save_results(question, results, opts, provider_override, mode)
    end
  end

  # ============================================================================
  # Dispatch
  # ============================================================================

  defp dispatch_consultation(opts, question, context, eval_opts, provider_override) do
    if opts[:multi_model] do
      perspective = parse_perspective(opts[:perspective] || "brainstorming")
      {ask_multi_model(question, perspective, context, eval_opts), :multi_model}
    else
      results = dispatch_standard(opts, question, context, eval_opts, provider_override)
      {results, :standard}
    end
  end

  defp dispatch_standard(opts, question, context, eval_opts, provider_override) do
    if opts[:all] do
      ask_all(question, context, eval_opts, provider_override)
    else
      perspective = parse_perspective(opts[:perspective] || "brainstorming")
      ask_one(question, perspective, context, eval_opts, provider_override)
    end
  end

  # ============================================================================
  # Single Perspective
  # ============================================================================

  defp ask_one(question, perspective, context, eval_opts, provider_override) do
    Mix.shell().info("Consulting :#{perspective}...\n")

    case Consult.ask_one(AdvisoryLLM, question, perspective, [context: context] ++ eval_opts) do
      {:ok, eval} ->
        print_evaluation(perspective, eval, provider_override)
        [{perspective, eval}]

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # ============================================================================
  # Multi-Model (same perspective, all providers)
  # ============================================================================

  defp ask_multi_model(question, perspective, context, eval_opts) do
    providers = [:anthropic, :gemini, :openai, :opencode]
    Mix.shell().info("Consulting :#{perspective} across #{length(providers)} providers...\n")

    case Consult.ask_multi_model(
           AdvisoryLLM,
           question,
           perspective,
           [context: context] ++ eval_opts
         ) do
      {:ok, results} ->
        {successes, failures} =
          Enum.split_with(results, fn
            {_, {:error, _}} -> false
            _ -> true
          end)

        Enum.each(successes, fn {provider, eval} ->
          print_multi_model_evaluation(perspective, provider, eval)
        end)

        Enum.each(failures, fn {provider, {:error, reason}} ->
          Mix.shell().error("=== #{provider} === ERROR: #{inspect(reason)}\n")
        end)

        Mix.shell().info(
          "--- Done: #{length(successes)}/#{length(providers)} providers responded" <>
            if(failures != [], do: ", #{length(failures)} failed", else: "") <>
            " ---"
        )

        successes

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # ============================================================================
  # All Perspectives
  # ============================================================================

  defp ask_all(question, context, eval_opts, provider_override) do
    count = length(@perspectives)
    Mix.shell().info("Consulting all #{count} perspectives in parallel...\n")

    case Consult.ask(AdvisoryLLM, question, [context: context] ++ eval_opts) do
      {:ok, results} ->
        {successes, failures} =
          Enum.split_with(results, fn
            {_, {:error, _}} -> false
            _ -> true
          end)

        Enum.each(successes, fn {perspective, eval} ->
          print_evaluation(perspective, eval, provider_override)
        end)

        Enum.each(failures, fn {perspective, {:error, reason}} ->
          Mix.shell().error("=== #{perspective} === ERROR: #{inspect(reason)}\n")
        end)

        Mix.shell().info(
          "--- Done: #{length(successes)}/#{count} perspectives responded" <>
            if(failures != [], do: ", #{length(failures)} failed", else: "") <>
            " ---"
        )

        # Return successful results for saving
        successes

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # ============================================================================
  # Output
  # ============================================================================

  defp print_evaluation(perspective, eval, provider_override) do
    provider = provider_override || AdvisoryLLM.provider_map()[perspective] || :unknown

    Mix.shell().info("""
    ╔══════════════════════════════════════════════════════════════╗
    ║  #{String.pad_trailing(to_string(perspective), 20)} (#{provider})#{String.duplicate(" ", max(0, 33 - String.length(to_string(provider))))}║
    ╚══════════════════════════════════════════════════════════════╝

    #{eval.reasoning}
    """)
  end

  defp print_multi_model_evaluation(perspective, provider, eval) do
    Mix.shell().info("""
    ╔══════════════════════════════════════════════════════════════╗
    ║  #{String.pad_trailing(to_string(provider), 20)} (as :#{perspective})#{String.duplicate(" ", max(0, 30 - String.length(to_string(perspective))))}║
    ╚══════════════════════════════════════════════════════════════╝

    #{eval.reasoning}
    """)
  end

  # ============================================================================
  # Save to .arbor/council/
  # ============================================================================

  defp save_results(question, results, opts, provider_override, mode) do
    slug = slugify(question)
    date = Date.utc_today() |> Date.to_string()
    dir = Path.join([".arbor", "council", "#{date}-#{slug}"])

    File.mkdir_p!(dir)

    write_question_file(dir, question, results, opts, provider_override, mode)
    write_perspectives_file(dir, question, results, provider_override, mode)

    Mix.shell().info("\nSaved to #{dir}/")
  end

  defp write_question_file(dir, question, results, opts, provider_override, mode) do
    doc_paths = Keyword.get_values(opts, :docs) |> Enum.flat_map(&split_paths/1)
    perspectives_consulted = format_consulted(results, opts, mode)

    provider_line =
      if provider_override, do: "provider: #{provider_override}\n", else: ""

    docs_lines =
      case doc_paths do
        [] -> ""
        paths -> "docs:\n" <> Enum.map_join(paths, "\n", &"  - #{&1}") <> "\n"
      end

    context_line =
      case opts[:context] do
        nil -> ""
        ctx -> "context: #{ctx}\n"
      end

    content = """
    ---
    date: #{Date.utc_today()}
    perspectives: #{perspectives_consulted}
    responded: #{length(results)}/#{if opts[:all], do: length(@perspectives), else: 1}
    #{provider_line}#{docs_lines}#{context_line}---

    # #{question}

    #{format_docs_section(doc_paths)}#{format_context_section(opts[:context])}
    """

    File.write!(Path.join(dir, "question.md"), String.trim(content) <> "\n")
  end

  defp write_perspectives_file(dir, question, results, provider_override, mode) do
    {title, body} =
      case mode do
        :multi_model ->
          {"# Multi-Model Responses",
           Enum.map_join(results, "\n---\n\n", fn {provider, eval} ->
             """
             ## #{provider}

             #{eval.reasoning}
             """
           end)}

        _ ->
          {"# Council Perspectives",
           Enum.map_join(results, "\n---\n\n", fn {perspective, eval} ->
             provider =
               provider_override || AdvisoryLLM.provider_map()[perspective] || :unknown

             """
             ## #{perspective} (#{provider})

             #{eval.reasoning}
             """
           end)}
      end

    header = """
    ---
    date: #{Date.utc_today()}
    question: "#{String.replace(question, "\"", "\\\"")}"
    mode: #{mode}
    responded: #{length(results)}
    ---

    #{title}
    """

    File.write!(
      Path.join(dir, "perspectives.md"),
      String.trim(header) <> "\n\n" <> String.trim(body) <> "\n"
    )
  end

  defp format_consulted(results, opts, :multi_model) do
    perspective = opts[:perspective] || "brainstorming"
    providers = Enum.map_join(results, ", ", fn {p, _} -> to_string(p) end)
    "multi-model :#{perspective} (#{providers})"
  end

  defp format_consulted(results, opts, _mode) do
    if opts[:all],
      do: "all (#{length(@perspectives)})",
      else: Enum.map_join(results, ", ", fn {p, _} -> to_string(p) end)
  end

  defp format_docs_section([]), do: ""

  defp format_docs_section(doc_paths) do
    "## Reference Documents\n\n" <>
      Enum.map_join(doc_paths, "\n", &"- #{&1}") <> "\n\n"
  end

  defp format_context_section(nil), do: ""

  defp format_context_section(context_str) do
    pairs =
      context_str
      |> String.split(",")
      |> Enum.map_join("\n", fn pair ->
        case String.split(pair, ":", parts: 2) do
          [k, v] -> "- **#{String.trim(k)}**: #{String.trim(v)}"
          [k] -> "- **#{String.trim(k)}**"
        end
      end)

    "## Context\n\n" <> pairs <> "\n\n"
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(6)
    |> Enum.join("-")
    |> String.slice(0, 50)
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
    base = build_docs_context(Keyword.get_values(opts, :docs))

    case opts[:context] do
      nil -> base
      context_str -> Map.merge(base, parse_context_string(context_str))
    end
  end

  defp build_docs_context([]), do: %{}

  defp build_docs_context(doc_paths),
    do: %{reference_docs: Enum.flat_map(doc_paths, &split_paths/1)}

  defp parse_context_string(str) do
    str
    |> String.split(",")
    |> Enum.map(&parse_context_pair/1)
    |> Map.new(&atomize_context_key/1)
  end

  defp parse_context_pair(pair) do
    case String.split(pair, ":", parts: 2) do
      [k, v] -> {String.trim(k), String.trim(v)}
      [k] -> {String.trim(k), "true"}
    end
  end

  defp atomize_context_key({k, v}) do
    case SafeAtom.to_existing(k) do
      {:ok, atom} -> {atom, v}
      {:error, _} -> {k, v}
    end
  end

  defp build_eval_opts(opts) do
    eval_opts = []

    eval_opts =
      case opts[:provider] do
        nil ->
          eval_opts

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

  defp ensure_minimal_deps do
    # The council only needs:
    # - arbor_ai: LLM API calls (BackendRegistry, QuotaTracker, SessionRegistry)
    # - logger/jason/req: transitive deps for AI calls
    # - arbor_contracts/arbor_common: pure modules, no processes needed
    #
    # It does NOT need: gateway, dashboard, signals, historian, shell, sandbox,
    # sdlc, agent, security, trust, persistence — all of which may bind ports
    # or start heavy process trees.
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:arbor_ai)
  end
end
