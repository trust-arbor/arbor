# Phase 2: Compaction strategy evaluation
#
# Replays the Phase 1 transcript through ContextCompactor with
# different effective window sizes to measure information retention.

IO.puts("[Phase 2] Compaction Strategy Evaluation")
IO.puts("")

# Find the most recent Phase 1 transcript
evals_dir = Path.join([File.cwd!(), ".arbor", "evals"])

transcript_path =
  evals_dir
  |> File.ls!()
  |> Enum.filter(&String.starts_with?(&1, "phase1-transcript-"))
  |> Enum.sort(:desc)
  |> List.first()

unless transcript_path do
  IO.puts("ERROR: No Phase 1 transcript found in #{evals_dir}")
  IO.puts("Run scripts/phase1_transcript.exs first.")
  System.halt(1)
end

full_path = Path.join(evals_dir, transcript_path)
IO.puts("Transcript: #{transcript_path}")

case Arbor.Agent.Eval.CompactionEval.run(
       transcript_path: full_path,
       effective_windows: [2000, 3000, 5000, 8000],
       strategies: [:none, :heuristic],
       checkpoints: [0.25, 0.50, 0.75, 1.0]
     ) do
  {:ok, eval_result} ->
    IO.puts("\n[Phase 2] COMPLETED")
    IO.puts("  Strategies tested: #{length(eval_result.results)}")

    # Save results
    result_path =
      Path.join(evals_dir, "phase2-compaction-eval-#{System.os_time(:second)}.json")

    serializable = %{
      transcript: transcript_path,
      ground_truth: %{
        files: eval_result.ground_truth.all_paths,
        modules: eval_result.ground_truth.all_modules,
        total_tool_calls: eval_result.ground_truth.total_tool_calls,
        key_facts_count: length(eval_result.ground_truth.key_facts)
      },
      results:
        Enum.map(eval_result.results, fn r ->
          %{
            label: r.label,
            strategy: r.strategy,
            effective_window: r.effective_window,
            message_count: r.message_count,
            final_stats: r.final_stats,
            checkpoints:
              Map.new(r.checkpoints, fn {pct, m} ->
                {"#{trunc(pct * 100)}%", m}
              end)
          }
        end),
      summary: eval_result.summary
    }

    File.write!(result_path, Jason.encode!(serializable, pretty: true))
    IO.puts("  Results saved: #{result_path}")

  {:error, reason} ->
    IO.puts("\n[Phase 2] FAILED: #{inspect(reason)}")
end
