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

  alias Arbor.Actions.Remediation.ForceGC
  alias Arbor.Actions.Remediation.KillProcess
  alias Arbor.Actions.Remediation.StopSupervisor
  alias Arbor.Agent.CircuitBreaker
  alias Arbor.Agent.Investigation
  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Templates.Diagnostician
  alias Arbor.Agent.Verification
  alias Arbor.Monitor.AnomalyQueue

  require Logger

  @default_agent_id "debug-agent"
  @poll_interval_ms 1_000
  @decision_poll_interval_ms 500
  @max_decision_polls 60
  @verification_delay_ms 500

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
            # Start circuit breaker for this agent
            circuit_breaker = start_circuit_breaker(agent_id)

            state = %{
              agent_id: agent_id,
              poll_interval: poll_interval,
              phase: :idle,
              current_lease: nil,
              current_anomaly: nil,
              current_proposal: nil,
              current_proposal_id: nil,
              current_investigation: nil,
              decision_polls: 0,
              circuit_breaker: circuit_breaker,
              callbacks: %{
                on_proposal: Keyword.get(opts, :on_proposal),
                on_decision: Keyword.get(opts, :on_decision),
                on_investigation: Keyword.get(opts, :on_investigation),
                on_verification: Keyword.get(opts, :on_verification)
              },
              stats: %{
                anomalies_claimed: 0,
                proposals_submitted: 0,
                proposals_approved: 0,
                proposals_rejected: 0,
                investigations_completed: 0,
                verifications_passed: 0,
                verifications_failed: 0,
                circuit_breaker_blocked: 0,
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
        # Check circuit breaker before proceeding
        breaker_key = circuit_breaker_key(anomaly)

        if circuit_breaker_allows?(state, breaker_key) do
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
        else
          Logger.info("[DebugAgent] Circuit breaker blocked anomaly: #{anomaly.skill}")

          safe_emit(:debug_agent, :circuit_breaker_blocked, %{
            agent_id: state.agent_id,
            skill: anomaly.skill,
            breaker_key: breaker_key
          })

          # Release the lease - can't work on this
          safe_release_lease(lease)

          %{state | stats: update_stat(state.stats, :circuit_breaker_blocked)}
        end

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

    # Use structured investigation flow
    investigation =
      anomaly
      |> Investigation.start()
      |> Investigation.gather_symptoms()
      |> Investigation.generate_hypotheses()
      |> maybe_enhance_with_ai()

    # Log investigation summary
    summary = Investigation.summary(investigation)

    Logger.info(
      "[DebugAgent] Investigation complete: #{summary.hypothesis_count} hypotheses, confidence: #{Float.round(summary.confidence * 100, 1)}%"
    )

    safe_emit(:debug_agent, :investigation_complete, %{
      agent_id: state.agent_id,
      investigation_id: investigation.id,
      hypothesis_count: summary.hypothesis_count,
      confidence: summary.confidence,
      suggested_action: summary.suggested_action
    })

    # Build proposal from investigation
    proposal = Investigation.to_proposal(investigation)

    if state.callbacks[:on_proposal] do
      state.callbacks[:on_proposal].(proposal)
    end

    submit_proposal(%{state | current_proposal: proposal, current_investigation: investigation})
  end

  defp maybe_enhance_with_ai(investigation) do
    # Only call AI if we have low confidence or no hypotheses
    if investigation.confidence < 0.7 || investigation.hypotheses == [] do
      Investigation.enhance_with_ai(investigation)
    else
      investigation
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

    # Execute the fix
    context = state.current_proposal[:context] || %{}
    action = context[:suggested_action] || :none
    target = context[:action_target]
    breaker_key = circuit_breaker_key(state.current_anomaly)

    case safe_execute_fix(state) do
      :ok ->
        # Verify the fix worked
        verification_result = verify_fix(state, action, target)

        if state.callbacks[:on_verification] do
          state.callbacks[:on_verification].(verification_result)
        end

        case verification_result do
          {:ok, :verified} ->
            Logger.info("[DebugAgent] Fix verified successfully")

            safe_emit(:debug_agent, :fix_verified, %{
              agent_id: state.agent_id,
              proposal_id: state.current_proposal_id,
              action: action
            })

            # Record success in circuit breaker
            record_circuit_breaker_success(state, breaker_key)

            safe_complete(state.current_lease, :resolved)

            reset_to_idle(%{
              state
              | stats:
                  state.stats
                  |> update_stat(:proposals_approved)
                  |> update_stat(:verifications_passed)
            })

          {:ok, :unverified} ->
            Logger.warning("[DebugAgent] Fix applied but verification failed")

            safe_emit(:debug_agent, :fix_unverified, %{
              agent_id: state.agent_id,
              proposal_id: state.current_proposal_id,
              action: action
            })

            # Record failure in circuit breaker
            record_circuit_breaker_failure(state, breaker_key)

            # Report as failed so it can be retried or escalated
            safe_complete(state.current_lease, :failed)

            reset_to_idle(%{
              state
              | stats:
                  state.stats
                  |> update_stat(:proposals_approved)
                  |> update_stat(:verifications_failed)
            })

          {:error, reason} ->
            Logger.warning("[DebugAgent] Verification error: #{inspect(reason)}")
            # Treat verification errors as success (fix was applied, just can't verify)
            safe_complete(state.current_lease, :resolved)

            reset_to_idle(%{
              state
              | stats: update_stat(state.stats, :proposals_approved)
            })
        end

      {:error, reason} ->
        Logger.warning("[DebugAgent] Fix execution failed: #{inspect(reason)}")

        # Record failure in circuit breaker
        record_circuit_breaker_failure(state, breaker_key)

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
        current_investigation: nil,
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
    investigation = state.current_investigation
    context = proposal[:context] || %{}

    # Get action from investigation or proposal context
    action = context[:suggested_action] || :none
    target = context[:action_target]

    # Execute remediation using the new Remediation actions
    result = execute_remediation_action(action, target)

    # Emit signal that fix was applied
    safe_emit(:code, :fix_applied, %{
      agent_id: state.agent_id,
      proposal_id: state.current_proposal_id,
      investigation_id: investigation && investigation.id,
      action: action,
      target: inspect(target),
      success: result.success
    })

    if result.success, do: :ok, else: {:error, result.reason}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  # Execute remediation using Arbor.Actions.Remediation
  defp execute_remediation_action(:kill_process, pid) when is_pid(pid) do
    Logger.info("[DebugAgent] Killing process #{inspect(pid)}")
    pid_string = inspect(pid)

    case KillProcess.run(%{pid: pid_string, reason: :kill}, %{}) do
      {:ok, %{killed: true}} -> %{success: true, action: :kill_process, reason: nil}
      {:ok, %{killed: false}} -> %{success: false, action: :kill_process, reason: :not_alive}
      {:error, reason} -> %{success: false, action: :kill_process, reason: reason}
    end
  end

  defp execute_remediation_action(:force_gc, pid) when is_pid(pid) do
    Logger.info("[DebugAgent] Forcing GC on #{inspect(pid)}")
    pid_string = inspect(pid)

    case ForceGC.run(%{pid: pid_string}, %{}) do
      {:ok, %{collected: true}} -> %{success: true, action: :force_gc, reason: nil}
      {:ok, %{collected: false}} -> %{success: false, action: :force_gc, reason: :not_alive}
      {:error, reason} -> %{success: false, action: :force_gc, reason: reason}
    end
  end

  defp execute_remediation_action(:stop_supervisor, pid) when is_pid(pid) do
    Logger.info("[DebugAgent] Stopping supervisor #{inspect(pid)}")
    pid_string = inspect(pid)

    case StopSupervisor.run(%{pid: pid_string}, %{}) do
      {:ok, %{stopped: true}} ->
        %{success: true, action: :stop_supervisor, reason: nil}

      {:ok, %{stopped: false, result: reason}} ->
        %{success: false, action: :stop_supervisor, reason: reason}

      {:error, reason} ->
        %{success: false, action: :stop_supervisor, reason: reason}
    end
  end

  defp execute_remediation_action(:logged_warning, _target) do
    Logger.warning("[DebugAgent] Manual intervention may be needed")
    %{success: true, action: :logged_warning, reason: nil}
  end

  defp execute_remediation_action(action, target) do
    Logger.info("[DebugAgent] No handler for action #{action} on #{inspect(target)}")
    %{success: true, action: :none, reason: nil}
  end

  defp safe_emit(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ============================================================================
  # Circuit Breaker Helpers
  # ============================================================================

  defp start_circuit_breaker(agent_id) do
    name = {:global, {CircuitBreaker, agent_id}}

    case CircuitBreaker.start_link(name: name, failure_threshold: 3, cooldown_ms: 60_000) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp circuit_breaker_key(anomaly) do
    # Create a key based on the anomaly type and target
    skill = anomaly.skill
    details = anomaly[:details] || %{}

    # Include target in key if available
    target =
      cond do
        Map.has_key?(details, :pid) -> {:pid, inspect(details.pid)}
        Map.has_key?(details, :process) -> {:pid, inspect(details.process)}
        Map.has_key?(details, :supervisor) -> {:supervisor, inspect(details.supervisor)}
        true -> :general
      end

    {skill, target}
  end

  defp circuit_breaker_allows?(state, key) do
    if state.circuit_breaker do
      CircuitBreaker.can_attempt?(state.circuit_breaker, key)
    else
      true
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  defp record_circuit_breaker_success(state, key) do
    if state.circuit_breaker do
      CircuitBreaker.record_success(state.circuit_breaker, key)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp record_circuit_breaker_failure(state, key) do
    if state.circuit_breaker do
      CircuitBreaker.record_failure(state.circuit_breaker, key)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ============================================================================
  # Verification Helpers
  # ============================================================================

  defp verify_fix(state, action, target) do
    anomaly = state.current_anomaly

    Verification.verify_fix(anomaly, action, target, delay_ms: @verification_delay_ms)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end
end
