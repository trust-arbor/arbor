defmodule Arbor.Demo.Orchestrator do
  @moduledoc """
  Orchestrates the self-healing demo flow by subscribing to signals and triggering actions.

  ## Signal Flow

  ```
  1. demo.fault_injected → start DebugAgent bounded reasoning
  2. monitor.anomaly_detected → (DebugAgent handles via its own subscription)
  3. consensus.proposal_submitted → emit demo.pipeline_stage_changed (Propose)
  4. consensus.evaluation_started → emit demo.pipeline_stage_changed (Review)
  5. consensus.decision_made →
     - approved: trigger hot-load, emit demo.pipeline_stage_changed (Fix)
     - rejected: emit demo.pipeline_stage_changed (show rejection)
  6. code.hot_loaded → verify fix, emit demo.pipeline_stage_changed (Verify)
  ```

  ## Usage

      # Start the orchestrator (usually done by Arbor.Demo.Application)
      {:ok, pid} = Arbor.Demo.Orchestrator.start_link([])

      # Stop the orchestrator
      :ok = GenServer.stop(pid)
  """

  use GenServer

  require Logger

  alias Arbor.Agent.DebugAgent

  @type state :: %{
          subscription_ids: [String.t()],
          debug_agent_id: String.t() | nil,
          current_proposal_id: String.t() | nil,
          pipeline_stage: atom(),
          bus_monitor_ref: reference() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the orchestrator.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current state of the orchestrator.
  """
  @spec state() :: state()
  def state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Get the current pipeline stage.
  """
  @spec pipeline_stage() :: atom()
  def pipeline_stage do
    GenServer.call(__MODULE__, :get_pipeline_stage)
  end

  @doc """
  Reset the orchestrator to idle state.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      subscription_ids: [],
      debug_agent_id: nil,
      current_proposal_id: nil,
      pipeline_stage: :idle,
      bus_monitor_ref: nil
    }

    # Subscribe to relevant signals
    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    state = do_subscribe(state)
    {:noreply, state}
  end

  defp do_subscribe(state) do
    subscription_ids =
      [
        subscribe_pattern("demo.*"),
        subscribe_pattern("monitor.*"),
        subscribe_pattern("consensus.*"),
        subscribe_pattern("code.*"),
        subscribe_pattern("debug_agent.*")
      ]
      |> Enum.reject(&is_nil/1)

    # Monitor the Bus so we can re-subscribe if it restarts
    bus_ref = monitor_bus()

    %{state | subscription_ids: subscription_ids, bus_monitor_ref: bus_ref}
  end

  defp monitor_bus do
    case Process.whereis(Arbor.Signals.Bus) do
      nil -> nil
      pid -> Process.monitor(pid)
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_pipeline_stage, _from, state) do
    {:reply, state.pipeline_stage, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    # Stop debug agent if running
    if state.debug_agent_id do
      safe_stop_debug_agent(state.debug_agent_id)
    end

    new_state = %{
      state
      | debug_agent_id: nil,
        current_proposal_id: nil,
        pipeline_stage: :idle
    }

    emit_stage_change(:idle, nil)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:signal_received, signal}, state) do
    new_state = handle_signal(signal, state)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{bus_monitor_ref: ref} = state)
      when not is_nil(ref) do
    # Bus process went down, wait a moment and re-subscribe
    Logger.info("[Orchestrator] Signal Bus restarted, re-subscribing...")
    Process.send_after(self(), :resubscribe, 100)
    {:noreply, %{state | bus_monitor_ref: nil, subscription_ids: []}}
  end

  def handle_info(:resubscribe, state) do
    new_state = do_subscribe(state)
    Logger.info("[Orchestrator] Re-subscribed to #{length(new_state.subscription_ids)} patterns")
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Unsubscribe from all signals
    Enum.each(state.subscription_ids, &safe_unsubscribe/1)

    # Stop debug agent if running
    if state.debug_agent_id do
      safe_stop_debug_agent(state.debug_agent_id)
    end

    :ok
  end

  # ============================================================================
  # Signal Handlers
  # ============================================================================

  defp handle_signal(signal, state) do
    category = extract_category(signal)
    type = extract_type(signal)
    dispatch_signal({category, type}, signal, state)
  end

  defp dispatch_signal({:demo, :fault_injected}, signal, state),
    do: handle_fault_injected(signal, state)

  defp dispatch_signal({:demo, :fault_cleared}, signal, state),
    do: handle_fault_cleared(signal, state)

  defp dispatch_signal({:monitor, :anomaly_detected}, signal, state),
    do: handle_anomaly_detected(signal, state)

  defp dispatch_signal({:consensus, :proposal_submitted}, signal, state),
    do: handle_proposal_submitted(signal, state)

  defp dispatch_signal({:consensus, :evaluation_started}, signal, state),
    do: handle_evaluation_started(signal, state)

  defp dispatch_signal({:consensus, :decision_made}, signal, state),
    do: handle_decision_made(signal, state)

  defp dispatch_signal({:code, :hot_loaded}, signal, state),
    do: handle_hot_loaded(signal, state)

  defp dispatch_signal({:code, :hot_load_failed}, signal, state),
    do: handle_hot_load_failed(signal, state)

  defp dispatch_signal({:debug_agent, :proposal_created}, signal, state),
    do: handle_debug_agent_proposal(signal, state)

  defp dispatch_signal(_, _signal, state), do: state

  defp handle_fault_injected(signal, state) do
    Logger.info("[Orchestrator] Fault injected, starting DebugAgent")
    data = extract_data(signal)

    # Update pipeline stage
    emit_stage_change(:detect, data)

    # Start debug agent if not already running
    case start_debug_agent() do
      {:ok, agent_id} ->
        %{state | debug_agent_id: agent_id, pipeline_stage: :detect}

      {:error, reason} ->
        Logger.error("[Orchestrator] Failed to start DebugAgent: #{inspect(reason)}")
        %{state | pipeline_stage: :detect}
    end
  end

  defp handle_fault_cleared(_signal, state) do
    Logger.info("[Orchestrator] Fault cleared")
    emit_stage_change(:idle, nil)
    %{state | pipeline_stage: :idle}
  end

  defp handle_anomaly_detected(signal, state) do
    Logger.info("[Orchestrator] Anomaly detected, transitioning to diagnose")
    data = extract_data(signal)
    emit_stage_change(:diagnose, data)

    # Restart DebugAgent if not running (it may have completed before anomaly was detected)
    new_state =
      if state.debug_agent_id == nil or not debug_agent_running?(state.debug_agent_id) do
        Logger.info("[Orchestrator] Starting DebugAgent for diagnosis")

        case start_debug_agent() do
          {:ok, agent_id} -> %{state | debug_agent_id: agent_id}
          {:error, _} -> state
        end
      else
        state
      end

    %{new_state | pipeline_stage: :diagnose}
  end

  defp debug_agent_running?(agent_id) do
    case Arbor.Agent.DebugAgent.get_state(agent_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp handle_proposal_submitted(signal, state) do
    Logger.info("[Orchestrator] Proposal submitted")
    data = extract_data(signal)
    proposal_id = data[:proposal_id]
    emit_stage_change(:propose, data)
    %{state | current_proposal_id: proposal_id, pipeline_stage: :propose}
  end

  defp handle_evaluation_started(signal, state) do
    Logger.info("[Orchestrator] Evaluation started")
    data = extract_data(signal)
    emit_stage_change(:review, data)
    %{state | pipeline_stage: :review}
  end

  defp handle_decision_made(signal, state) do
    data = extract_data(signal)
    decision = data[:decision] || data["decision"]

    case decision do
      :approved ->
        Logger.info("[Orchestrator] Proposal approved, triggering fix")
        emit_stage_change(:fix, data)
        %{state | pipeline_stage: :fix}

      :rejected ->
        Logger.info("[Orchestrator] Proposal rejected")
        reason = data[:reason] || data["reason"] || "Unknown reason"
        emit_stage_change(:rejected, Map.put(data, :rejection_reason, reason))
        %{state | pipeline_stage: :rejected, current_proposal_id: nil}

      _ ->
        Logger.warning("[Orchestrator] Unknown decision: #{inspect(decision)}")
        state
    end
  end

  defp handle_hot_loaded(signal, state) do
    Logger.info("[Orchestrator] Hot-load complete, verifying")
    data = extract_data(signal)
    emit_stage_change(:verify, data)

    # Schedule verification check
    Process.send_after(self(), {:verify_fix, data}, 2_000)

    %{state | pipeline_stage: :verify}
  end

  defp handle_hot_load_failed(signal, state) do
    Logger.error("[Orchestrator] Hot-load failed")
    data = extract_data(signal)
    emit_stage_change(:fix_failed, data)
    %{state | pipeline_stage: :fix_failed}
  end

  defp handle_debug_agent_proposal(signal, state) do
    Logger.info("[Orchestrator] DebugAgent created proposal")
    data = extract_data(signal)
    emit_stage_change(:propose, data)
    %{state | pipeline_stage: :propose}
  end

  # ============================================================================
  # Debug Agent Management
  # ============================================================================

  defp start_debug_agent do
    agent_id = "debug-agent-#{System.system_time(:millisecond)}"

    callbacks = %{
      on_proposal: fn proposal ->
        emit_signal(:debug_agent, :proposal_created, %{proposal: proposal})
      end,
      on_decision: fn decision ->
        emit_signal(:debug_agent, :decision_received, %{decision: decision})
      end
    }

    case DebugAgent.start(agent_id: agent_id, on_proposal: callbacks.on_proposal, on_decision: callbacks.on_decision) do
      {:ok, ^agent_id} ->
        spawn(fn -> run_debug_agent_bounded(agent_id) end)
        {:ok, agent_id}

      {:error, _} = error ->
        error
    end
  rescue
    e ->
      Logger.error("[Orchestrator] Failed to start DebugAgent: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  defp run_debug_agent_bounded(agent_id) do
    case DebugAgent.run_bounded(agent_id, cycles: 10, timeout: 30_000) do
      {:ok, summary} ->
        Logger.info("[Orchestrator] DebugAgent completed: #{inspect(summary)}")

      {:error, reason} ->
        Logger.error("[Orchestrator] DebugAgent failed: #{inspect(reason)}")
    end
  end

  defp safe_stop_debug_agent(agent_id) do
    DebugAgent.stop(agent_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ============================================================================
  # Signal Helpers
  # ============================================================================

  defp subscribe_pattern(pattern) do
    pid = self()

    case Arbor.Signals.subscribe(pattern, fn signal ->
           send(pid, {:signal_received, signal})
           :ok
         end) do
      {:ok, id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_unsubscribe(nil), do: :ok

  defp safe_unsubscribe(subscription_id) do
    Arbor.Signals.unsubscribe(subscription_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp emit_signal(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp emit_stage_change(stage, data) do
    emit_signal(:demo, :pipeline_stage_changed, %{
      stage: stage,
      timestamp: System.system_time(:millisecond),
      data: data
    })
  end

  defp extract_category(signal) do
    # Signal is a struct - use Map.get for safe access
    cat = Map.get(signal, :category) || Map.get(signal, "category")
    to_atom_safe(cat)
  end

  defp extract_type(signal) do
    # Signal is a struct - use Map.get for safe access
    type = Map.get(signal, :type) || Map.get(signal, "type")
    to_atom_safe(type)
  end

  defp extract_data(signal) do
    # Signal struct has .data field
    case Map.get(signal, :data) do
      data when is_map(data) -> data
      data when is_list(data) -> Map.new(data)
      _ -> %{}
    end
  end

  defp to_atom_safe(val) when is_atom(val), do: val

  defp to_atom_safe(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> nil
  end

  defp to_atom_safe(_), do: nil
end
