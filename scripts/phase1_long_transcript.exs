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

IO.puts("[Phase 1 Extended] Starting long-running SimpleAgent transcript generation...")
IO.puts("[Phase 1 Extended] Model: arcee-ai/trinity-large-preview:free")
IO.puts("[Phase 1 Extended] Max turns: 200, context_management: :none")
IO.puts("[Phase 1 Extended] Target: fill context window naturally to 50%+")

start = System.monotonic_time(:second)

result =
  Arbor.Agent.SimpleAgent.run(task,
    provider: :openrouter,
    model: "arcee-ai/trinity-large-preview:free",
    max_turns: 200,
    working_dir: "/Users/azmaveth/code/trust-arbor/arbor",
    context_management: :none
  )

elapsed = System.monotonic_time(:second) - start

case result do
  {:ok, r} ->
    IO.puts("\n[Phase 1 Extended] COMPLETED in #{elapsed}s")
    IO.puts("  Status: #{r.status}")
    IO.puts("  Turns: #{r.turns}")
    IO.puts("  Tool calls: #{length(r.tool_calls)}")

    file_reads =
      r.tool_calls
      |> Enum.filter(&(&1.name == "file_read"))
      |> Enum.map(&(&1.args["path"] || Map.get(&1.args, :path, "unknown")))

    IO.puts("  Unique files read: #{length(Enum.uniq(file_reads))}")
    IO.puts("  Total file reads: #{length(file_reads)}")

    repeated = file_reads |> Enum.frequencies() |> Enum.count(fn {_, c} -> c > 1 end)
    IO.puts("  Files read more than once: #{repeated}")

    # Estimate total tokens
    total_result_chars =
      Enum.reduce(r.tool_calls, 0, fn tc, acc ->
        acc + String.length(tc.result || "")
      end)

    total_text_chars = String.length(r.text || "")
    est_tokens = div(total_result_chars + total_text_chars, 4)
    IO.puts("  Estimated total tokens: #{est_tokens}")
    IO.puts("  Context fill (vs 75k effective): #{Float.round(est_tokens / 75_000 * 100, 1)}%")

    other_tools =
      r.tool_calls
      |> Enum.map(& &1.name)
      |> Enum.frequencies()

    IO.puts("  Tool usage: #{inspect(other_tools)}")

    # Save full transcript — keep MORE of the result (8000 chars instead of 2000)
    transcript_data = %{
      task: task,
      model: r.model,
      status: r.status,
      turns: r.turns,
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
      estimated_tokens: est_tokens
    }

    path =
      Path.join([
        "/Users/azmaveth/code/trust-arbor/arbor/.arbor/evals",
        "phase1-long-transcript-#{System.os_time(:second)}.json"
      ])

    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(transcript_data, pretty: true))
    IO.puts("  Transcript saved: #{path}")

    if r.text do
      IO.puts("\n--- Agent Summary (first 1200 chars) ---")
      IO.puts(String.slice(r.text, 0, 1200))
    end

  {:error, reason} ->
    IO.puts("\n[Phase 1 Extended] FAILED after #{elapsed}s: #{inspect(reason)}")
end
