defmodule Arbor.Agent.Eval.SecurityReview.Runner do
  @moduledoc """
  Runs API-class reviewers over the L2-review corpus and records their raw
  findings — the producer half of the Security Sentinel L2-review eval (Phase 0).

  For every cell `reviewer × corpus-item × strategy × run` it builds the review
  unit(s), calls the model (via `Arbor.LLM.generate`, the same path L1 uses),
  parses the JSON findings with `Arbor.Actions.Security.DiffFindings`, and emits a
  result envelope. Scoring/judging against the corpus labels is the **next** piece;
  this runner only produces the raw findings.

  ## Strategies

    * `:a` (per-file) — one review call per file in the item. A cross-file bug is
      invisible here (each file is reviewed alone) — the discriminator.
    * `:b_lite` (whole-subsystem) — one review call with all the item's files
      concatenated, so cross-file issues are visible. (For single-file items :a and
      :b_lite are identical.)

  The LLM call is injected (`:llm`) so the loop is unit-tested without a model.

  ## Cost

  Defaults to local tier only (`[:local]`) and `k: 1`. Cloud reviewers are inert
  unless `:tiers` includes `:cloud`. Agentic (ACP) reviewers are a later increment.
  """

  alias Arbor.Actions.Security.DiffFindings
  alias Arbor.Agent.Eval.SecurityReview.{AnthropicLoop, Prompt, Reviewers, Tools}

  # LM Studio's Anthropic-compatible endpoint (no /v1 — AnthropicLoop appends
  # /v1/messages). The agentic strategy speaks Anthropic tool-format here because
  # local models emit Anthropic tool_use, which the OpenAI endpoint mangles.
  @default_agentic_base_url "http://localhost:1234"

  @default_output_dir ".arbor/evals"

  @type cell :: %{
          reviewer: String.t(),
          provider: atom(),
          model: String.t(),
          strategy: :a | :b_lite,
          run: pos_integer(),
          item_id: String.t(),
          item_category: String.t() | atom(),
          item_cross_file: boolean(),
          units: non_neg_integer(),
          findings: [map()],
          errors: [term()],
          elapsed_ms: non_neg_integer()
        }

  @doc """
  Run the eval. Reads the corpus from `corpus_dir` (its `manifest.json` + buggy
  snapshots), loops the cells, returns `{:ok, %{results: [cell], ...}}`.

  ## Options

    * `:tiers` — reviewer tiers to call (default `[:local]`)
    * `:reviewers` — explicit reviewer list (overrides tier filtering; tests use this)
    * `:strategies` — `[:a, :b_lite]` (default both)
    * `:k` — runs per cell, for variance (default `1`)
    * `:llm` — `(call_map -> {:ok, text} | {:error, reason})` (default `Arbor.LLM`)
    * `:output_dir` — where the results JSON is written (default `#{@default_output_dir}`)
    * `:write?` — write the results JSON (default `true`; tests pass `false`)
    * `:now` — timestamp string for the output filename (default derived)
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(corpus_dir, opts \\ []) do
    with {:ok, items} <- load_corpus(corpus_dir) do
      reviewers = opts[:reviewers] || Reviewers.by_tiers(opts[:tiers] || [:local])
      strategies = opts[:strategies] || [:a, :b_lite]
      k = opts[:k] || 1
      llm = opts[:llm] || (&default_llm/1)
      timeout = opts[:timeout] || 600_000
      max_rounds = opts[:max_rounds] || 8
      write? = Keyword.get(opts, :write?, true)
      output_dir = opts[:output_dir] || @default_output_dir
      stamp = opts[:now] || default_stamp()

      # Per-cell incremental JSONL: each cell is appended as it completes, so a long
      # run is observable and salvageable — a killed run is no longer total loss.
      cells_path = if write?, do: Path.join(output_dir, "security-review-cells-#{stamp}.jsonl")
      if cells_path, do: File.mkdir_p!(output_dir)

      results =
        for reviewer <- reviewers,
            item <- items,
            strategy <- strategies,
            run_i <- 1..k do
          cell = run_cell(reviewer, item, strategy, run_i, llm, timeout, max_rounds, corpus_dir)
          if cells_path, do: File.write!(cells_path, Jason.encode!(cell) <> "\n", [:append])
          cell
        end

      summary = %{
        corpus_dir: corpus_dir,
        reviewers: Enum.map(reviewers, & &1.id),
        strategies: strategies,
        k: k,
        cell_count: length(results),
        results: results
      }

      if write?, do: write_results(summary, Keyword.put(opts, :now, stamp))

      {:ok, summary}
    end
  end

  # ---------------------------------------------------------------------------
  # One cell
  # ---------------------------------------------------------------------------

  defp run_cell(reviewer, item, strategy, run_i, llm, timeout, max_rounds, corpus_dir) do
    start = System.monotonic_time(:millisecond)
    units = build_units(strategy, item, corpus_dir)

    {findings, errors} =
      Enum.reduce(units, {[], []}, fn unit, {fs, es} ->
        case review_unit(reviewer, unit, llm, timeout, max_rounds) do
          {:ok, found} -> {fs ++ found, es}
          {:error, reason} -> {fs, [%{unit: unit.label, reason: inspect(reason)} | es]}
        end
      end)

    %{
      reviewer: reviewer.id,
      provider: reviewer.provider,
      model: reviewer.model,
      strategy: strategy,
      run: run_i,
      item_id: item.id,
      item_category: item.category,
      item_cross_file: item.cross_file,
      units: length(units),
      findings: findings,
      errors: Enum.reverse(errors),
      elapsed_ms: System.monotonic_time(:millisecond) - start
    }
  end

  # :agentic — one unit that hands the model read-only navigation tools over the
  # item's buggy-snapshot dir (it reads on demand instead of being handed a dump).
  defp build_units(:agentic, item, corpus_dir) do
    [%{label: "agentic:#{item.id}", scope: Path.join([corpus_dir, item.id, "buggy"])}]
  end

  # :b_lite — all files concatenated into one unit.
  defp build_units(:b_lite, item, _corpus_dir) do
    code =
      item.files
      |> Enum.map_join("\n\n", fn %{path: p, code: c} -> "# ==== #{p} ====\n#{c}" end)

    [%{label: "#{length(item.files)} files", code: code}]
  end

  # :a — one unit per file.
  defp build_units(_a, item, _corpus_dir) do
    Enum.map(item.files, fn %{path: p, code: c} -> %{label: p, code: c} end)
  end

  # A unit carries either :scope (agentic — navigate with tools) or :code (dump).
  defp review_unit(reviewer, %{scope: scope} = unit, llm, timeout, max_rounds) do
    call = %{
      provider: reviewer.provider,
      model: reviewer.model,
      system: Prompt.agent_system(),
      user: Prompt.agent_user(),
      timeout: timeout,
      tools: Tools.for_scope(scope),
      max_tool_rounds: max_rounds
    }

    dispatch(call, unit, llm)
  end

  defp review_unit(reviewer, %{code: code} = unit, llm, timeout, _max_rounds) do
    call = %{
      provider: reviewer.provider,
      model: reviewer.model,
      system: Prompt.system(),
      user: Prompt.user(code, unit.label),
      timeout: timeout
    }

    dispatch(call, unit, llm)
  end

  # Rescue here (not just in default_llm) so ANY reviewer fn that raises — a bad
  # provider, an unloaded model, a transport blowup, a tool-loop error — becomes a
  # captured per-unit error rather than killing the whole run.
  defp dispatch(call, _unit, llm) do
    try do
      case llm.(call) do
        {:ok, text} when is_binary(text) -> {:ok, extract_findings(text)}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_llm_return, other}}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:caught, kind, reason}}
    end
  end

  # Reuse DiffFindings' fence-tolerant, closed-vocabulary parser; project each
  # Finding to the plain fields the scorer compares to the corpus label. (The L1
  # detector tag DiffFindings stamps is irrelevant here — the reviewer/strategy is
  # recorded in the cell envelope instead.)
  defp extract_findings(text) do
    text
    |> DiffFindings.parse(git_sha: nil)
    |> Enum.map(fn f ->
      %{
        category: f.category,
        title: f.title,
        file: get_in(f.location, [:file]) || f.location["file"],
        line: get_in(f.location, [:line]) || f.location["line"],
        severity: get_in(f.severity, [:level]) || f.severity["level"],
        rationale: f.invariant_violated
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Default LLM call (the real path)
  # ---------------------------------------------------------------------------

  @doc false
  def default_llm(%{tools: tools} = call) when is_list(tools) and tools != [] do
    # Agentic path: drive the Anthropic-format tool loop directly against LM Studio's
    # /v1/messages (the OpenAI endpoint mangles local models' Anthropic tool_use).
    AnthropicLoop.run(%{
      base_url: call[:base_url] || @default_agentic_base_url,
      model: call.model,
      system: call.system,
      user: call.user,
      tools: tools,
      max_rounds: call[:max_tool_rounds] || 8,
      receive_timeout: call[:timeout] || 600_000
    })
  end

  def default_llm(%{provider: provider, model: model, system: system, user: user} = call) do
    # Single-shot path. `timeout` is the PER-CALL HTTP receive timeout. build_request
    # never sets request.receive_timeout, so Req's low default (~120s) fires first and
    # every cold-autoloaded local model times out — push it up via req_http_options
    # (retry: false keeps the local-provider default that supplying it replaces).
    per_call = call[:timeout] || 600_000

    case Arbor.LLM.generate(
           provider: to_string(provider),
           model: model,
           system: system,
           prompt: user,
           temperature: 0.2,
           # Effectively uncapped (Anthropic path requires a value; 32k = modern-model max).
           max_tokens: 32_000,
           timeout: per_call,
           client_opts: [req_http_options: [receive_timeout: per_call, retry: false]]
         ) do
      {:ok, %{text: text}} -> {:ok, text}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Corpus loading
  # ---------------------------------------------------------------------------

  @doc """
  Load the corpus written by `Arbor.Agent.Eval.SecurityReview.Corpus`: read
  `manifest.json` and each item's buggy snapshots. Returns `{:ok, items}` where
  each item carries `files: [%{path, code}]`.
  """
  @spec load_corpus(String.t()) :: {:ok, [map()]} | {:error, term()}
  def load_corpus(corpus_dir) do
    manifest_path = Path.join(corpus_dir, "manifest.json")

    with {:ok, json} <- File.read(manifest_path),
         {:ok, entries} <- Jason.decode(json) do
      items =
        Enum.map(entries, fn e ->
          %{
            id: e["id"],
            category: e["category"],
            cross_file: e["cross_file"] || false,
            invariant: e["invariant"] || "",
            files: read_buggy_files(corpus_dir, e["id"], e["files"] || [])
          }
        end)

      {:ok, items}
    else
      {:error, reason} -> {:error, {:corpus_unreadable, reason}}
    end
  end

  defp read_buggy_files(corpus_dir, id, paths) do
    Enum.flat_map(paths, fn path ->
      case File.read(Path.join([corpus_dir, id, "buggy", path])) do
        {:ok, code} -> [%{path: path, code: code}]
        {:error, _} -> []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------------

  defp write_results(summary, opts) do
    dir = opts[:output_dir] || @default_output_dir
    File.mkdir_p!(dir)
    stamp = opts[:now] || default_stamp()
    path = Path.join(dir, "security-review-results-#{stamp}.json")
    File.write!(path, Jason.encode!(summary, pretty: true))
    path
  end

  defp default_stamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9T]/, "")
  end
end
