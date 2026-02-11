defmodule Mix.Tasks.Arbor.Pipeline.Benchmark do
  @shortdoc "Benchmark orchestrator overhead vs direct execution"
  @moduledoc """
  Measures the overhead of running commands through the orchestrator pipeline
  engine versus executing them directly.

  ## Usage

      mix arbor.pipeline.benchmark
      mix arbor.pipeline.benchmark --iterations 20
      mix arbor.pipeline.benchmark --pipeline specs/pipelines/benchmark-overhead.dot
      mix arbor.pipeline.benchmark --real-commands

  ## Options

  - `--iterations` / `-n` — Number of iterations per benchmark (default: 10)
  - `--pipeline` / `-p` — Custom pipeline DOT file (default: benchmark-overhead.dot)
  - `--real-commands` — Use real commands (mix compile, mix test) instead of echo
  - `--no-checkpoint` — Disable checkpoint writes to isolate I/O overhead
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  alias Arbor.Orchestrator.Engine

  @default_pipeline "specs/pipelines/benchmark-overhead.dot"

  @impl true
  def run(args) do
    {opts, _files, _} =
      OptionParser.parse(args,
        strict: [
          iterations: :integer,
          pipeline: :string,
          real_commands: :boolean,
          no_checkpoint: :boolean
        ],
        aliases: [n: :iterations, p: :pipeline]
      )

    ensure_orchestrator_started()

    iterations = Keyword.get(opts, :iterations, 10)
    pipeline_path = Keyword.get(opts, :pipeline, @default_pipeline)
    real_commands = Keyword.get(opts, :real_commands, false)
    no_checkpoint = Keyword.get(opts, :no_checkpoint, false)

    info("")
    info("=== Arbor Orchestrator Overhead Benchmark ===")
    info("")

    if real_commands do
      run_real_benchmark(iterations, pipeline_path, no_checkpoint)
    else
      run_fast_benchmark(iterations, pipeline_path, no_checkpoint)
    end
  end

  # --- Fast benchmark: echo commands, measures raw engine overhead ---

  defp run_fast_benchmark(iterations, pipeline_path, no_checkpoint) do
    info("Mode: Fast commands (echo)")
    info("Iterations: #{iterations}")
    info("Checkpoint writes: #{if no_checkpoint, do: "disabled", else: "enabled"}")
    info("")

    # Define the equivalent direct commands
    commands = [
      {"echo", ["step_a_output"]},
      {"echo", ["step_b_output"]},
      {"echo", ["step_c_output"]}
    ]

    # Benchmark 1: Direct execution
    info("--- Direct Execution ---")
    direct_times = bench(iterations, fn -> run_direct(commands) end)
    print_stats("Direct", direct_times)

    # Benchmark 2: Orchestrator (parse included)
    info("--- Orchestrator (parse + execute) ---")
    source = File.read!(pipeline_path)

    orchestrator_times =
      bench(iterations, fn ->
        run_orchestrator(source, no_checkpoint)
      end)

    print_stats("Orchestrator (full)", orchestrator_times)

    # Benchmark 3: Orchestrator (pre-parsed graph)
    info("--- Orchestrator (pre-parsed, execute only) ---")
    {:ok, graph} = Arbor.Orchestrator.parse(source)

    orchestrator_preparsed_times =
      bench(iterations, fn ->
        run_orchestrator_preparsed(graph, no_checkpoint)
      end)

    print_stats("Orchestrator (pre-parsed)", orchestrator_preparsed_times)

    # Benchmark 4: Parse only
    info("--- Parse Only ---")
    parse_times = bench(iterations, fn -> Arbor.Orchestrator.parse(source) end)
    print_stats("Parse only", parse_times)

    # Summary
    info("")
    info("=== Summary ===")
    direct_mean = mean(direct_times)
    orch_mean = mean(orchestrator_times)
    preparsed_mean = mean(orchestrator_preparsed_times)
    parse_mean = mean(parse_times)

    overhead_full = orch_mean - direct_mean
    overhead_engine = preparsed_mean - direct_mean

    info("Direct mean:           #{format_us(direct_mean)}")
    info("Orchestrator mean:     #{format_us(orch_mean)}")
    info("  Parse overhead:      #{format_us(parse_mean)} (#{format_pct(parse_mean, orch_mean)})")

    info(
      "  Engine overhead:     #{format_us(overhead_engine)} (#{format_pct(overhead_engine, orch_mean)})"
    )

    info(
      "  Command execution:   #{format_us(direct_mean)} (#{format_pct(direct_mean, orch_mean)})"
    )

    info(
      "Total overhead:        #{format_us(overhead_full)} (#{format_x(orch_mean / max(direct_mean, 1))}x slower)"
    )

    info("")
  end

  # --- Real benchmark: actual mix commands ---

  defp run_real_benchmark(iterations, _pipeline_path, no_checkpoint) do
    info("Mode: Real commands (mix test on arbor_orchestrator)")
    info("Iterations: #{iterations}")
    info("")

    # Single real command: run orchestrator's own tests
    test_cmd = {"mix", ["test", "--no-color"]}

    info("--- Direct: mix test ---")

    direct_times =
      bench(iterations, fn ->
        {_output, 0} = System.cmd(elem(test_cmd, 0), elem(test_cmd, 1), stderr_to_stdout: true)
        :ok
      end)

    print_stats("Direct mix test", direct_times)

    # Create a minimal pipeline for the real command
    real_source = """
    digraph RealBench {
      graph [goal="Benchmark real command"]
      start [shape=Mdiamond]
      run_test [type="tool", tool_command="mix test --no-color", max_retries="1"]
      done [shape=Msquare]
      start -> run_test -> done
    }
    """

    info("--- Orchestrator: mix test via pipeline ---")
    {:ok, graph} = Arbor.Orchestrator.parse(real_source)

    orch_times =
      bench(iterations, fn ->
        run_orchestrator_preparsed(graph, no_checkpoint)
      end)

    print_stats("Orchestrator mix test", orch_times)

    # Summary
    info("")
    info("=== Summary ===")
    direct_mean = mean(direct_times)
    orch_mean = mean(orch_times)
    overhead = orch_mean - direct_mean

    info("Direct mean:       #{format_ms(direct_mean)}")
    info("Orchestrator mean: #{format_ms(orch_mean)}")

    info(
      "Overhead:          #{format_ms(overhead)} (#{format_x(orch_mean / max(direct_mean, 1))}x)"
    )

    info("")
  end

  # --- Runners ---

  defp run_direct(commands) do
    Enum.each(commands, fn {cmd, args} ->
      System.cmd(cmd, args, stderr_to_stdout: true)
    end)
  end

  defp run_orchestrator(source, no_checkpoint) do
    {:ok, graph} = Arbor.Orchestrator.parse(source)
    run_orchestrator_preparsed(graph, no_checkpoint)
  end

  defp run_orchestrator_preparsed(graph, no_checkpoint) do
    logs_root =
      if no_checkpoint do
        nil
      else
        tmp = Path.join(System.tmp_dir!(), "arbor_bench_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        tmp
      end

    opts =
      if logs_root do
        [logs_root: logs_root, max_steps: 50]
      else
        [logs_root: Path.join(System.tmp_dir!(), "arbor_bench_noop"), max_steps: 50]
      end

    {:ok, _result} = Engine.run(graph, opts)

    # Clean up
    if logs_root, do: File.rm_rf(logs_root)
  end

  # --- Measurement ---

  defp bench(iterations, fun) do
    # Warmup
    fun.()

    Enum.map(1..iterations, fn _i ->
      {time_us, _result} = :timer.tc(fun)
      time_us
    end)
  end

  defp mean(times) do
    Enum.sum(times) / max(length(times), 1)
  end

  defp median(times) do
    sorted = Enum.sort(times)
    len = length(sorted)

    if rem(len, 2) == 0 do
      (Enum.at(sorted, div(len, 2) - 1) + Enum.at(sorted, div(len, 2))) / 2
    else
      Enum.at(sorted, div(len, 2))
    end
  end

  defp percentile(times, p) do
    sorted = Enum.sort(times)
    k = p / 100.0 * (length(sorted) - 1)
    f = floor(k)
    c = ceil(k)

    if f == c do
      Enum.at(sorted, f)
    else
      lower = Enum.at(sorted, f)
      upper = Enum.at(sorted, c)
      lower + (upper - lower) * (k - f)
    end
  end

  defp print_stats(label, times) do
    info("  #{label}:")
    info("    mean:   #{format_us(mean(times))}")
    info("    median: #{format_us(median(times))}")
    info("    min:    #{format_us(Enum.min(times))}")
    info("    max:    #{format_us(Enum.max(times))}")
    info("    p95:    #{format_us(percentile(times, 95))}")
    info("")
  end

  defp format_us(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 2)}s"
  defp format_us(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 2)}ms"
  defp format_us(us), do: "#{round(us)}us"

  defp format_ms(us), do: "#{Float.round(us / 1_000, 1)}ms"

  defp format_pct(part, total) when total > 0,
    do: "#{Float.round(part / total * 100, 1)}%"

  defp format_pct(_, _), do: "0%"

  defp format_x(ratio), do: "#{Float.round(ratio, 2)}"
end
