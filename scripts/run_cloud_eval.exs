#!/usr/bin/env elixir
# Run coding eval against Ollama cloud models
# Usage: mix run --no-start scripts/run_cloud_eval.exs

# Start only what we need (no gateway/web servers)
Application.ensure_all_started(:req)
Application.ensure_all_started(:jason)

alias Arbor.Orchestrator.Eval
alias Arbor.Orchestrator.Eval.Subjects.LocalLLM
alias Arbor.Orchestrator.Eval.RunStore

{:ok, samples} = Eval.load_dataset("apps/arbor_orchestrator/priv/eval_datasets/elixir_coding.jsonl")

models = [
  {"glm-5:cloud", "ollama"},
  {"minimax-m2.5:cloud", "ollama"},
  {"kimi-k2.5:cloud", "ollama"},
  {"deepseek-v3.2:cloud", "ollama"}
]

for {model, provider} <- models do
  IO.puts("\n=== #{model} ===")
  opts = [provider: provider, model: model]

  results =
    for sample <- samples do
      id = sample["id"]
      IO.write("  #{id}... ")

      case LocalLLM.run(sample["input"], opts) do
        {:ok, %{text: text}} ->
          c = Eval.grader("compile_check").grade(text, sample["expected"])

          # Run functional test in isolated process
          parent = self()

          {_pid, ref} =
            spawn_monitor(fn ->
              Process.flag(:trap_exit, true)

              result =
                try do
                  Eval.grader("functional_test").grade(text, sample["expected"])
                rescue
                  e -> %{score: 0.0, passed: false, detail: "crash: #{Exception.message(e)}"}
                catch
                  :exit, reason ->
                    %{score: 0.0, passed: false, detail: "exit: #{inspect(reason)}"}
                end

              send(parent, {:func_result, result})
            end)

          func =
            receive do
              {:func_result, r} ->
                Process.demonitor(ref, [:flush])
                r

              {:DOWN, ^ref, :process, _, reason} ->
                %{score: 0.0, passed: false, detail: "down: #{inspect(reason)}"}
            after
              20_000 ->
                Process.demonitor(ref, [:flush])
                %{score: 0.0, passed: false, detail: "timeout"}
            end

          IO.puts("compile=#{c.score}, func=#{Float.round(func.score, 2)}")

          %{
            "id" => id,
            "compile" => c.score,
            "functional" => Float.round(func.score, 2),
            "passed" => c.score == 1.0 and func.score == 1.0
          }

        {:error, reason} ->
          IO.puts("ERROR: #{inspect(reason)}")
          %{"id" => id, "compile" => 0.0, "functional" => 0.0, "passed" => false}
      end
    end

  # Compute metrics
  compile_scores = Enum.map(results, & &1["compile"])
  func_scores = Enum.map(results, & &1["functional"])
  pass_count = Enum.count(results, & &1["passed"])
  n = length(results)

  metrics = %{
    "compile_accuracy" => Enum.count(compile_scores, &(&1 == 1.0)) / n,
    "compile_mean" => Enum.sum(compile_scores) / n,
    "functional_mean" => Float.round(Enum.sum(func_scores) / n, 3),
    "full_pass_rate" => pass_count / n,
    "accuracy" => pass_count / n
  }

  IO.puts("  TOTALS: compile=#{metrics["compile_accuracy"]}, func_mean=#{metrics["functional_mean"]}, pass=#{metrics["full_pass_rate"]}")

  # Save run
  slug = model |> String.replace(":", "-") |> String.replace("/", "-")
  run_id = "#{slug}-2026-02-13"

  RunStore.save_run(run_id, %{
    model: model,
    provider: provider,
    dataset: "elixir_coding.jsonl",
    graders: ["compile_check", "functional_test"],
    metrics: metrics,
    sample_count: n,
    results: results
  })

  IO.puts("  Saved as #{run_id}")
end

IO.puts("\nDone!")
