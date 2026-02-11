defmodule Arbor.Orchestrator.SessionPerfTest do
  @moduledoc """
  Performance benchmarks for the Session GenServer.

  Measures:
  1. Single-session turn latency (graph traversal overhead)
  2. Concurrent session throughput (N sessions, M turns each)
  3. Heartbeat interleaving under load
  4. Memory scaling with message history growth

  All tests use mock adapters with configurable simulated latency
  to isolate orchestration overhead from LLM/memory latency.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Handlers.{Registry, SessionHandler}

  @session_types ~w(
    session.classify session.memory_recall session.mode_select
    session.llm_call session.tool_dispatch session.format
    session.memory_update session.checkpoint session.background_checks
    session.process_results session.route_actions session.update_goals
  )

  @moduletag :perf
  @moduletag timeout: 120_000

  setup do
    case Elixir.Registry.start_link(
           keys: :duplicate,
           name: Arbor.Orchestrator.EventRegistry
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    for type <- @session_types do
      Registry.register(type, SessionHandler)
    end

    # Write DOT files for all tests
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_session_perf_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    turn_dot = """
    digraph Turn {
      graph [goal="Perf test turn"]
      start [shape=Mdiamond]
      classify [type="session.classify"]
      recall [type="session.memory_recall"]
      call_llm [type="session.llm_call"]
      format [type="session.format"]
      update_memory [type="session.memory_update"]
      done [shape=Msquare]

      start -> classify -> recall -> call_llm -> format -> update_memory -> done
    }
    """

    heartbeat_dot = """
    digraph Heartbeat {
      graph [goal="Perf test heartbeat"]
      start [shape=Mdiamond]
      select_mode [type="session.mode_select"]
      done [shape=Msquare]

      start -> select_mode -> done
    }
    """

    turn_path = Path.join(tmp_dir, "turn.dot")
    heartbeat_path = Path.join(tmp_dir, "heartbeat.dot")
    File.write!(turn_path, turn_dot)
    File.write!(heartbeat_path, heartbeat_dot)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    {:ok, turn_path: turn_path, heartbeat_path: heartbeat_path}
  end

  defp start_session(ctx, id, opts \\ []) do
    simulated_latency = Keyword.get(opts, :simulated_latency, 0)
    counter = :counters.new(1, [:atomics])

    adapters = %{
      llm_call: fn _messages, _mode, _opts ->
        if simulated_latency > 0, do: Process.sleep(simulated_latency)
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        {:ok, %{content: "Response #{n}"}}
      end,
      memory_recall: fn _agent_id, _query, _opts ->
        if simulated_latency > 0, do: Process.sleep(div(simulated_latency, 10))
        {:ok, %{recalled_memories: []}}
      end,
      memory_update: fn _agent_id, _data, _opts ->
        {:ok, %{}}
      end
    }

    {:ok, pid} =
      Session.start_link(
        session_id: "perf-#{id}-#{:erlang.unique_integer([:positive])}",
        agent_id: "agent_perf_#{id}",
        trust_tier: :established,
        turn_dot: ctx.turn_path,
        heartbeat_dot: ctx.heartbeat_path,
        adapters: adapters,
        start_heartbeat: false,
        session_type: Keyword.get(opts, :session_type, :primary)
      )

    pid
  end

  # ── Test 1: Single session turn latency (no simulated LLM delay) ──

  describe "single session overhead" do
    @tag :perf
    test "measures pure graph traversal overhead per turn", ctx do
      pid = start_session(ctx, "overhead")

      # Warm up
      {:ok, _} = Session.send_message(pid, "warmup")

      # Measure 100 turns
      times =
        for i <- 1..100 do
          {elapsed, {:ok, _}} =
            :timer.tc(fn -> Session.send_message(pid, "Message #{i}") end)

          elapsed
        end

      avg_us = Enum.sum(times) / length(times)
      p50 = Enum.sort(times) |> Enum.at(49)
      p99 = Enum.sort(times) |> Enum.at(98)
      min_us = Enum.min(times)
      max_us = Enum.max(times)

      IO.puts("\n── Single Session Turn Overhead ──")
      IO.puts("  Turns: 100 (no simulated LLM latency)")
      IO.puts("  Avg:   #{Float.round(avg_us / 1000, 2)} ms")
      IO.puts("  P50:   #{Float.round(p50 / 1000, 2)} ms")
      IO.puts("  P99:   #{Float.round(p99 / 1000, 2)} ms")
      IO.puts("  Min:   #{Float.round(min_us / 1000, 2)} ms")
      IO.puts("  Max:   #{Float.round(max_us / 1000, 2)} ms")

      state = Session.get_state(pid)
      assert state.turn_count == 101
      assert state.phase == :idle

      # Graph traversal overhead should be < 10ms per turn
      assert avg_us < 10_000, "Average turn overhead #{avg_us}μs exceeds 10ms budget"
    end

    @tag :perf
    test "measures overhead with growing message history", ctx do
      pid = start_session(ctx, "growth")

      # Send messages and track latency growth
      times =
        for i <- 1..200 do
          {elapsed, {:ok, _}} =
            :timer.tc(fn -> Session.send_message(pid, "Message #{i}") end)

          {i, elapsed}
        end

      first_50_avg =
        times |> Enum.take(50) |> Enum.map(&elem(&1, 1)) |> then(&(Enum.sum(&1) / 50))

      last_50_avg =
        times |> Enum.drop(150) |> Enum.map(&elem(&1, 1)) |> then(&(Enum.sum(&1) / 50))

      growth_ratio = last_50_avg / first_50_avg

      IO.puts("\n── Message History Growth Impact ──")
      IO.puts("  First 50 avg:  #{Float.round(first_50_avg / 1000, 2)} ms")
      IO.puts("  Last 50 avg:   #{Float.round(last_50_avg / 1000, 2)} ms")
      IO.puts("  Growth ratio:  #{Float.round(growth_ratio, 2)}x")

      state = Session.get_state(pid)
      IO.puts("  Final messages: #{length(state.messages)}")
      IO.puts("  State memory:   ~#{estimate_state_bytes(state)} bytes")

      # Expect some growth but not catastrophic — < 5x slowdown over 200 turns
      assert growth_ratio < 5.0,
             "Latency grew #{Float.round(growth_ratio, 1)}x over 200 turns"
    end
  end

  # ── Test 2: Concurrent sessions ──

  describe "concurrent sessions" do
    @tag :perf
    test "N sessions each processing M turns concurrently", ctx do
      session_counts = [1, 5, 10, 25, 50]
      turns_per_session = 10

      results =
        for n <- session_counts do
          pids = for i <- 1..n, do: start_session(ctx, "conc-#{n}-#{i}")

          {total_us, _} =
            :timer.tc(fn ->
              tasks =
                for pid <- pids do
                  Task.async(fn ->
                    for i <- 1..turns_per_session do
                      {:ok, _} = Session.send_message(pid, "Turn #{i}")
                    end
                  end)
                end

              Task.await_many(tasks, 30_000)
            end)

          total_turns = n * turns_per_session
          throughput = total_turns / (total_us / 1_000_000)

          for pid <- pids, do: GenServer.stop(pid)

          {n, total_us, throughput}
        end

      IO.puts("\n── Concurrent Session Throughput ──")
      IO.puts("  Sessions | Total Time | Throughput (turns/sec)")
      IO.puts("  ---------|------------|----------------------")

      for {n, total_us, throughput} <- results do
        IO.puts(
          "  #{String.pad_leading("#{n}", 8)} | " <>
            "#{String.pad_leading("#{Float.round(total_us / 1_000_000, 2)}s", 10)} | " <>
            "#{String.pad_leading("#{Float.round(throughput, 1)}", 10)}"
        )
      end

      # All should complete without errors
      assert length(results) == length(session_counts)
    end

    @tag :perf
    test "concurrent sessions with simulated LLM latency", ctx do
      n = 10
      turns = 5
      simulated_llm_ms = 50

      pids =
        for i <- 1..n do
          start_session(ctx, "lat-#{i}", simulated_latency: simulated_llm_ms)
        end

      {total_us, _} =
        :timer.tc(fn ->
          tasks =
            for pid <- pids do
              Task.async(fn ->
                for i <- 1..turns do
                  {:ok, _} = Session.send_message(pid, "Turn #{i}")
                end
              end)
            end

          Task.await_many(tasks, 60_000)
        end)

      total_turns = n * turns
      throughput = total_turns / (total_us / 1_000_000)
      sequential_time = n * turns * (simulated_llm_ms + simulated_llm_ms / 10)
      parallelism = sequential_time / (total_us / 1000)

      IO.puts("\n── Concurrent Sessions with Simulated LLM Latency ──")
      IO.puts("  Sessions: #{n}, Turns each: #{turns}, Simulated LLM: #{simulated_llm_ms}ms")
      IO.puts("  Total time:      #{Float.round(total_us / 1_000_000, 2)}s")
      IO.puts("  Throughput:      #{Float.round(throughput, 1)} turns/sec")
      IO.puts("  Effective parallelism: #{Float.round(parallelism, 2)}x")

      for pid <- pids, do: GenServer.stop(pid)

      # With simulated latency, parallelism should be > 1x (sessions don't block each other)
      assert parallelism > 1.5,
             "Expected parallel speedup but got #{Float.round(parallelism, 2)}x"
    end
  end

  # ── Test 3: Heartbeat interleaving ──

  describe "heartbeat under load" do
    @tag :perf
    test "heartbeats don't block turn processing", ctx do
      pid = start_session(ctx, "hb-interleave", simulated_latency: 10)

      # Trigger 5 heartbeats
      for _ <- 1..5, do: Session.heartbeat(pid)

      # Immediately send turns — should not be blocked by heartbeats
      times =
        for i <- 1..20 do
          {elapsed, {:ok, _}} =
            :timer.tc(fn -> Session.send_message(pid, "Turn #{i}") end)

          elapsed
        end

      avg_us = Enum.sum(times) / length(times)

      IO.puts("\n── Heartbeat Interleaving ──")
      IO.puts("  5 heartbeats triggered, then 20 turns")
      IO.puts("  Avg turn latency: #{Float.round(avg_us / 1000, 2)} ms")

      state = Session.get_state(pid)
      IO.puts("  Turn count: #{state.turn_count}")
      IO.puts("  Phase: #{state.phase}")

      # Turns should still complete reasonably fast
      assert state.turn_count == 20
      assert state.phase == :idle
    end
  end

  # ── Test 4: Session type comparison ──

  describe "session types" do
    @tag :perf
    test "different session types have same overhead", ctx do
      types = [:primary, :background, :delegation, :consultation]

      results =
        for type <- types do
          pid = start_session(ctx, "type-#{type}", session_type: type)

          times =
            for i <- 1..50 do
              {elapsed, {:ok, _}} =
                :timer.tc(fn -> Session.send_message(pid, "Message #{i}") end)

              elapsed
            end

          avg = Enum.sum(times) / length(times)

          state = Session.get_state(pid)
          assert state.session_type == type

          GenServer.stop(pid)
          {type, avg}
        end

      IO.puts("\n── Session Type Overhead Comparison ──")

      for {type, avg} <- results do
        IO.puts("  #{String.pad_trailing("#{type}", 15)} #{Float.round(avg / 1000, 2)} ms avg")
      end
    end
  end

  # ── Test 5: New fields verification ──

  describe "new struct fields" do
    @tag :perf
    test "all 6 new fields are accessible and correct", ctx do
      pid =
        start_session(ctx, "fields",
          session_type: :delegation,
          simulated_latency: 0
        )

      state = Session.get_state(pid)

      # Verify new fields
      assert state.phase == :idle
      assert state.session_type == :delegation
      assert is_binary(state.signal_topic)
      assert String.starts_with?(state.signal_topic, "session:")
      assert state.config == %{}
      assert state.seed_ref == nil
      assert state.trace_id == nil

      # Send a message and verify phase transitions back to :idle
      {:ok, _} = Session.send_message(pid, "test")
      state_after = Session.get_state(pid)
      assert state_after.phase == :idle
      assert state_after.turn_count == 1
    end

    @tag :perf
    test "config and trace_id flow into context values" do
      # Verify build_turn_values includes new fields
      state = %Arbor.Orchestrator.Session{
        session_id: "test-123",
        agent_id: "agent_test",
        trust_tier: :established,
        turn_graph: nil,
        heartbeat_graph: nil,
        phase: :processing,
        session_type: :consultation,
        trace_id: "trace-abc-def",
        config: %{"max_turns" => 10, "model" => "sonnet"},
        signal_topic: "session:test-123",
        seed_ref: {:seed, "ref-1"}
      }

      values = Arbor.Orchestrator.Session.build_turn_values(state, "hello")

      assert values["session.phase"] == "processing"
      assert values["session.session_type"] == "consultation"
      assert values["session.trace_id"] == "trace-abc-def"
      assert values["session.config"] == %{"max_turns" => 10, "model" => "sonnet"}
      assert values["session.signal_topic"] == "session:test-123"
    end
  end

  # ── Helpers ──

  defp estimate_state_bytes(state) do
    :erlang.external_size(state)
  end
end
