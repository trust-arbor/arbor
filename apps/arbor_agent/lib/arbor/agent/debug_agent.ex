defmodule Arbor.Agent.DebugAgent do
  @moduledoc """
  Self-healing agent that diagnoses runtime anomalies and proposes fixes.

  Uses the queue-based healing infrastructure from `arbor_monitor`:
  - Claims anomalies from `AnomalyQueue`
  - Diagnoses via AI analysis
  - Submits proposals to consensus council
  - Reports outcomes back to the queue

  ## Production Flow

  1. **Claim work** — `AnomalyQueue.claim_next/1` with lease
  2. **Diagnose** — AI analysis of the anomaly
  3. **Propose** — Submit fix proposal to consensus
  4. **Await decision** — Poll proposal status
  5. **Report outcome** — `AnomalyQueue.report_outcome/3`

  ## Usage

      # Start as a worker under HealingSupervisor
      {:ok, pid} = Arbor.Monitor.HealingSupervisor.start_worker(
        Arbor.Agent.DebugAgent,
        agent_id: "debug-agent-1"
      )

      # Or start standalone
      {:ok, pid} = Arbor.Agent.DebugAgent.start_link(agent_id: "debug-agent")

      # Stop
      GenServer.stop(pid)
  """

  use GenServer

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Templates.Diagnostician
  alias Arbor.Monitor.AnomalyQueue

  require Logger

  @default_agent_id "debug-agent"
  @poll_interval_ms 1_000
  @decision_poll_interval_ms 500
  @max_decision_polls 60

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a debug agent as a GenServer.

  ## Options

    * `:agent_id` — Unique agent ID (default: "debug-agent")
    * `:poll_interval` — How often to check for work in ms (default: 1000)
    * `:on_proposal` — Callback when a proposal is created
    * `:on_decision` — Callback when a decision is received
  """
  def start_link(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)
    name = Keyword.get(opts, :name, via_name(agent_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a debug agent (convenience wrapper around start_link).

  Returns `{:ok, agent_id}` on success.
  """
  @spec start() :: {:ok, String.t()} | {:error, term()}
  def start, do: start([])

  @spec start(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(opts) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)

    case start_link(opts) do
      {:ok, _pid} -> {:ok, agent_id}
      {:error, {:already_started, _pid}} -> {:ok, agent_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stop a debug agent.

  Returns `:ok` whether or not the agent was running (idempotent).
  """
  @spec stop(String.t()) :: :ok
  def stop(agent_id) do
    GenServer.stop(via_name(agent_id))
    :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, _ -> :ok
  end

  @doc """
  Run a bounded number of healing cycles.

  Useful for testing — runs up to `max_cycles` work cycles, then returns.
  """
  @spec run_bounded(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def run_bounded(agent_id, max_cycles) when is_integer(max_cycles) and max_cycles > 0 do
    GenServer.call(via_name(agent_id), {:run_bounded, max_cycles}, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc """
  Get the current state of the debug agent.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found | :not_running}
  def get_state(agent_id) do
    case GenServer.call(via_name(agent_id), :get_state) do
      {:ok, state} -> {:ok, state}
      state when is_map(state) -> {:ok, state}
    end
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Trigger an immediate work check (useful for testing).
  """
  def check_now(agent_id) do
    GenServer.cast(via_name(agent_id), :check_now)
  end

  defp via_name(agent_id), do: {:global, {__MODULE__, agent_id}}

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval_ms)

    # Create agent from Diagnostician template
    case Lifecycle.create(agent_id, template: Diagnostician) do
      {:ok, _profile} ->
        # Start executor
        case Lifecycle.start(agent_id) do
          {:ok, _pid} ->
            state = %{
              agent_id: agent_id,
              poll_interval: poll_interval,
              phase: :idle,
              current_lease: nil,
              current_anomaly: nil,
              current_proposal: nil,
              current_proposal_id: nil,
              decision_polls: 0,
              callbacks: %{
                on_proposal: Keyword.get(opts, :on_proposal),
                on_decision: Keyword.get(opts, :on_decision)
              },
              stats: %{
                anomalies_claimed: 0,
                proposals_submitted: 0,
                proposals_approved: 0,
                proposals_rejected: 0,
                started_at: DateTime.utc_now()
              }
            }

            # Schedule first work check
            schedule_work_check(poll_interval)
            safe_emit(:debug_agent, :started, %{agent_id: agent_id})

            {:ok, state}

          {:error, reason} ->
            {:stop, {:executor_start_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:create_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Release any held lease
    if state.current_lease do
      safe_release_lease(state.current_lease)
    end

    # Lifecycle cleanup (stops executor if running)
    Lifecycle.stop(state.agent_id)
    safe_emit(:debug_agent, :stopped, %{agent_id: state.agent_id})
    :ok
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:run_bounded, max_cycles}, _from, state) do
    final_state = run_bounded_cycles(state, max_cycles)
    {:reply, {:ok, final_state.stats}, final_state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    new_state = do_work_cycle(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_work, state) do
    new_state = do_work_cycle(state)
    schedule_work_check(state.poll_interval)
    {:noreply, new_state}
  end

  def handle_info(:poll_decision, state) do
    new_state = poll_decision(state)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Work Cycle
  # ============================================================================

  defp do_work_cycle(%{phase: :idle} = state) do
    claim_work(state)
  end

  defp do_work_cycle(%{phase: :diagnosing} = state) do
    # Already working, don't interrupt
    state
  end

  defp do_work_cycle(%{phase: :awaiting_decision} = state) do
    # Waiting for decision, poll handled separately
    state
  end

  defp do_work_cycle(state), do: state

  defp run_bounded_cycles(state, 0), do: state

  defp run_bounded_cycles(state, remaining) do
    new_state = do_work_cycle(state)

    # If still working on something, wait a bit and check decision
    new_state =
      if new_state.phase in [:diagnosing, :awaiting_decision] do
        Process.sleep(100)

        if new_state.phase == :awaiting_decision do
          poll_decision(new_state)
        else
          new_state
        end
      else
        new_state
      end

    # Continue if we're back to idle and have cycles remaining
    if new_state.phase == :idle do
      run_bounded_cycles(new_state, remaining - 1)
    else
      # Still working, recurse without decrementing (work in progress)
      run_bounded_cycles(new_state, remaining)
    end
  end

  # ============================================================================
  # Phase: Claim Work
  # ============================================================================

  defp claim_work(state) do
    case safe_claim_next(state.agent_id) do
      {:ok, {lease, anomaly}} ->
        # claim_next returns {lease, anomaly} directly - anomaly is the claim
        Logger.info("[DebugAgent] Claimed anomaly: #{anomaly.skill}")

        safe_emit(:debug_agent, :anomaly_claimed, %{
          agent_id: state.agent_id,
          skill: anomaly.skill
        })

        # Start diagnosis
        diagnose_anomaly(%{
          state
          | phase: :diagnosing,
            current_lease: lease,
            current_anomaly: anomaly,
            stats: update_stat(state.stats, :anomalies_claimed)
        })

      {:ok, :empty} ->
        # No work available
        state

      {:error, reason} ->
        Logger.debug("[DebugAgent] Claim failed: #{inspect(reason)}")
        state
    end
  end

  # ============================================================================
  # Phase: Diagnose
  # ============================================================================

  defp diagnose_anomaly(state) do
    anomaly = state.current_anomaly
    context = build_analysis_context(anomaly)

    # Call AI analysis action
    case safe_ai_analyze(state.agent_id, anomaly, context) do
      {:ok, analysis} ->
        # Build proposal from analysis
        proposal = build_proposal(anomaly, analysis)

        if state.callbacks[:on_proposal] do
          state.callbacks[:on_proposal].(proposal)
        end

        submit_proposal(%{state | current_proposal: proposal})

      {:error, reason} ->
        Logger.warning("[DebugAgent] AI analysis failed: #{inspect(reason)}")
        # Report failure and return to idle
        safe_complete(state.current_lease, :failed)
        reset_to_idle(state)
    end
  end

  # ============================================================================
  # Phase: Submit Proposal
  # ============================================================================

  defp submit_proposal(state) do
    case safe_submit_proposal(state.current_proposal) do
      {:ok, proposal_id} ->
        Logger.info("[DebugAgent] Proposal submitted: #{proposal_id}")

        safe_emit(:debug_agent, :proposal_submitted, %{
          agent_id: state.agent_id,
          proposal_id: proposal_id
        })

        # Start polling for decision
        schedule_decision_poll()

        %{
          state
          | phase: :awaiting_decision,
            current_proposal_id: proposal_id,
            decision_polls: 0,
            stats: update_stat(state.stats, :proposals_submitted)
        }

      {:error, reason} ->
        Logger.warning("[DebugAgent] Proposal submission failed: #{inspect(reason)}")
        safe_complete(state.current_lease, :failed)
        reset_to_idle(state)
    end
  end

  # ============================================================================
  # Phase: Await Decision
  # ============================================================================

  defp poll_decision(state) do
    case safe_get_proposal_status(state.current_proposal_id) do
      {:ok, :approved} ->
        handle_approval(state)

      {:ok, :rejected} ->
        handle_rejection(state, "Council rejected the proposal")

      {:ok, :deadlock} ->
        Logger.warning("[DebugAgent] Council deadlocked on proposal")
        safe_complete(state.current_lease, :rejected)
        reset_to_idle(state)

      {:ok, :pending} ->
        # Still pending, keep polling
        if state.decision_polls < @max_decision_polls do
          schedule_decision_poll()
          %{state | decision_polls: state.decision_polls + 1}
        else
          Logger.warning("[DebugAgent] Decision timeout after #{@max_decision_polls} polls")
          safe_complete(state.current_lease, :failed)
          reset_to_idle(state)
        end

      {:ok, :evaluating} ->
        # Still evaluating, keep polling
        if state.decision_polls < @max_decision_polls do
          schedule_decision_poll()
          %{state | decision_polls: state.decision_polls + 1}
        else
          Logger.warning("[DebugAgent] Decision timeout after #{@max_decision_polls} polls")
          safe_complete(state.current_lease, :failed)
          reset_to_idle(state)
        end

      {:error, reason} ->
        Logger.warning("[DebugAgent] Status check failed: #{inspect(reason)}")
        # Keep trying
        if state.decision_polls < @max_decision_polls do
          schedule_decision_poll()
          %{state | decision_polls: state.decision_polls + 1}
        else
          safe_complete(state.current_lease, :failed)
          reset_to_idle(state)
        end
    end
  end

  defp handle_approval(state) do
    Logger.info("[DebugAgent] Proposal approved!")

    if state.callbacks[:on_decision] do
      state.callbacks[:on_decision].(%{decision: :approved, proposal: state.current_proposal})
    end

    safe_emit(:debug_agent, :proposal_approved, %{
      agent_id: state.agent_id,
      proposal_id: state.current_proposal_id
    })

    # Execute the fix (hot-load)
    case safe_execute_fix(state) do
      :ok ->
        # Report success to queue
        safe_complete(state.current_lease, :resolved)

        reset_to_idle(%{
          state
          | stats: update_stat(state.stats, :proposals_approved)
        })

      {:error, reason} ->
        Logger.warning("[DebugAgent] Fix execution failed: #{inspect(reason)}")
        safe_complete(state.current_lease, :failed)
        reset_to_idle(state)
    end
  end

  defp handle_rejection(state, reason) do
    Logger.info("[DebugAgent] Proposal rejected: #{reason}")

    if state.callbacks[:on_decision] do
      state.callbacks[:on_decision].(%{
        decision: :rejected,
        reason: reason,
        proposal: state.current_proposal
      })
    end

    safe_emit(:debug_agent, :proposal_rejected, %{
      agent_id: state.agent_id,
      proposal_id: state.current_proposal_id,
      reason: reason
    })

    # Report rejection to queue (triggers three-strike escalation)
    safe_complete(state.current_lease, :rejected)

    reset_to_idle(%{
      state
      | stats: update_stat(state.stats, :proposals_rejected)
    })
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp reset_to_idle(state) do
    %{
      state
      | phase: :idle,
        current_lease: nil,
        current_anomaly: nil,
        current_proposal: nil,
        current_proposal_id: nil,
        decision_polls: 0
    }
  end

  defp schedule_work_check(interval) do
    Process.send_after(self(), :check_work, interval)
  end

  defp schedule_decision_poll do
    Process.send_after(self(), :poll_decision, @decision_poll_interval_ms)
  end

  defp update_stat(stats, key) do
    Map.update(stats, key, 1, &(&1 + 1))
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

  defp build_proposal(anomaly, analysis_data) do
    details = anomaly.details || %{}

    %{
      topic: :runtime_fix,
      proposer: "debug-agent",
      description: "Fix for #{anomaly.skill} #{anomaly.severity} anomaly",
      target_module: analysis_data[:target_module] || infer_target_module(anomaly),
      fix_code: analysis_data[:suggested_fix] || "",
      root_cause: analysis_data[:root_cause] || "Unknown",
      confidence: analysis_data[:confidence] || 0.5,
      # Flatten context for RuntimeFix evaluator
      context: %{
        proposer: "debug-agent",
        skill: anomaly.skill,
        severity: anomaly.severity,
        metric: Map.get(details, :metric, :unknown),
        value: Map.get(details, :value, 0),
        threshold: Map.get(details, :threshold, 0),
        root_cause: analysis_data[:root_cause] || "Unknown",
        recommended_fix: analysis_data[:suggested_fix] || "",
        # Keep full data for reference
        anomaly: anomaly,
        analysis: analysis_data
      }
    }
  end

  defp infer_target_module(%{skill: skill, details: details}) do
    cond do
      is_map(details) && Map.has_key?(details, :module) ->
        details.module

      is_map(details) && Map.has_key?(details, :process) ->
        case details.process do
          pid when is_pid(pid) -> extract_module_from_pid(pid)
          _ -> nil
        end

      true ->
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
      :processes -> Arbor.Monitor.Skills.Processes
      :memory -> Arbor.Monitor.Skills.Memory
      :scheduler -> Arbor.Monitor.Skills.Scheduler
      _ -> nil
    end
  end

  # ============================================================================
  # Safe External Calls
  # ============================================================================

  defp safe_claim_next(agent_id) do
    if queue_available?() do
      AnomalyQueue.claim_next(agent_id)
    else
      {:ok, :empty}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_release_lease(lease) do
    if queue_available?() do
      AnomalyQueue.release(lease)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_complete(lease, outcome) do
    if queue_available?() do
      AnomalyQueue.complete(lease, outcome)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp queue_available? do
    Process.whereis(AnomalyQueue) != nil
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

  defp safe_ai_analyze(_agent_id, anomaly, context) do
    # Call AI directly for analysis (simpler than async Executor flow)
    prompt = """
    Analyze this BEAM runtime anomaly and suggest a fix:

    Skill: #{anomaly.skill}
    Severity: #{anomaly.severity}
    Details: #{inspect(anomaly.details)}

    Context:
    #{inspect(context)}

    Respond with:
    1. Root cause analysis
    2. Suggested fix (if code change needed)
    3. Confidence level (0.0 to 1.0)
    """

    # Force API backend for speed (uses configured OpenRouter model)
    case Arbor.AI.generate_text(prompt, backend: :api, max_tokens: 500) do
      {:ok, response} ->
        # Parse response into analysis data
        analysis = %{
          root_cause: extract_section(response, "Root cause"),
          suggested_fix: extract_section(response, "Suggested fix"),
          confidence: extract_confidence(response),
          raw_response: response
        }

        {:ok, analysis}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp extract_section(text, section_name) when is_binary(text) do
    # Simple extraction - look for section header and take content until next section or end
    pattern = ~r/#{Regex.escape(section_name)}[:\s]*(.+?)(?=\d+\.|$)/si

    case Regex.run(pattern, text) do
      [_, content] -> String.trim(content)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp extract_section(_, _), do: ""

  defp extract_confidence(text) when is_binary(text) do
    case Regex.run(~r/(\d+\.?\d*)\s*(?:confidence|%)?/i, text) do
      [_, num] -> parse_confidence_value(num)
      _ -> 0.5
    end
  rescue
    _ -> 0.5
  end

  defp extract_confidence(_), do: 0.5

  defp parse_confidence_value(num) do
    case Float.parse(num) do
      {parsed, _} when parsed > 1.0 -> parsed / 100
      {parsed, _} -> parsed
      :error -> 0.5
    end
  end

  defp safe_submit_proposal(proposal) do
    case Arbor.Consensus.submit(proposal, []) do
      {:ok, proposal_id} -> {:ok, proposal_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_get_proposal_status(proposal_id) do
    case Arbor.Consensus.get_proposal_by_id(proposal_id) do
      {:ok, proposal} ->
        status = proposal.status || :evaluating
        {:ok, status}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_execute_fix(state) do
    proposal = state.current_proposal
    anomaly = state.current_anomaly

    # Execute real remediation based on anomaly type
    result = execute_remediation(anomaly)

    # Emit signal that fix was applied
    safe_emit(:code, :fix_applied, %{
      agent_id: state.agent_id,
      proposal_id: state.current_proposal_id,
      target_module: proposal[:target_module],
      skill: anomaly.skill,
      action: result.action,
      success: result.success
    })

    if result.success, do: :ok, else: {:error, result.reason}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  # Execute actual remediation based on anomaly type
  defp execute_remediation(%{skill: :processes, details: details}) do
    # Message queue issue - kill the problematic process
    case Map.get(details, :pid) || Map.get(details, :process) do
      pid when is_pid(pid) ->
        Logger.info("[DebugAgent] Killing process #{inspect(pid)} with bloated message queue")
        Process.exit(pid, :kill)
        %{success: true, action: :kill_process, reason: nil}

      _ ->
        Logger.warning("[DebugAgent] No PID found in anomaly details, cannot remediate")
        %{success: false, action: :none, reason: :no_pid}
    end
  end

  defp execute_remediation(%{skill: :memory, details: details}) do
    # Memory issue - force GC on the problematic process
    case Map.get(details, :pid) || Map.get(details, :process) do
      pid when is_pid(pid) ->
        Logger.info("[DebugAgent] Forcing GC on process #{inspect(pid)}")
        :erlang.garbage_collect(pid)
        %{success: true, action: :force_gc, reason: nil}

      _ ->
        # Force GC on all processes as fallback
        Logger.info("[DebugAgent] Forcing global GC")
        :erlang.garbage_collect()
        %{success: true, action: :global_gc, reason: nil}
    end
  end

  defp execute_remediation(%{skill: :beam, details: details}) do
    # Process count issue - attempt to identify and kill leaked processes
    # This is tricky without more context; log for now
    process_count = Map.get(details, :value, 0)

    Logger.warning(
      "[DebugAgent] High process count (#{process_count}), manual intervention may be needed"
    )

    %{success: true, action: :logged_warning, reason: nil}
  end

  defp execute_remediation(%{skill: :supervisor, details: details}) do
    # Supervisor issue - log details for manual review
    # Restarting supervisors automatically is risky
    supervisor = Map.get(details, :supervisor)
    Logger.warning("[DebugAgent] Supervisor issue detected: #{inspect(supervisor)}")
    %{success: true, action: :logged_warning, reason: nil}
  end

  defp execute_remediation(%{skill: skill}) do
    Logger.info("[DebugAgent] No specific remediation for skill #{skill}")
    %{success: true, action: :none, reason: nil}
  end

  defp safe_emit(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
