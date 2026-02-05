defmodule Arbor.Agent.DebugAgent do
  @moduledoc """
  Self-healing agent that diagnoses runtime anomalies and proposes fixes.

  Wires together the Diagnostician template with Monitor subscription and
  custom reasoning. Uses bounded reasoning cycles for demo scenarios.

  ## Think Function Cycle

  The agent runs through cycles:

  1. **Check anomalies** — Query Monitor for current anomalies
     - None: `Intent.think("No anomalies detected")`
     - Found: `Intent.action(:ai_analyze, %{anomaly: ...})`

  2. **Process AI result** — Parse analysis and form proposal
     - Success: `Intent.action(:proposal_submit, %{proposal: ...})`
     - Failure: `Intent.think("Analysis failed: {reason}")`

  3. **Wait for council** — Subscribe to decision signal
     - Approved: `Intent.action(:code_hot_load, %{module: ..., code: ...})`
     - Rejected: Log and end cycle

  ## Usage

      # Start the debug agent
      {:ok, agent_id} = Arbor.Agent.DebugAgent.start()

      # Run bounded reasoning (for demo)
      {:ok, _} = Arbor.Agent.DebugAgent.run_bounded(agent_id, cycles: 10)

      # Stop
      :ok = Arbor.Agent.DebugAgent.stop(agent_id)
  """

  alias Arbor.Agent.{Executor, Lifecycle, ReasoningLoop}
  alias Arbor.Agent.Templates.Diagnostician
  alias Arbor.Contracts.Memory.Intent

  require Logger

  @default_cycles 10
  @default_agent_id "debug-agent"

  @type start_opts :: [
          agent_id: String.t(),
          cycles: pos_integer(),
          on_proposal: (map() -> :ok),
          on_decision: (map() -> :ok)
        ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a debug agent.

  Creates the agent from the Diagnostician template, starts the executor,
  and returns the agent ID. The reasoning loop is NOT started — use
  `run_bounded/2` to trigger a bounded reasoning session.

  ## Options

    * `:agent_id` — Custom agent ID (default: "debug-agent")
    * `:cycles` — Default cycles for bounded runs (default: 10)
    * `:on_proposal` — Callback when a proposal is created
    * `:on_decision` — Callback when a decision is received
  """
  @spec start(start_opts()) :: {:ok, String.t()} | {:error, term()}
  def start(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)

    # Create agent from Diagnostician template
    case Lifecycle.create(agent_id, template: Diagnostician) do
      {:ok, _profile} ->
        # Store opts in process dictionary for think_fn to access
        callbacks = %{
          on_proposal: Keyword.get(opts, :on_proposal),
          on_decision: Keyword.get(opts, :on_decision),
          cycles: Keyword.get(opts, :cycles, @default_cycles)
        }

        :persistent_term.put({__MODULE__, agent_id, :callbacks}, callbacks)

        # Start executor
        case Lifecycle.start(agent_id) do
          {:ok, _pid} ->
            safe_emit(:debug_agent, :started, %{agent_id: agent_id})
            {:ok, agent_id}

          {:error, reason} ->
            {:error, {:executor_start_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:create_failed, reason}}
    end
  end

  @doc """
  Stop the debug agent.
  """
  @spec stop(String.t()) :: :ok
  def stop(agent_id) do
    # Stop reasoning loop if running
    ReasoningLoop.stop(agent_id)

    # Stop executor
    Executor.stop(agent_id)

    # Clean up callbacks
    :persistent_term.erase({__MODULE__, agent_id, :callbacks})

    safe_emit(:debug_agent, :stopped, %{agent_id: agent_id})
    :ok
  end

  @doc """
  Run a bounded reasoning session.

  Starts a ReasoningLoop in bounded mode with the debug agent's custom
  think function. Returns when all cycles complete or an error occurs.

  ## Options

    * `:cycles` — Number of reasoning cycles (default: from start opts or 10)
    * `:timeout` — Max wait time per cycle in ms (default: 30_000)
  """
  @spec run_bounded(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_bounded(agent_id, opts \\ []) do
    callbacks = get_callbacks(agent_id)
    cycles = Keyword.get(opts, :cycles, callbacks[:cycles] || @default_cycles)
    timeout = Keyword.get(opts, :timeout, 30_000)

    # Initialize state for the think function
    init_state(agent_id)

    # Start reasoning loop with custom think function
    case ReasoningLoop.start(agent_id, {:bounded, cycles},
           think_fn: &think_fn(agent_id, &1, &2),
           intent_timeout: timeout
         ) do
      {:ok, pid} ->
        # Wait for loop to complete (it stops itself when bounded limit reached)
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            cleanup_state(agent_id)

            case reason do
              :normal -> {:ok, get_summary(agent_id)}
              other -> {:error, {:loop_crashed, other}}
            end
        after
          cycles * timeout + 5_000 ->
            Process.demonitor(ref, [:flush])
            ReasoningLoop.stop(agent_id)
            cleanup_state(agent_id)
            {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the current state of the debug agent.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) do
    case :persistent_term.get({__MODULE__, agent_id, :state}, :not_found) do
      :not_found -> {:error, :not_found}
      state -> {:ok, state}
    end
  end

  # ============================================================================
  # Think Function
  # ============================================================================

  # The think function implements the diagnosis cycle:
  # 1. Check for anomalies
  # 2. If found, request AI analysis
  # 3. Process AI result and form proposal
  # 4. Wait for council decision
  # 5. Execute approved fix

  defp think_fn(agent_id, _agent_id_arg, last_percept) do
    state = get_state!(agent_id)

    case state.phase do
      :check_anomalies ->
        check_anomalies(agent_id, state)

      :await_analysis ->
        process_analysis_result(agent_id, state, last_percept)

      :await_decision ->
        process_decision(agent_id, state, last_percept)

      :complete ->
        Intent.think("Cycle complete. Waiting for next anomaly check.")
    end
  end

  defp check_anomalies(agent_id, state) do
    anomalies = safe_get_anomalies()

    if anomalies == [] do
      Logger.debug("[DebugAgent] No anomalies detected")
      update_state(agent_id, %{state | phase: :check_anomalies, last_check: now()})
      Intent.think("No anomalies detected. Runtime is healthy.")
    else
      anomaly = hd(anomalies)
      Logger.info("[DebugAgent] Anomaly detected: #{inspect(anomaly.details)}")

      update_state(agent_id, %{
        state
        | phase: :await_analysis,
          current_anomaly: anomaly
      })

      # Request AI analysis
      Intent.action(
        :ai_analyze,
        %{
          anomaly: anomaly,
          context: build_analysis_context(anomaly)
        },
        reasoning:
          "Anomaly detected: #{anomaly.skill} / #{anomaly.severity}. Requesting AI analysis."
      )
    end
  end

  defp process_analysis_result(agent_id, state, percept) do
    case extract_percept_outcome(percept) do
      {:success, data} ->
        # Form a proposal from the analysis
        proposal = build_proposal(state.current_anomaly, data)
        callbacks = get_callbacks(agent_id)

        if callbacks[:on_proposal], do: callbacks[:on_proposal].(proposal)

        update_state(agent_id, %{
          state
          | phase: :await_decision,
            current_proposal: proposal
        })

        Intent.action(
          :proposal_submit,
          %{proposal: proposal},
          reasoning: "Analysis complete. Submitting proposal for council review."
        )

      {:failure, reason} ->
        Logger.warning("[DebugAgent] AI analysis failed: #{inspect(reason)}")
        update_state(agent_id, %{state | phase: :check_anomalies, current_anomaly: nil})

        Intent.think("AI analysis failed: #{inspect(reason)}. Will retry on next cycle.")

      :no_percept ->
        # Still waiting for analysis result
        Intent.wait(reasoning: "Waiting for AI analysis result...")
    end
  end

  defp process_decision(agent_id, state, percept) do
    case extract_percept_outcome(percept) do
      {:success, %{decision: :approved, proposal_id: _id}} ->
        callbacks = get_callbacks(agent_id)

        if callbacks[:on_decision],
          do: callbacks[:on_decision].(%{decision: :approved, proposal: state.current_proposal})

        update_state(agent_id, %{
          state
          | phase: :complete,
            current_anomaly: nil,
            current_proposal: nil
        })

        # Execute the fix
        Intent.action(
          :code_hot_load,
          %{
            module: state.current_proposal[:target_module],
            code: state.current_proposal[:fix_code]
          },
          reasoning: "Proposal approved by council. Executing hot-load."
        )

      {:success, %{decision: :rejected, reason: reason}} ->
        callbacks = get_callbacks(agent_id)

        if callbacks[:on_decision],
          do:
            callbacks[:on_decision].(%{
              decision: :rejected,
              reason: reason,
              proposal: state.current_proposal
            })

        Logger.info("[DebugAgent] Proposal rejected: #{reason}")

        update_state(agent_id, %{
          state
          | phase: :check_anomalies,
            current_anomaly: nil,
            current_proposal: nil
        })

        Intent.think("Proposal rejected by council: #{reason}. Returning to monitoring.")

      {:failure, reason} ->
        Logger.warning("[DebugAgent] Decision retrieval failed: #{inspect(reason)}")
        update_state(agent_id, %{state | phase: :check_anomalies})
        Intent.think("Failed to get decision: #{inspect(reason)}. Will retry.")

      :no_percept ->
        Intent.wait(reasoning: "Waiting for council decision...")
    end
  end

  # ============================================================================
  # State Management
  # ============================================================================

  defp init_state(agent_id) do
    state = %{
      phase: :check_anomalies,
      current_anomaly: nil,
      current_proposal: nil,
      proposals_submitted: 0,
      proposals_approved: 0,
      proposals_rejected: 0,
      anomalies_detected: 0,
      last_check: nil,
      started_at: now()
    }

    :persistent_term.put({__MODULE__, agent_id, :state}, state)
    state
  end

  defp update_state(agent_id, state) do
    :persistent_term.put({__MODULE__, agent_id, :state}, state)
    state
  end

  defp get_state!(agent_id) do
    case :persistent_term.get({__MODULE__, agent_id, :state}, :not_found) do
      :not_found -> init_state(agent_id)
      state -> state
    end
  end

  defp cleanup_state(agent_id) do
    :persistent_term.erase({__MODULE__, agent_id, :state})
  end

  defp get_summary(agent_id) do
    case get_state(agent_id) do
      {:ok, state} ->
        %{
          proposals_submitted: state.proposals_submitted,
          proposals_approved: state.proposals_approved,
          proposals_rejected: state.proposals_rejected,
          anomalies_detected: state.anomalies_detected,
          duration_ms: DateTime.diff(now(), state.started_at, :millisecond)
        }

      {:error, :not_found} ->
        %{error: :no_state}
    end
  end

  defp get_callbacks(agent_id) do
    :persistent_term.get({__MODULE__, agent_id, :callbacks}, %{})
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp safe_get_anomalies do
    Arbor.Monitor.anomalies()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_analysis_context(anomaly) do
    metrics = safe_get_metrics(anomaly.skill)

    %{
      skill: anomaly.skill,
      severity: anomaly.severity,
      details: anomaly.details,
      timestamp: anomaly.timestamp,
      related_metrics: metrics
    }
  end

  defp safe_get_metrics(skill) do
    case Arbor.Monitor.metrics(skill) do
      {:ok, metrics} -> metrics
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp build_proposal(anomaly, analysis_data) do
    %{
      topic: :runtime_fix,
      description: "Fix for #{anomaly.skill} #{anomaly.severity} anomaly",
      target_module: analysis_data[:target_module] || infer_target_module(anomaly),
      fix_code: analysis_data[:suggested_fix] || "",
      root_cause: analysis_data[:root_cause] || "Unknown",
      confidence: analysis_data[:confidence] || 0.5,
      anomaly_id: anomaly.id,
      context: %{
        anomaly: anomaly,
        analysis: analysis_data
      }
    }
  end

  defp infer_target_module(%{skill: skill, details: details}) do
    # Try to infer target module from anomaly details
    cond do
      is_map(details) && Map.has_key?(details, :module) ->
        details.module

      is_map(details) && Map.has_key?(details, :process) ->
        # Try to extract module from process info
        case details.process do
          pid when is_pid(pid) -> extract_module_from_pid(pid)
          _ -> nil
        end

      true ->
        # Default based on skill
        skill_to_module(skill)
    end
  end

  defp extract_module_from_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, :"$initial_call", 0) do
          {_, {mod, _, _}} -> mod
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp skill_to_module(skill) do
    case skill do
      :beam -> Arbor.Monitor.Skills.Beam
      :process -> Arbor.Monitor.Skills.Process
      :memory -> Arbor.Monitor.Skills.Memory
      :scheduler -> Arbor.Monitor.Skills.Scheduler
      _ -> nil
    end
  end

  defp extract_percept_outcome(nil), do: :no_percept

  defp extract_percept_outcome(%{outcome: :success, data: data}), do: {:success, data}

  defp extract_percept_outcome(%{outcome: :failure, error: error}), do: {:failure, error}

  defp extract_percept_outcome(%{outcome: :blocked, error: error}), do: {:failure, error}

  defp extract_percept_outcome(_), do: :no_percept

  defp now, do: DateTime.utc_now()

  defp safe_emit(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
