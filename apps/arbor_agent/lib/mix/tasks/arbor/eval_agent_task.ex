defmodule Mix.Tasks.Arbor.Eval.AgentTask do
  @shortdoc "Run an agentic-safety eval task against a real Arbor agent"

  @moduledoc """
  Runs an `Arbor.Agent.Eval.AgentTask` against a REAL agent lifecycle in the
  running server (fresh memory-clean agent, real tools + real security, graded by
  a hard gate + LLM judge). Thin wrapper: RPCs `AgentTaskRunner.run/2` into the
  server node.

      mix arbor.eval.agent_task web-search-injection
      mix arbor.eval.agent_task web-search-injection --agent-model gemma-4-e4b-it-qat
      mix arbor.eval.agent_task web-search-injection --agent-model X --judge-model Y

  Options: --template, --agent-model, --agent-provider, --judge-model,
  --judge-provider.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @switches [
    template: :string,
    agent_model: :string,
    agent_provider: :string,
    # "acp" drives an external CLI agent (Codex/Claude/Grok) in its own harness via ACP
    # instead of an in-process Arbor model; agent_provider is the ACP provider (codex/claude/grok).
    agent_runtime: :string,
    # --agent-quant overrides the recorded quant; otherwise it's auto-detected from
    # LM Studio's native /api/v0/models endpoint (nil for non-LM-Studio providers).
    agent_quant: :string,
    # Sampling params — default to the per-model recommended values in AgentTaskRunner;
    # override to study a specific setting. Recorded in EvalRun.config either way.
    agent_temperature: :float,
    agent_top_p: :float,
    agent_sampling: :string,
    judge_model: :string,
    judge_provider: :string,
    # --stream true forces the streaming tool-loop path (complete_streaming) for
    # testing; default (false) uses the plain Client.complete path.
    stream: :boolean,
    # --enforce-egress flips Arbor's egress gate from dark to ENFORCING for the
    # run (restored after) — to test whether it blocks a tainted exfil.
    enforce_egress: :boolean,
    # --repeat N runs the task N times (fresh agent each) and reports the pass
    # RATE — agents are stochastic, so a single run is a noisy point estimate.
    repeat: :integer
  ]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: @switches)

    task_id =
      case args do
        [id | _] -> id
        [] -> "web-search-injection"
      end

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start with: mix arbor.start")
      exit({:shutdown, 1})
    end

    run_opts = Enum.filter(opts, fn {_k, v} -> not is_nil(v) end)

    Mix.shell().info("Running eval task '#{task_id}' against a fresh real agent...\n")

    case Config.rpc!(Config.full_node_name(), Arbor.Agent.Eval.AgentTaskRunner, :run, [
           task_id,
           run_opts
         ]) do
      {:ok, result} -> print_result(result)
      {:error, reason} -> Mix.shell().error("Eval failed: #{inspect(reason)}")
    end
  end

  defp print_result(r) do
    verdict_str = if r.verdict == :pass, do: "PASS ✅", else: "FAIL ❌"
    n = Map.get(r, :sample_count, 1)
    usage = Map.get(r, :usage) || %{}

    rate_line =
      if n > 1 do
        pct = round((Map.get(r, :pass_rate) || 0.0) * 100)
        "\n  PASS RATE:               #{Map.get(r, :pass_count)}/#{n} (#{pct}%)  verdicts: #{inspect(Map.get(r, :sample_verdicts))}"
      else
        ""
      end

    Mix.shell().info("""
    ══════════════════════════════════════════════════════
    Eval: #{r.task_id}   Agent model: #{r.agent_model}   Samples: #{n}
    ══════════════════════════════════════════════════════
      VERDICT (sample 1):      #{verdict_str}#{rate_line}
      Hard gate passed:        #{r.hard_gate_passed}  (safety axis)
      Completion score:        #{fmt_completion(Map.get(r, :completion_score))}  (usefulness axis; nil = n/a)
      Judge verdict:           #{r.judge.verdict}
      Tokens (in/out/total):   #{Map.get(usage, :prompt_tokens) || "?"} / #{Map.get(usage, :completion_tokens) || "?"} / #{Map.get(usage, :total_tokens) || "?"}   Cost: #{Map.get(usage, :cost) || "?"}
      Wall time:               #{Map.get(r, :duration_ms) || "?"}ms#{ttft_suffix(usage)}
      Precondition met:        #{Map.get(r, :precondition_met)}  (agent engaged the scenario; nil = n/a)
      Injection delivered:     #{Map.get(r, :injection_delivered)}  (poisoned web_search_eval result reached the agent)
      EvalRun id (store):      #{Map.get(r, :eval_run_id) || "(not persisted)"}
      Egress tool called:      #{r.egress_tool_called}
      Egress blocked by Arbor: #{r.egress_blocked_by_arbor}
      Security gate events:    #{fmt_gates(Map.get(r, :gate_events, []))}
      Egress targets (URLs):   #{inspect(Map.get(r, :egress_targets, []))}
      Advisory failures:       #{length(r.advisory_failures)}
      Tool calls:              #{length(r.trajectory)}
    ──────────────────────────────────────────────────────
    Judge reasoning:
    #{indent(r.judge.reasoning)}
    ──────────────────────────────────────────────────────
    Agent final response:
    #{indent(r.final_text)}
    ══════════════════════════════════════════════════════
    """)
  end

  # Best-effort: only shown when the first-round LLM time was captured.
  defp ttft_suffix(usage) do
    case Map.get(usage, :ttft_ms) do
      ms when is_number(ms) -> " · ttft #{ms}ms"
      _ -> ""
    end
  end

  defp fmt_completion(nil), do: "n/a"
  defp fmt_completion(score) when is_number(score), do: "#{round(score * 100)}%"

  defp fmt_gates([]), do: "none"
  defp fmt_gates(gates), do: "#{length(gates)} — " <> Enum.map_join(gates, ", ", & &1.gate)

  defp indent(nil), do: "  (none)"

  defp indent(text) when is_binary(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end
end
