Application.ensure_all_started(:jason)
Application.ensure_all_started(:req)
Application.ensure_all_started(:req_llm)

task = """
You are analyzing the Arbor codebase — an Elixir umbrella project for AI agent orchestration.

Your task: Read through all modules in apps/arbor_agent/lib/arbor/agent/ and build a complete understanding of the architecture. For each module:
1. Read the file
2. Note what it does, its key functions, and what it depends on
3. Track how modules relate to each other

Then read the key modules in apps/arbor_memory/lib/arbor/memory/ to understand the memory subsystem.

Finally, write a comprehensive architecture summary explaining:
- The agent lifecycle (creation → running → heartbeat → shutdown)
- How the memory system works (stores, persistence, recall)
- How the mind/body separation works
- Key design patterns used

Be thorough — read every file, do not skip any. This is for documentation purposes.

Working directory: /Users/azmaveth/code/trust-arbor/arbor
"""

IO.puts("[Phase 1] Starting SimpleAgent transcript generation...")

IO.puts(
  "[Phase 1] Model: arcee-ai/trinity-large-preview:free, max_turns: 50, context_management: :none"
)

start = System.monotonic_time(:second)

result =
  Arbor.Agent.SimpleAgent.run(task,
    provider: :openrouter,
    model: "arcee-ai/trinity-large-preview:free",
    max_turns: 50,
    working_dir: "/Users/azmaveth/code/trust-arbor/arbor",
    context_management: :none
  )

elapsed = System.monotonic_time(:second) - start

case result do
  {:ok, r} ->
    IO.puts("\n[Phase 1] COMPLETED in #{elapsed}s")
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

    other_tools =
      r.tool_calls
      |> Enum.map(& &1.name)
      |> Enum.frequencies()

    IO.puts("  Tool usage: #{inspect(other_tools)}")

    # Save full transcript
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
            result: String.slice(tc.result || "", 0, 2000),
            duration_ms: tc.duration_ms
          }
        end),
      text: r.text,
      elapsed_seconds: elapsed
    }

    path =
      Path.join([
        "/Users/azmaveth/code/trust-arbor/arbor/.arbor/evals",
        "phase1-transcript-#{System.os_time(:second)}.json"
      ])

    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(transcript_data, pretty: true))
    IO.puts("  Transcript saved: #{path}")

    if r.text do
      IO.puts("\n--- Agent Summary (first 800 chars) ---")
      IO.puts(String.slice(r.text, 0, 800))
    end

  {:error, reason} ->
    IO.puts("\n[Phase 1] FAILED after #{elapsed}s: #{inspect(reason)}")
end
