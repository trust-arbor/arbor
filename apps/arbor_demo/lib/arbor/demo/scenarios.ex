defmodule Arbor.Demo.Scenarios do
  @moduledoc """
  Pre-scripted demo scenarios with known outcomes.

  Provides reliable, repeatable demo flows for conference presentations.
  Each scenario includes:
  - Which fault to inject
  - Expected timing windows
  - Expected council decision
  - Recovery steps if something fails

  ## Available Scenarios

  - `:successful_heal` - Message queue flood → detect → diagnose → approve → fix
  - `:rejected_fix` - Supervisor crash with protected module → reject
  - `:second_success` - Process leak → detect → diagnose → approve → fix

  ## Usage

      # Run a single scenario
      {:ok, result} = Arbor.Demo.Scenarios.run(:successful_heal)

      # Run full rehearsal (all 3 scenarios)
      {:ok, results} = Arbor.Demo.Scenarios.rehearsal()

      # Get scenario definition
      scenario = Arbor.Demo.Scenarios.scenario(:successful_heal)
  """

  alias Arbor.Demo
  alias Arbor.Demo.{Orchestrator, Timing}
  alias Arbor.Signals

  require Logger

  @type scenario_result :: %{
          scenario: atom(),
          success: boolean(),
          duration_ms: non_neg_integer(),
          final_stage: atom(),
          expected_decision: atom(),
          actual_decision: atom() | nil,
          events: [map()]
        }

  # ============================================================================
  # Scenario Definitions
  # ============================================================================

  @doc """
  Get a scenario definition by name.
  """
  @spec scenario(atom()) :: map() | nil
  def scenario(:successful_heal) do
    %{
      name: :successful_heal,
      description: "Message queue flood triggers successful self-healing",
      fault: :message_queue_flood,
      expected_decision: :approved,
      narrator_notes: [
        "I've just flooded a process's message queue. Watch the pipeline.",
        "The Monitor detected the anomaly. Our DebugAgent is analyzing...",
        "It's proposing a fix. Look at the code diff—it adds a queue limit.",
        "Three evaluators are reviewing. All approved. The fix will be hot-loaded.",
        "Code loaded. Verification passed. The process is healthy again."
      ],
      recovery_steps: [
        "If stuck at Detect: Call Demo.force_detect()",
        "If stuck at Diagnose: Check DebugAgent logs",
        "If stuck at Review: Council may be timing out, check evaluator status"
      ]
    }
  end

  def scenario(:rejected_fix) do
    %{
      name: :rejected_fix,
      description: "Fix proposal is rejected due to protected module",
      fault: :supervisor_crash,
      # The mock proposal targets a protected module
      mock_proposal: protected_module_fix(),
      expected_decision: :rejected,
      narrator_notes: [
        "Now I'll inject a supervisor crash affecting a protected module.",
        "Watch—the agent proposes a fix, but the council will reject it.",
        "See? The security evaluator flagged this. The target is protected.",
        "This isn't theater. The governance is real."
      ],
      recovery_steps: [
        "If unexpectedly approved: Check evaluator configuration",
        "If stuck: Council timeout, show the rejection flow manually"
      ]
    }
  end

  def scenario(:second_success) do
    %{
      name: :second_success,
      description: "Process leak triggers successful self-healing",
      fault: :process_leak,
      expected_decision: :approved,
      narrator_notes: [
        "Let's try another fault—a process leak.",
        "Same pipeline: detect, diagnose, propose, review, fix.",
        "Approved and hot-loaded. Self-healing with accountability."
      ],
      recovery_steps: [
        "Same as successful_heal scenario"
      ]
    }
  end

  def scenario(_), do: nil

  @doc """
  List all available scenario names.
  """
  @spec available_scenarios() :: [atom()]
  def available_scenarios do
    [:successful_heal, :rejected_fix, :second_success]
  end

  # ============================================================================
  # Scenario Execution
  # ============================================================================

  @doc """
  Run a single scenario and return the result.

  ## Options

  - `:timeout` - Overall scenario timeout (default: from Timing config)
  - `:verbose` - Print progress to console (default: false)
  """
  @spec run(atom(), keyword()) :: {:ok, scenario_result()} | {:error, term()}
  def run(scenario_name, opts \\ []) do
    case scenario(scenario_name) do
      nil ->
        {:error, {:unknown_scenario, scenario_name}}

      scenario_def ->
        execute_scenario(scenario_def, opts)
    end
  end

  @doc """
  Run all three demo scenarios in sequence.

  Returns timing and success/failure for each.
  """
  @spec rehearsal(keyword()) :: {:ok, [scenario_result()]} | {:error, term()}
  def rehearsal(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, true)

    verbose_puts(verbose, "\n=== Arbor Demo Rehearsal ===\n")

    results =
      for scenario_name <- [:successful_heal, :rejected_fix, :second_success] do
        verbose_puts(verbose, "Running: #{scenario_name}")

        result = run_scenario_safely(scenario_name, opts)

        verbose_print_result(verbose, result)

        # Brief pause between scenarios
        Process.sleep(500)

        result
      end

    verbose_print_summary(verbose, results)

    {:ok, results}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp run_scenario_safely(scenario_name, opts) do
    case run(scenario_name, opts) do
      {:ok, result} -> result
      {:error, reason} -> %{scenario: scenario_name, success: false, error: reason}
    end
  end

  defp verbose_puts(false, _msg), do: :ok
  defp verbose_puts(true, msg), do: IO.puts(msg)

  defp verbose_print_result(false, _result), do: :ok

  defp verbose_print_result(true, result) do
    status = if result[:success], do: "✓", else: "✗"
    duration = result[:duration_ms] || 0
    IO.puts("  #{status} Completed in #{duration}ms\n")
  end

  defp verbose_print_summary(false, _results), do: :ok
  defp verbose_print_summary(true, results), do: print_rehearsal_summary(results)

  defp execute_scenario(scenario_def, opts) do
    timeout = Keyword.get(opts, :timeout, Timing.total_scenario_timeout())
    verbose = Keyword.get(opts, :verbose, false)

    events = []
    start_time = System.monotonic_time(:millisecond)

    # Subscribe to demo signals to track progress
    {:ok, sub_id} = subscribe_to_demo_signals(self())

    try do
      # Reset orchestrator to clean state
      Orchestrator.reset()
      Process.sleep(100)

      # Inject the fault
      if verbose, do: IO.puts("  Injecting fault: #{scenario_def.fault}")
      {:ok, _} = Demo.inject_fault(scenario_def.fault)

      # Wait for the scenario to complete or timeout
      result = wait_for_completion(scenario_def, timeout, events)

      duration_ms = System.monotonic_time(:millisecond) - start_time

      # Clean up
      Demo.clear_all()
      Orchestrator.reset()

      {:ok, build_result(scenario_def, result, duration_ms)}
    after
      safe_unsubscribe(sub_id)
    end
  end

  defp wait_for_completion(scenario_def, timeout, events) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop(scenario_def, deadline, events)
  end

  defp wait_loop(scenario_def, deadline, events) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, events, Orchestrator.pipeline_stage()}
    else
      receive do
        {:demo_signal, signal} ->
          events = [signal | events]
          stage = extract_stage(signal)
          decision = extract_decision(signal)

          cond do
            # Scenario complete - got a decision
            decision != nil ->
              {:complete, Enum.reverse(events), stage, decision}

            # Reached terminal stage
            stage in [:verify, :rejected, :fix_failed] ->
              # Give a moment for final signals
              Process.sleep(200)
              {:complete, Enum.reverse(events), stage, decision}

            true ->
              wait_loop(scenario_def, deadline, events)
          end
      after
        min(remaining, 500) ->
          # Check orchestrator state periodically
          stage = Orchestrator.pipeline_stage()

          if stage in [:verify, :rejected, :fix_failed] do
            {:complete, Enum.reverse(events), stage, nil}
          else
            wait_loop(scenario_def, deadline, events)
          end
      end
    end
  end

  defp build_result(scenario_def, result, duration_ms) do
    {status, events, final_stage, actual_decision} =
      case result do
        {:complete, events, stage, decision} -> {:complete, events, stage, decision}
        {:timeout, events, stage} -> {:timeout, events, stage, nil}
      end

    # Infer decision from final stage if not explicitly captured
    actual_decision =
      actual_decision ||
        case final_stage do
          :verify -> :approved
          :rejected -> :rejected
          :fix_failed -> :approved
          # Approved but fix failed
          _ -> nil
        end

    success =
      status == :complete and
        actual_decision == scenario_def.expected_decision

    %{
      scenario: scenario_def.name,
      success: success,
      duration_ms: duration_ms,
      final_stage: final_stage,
      expected_decision: scenario_def.expected_decision,
      actual_decision: actual_decision,
      events: events
    }
  end

  defp subscribe_to_demo_signals(pid) do
    Signals.subscribe("demo.*", fn signal ->
      send(pid, {:demo_signal, signal})
      :ok
    end)
  rescue
    _ -> {:ok, nil}
  catch
    :exit, _ -> {:ok, nil}
  end

  defp safe_unsubscribe(nil), do: :ok

  defp safe_unsubscribe(sub_id) do
    Signals.unsubscribe(sub_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp extract_stage(signal) do
    get_in(signal, [:data, :stage]) ||
      signal[:stage] ||
      Map.get(signal, "stage")
  end

  defp extract_decision(signal) do
    get_in(signal, [:data, :decision]) ||
      signal[:decision] ||
      Map.get(signal, "decision")
  end

  defp print_rehearsal_summary(results) do
    total = length(results)
    passed = Enum.count(results, & &1[:success])
    total_time = Enum.sum(Enum.map(results, &(&1[:duration_ms] || 0)))

    IO.puts("=== Summary ===")
    IO.puts("Passed: #{passed}/#{total}")
    IO.puts("Total time: #{total_time}ms")

    if passed == total do
      IO.puts("\n✓ All scenarios passed! Ready for demo.")
    else
      IO.puts("\n✗ Some scenarios failed. Review before presenting.")

      for result <- results, not result[:success] do
        IO.puts("  - #{result[:scenario]}: expected #{result[:expected_decision]}, got #{result[:actual_decision]}")
      end
    end
  end

  # Mock fix proposal for rejection scenario
  defp protected_module_fix do
    %{
      title: "Fix supervisor crash",
      target_module: "Arbor.Security.Kernel",
      # Protected module
      changes: [
        %{
          type: :modify,
          file: "lib/arbor/security/kernel.ex",
          diff: "+  def restart_strategy, do: :one_for_all"
        }
      ]
    }
  end
end
