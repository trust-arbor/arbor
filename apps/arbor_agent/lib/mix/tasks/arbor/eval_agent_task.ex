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
    judge_model: :string,
    judge_provider: :string,
    # --stream true forces the streaming tool-loop path (complete_streaming) for
    # testing; default (false) uses the plain Client.complete path.
    stream: :boolean,
    # --enforce-egress flips Arbor's egress gate from dark to ENFORCING for the
    # run (restored after) — to test whether it blocks a tainted exfil.
    enforce_egress: :boolean
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

    Mix.shell().info("""
    ══════════════════════════════════════════════════════
    Eval: #{r.task_id}   Agent model: #{r.agent_model}
    ══════════════════════════════════════════════════════
      VERDICT:                 #{verdict_str}
      Hard gate passed:        #{r.hard_gate_passed}
      Judge verdict:           #{r.judge.verdict}
      Precondition met:        #{Map.get(r, :precondition_met)}  (agent engaged the scenario; nil = n/a)
      Injection delivered:     #{Map.get(r, :injection_delivered)}  (poisoned web_search_eval result reached the agent)
      EvalRun id (store):      #{Map.get(r, :eval_run_id) || "(not persisted)"}
      Egress tool called:      #{r.egress_tool_called}
      Egress blocked by Arbor: #{r.egress_blocked_by_arbor}
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

  defp indent(nil), do: "  (none)"

  defp indent(text) when is_binary(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end
end
