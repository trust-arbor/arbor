defmodule Arbor.Agent.Executor do
  @moduledoc """
  Executes intents from the Mind and returns percepts.

  The Executor is the "Body" side of the Mind-Body architecture. It receives
  intents via Bridge subscription, checks reflexes and capabilities, executes
  in a sandbox appropriate for the agent's trust tier, and returns percepts.

  ## States

  - `:running` — actively processing intents
  - `:paused` — subscribed but queueing intents without processing
  - `:stopped` — not processing, no subscription

  ## Example

      {:ok, pid} = Executor.start("agent-1", trust_tier: :probationary)
      :ok = Executor.pause("agent-1")
      :ok = Executor.resume("agent-1")
      :ok = Executor.stop("agent-1")
  """

  use GenServer

  alias Arbor.Agent.Executor.ActionDispatch
  alias Arbor.Contracts.Memory.{Intent, Percept}
  alias Arbor.Contracts.Security.TrustBounds

  require Logger

  @type state :: %{
          agent_id: String.t(),
          status: :running | :paused | :stopped,
          trust_tier: atom(),
          intent_subscription: String.t() | nil,
          pending_intents: :queue.queue(),
          current_intent: Intent.t() | nil,
          stats: map()
        }

  # -- Public API --

  @doc """
  Start an executor for the given agent.
  """
  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(agent_id, opts \\ []) do
    GenServer.start(__MODULE__, {agent_id, opts}, name: via(agent_id))
  end

  @doc """
  Pause intent processing. Intents are queued but not executed.
  """
  @spec pause(String.t()) :: :ok | {:error, :not_running | :not_found}
  def pause(agent_id) do
    call(agent_id, :pause)
  end

  @doc """
  Resume intent processing from paused state.
  """
  @spec resume(String.t()) :: :ok | {:error, :not_paused | :not_found}
  def resume(agent_id) do
    call(agent_id, :resume)
  end

  @doc """
  Stop the executor.
  """
  @spec stop(String.t()) :: :ok
  def stop(agent_id) do
    case GenServer.whereis(via(agent_id)) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc """
  Get executor status and stats.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(agent_id) do
    call(agent_id, :status)
  end

  @doc """
  Submit an intent for execution (used when Bridge is not yet wired).
  """
  @spec execute(String.t(), Intent.t()) :: :ok | {:error, :not_found}
  def execute(agent_id, %Intent{} = intent) do
    case GenServer.whereis(via(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:intent, intent})
    end
  end

  # -- GenServer Callbacks --

  @impl true
  def init({agent_id, opts}) do
    trust_tier = Keyword.get(opts, :trust_tier, :untrusted)

    Logger.info("[Executor] Starting for agent #{agent_id}, trust_tier=#{trust_tier}")

    state = %{
      agent_id: agent_id,
      status: :running,
      trust_tier: trust_tier,
      intent_subscription: nil,
      pending_intents: :queue.new(),
      current_intent: nil,
      stats: %{
        intents_received: 0,
        intents_executed: 0,
        intents_blocked: 0,
        total_duration_ms: 0,
        started_at: DateTime.utc_now()
      }
    }

    # Subscribe to intents via Bridge (non-fatal if unavailable)
    state = subscribe_to_intents(state)
    Logger.debug("[Executor] Subscription result: #{inspect(state.intent_subscription)}")

    safe_emit(:agent, :executor_started, %{
      agent_id: agent_id,
      trust_tier: trust_tier
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:pause, _from, %{status: :running} = state) do
    safe_emit(:agent, :executor_paused, %{agent_id: state.agent_id})
    {:reply, :ok, %{state | status: :paused}}
  end

  def handle_call(:pause, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call(:resume, _from, %{status: :paused} = state) do
    safe_emit(:agent, :executor_resumed, %{agent_id: state.agent_id})
    state = %{state | status: :running}
    state = drain_pending(state)
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    {:reply, {:error, :not_paused}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      agent_id: state.agent_id,
      status: state.status,
      trust_tier: state.trust_tier,
      pending_count: :queue.len(state.pending_intents),
      stats: state.stats
    }

    {:reply, {:ok, info}, state}
  end

  # H3: Authorize intent source before processing. The intent's source_agent
  # must hold a capability for arbor://agent/intent/{target_agent_id}.
  @impl true
  def handle_cast({:intent, %Intent{} = intent}, state) do
    state = update_in(state, [:stats, :intents_received], &(&1 + 1))

    safe_emit(:agent, :intent_received, %{
      agent_id: state.agent_id,
      intent_id: intent.id,
      action: intent.action
    })

    # Authorize the intent sender (if source_agent is available)
    case authorize_intent_sender(intent, state) do
      :ok ->
        case state.status do
          :running ->
            state = process_intent(intent, state)
            {:noreply, state}

          :paused ->
            pending = :queue.in(intent, state.pending_intents)
            {:noreply, %{state | pending_intents: pending}}

          :stopped ->
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning(
          "[Executor] Intent sender unauthorized: #{inspect(reason)} " <>
            "for intent #{intent.id} targeting #{state.agent_id}"
        )

        handle_blocked(intent, {:sender_unauthorized, reason}, state)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.intent_subscription do
      safe_call(fn -> Arbor.Signals.unsubscribe(state.intent_subscription) end)
    end

    :ok
  end

  # -- Private --

  # H3: Authorize the source of an intent. If the intent has a source_agent,
  # verify it holds a capability for sending intents to this agent.
  # Intents without source_agent (self-generated) are allowed.
  defp authorize_intent_sender(%Intent{} = intent, state) do
    source = Map.get(intent, :source_agent, nil)

    cond do
      is_nil(source) ->
        # Self-generated intents (from the agent's own Mind) — always allowed
        :ok

      source == state.agent_id ->
        # Agent sending intents to itself — always allowed
        :ok

      true ->
        resource = "arbor://agent/intent/#{state.agent_id}"

        case safe_call(fn -> Arbor.Security.authorize(source, resource, :send) end) do
          {:ok, :authorized} -> :ok
          {:error, reason} -> {:error, reason}
          _ -> {:error, :security_unavailable}
        end
    end
  end

  defp process_intent(%Intent{} = intent, state) do
    start_time = System.monotonic_time(:millisecond)
    state = %{state | current_intent: intent}

    # Step 1: Check reflexes
    reflex_context = build_reflex_context(intent)

    case safe_reflex_check(reflex_context) do
      {:blocked, _reflex, reason} ->
        handle_blocked(intent, reason, state)

      _ ->
        # Step 2: Check capabilities
        case check_capabilities(intent, state) do
          :authorized ->
            # Step 3: Execute
            execute_intent(intent, state, start_time)

          {:blocked, reason} ->
            handle_blocked(intent, reason, state)
        end
    end
  end

  defp execute_intent(%Intent{} = intent, state, start_time) do
    sandbox_level = TrustBounds.sandbox_for_tier(state.trust_tier)

    result = do_execute(intent, sandbox_level)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    {outcome, data, error} =
      case result do
        {:ok, result_data} -> {:success, result_data, nil}
        {:error, reason} -> {:failure, %{}, reason}
      end

    percept =
      Percept.new(:action_result, outcome,
        intent_id: intent.id,
        data: data,
        error: error,
        duration_ms: duration_ms
      )

    # Emit percept via Bridge (non-fatal if unavailable)
    safe_call(fn -> Arbor.Memory.emit_percept(state.agent_id, percept) end)
    safe_call(fn -> Arbor.Memory.record_percept(state.agent_id, percept) end)

    # Forward percept to ActionCycleServer for Mind processing
    forward_percept_to_action_cycle(state.agent_id, percept)

    safe_emit(:agent, :intent_executed, %{
      agent_id: state.agent_id,
      intent_id: intent.id,
      outcome: outcome,
      duration_ms: duration_ms
    })

    state
    |> update_in([:stats, :intents_executed], &(&1 + 1))
    |> update_in([:stats, :total_duration_ms], &(&1 + duration_ms))
    |> Map.put(:current_intent, nil)
  end

  defp handle_blocked(%Intent{} = intent, reason, state) do
    percept = Percept.blocked(intent.id, inspect(reason))

    safe_call(fn -> Arbor.Memory.emit_percept(state.agent_id, percept) end)
    safe_call(fn -> Arbor.Memory.record_percept(state.agent_id, percept) end)

    # Forward blocked percept to ActionCycleServer for Mind awareness
    forward_percept_to_action_cycle(state.agent_id, percept)

    safe_emit(:agent, :intent_blocked, %{
      agent_id: state.agent_id,
      intent_id: intent.id,
      reason: reason
    })

    state
    |> update_in([:stats, :intents_blocked], &(&1 + 1))
    |> Map.put(:current_intent, nil)
  end

  defp do_execute(%Intent{type: :think} = intent, _sandbox_level) do
    {:ok, %{thought: intent.reasoning}}
  end

  # H5: Enforce sandbox level on action execution. The sandbox_level computed
  # from the agent's trust tier is passed into the action dispatch context.
  defp do_execute(%Intent{type: :act, action: action, params: params}, sandbox_level) do
    Logger.info("Executor: dispatching action=#{inspect(action)} sandbox=#{sandbox_level}")

    # Inject sandbox level into params so actions can respect it
    params_with_sandbox = Map.put(params || %{}, :sandbox, sandbox_level)
    ActionDispatch.dispatch(action, params_with_sandbox)
  end

  defp do_execute(%Intent{type: :wait}, _sandbox_level) do
    {:ok, %{status: :waiting}}
  end

  defp do_execute(%Intent{type: :reflect} = intent, _sandbox_level) do
    {:ok, %{reflection: intent.reasoning}}
  end

  defp do_execute(%Intent{type: :internal} = intent, _sandbox_level) do
    {:ok, %{internal: intent.params}}
  end

  defp do_execute(%Intent{}, _sandbox_level) do
    {:error, :unknown_intent_type}
  end

  defp build_reflex_context(%Intent{action: action, params: params}) do
    context = %{}
    context = if action, do: Map.put(context, :action, action), else: context

    context =
      if params[:command], do: Map.put(context, :command, params[:command]), else: context

    if params[:path], do: Map.put(context, :path, params[:path]), else: context
  end

  defp check_capabilities(%Intent{type: type}, _state)
       when type in [:think, :reflect, :wait, :internal] do
    :authorized
  end

  # P0-2: Use full authorize/4 pipeline directly (reflexes, identity,
  # constraints, escalation, audit). Shadow mode removed — can?/3 is only
  # for UI hints, not security decisions.
  #
  # URI unification: use the canonical dotted name format matching ToolBridge
  # (e.g., "arbor://actions/execute/file.read" instead of "arbor://agent/action/file_read").
  # Falls back to old format for actions without a discoverable module.
  defp check_capabilities(%Intent{action: action}, state) do
    resource =
      case ActionDispatch.canonical_action_name(action) do
        {:ok, name} -> "arbor://actions/execute/#{name}"
        :error -> "arbor://agent/action/#{action}"
      end

    case safe_call(fn -> Arbor.Security.authorize(state.agent_id, resource, :execute) end) do
      {:ok, :authorized} -> :authorized
      {:ok, :pending_approval, _ref} -> {:blocked, :pending_approval}
      {:error, reason} -> {:blocked, reason}
      _ -> {:blocked, :security_unavailable}
    end
  end

  defp drain_pending(state) do
    case :queue.out(state.pending_intents) do
      {:empty, _} ->
        state

      {{:value, intent}, rest} ->
        state = %{state | pending_intents: rest}
        state = process_intent(intent, state)
        drain_pending(state)
    end
  end

  defp subscribe_to_intents(state) do
    # Capture the Executor's PID - the handler runs in a spawned async process
    # so self() inside the handler would return the wrong PID
    executor_pid = self()

    Logger.debug("[Executor] Subscribing to intents for #{state.agent_id}")

    handler = build_intent_handler(executor_pid)
    result = safe_call(fn -> Arbor.Memory.subscribe_to_intents(state.agent_id, handler) end)

    Logger.debug("[Executor] Subscription result: #{inspect(result)}")

    case result do
      {:ok, sub_id} -> %{state | intent_subscription: sub_id}
      _ -> state
    end
  end

  defp build_intent_handler(executor_pid) do
    fn signal ->
      # Signal.data contains %{intent: %Intent{}, ...}
      intent = extract_intent_from_signal(signal)
      maybe_forward_intent(intent, executor_pid)
      :ok
    end
  end

  defp maybe_forward_intent(nil, _executor_pid), do: :ok

  defp maybe_forward_intent(intent, executor_pid) do
    Logger.debug("[Executor] Received intent signal: #{intent.id}")
    GenServer.cast(executor_pid, {:intent, intent})
  end

  defp extract_intent_from_signal(signal) do
    data = Map.get(signal, :data) || %{}
    data[:intent] || data["intent"]
  end

  defp safe_reflex_check(context) do
    safe_call(fn -> Arbor.Security.check_reflex(context) end) || :ok
  end

  defp safe_emit(category, type, data) do
    safe_call(fn -> Arbor.Signals.emit(category, type, data) end)
  end

  # Safely call an external service. Returns the result or nil on failure.
  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("Executor safe_call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("Executor safe_call caught exit: #{inspect(reason)}")
      nil
  end

  # Forward execution results to ActionCycleServer so the Mind can process them.
  # Converts Percept struct to a plain map (ActionCycleServer expects maps).
  defp forward_percept_to_action_cycle(agent_id, %Percept{} = percept) do
    action_cycle = Arbor.Agent.ActionCycleSupervisor

    if Code.ensure_loaded?(action_cycle) do
      case apply(action_cycle, :lookup, [agent_id]) do
        {:ok, pid} ->
          percept_map =
            percept
            |> Map.from_struct()
            |> Map.update(:created_at, nil, fn
              %DateTime{} = dt -> DateTime.to_iso8601(dt)
              other -> other
            end)

          send(pid, {:percept, percept_map})

        :error ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp via(agent_id) do
    {:via, Registry, {Arbor.Agent.ExecutorRegistry, agent_id}}
  end

  defp call(agent_id, msg) do
    case GenServer.whereis(via(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, msg)
    end
  end
end
