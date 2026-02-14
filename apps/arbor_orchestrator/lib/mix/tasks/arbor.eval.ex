defmodule Mix.Tasks.Arbor.Eval do
  @shortdoc "Run LLM evaluation jobs and persist results"
  @moduledoc """
  Run evaluation jobs against LLM models across multiple domains,
  persisting results to Postgres for historical comparison.

  ## Run an eval

      mix arbor.eval --domain coding --model "kimi-k2.5:cloud" --provider ollama
      mix arbor.eval --domain heartbeat --model "trinity-large-preview:free" --provider ollama
      mix arbor.eval --domain chat --model "claude-sonnet-4-5-20250929" --provider anthropic

  ## Multi-model eval

      mix arbor.eval --domain coding --models "kimi-k2.5:cloud,glm-5:cloud" --provider ollama

  ## List past runs

      mix arbor.eval --list
      mix arbor.eval --list --domain coding
      mix arbor.eval --list --domain coding --model "kimi-k2.5:cloud"

  ## Compare runs

      mix arbor.eval --compare <run_id_a> <run_id_b>

  ## Options

    - `--domain` — eval domain: coding, heartbeat, chat, embedding
    - `--model` — model identifier
    - `--models` — comma-separated model identifiers (multi-model mode)
    - `--provider` — provider name (ollama, lm_studio, anthropic, openai, etc.)
    - `--dataset` — override default dataset for domain
    - `--list` — list past runs
    - `--compare` — compare two runs (pass two run IDs as positional args)
    - `--limit` — limit number of samples
    - `--stream` — use streaming mode for TTFT measurement
    - `--timeout` — per-request timeout in ms (default: 60000)
  """

  use Mix.Task

  @domain_datasets %{
    "coding" => "apps/arbor_orchestrator/priv/eval_datasets/elixir_coding.jsonl",
    "heartbeat" => "apps/arbor_orchestrator/priv/eval_datasets/heartbeat_json.jsonl",
    "chat" => "apps/arbor_orchestrator/priv/eval_datasets/chat_quality.jsonl"
  }

  @domain_graders %{
    "coding" => ["compile_check", "functional_test"],
    "heartbeat" => ["json_valid"],
    "chat" => ["contains"]
  }

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          domain: :string,
          model: :string,
          models: :string,
          provider: :string,
          dataset: :string,
          list: :boolean,
          compare: :boolean,
          limit: :integer,
          stream: :boolean,
          timeout: :integer
        ]
      )

    ensure_started()

    cond do
      Keyword.get(opts, :list, false) ->
        list_runs(opts)

      Keyword.get(opts, :compare, false) ->
        compare_runs(positional, opts)

      true ->
        run_eval(opts)
    end
  end

  # --- Run eval ---

  defp run_eval(opts) do
    domain = Keyword.get(opts, :domain, "coding")
    provider = Keyword.get(opts, :provider, "ollama")
    timeout = Keyword.get(opts, :timeout, 60_000)
    use_stream = Keyword.get(opts, :stream, false)
    limit = Keyword.get(opts, :limit)

    models =
      case Keyword.get(opts, :models) do
        nil ->
          case Keyword.get(opts, :model) do
            nil ->
              Mix.shell().error("Error: --model or --models required")
              System.halt(1)

            model ->
              [model]
          end

        models_str ->
          String.split(models_str, ",", trim: true) |> Enum.map(&String.trim/1)
      end

    dataset = Keyword.get(opts, :dataset, Map.get(@domain_datasets, domain))

    unless dataset do
      Mix.shell().error("Error: no default dataset for domain '#{domain}'. Use --dataset.")
      System.halt(1)
    end

    graders = Map.get(@domain_graders, domain, ["contains"])

    Mix.shell().info("\nArbor Eval — #{domain}")
    Mix.shell().info("Models: #{Enum.join(models, ", ")}")
    Mix.shell().info("Provider: #{provider}")
    Mix.shell().info("Dataset: #{dataset}")
    Mix.shell().info("Graders: #{Enum.join(graders, ", ")}")
    Mix.shell().info(String.duplicate("─", 50))

    alias Arbor.Orchestrator.Eval
    alias Arbor.Orchestrator.Eval.{PersistenceBridge, RunStore}

    {:ok, samples} = Eval.load_dataset(dataset, if(limit, do: [limit: limit], else: []))
    Mix.shell().info("Loaded #{length(samples)} samples\n")

    for model <- models do
      Mix.shell().info("=== #{model} ===")

      subject_opts = [
        provider: provider,
        model: model,
        timeout: timeout,
        stream: use_stream
      ]

      run_id = PersistenceBridge.generate_run_id(model, domain)
      start_time = System.monotonic_time(:millisecond)

      # Create run record (status: running)
      PersistenceBridge.create_run(%{
        id: run_id,
        domain: domain,
        model: model,
        provider: provider,
        dataset: dataset,
        graders: graders,
        status: "running",
        config: %{timeout: timeout, stream: use_stream}
      })

      results = run_samples(samples, graders, subject_opts)

      duration_ms = System.monotonic_time(:millisecond) - start_time

      # Compute metrics
      compile_scores = extract_scores(results, "compile_check")
      func_scores = extract_scores(results, "functional_test")
      pass_count = Enum.count(results, & &1.passed)
      n = length(results)

      metrics = %{
        "accuracy" => if(n > 0, do: pass_count / n, else: 0),
        "full_pass_rate" => if(n > 0, do: pass_count / n, else: 0),
        "sample_count" => n
      }

      metrics =
        if compile_scores != [] do
          Map.put(
            metrics,
            "compile_accuracy",
            Enum.count(compile_scores, &(&1 == 1.0)) / n
          )
        else
          metrics
        end

      metrics =
        if func_scores != [] do
          Map.put(
            metrics,
            "functional_mean",
            Float.round(Enum.sum(func_scores) / n, 3)
          )
        else
          metrics
        end

      # Add timing metrics
      durations = Enum.map(results, & &1.duration_ms) |> Enum.filter(&(&1 > 0))

      timing =
        if durations != [] do
          sorted = Enum.sort(durations)
          avg = Float.round(Enum.sum(sorted) / length(sorted), 1)
          %{"avg_duration_ms" => avg}
        else
          %{}
        end

      metrics = Map.merge(metrics, timing)

      # Complete run
      PersistenceBridge.complete_run(run_id, metrics, n, duration_ms)

      # Persist individual results
      Enum.each(results, fn result ->
        PersistenceBridge.save_result(%{
          id: PersistenceBridge.generate_run_id(model, "result"),
          run_id: run_id,
          sample_id: result.id,
          input: encode_field(result.input),
          expected: encode_field(result.expected),
          actual: result.actual,
          passed: result.passed,
          scores: result.scores_map,
          duration_ms: result.duration_ms,
          ttft_ms: result.ttft_ms,
          tokens_generated: result.tokens_generated
        })
      end)

      # Also save to JSON RunStore for backwards compat
      run_data = %{
        model: model,
        provider: provider,
        dataset: dataset,
        graders: graders,
        metrics: metrics,
        sample_count: n,
        results: Enum.map(results, &Map.from_struct/1)
      }

      slug = model |> String.replace(~r/[:\/.]+/, "-")
      date = Date.utc_today() |> Date.to_iso8601()
      RunStore.save_run("#{slug}-#{date}", run_data)

      Mix.shell().info(
        "  TOTALS: pass=#{pass_count}/#{n} (#{Float.round(pass_count / max(n, 1) * 100, 1)}%)"
      )

      Mix.shell().info("  Saved as #{run_id}\n")
    end

    Mix.shell().info("Done!")
  end

  defp run_samples(samples, grader_names, subject_opts) do
    subject = Arbor.Orchestrator.Eval.Subjects.LocalLLM
    graders = Enum.map(grader_names, &Arbor.Orchestrator.Eval.grader/1) |> Enum.reject(&is_nil/1)

    Enum.map(samples, fn sample ->
      id = sample["id"]
      Mix.shell().info("  #{id}... ")

      input = sample["input"]
      expected = sample["expected"]

      {actual, timing} =
        case subject.run(input, subject_opts) do
          {:ok, %{text: text} = result} ->
            {text,
             %{
               duration_ms: result[:duration_ms] || 0,
               ttft_ms: result[:ttft_ms],
               tokens_generated: result[:tokens_generated]
             }}

          {:error, reason} ->
            Mix.shell().info("    ERROR: #{inspect(reason)}")
            {"", %{duration_ms: 0, ttft_ms: nil, tokens_generated: nil}}
        end

      scores =
        Enum.map(graders, fn grader_mod ->
          try do
            grader_mod.grade(actual, expected, subject_opts)
          rescue
            e -> %{score: 0.0, passed: false, detail: "crash: #{Exception.message(e)}"}
          end
        end)

      passed = Enum.all?(scores, & &1.passed)

      scores_map =
        Enum.zip(grader_names, scores)
        |> Map.new(fn {name, score} -> {name, Map.from_struct(score)} end)

      if actual != "" do
        score_strs =
          Enum.map(Enum.zip(grader_names, scores), fn {name, s} ->
            "#{name}=#{Float.round(s.score, 2)}"
          end)

        Mix.shell().info("    #{Enum.join(score_strs, ", ")}")
      end

      %{
        id: id,
        input: input,
        expected: expected,
        actual: actual,
        passed: passed,
        scores: scores,
        scores_map: scores_map,
        duration_ms: timing.duration_ms,
        ttft_ms: timing.ttft_ms,
        tokens_generated: timing.tokens_generated
      }
    end)
  end

  # --- List runs ---

  defp list_runs(opts) do
    alias Arbor.Orchestrator.Eval.PersistenceBridge

    filters =
      []
      |> maybe_filter(:domain, Keyword.get(opts, :domain))
      |> maybe_filter(:model, Keyword.get(opts, :model))
      |> maybe_filter(:provider, Keyword.get(opts, :provider))

    case PersistenceBridge.list_runs(filters) do
      {:ok, runs} when is_list(runs) ->
        if runs == [] do
          Mix.shell().info("No eval runs found.")
        else
          Mix.shell().info("\nEval Runs (#{length(runs)} total)")
          Mix.shell().info(String.duplicate("─", 80))

          Enum.each(runs, fn run ->
            id = run_field(run, :id)
            domain = run_field(run, :domain)
            model = run_field(run, :model)
            provider = run_field(run, :provider)
            status = run_field(run, :status)
            metrics = run_field(run, :metrics) || %{}
            accuracy = metrics["accuracy"] || metrics["full_pass_rate"] || 0

            Mix.shell().info(
              "  #{id}  #{domain}  #{model}@#{provider}  #{status}  acc=#{Float.round(accuracy * 1.0, 2)}"
            )
          end)
        end

      other ->
        Mix.shell().error("Error listing runs: #{inspect(other)}")
    end
  end

  # --- Compare runs ---

  defp compare_runs([id_a, id_b], _opts) do
    alias Arbor.Orchestrator.Eval.PersistenceBridge

    with {:ok, run_a} <- PersistenceBridge.get_run(id_a),
         {:ok, run_b} <- PersistenceBridge.get_run(id_b) do
      Mix.shell().info("\nComparing eval runs:")
      Mix.shell().info("  A: #{id_a}")
      Mix.shell().info("  B: #{id_b}")
      Mix.shell().info(String.duplicate("─", 50))

      metrics_a = run_field(run_a, :metrics) || %{}
      metrics_b = run_field(run_b, :metrics) || %{}

      all_keys = MapSet.union(MapSet.new(Map.keys(metrics_a)), MapSet.new(Map.keys(metrics_b)))

      Enum.each(Enum.sort(all_keys), fn key ->
        val_a = metrics_a[key]
        val_b = metrics_b[key]

        diff =
          if is_number(val_a) and is_number(val_b) do
            d = val_b - val_a
            sign = if d >= 0, do: "+", else: ""
            " (#{sign}#{Float.round(d * 1.0, 3)})"
          else
            ""
          end

        Mix.shell().info("  #{key}: #{inspect(val_a)} → #{inspect(val_b)}#{diff}")
      end)
    else
      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  defp compare_runs(_, _) do
    Mix.shell().error("Usage: mix arbor.eval --compare <run_id_a> <run_id_b>")
  end

  # --- Helpers ---

  defp ensure_started do
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:jason)

    # Try to start Ecto for persistence (optional)
    try do
      Application.ensure_all_started(:postgrex)
      Application.ensure_all_started(:ecto_sql)

      repo = Arbor.Persistence.Repo

      if Code.ensure_loaded?(repo) do
        apply(repo, :start_link, [[]])
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp maybe_filter(filters, _key, nil), do: filters
  defp maybe_filter(filters, key, value), do: [{key, value} | filters]

  defp run_field(run, key) when is_map(run) do
    Map.get(run, key) || Map.get(run, to_string(key))
  end

  defp extract_scores(results, grader_name) do
    Enum.flat_map(results, fn result ->
      case Map.get(result.scores_map, grader_name) do
        %{score: score} -> [score]
        %{"score" => score} -> [score]
        _ -> []
      end
    end)
  end

  defp encode_field(value) when is_binary(value), do: value
  defp encode_field(value) when is_map(value), do: Jason.encode!(value)
  defp encode_field(value) when is_list(value), do: Jason.encode!(value)
  defp encode_field(nil), do: nil
  defp encode_field(value), do: inspect(value)
end
