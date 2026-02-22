Application.ensure_all_started(:jason)
Application.ensure_all_started(:req)
Application.ensure_all_started(:req_llm)

task = """
You are analyzing the Arbor codebase — an Elixir umbrella project for AI agent orchestration.

Your task is comprehensive: Read through EVERY .ex file in these directories and their subdirectories:

1. apps/arbor_agent/lib/arbor/agent/ — the agent subsystem
2. apps/arbor_memory/lib/arbor/memory/ — the memory subsystem
3. apps/arbor_orchestrator/lib/arbor/orchestrator/ — the pipeline engine

For EACH file:
- Read it completely
- Note the module name, purpose, key public functions, and dependencies
- Track cross-module relationships

After reading everything, produce a comprehensive analysis covering:
- Complete module dependency graph (what depends on what)
- The agent lifecycle (creation → running → heartbeat → shutdown)
- How the memory system works (stores, persistence, recall, embeddings)
- How the orchestrator pipeline engine works (DOT parsing, handlers, execution)
- How the mind/body separation works in the agent
- Security integration points across all three subsystems
- Key design patterns (facades, runtime bridges, capability-based security)

Be thorough — read every single file. Do not skip any. Do not summarize from file listings alone.
You must use file_read on each file individually.

Working directory: /Users/azmaveth/code/trust-arbor/arbor
"""

model = "arcee-ai/trinity-large-preview:free"
max_turns = 200

run_agent = fn mode ->
  IO.puts("\n=== Running with context_management: #{mode} ===")
  start = System.monotonic_time(:second)

  result =
    Arbor.Agent.SimpleAgent.run(task,
      provider: :openrouter,
      model: model,
      max_turns: max_turns,
      working_dir: "/Users/azmaveth/code/trust-arbor/arbor",
      context_management: mode
    )

  elapsed = System.monotonic_time(:second) - start

  case result do
    {:ok, r} ->
      IO.puts("  Status: #{r.status}")
      IO.puts("  Turns: #{r.turns}")
      IO.puts("  Tool calls: #{length(r.tool_calls)}")
      IO.puts("  Elapsed: #{elapsed}s")

      file_reads =
        r.tool_calls
        |> Enum.filter(&(&1.name == "file_read"))
        |> Enum.map(&(&1.args["path"] || Map.get(&1.args, :path, "unknown")))

      IO.puts("  Unique files read: #{length(Enum.uniq(file_reads))}")
      IO.puts("  Total file reads: #{length(file_reads)}")

      repeated = file_reads |> Enum.frequencies() |> Enum.count(fn {_, c} -> c > 1 end)
      IO.puts("  Files read more than once: #{repeated}")

      total_result_chars =
        Enum.reduce(r.tool_calls, 0, fn tc, acc ->
          acc + String.length(tc.result || "")
        end)

      total_text_chars = String.length(r.text || "")
      est_tokens = div(total_result_chars + total_text_chars, 4)
      IO.puts("  Estimated total tokens: #{est_tokens}")

      if Map.has_key?(r, :context_stats) do
        stats = r.context_stats
        IO.puts("  Context stats:")
        IO.puts("    Token count: #{stats.token_count}")
        IO.puts("    Peak tokens: #{stats.peak_tokens}")
        IO.puts("    Effective window: #{stats.effective_window}")
        IO.puts("    Compressions: #{stats.compression_count}")
        IO.puts("    Squashes: #{stats.squash_count}")
        IO.puts("    File index size: #{stats.file_index_size}")
      end

      tool_usage =
        r.tool_calls
        |> Enum.map(& &1.name)
        |> Enum.frequencies()

      IO.puts("  Tool usage: #{inspect(tool_usage)}")

      # Save transcript
      transcript_data = %{
        task: task,
        model: Map.get(r, :model, model),
        status: r.status,
        turns: r.turns,
        context_management: mode,
        tool_call_count: length(r.tool_calls),
        tool_calls:
          Enum.map(r.tool_calls, fn tc ->
            %{
              turn: tc.turn,
              name: tc.name,
              args: tc.args,
              result: String.slice(tc.result || "", 0, 8000),
              duration_ms: tc.duration_ms
            }
          end),
        text: r.text,
        elapsed_seconds: elapsed,
        estimated_tokens: est_tokens,
        context_stats: Map.get(r, :context_stats)
      }

      path =
        Path.join([
          "/Users/azmaveth/code/trust-arbor/arbor/.arbor/evals",
          "phase2-#{mode}-#{System.os_time(:second)}.json"
        ])

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(transcript_data, pretty: true))
      IO.puts("  Transcript saved: #{path}")

      if r.text do
        IO.puts("\n--- Agent Summary (first 500 chars) ---")
        IO.puts(String.slice(r.text, 0, 500))
      end

      {mode, r}

    {:error, reason} ->
      IO.puts("  FAILED after #{elapsed}s: #{inspect(reason, limit: 200)}")
      {mode, {:error, reason}}
  end
end

# Run baseline first (no compaction — will overflow)
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Phase 2: Side-by-side comparison — none vs heuristic")
IO.puts(String.duplicate("=", 70))

{_, baseline} = run_agent.(:none)

# Run with heuristic compaction (should manage context)
{_, heuristic} = run_agent.(:heuristic)

# Summary comparison
IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("COMPARISON SUMMARY")
IO.puts(String.duplicate("=", 70))

format_result = fn
  {:error, _} -> "FAILED (error)"
  r ->
    "#{r.status} | #{r.turns} turns | #{length(r.tool_calls)} tool calls"
end

IO.puts("Baseline (none):      #{format_result.(baseline)}")
IO.puts("Heuristic:            #{format_result.(heuristic)}")
