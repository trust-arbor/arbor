defmodule Arbor.Agent.Executor do
  @moduledoc """
  Executes intents from the Mind and returns percepts.

  The Executor is the "Body" side of the Mind-Body architecture. It is the
  imperative shell around `Arbor.Agent.Executor.DecideCore`: it gathers
  sender/reflex/auth verdicts, calls `decide/2`, and interprets the effect
  (`execute` / `skip` / `block` / `ask` / `reject_sender`).

  `:ask` parks the intent (does not fail it) and waits on
  `Arbor.Comms.await_interaction_response/3` in a linked-off waiter so the
  GenServer stays free to process other intents.

  ## States

  - `:running` — actively processing intents
  - `:paused` — subscribed but queueing intents without processing
  - `:stopped` — not processing, no subscription

  ## Example

      {:ok, pid} = Executor.start("agent-1")
      :ok = Executor.pause("agent-1")
      :ok = Executor.resume("agent-1")
      :ok = Executor.stop("agent-1")
  """

  use GenServer

  alias Arbor.Agent.Config
  alias Arbor.Agent.Executor.{ActionDispatch, DecideCore}
  alias Arbor.Contracts.Memory.{Intent, Percept}
  alias Arbor.Contracts.Security.SandboxLevel

  @default_approval_timeout_ms 900_000

  require Logger

  @type state :: %{
          agent_id: String.t(),
          status: :running | :paused | :stopped,
          sandbox_level: atom(),
          intent_subscription: String.t() | nil,
          pending_intents: :queue.queue(),
          current_intent: Intent.t() | nil,
          awaiting_approval: map(),
          approval_timeout_ms: pos_integer(),
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
  Start an executor linked to the calling process (for supervision).
  """
  @spec start_link(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(agent_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {agent_id, opts}, name: via(agent_id))
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
    sandbox_level = SandboxLevel.coerce(Keyword.get(opts, :sandbox_level))

    Logger.info("[Executor] Starting for agent #{agent_id}, sandbox=#{sandbox_level}")

    approval_timeout_ms =
      Keyword.get(opts, :approval_timeout_ms, @default_approval_timeout_ms)

    state = %{
      agent_id: agent_id,
      status: :running,
      sandbox_level: sandbox_level,
      intent_subscription: nil,
      pending_intents: :queue.new(),
      current_intent: nil,
      awaiting_approval: %{},
      approval_timeout_ms: approval_timeout_ms,
      stats: %{
        intents_received: 0,
        intents_executed: 0,
        intents_blocked: 0,
        intents_parked: 0,
        total_duration_ms: 0,
        started_at: DateTime.utc_now()
      }
    }

    # Subscribe to intents via Bridge (non-fatal if unavailable)
    state = subscribe_to_intents(state)
    Logger.debug("[Executor] Subscription result: #{inspect(state.intent_subscription)}")

    safe_emit(:agent, :executor_started, %{
      agent_id: agent_id
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
      pending_count: :queue.len(state.pending_intents),
      awaiting_count: map_size(awaiting_approval(state)),
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

    sender_verdict = authorize_intent_sender(intent, state)

    case sender_verdict do
      {:error, reason} ->
        Logger.warning(
          "[Executor] Intent sender unauthorized: #{inspect(reason)} " <>
            "for intent #{intent.id} targeting #{state.agent_id}"
        )

        {:noreply, process_intent(intent, state, sender_verdict)}

      :ok ->
        case state.status do
          :running ->
            {:noreply, process_intent(intent, state, sender_verdict)}

          :paused ->
            pending = :queue.in(intent, state.pending_intents)
            {:noreply, %{state | pending_intents: pending}}

          :stopped ->
            {:noreply, state}
        end
    end
  end

  def handle_cast({:approval_resolved, intent_id, request_id, result}, state)
      when is_binary(intent_id) do
    {:noreply, resolve_approval(state, intent_id, request_id, result)}
  end

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, reason}, state) do
    {:noreply, waiter_down(state, mon, reason)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.values(awaiting_approval(state)), fn parked ->
      if is_pid(parked.waiter_pid), do: Process.exit(parked.waiter_pid, :shutdown)
    end)

    if state.intent_subscription do
      safe_call(fn -> Arbor.Signals.unsubscribe(state.intent_subscription) end)
    end

    :ok
  end

  # -- Private --

  # H3: Authorize the source of an intent. If the intent names a source_agent
  # (struct field or metadata), verify it holds arbor://agent/intent/{target}.
  # Missing source is treated as self-generated.
  defp authorize_intent_sender(%Intent{} = intent, state) do
    source = intent_source_agent(intent)

    if is_nil(source) or source == state.agent_id do
      :ok
    else
      resource = "arbor://agent/intent/#{state.agent_id}"

      case safe_call(fn -> Arbor.Security.authorize(source, resource, :send) end) do
        {:ok, :authorized} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> {:error, :security_unavailable}
      end
    end
  end

  defp intent_source_agent(%Intent{} = intent) do
    metadata = intent.metadata || %{}

    Map.get(intent, :source_agent) ||
      Map.get(metadata, :source_agent) ||
      Map.get(metadata, "source_agent")
  end

  defp process_intent(%Intent{} = intent, state, sender_verdict \\ :ok) do
    start_time = System.monotonic_time(:millisecond)
    state = %{state | current_intent: intent}

    reflex_verdict =
      case safe_reflex_check(build_reflex_context(intent)) do
        {:blocked, _reflex, _reason} = blocked -> blocked
        _ -> :ok
      end

    {canonical_uri, auth_verdict} = gather_auth(intent, state)

    snapshot = %{
      agent_id: state.agent_id,
      sandbox_level: state.sandbox_level,
      sender_verdict: sender_verdict,
      reflex_verdict: reflex_verdict,
      auth_verdict: auth_verdict,
      canonical_uri: canonical_uri
    }

    apply_decision(DecideCore.decide(intent, snapshot), intent, state, start_time, false)
  end

  defp apply_decision({:reject_sender, reason}, intent, state, _start_time, _from_approval) do
    handle_blocked(intent, {:sender_unauthorized, reason}, state)
  end

  defp apply_decision({:block, reason}, intent, state, _start_time, _from_approval) do
    handle_blocked(intent, reason, state)
  end

  defp apply_decision({:ask, _resource, _meta}, intent, state, _start_time, true) do
    # Ceiling still :ask after a granted approval — do not loop. The one-shot
    # ceiling bypass lives in hitl-approve-once-ceiling-bypass.md.
    handle_blocked(intent, :still_requires_approval, state)
  end

  defp apply_decision({:ask, resource, meta}, intent, state, start_time, false) do
    handle_ask(intent, resource, meta, state, start_time)
  end

  defp apply_decision({:skip, _reason}, intent, state, start_time, _from_approval) do
    finalize_result(intent, state, start_time, mental_result(intent))
  end

  defp apply_decision(
         {:execute, action, params, sandbox},
         intent,
         state,
         start_time,
         from_approval
       ) do
    Logger.info("Executor: dispatching action=#{inspect(action)} sandbox=#{sandbox}")

    result =
      ActionDispatch.dispatch(action, params, state.agent_id, %{
        sandbox_level: state.sandbox_level
      })

    case result do
      {:ok, :pending_approval, id} ->
        apply_decision(
          {:ask, canonical_uri_for(intent), %{approval_id: id}},
          intent,
          state,
          start_time,
          from_approval
        )

      other ->
        finalize_result(intent, drop_awaiting(state, intent.id), start_time, other)
    end
  end

  defp apply_decision(_other, intent, state, _start_time, _from_approval) do
    handle_blocked(intent, :invalid_decision, state)
  end

  defp mental_result(%Intent{type: :think} = intent), do: {:ok, %{thought: intent.reasoning}}
  defp mental_result(%Intent{type: :wait}), do: {:ok, %{status: :waiting}}
  defp mental_result(%Intent{type: :reflect} = intent), do: {:ok, %{reflection: intent.reasoning}}
  defp mental_result(%Intent{type: :internal} = intent), do: {:ok, %{internal: intent.params}}
  defp mental_result(%Intent{}), do: {:error, :unknown_intent_type}

  defp finalize_result(%Intent{} = intent, state, start_time, result) do
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

    safe_call(fn -> Arbor.Memory.emit_percept(state.agent_id, percept) end)
    safe_call(fn -> Arbor.Memory.record_percept(state.agent_id, percept) end)
    complete_or_fail_intent(state.agent_id, intent, outcome)
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
    state = drop_awaiting(state, intent.id)
    percept = Percept.blocked(intent.id, inspect(reason))

    safe_call(fn -> Arbor.Memory.emit_percept(state.agent_id, percept) end)
    safe_call(fn -> Arbor.Memory.record_percept(state.agent_id, percept) end)

    # Mark intent failed in IntentStore so it isn't re-routed
    safe_call(fn ->
      Arbor.Memory.fail_intent(state.agent_id, intent.id, "blocked: #{inspect(reason)}")
    end)

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

  defp handle_ask(%Intent{} = intent, resource, meta, state, start_time) do
    request_id = Map.get(meta, :approval_id) || Map.get(meta, "approval_id")
    awaiting = awaiting_approval(state)

    cond do
      not valid_approval_id?(request_id) ->
        handle_blocked(intent, :missing_approval_id, state)

      Map.has_key?(awaiting, intent.id) ->
        handle_blocked(intent, :still_requires_approval, drop_awaiting(state, intent.id))

      true ->
        park_for_approval(intent, resource, request_id, awaiting, state, start_time)
    end
  end

  defp park_for_approval(intent, resource, request_id, awaiting, state, start_time) do
    {waiter_pid, waiter_mon} = spawn_approval_waiter(state, intent.id, request_id)

    parked = %{
      intent: intent,
      request_id: request_id,
      resource: resource,
      waiter_pid: waiter_pid,
      waiter_mon: waiter_mon,
      started_at_mono: start_time
    }

    percept =
      Percept.new(:action_result, :partial,
        intent_id: intent.id,
        data: %{
          status: :awaiting_approval,
          resource: resource,
          approval_id: request_id
        }
      )

    safe_call(fn -> Arbor.Memory.emit_percept(state.agent_id, percept) end)
    safe_call(fn -> Arbor.Memory.record_percept(state.agent_id, percept) end)
    forward_percept_to_action_cycle(state.agent_id, percept)

    safe_emit(:agent, :intent_awaiting_approval, %{
      agent_id: state.agent_id,
      intent_id: intent.id,
      resource: resource,
      approval_id: request_id
    })

    state
    |> Map.put(:awaiting_approval, Map.put(awaiting, intent.id, parked))
    |> update_in([:stats, :intents_parked], &((&1 || 0) + 1))
    |> Map.put(:current_intent, nil)
  end

  defp valid_approval_id?(id) when is_binary(id) and id != "", do: true
  defp valid_approval_id?(_), do: false

  defp spawn_approval_waiter(_state, _intent_id, request_id)
       when not is_binary(request_id) or request_id == "" do
    {nil, nil}
  end

  defp spawn_approval_waiter(state, intent_id, request_id) do
    executor_pid = self()
    agent_id = state.agent_id
    timeout = Map.get(state, :approval_timeout_ms, @default_approval_timeout_ms)

    spawn_monitor(fn ->
      result = await_approval(request_id, agent_id, timeout)
      GenServer.cast(executor_pid, {:approval_resolved, intent_id, request_id, result})
    end)
  end

  defp await_approval(request_id, agent_id, timeout) do
    mod = Config.executor_interaction_await()

    if function_exported?(mod, :await_interaction_response, 3) do
      mod.await_interaction_response(request_id, agent_id, timeout: timeout)
    else
      {:error, :comms_unavailable}
    end
  rescue
    e -> {:error, {:await_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:await_failed, reason}}
  end

  defp resolve_approval(state, intent_id, request_id, result) do
    case Map.get(awaiting_approval(state), intent_id) do
      %{request_id: ^request_id, intent: intent, waiter_mon: mon} = parked ->
        if is_reference(mon), do: Process.demonitor(mon, [:flush])

        state = drop_awaiting(state, intent_id)
        start_time = Map.get(parked, :started_at_mono, System.monotonic_time(:millisecond))

        if approval_granted?(result) do
          retry_after_approval(intent, state, start_time)
        else
          handle_blocked(intent, {:approval_denied, result}, state)
        end

      _other ->
        state
    end
  end

  defp retry_after_approval(%Intent{} = intent, state, start_time) do
    reflex_verdict =
      case safe_reflex_check(build_reflex_context(intent)) do
        {:blocked, _reflex, _reason} = blocked -> blocked
        _ -> :ok
      end

    {canonical_uri, auth_verdict} = gather_auth(intent, state)

    snapshot = %{
      agent_id: state.agent_id,
      sandbox_level: state.sandbox_level,
      sender_verdict: :ok,
      reflex_verdict: reflex_verdict,
      auth_verdict: auth_verdict,
      canonical_uri: canonical_uri
    }

    apply_decision(DecideCore.decide(intent, snapshot), intent, state, start_time, true)
  end

  defp waiter_down(state, mon, reason) do
    parked =
      Enum.find(awaiting_approval(state), fn {_id, entry} -> entry.waiter_mon == mon end)

    case parked do
      {intent_id, %{intent: intent}} when reason not in [:normal, :shutdown] ->
        handle_blocked(intent, {:approval_waiter_down, reason}, drop_awaiting(state, intent_id))

      _ ->
        state
    end
  end

  defp approval_granted?({:ok, response, _meta}), do: granted_response?(response)
  defp approval_granted?({:ok, response}), do: granted_response?(response)
  defp approval_granted?(_), do: false

  defp granted_response?(response)
       when response in [:approved, :approve, :allow, "approved", "approve", "allow"],
       do: true

  defp granted_response?({:approved, _}), do: true
  defp granted_response?({:approve, _}), do: true
  defp granted_response?(_), do: false

  defp awaiting_approval(state), do: Map.get(state, :awaiting_approval, %{})

  defp drop_awaiting(state, intent_id) do
    Map.put(state, :awaiting_approval, Map.delete(awaiting_approval(state), intent_id))
  end

  defp gather_auth(%Intent{type: type}, _state)
       when type in [:think, :reflect, :wait, :internal] do
    {nil, nil}
  end

  defp gather_auth(%Intent{} = intent, state) do
    resource = canonical_uri_for(intent)

    # Trust.authorize mints under policy then applies ApprovalGuard, so a
    # mintable-but-unheld URI can still return pending_approval. Security.authorize
    # only checks already-held caps and would skip the park path.
    # Sender already verified. Skip identity re-verification — autonomous
    # agents do not carry a signed_request in the heartbeat context.
    verdict =
      case safe_call(fn ->
             Config.executor_authorizer().authorize(
               state.agent_id,
               resource,
               :execute,
               verify_identity: false
             )
           end) do
        {:ok, :authorized} = authorized -> authorized
        {:ok, :pending_approval, _id} = pending -> pending
        {:error, reason} -> {:error, reason}
        _ -> {:error, :security_unavailable}
      end

    {resource, verdict}
  end

  defp canonical_uri_for(%Intent{action: action}) do
    case ActionDispatch.resolve_action_module(action) do
      {:ok, module} -> Arbor.Actions.canonical_uri_for(module, %{})
      :error -> "arbor://agent/action/#{action}"
    end
  end

  defp build_reflex_context(%Intent{action: action, params: params}) do
    context = %{}
    context = if action, do: Map.put(context, :action, action), else: context

    context =
      if params[:command], do: Map.put(context, :command, params[:command]), else: context

    if params[:path], do: Map.put(context, :path, params[:path]), else: context
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
    # Bridge.subscribe_to_intents extracts the Intent from the signal
    # and passes the Intent struct directly to this handler.
    fn %Intent{} = intent ->
      Logger.debug("[Executor] Received intent: #{intent.id}")
      GenServer.cast(executor_pid, {:intent, intent})
    end
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
  defp complete_or_fail_intent(agent_id, %Intent{id: intent_id}, :success) do
    safe_call(fn -> Arbor.Memory.complete_intent(agent_id, intent_id) end)
  end

  defp complete_or_fail_intent(agent_id, %Intent{id: intent_id}, _outcome) do
    safe_call(fn -> Arbor.Memory.fail_intent(agent_id, intent_id, "execution failed") end)
  end

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
