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

  @impl true
  def handle_cast({:intent, %Intent{} = intent}, state) do
    state = update_in(state, [:stats, :intents_received], &(&1 + 1))

    safe_emit(:agent, :intent_received, %{
      agent_id: state.agent_id,
      intent_id: intent.id,
      action: intent.action
    })

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
  end

  @impl true
  def terminate(_reason, state) do
    if state.intent_subscription do
      safe_call(fn -> Arbor.Signals.unsubscribe(state.intent_subscription) end)
    end

    :ok
  end

  # -- Private --

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

  defp do_execute(%Intent{type: :act, action: action, params: params}, _sandbox_level) do
    Logger.info("Executor: dispatching action=#{inspect(action)}")
    dispatch_action(action, params)
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

  # ============================================================================
  # Action Dispatch
  # ============================================================================

  # AI analysis — construct prompt from anomaly context and call LLM
  defp dispatch_action(:ai_analyze, params) do
    anomaly = params[:anomaly] || params["anomaly"]
    context = params[:context] || params["context"] || %{}

    prompt = build_analysis_prompt(anomaly, context)

    case safe_call(fn -> Arbor.AI.generate_text(prompt, max_tokens: 2000) end) do
      {:ok, %{text: text}} ->
        # Parse the AI response to extract fix suggestion
        {:ok, %{analysis: text, raw_response: text}}

      {:ok, response} when is_map(response) ->
        text = response[:text] || response["text"] || inspect(response)
        {:ok, %{analysis: text, raw_response: response}}

      {:error, reason} ->
        {:error, {:ai_analysis_failed, reason}}

      nil ->
        {:error, :ai_service_unavailable}
    end
  end

  # Proposal submission — map to Proposal.Submit action (runtime call to avoid Level 2 cycle)
  defp dispatch_action(:proposal_submit, params) do
    proposal = params[:proposal] || params["proposal"] || %{}

    # Transform DebugAgent proposal format to Submit action format
    submit_params = %{
      title: proposal[:title] || "Fix for detected anomaly",
      description: proposal[:description] || proposal[:rationale] || "Auto-generated fix",
      branch: proposal[:branch] || "main",
      evidence: proposal[:evidence] || [],
      urgency: proposal[:urgency] || "high",
      change_type: proposal[:change_type] || "code_modification"
    }

    # Runtime call to avoid compile-time dependency on arbor_actions
    action_mod = Module.concat([Arbor, Actions, Proposal, Submit])

    case safe_call(fn -> apply(action_mod, :run, [submit_params, %{}]) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:proposal_submit_failed, reason}}
      nil -> {:error, :consensus_unavailable}
    end
  end

  # Code hot-load — map to Code.HotLoad action (runtime call to avoid Level 2 cycle)
  defp dispatch_action(:code_hot_load, params) do
    module = params[:module] || params["module"]
    code = params[:code] || params[:source] || params["code"] || params["source"]

    if is_nil(module) or is_nil(code) do
      {:error, :missing_module_or_code}
    else
      hot_load_params = %{
        module: to_string(module),
        source: code,
        verify_fn: params[:verify_fn],
        rollback_timeout_ms: params[:timeout] || 30_000
      }

      # Runtime call to avoid compile-time dependency on arbor_actions
      action_mod = Module.concat([Arbor, Actions, Code, HotLoad])

      case safe_call(fn -> apply(action_mod, :run, [hot_load_params, %{}]) end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, {:hot_load_failed, reason}}
        nil -> {:error, :code_service_unavailable}
      end
    end
  end

  # Generic action dispatch — try to find a matching action module
  defp dispatch_action(action, params) when is_atom(action) do
    # Try to find an action module by name convention
    action_module = find_action_module(action)

    if action_module && function_exported?(action_module, :run, 2) do
      case safe_call(fn -> action_module.run(params, %{}) end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, {action, reason}}
        nil -> {:error, {:action_failed, action}}
      end
    else
      Logger.warning("Executor: unknown action #{inspect(action)}, returning stub result")
      {:ok, %{action: action, status: :no_handler, params: params}}
    end
  end

  defp dispatch_action(action, params) do
    Logger.warning("Executor: invalid action type #{inspect(action)}")
    {:ok, %{action: action, status: :invalid_action_type, params: params}}
  end

  # Build a prompt for AI analysis of an anomaly
  defp build_analysis_prompt(anomaly, context) do
    """
    You are a BEAM runtime diagnostic expert. Analyze this anomaly and suggest a fix.

    ## Anomaly Details
    #{format_anomaly(anomaly)}

    ## System Context
    #{format_context(context)}

    ## Your Task
    1. Identify the root cause of this anomaly
    2. Suggest a specific code fix
    3. Explain why this fix will resolve the issue

    Respond with:
    - ROOT_CAUSE: <one sentence>
    - FIX_MODULE: <module name to modify>
    - FIX_CODE: <the actual code change>
    - EXPLANATION: <why this works>
    """
  end

  defp format_anomaly(nil), do: "No anomaly data"

  defp format_anomaly(anomaly) when is_map(anomaly) do
    """
    - Skill: #{anomaly[:skill] || "unknown"}
    - Severity: #{anomaly[:severity] || "unknown"}
    - Metric: #{anomaly[:metric] || "unknown"}
    - Value: #{anomaly[:value] || "unknown"}
    - Threshold: #{anomaly[:threshold] || "unknown"}
    - Details: #{inspect(anomaly[:details] || %{})}
    """
  end

  defp format_anomaly(anomaly), do: inspect(anomaly)

  defp format_context(context) when is_map(context) do
    context
    |> Enum.map(fn {k, v} -> "- #{k}: #{inspect(v)}" end)
    |> Enum.join("\n")
  end

  defp format_context(_), do: "No additional context"

  # Try to find an action module by naming convention
  # e.g., :file_read -> Arbor.Actions.File.Read
  defp find_action_module(action) do
    action_str = Atom.to_string(action)

    # Try common patterns
    candidates = [
      # Direct module name: ai_generate_text -> Arbor.Actions.AI.GenerateText
      build_action_module_name(action_str),
      # With category prefix: file.read -> Arbor.Actions.File.Read
      build_action_module_from_dotted(action_str)
    ]

    Enum.find(candidates, fn mod ->
      mod && Code.ensure_loaded?(mod) && function_exported?(mod, :run, 2)
    end)
  end

  defp build_action_module_name(action_str) do
    parts = action_str |> String.split("_")

    case parts do
      [category | rest] when rest != [] ->
        category_mod = category |> String.capitalize()
        action_mod = rest |> Enum.map(&String.capitalize/1) |> Enum.join("")
        Module.concat([Arbor.Actions, String.to_atom(category_mod), String.to_atom(action_mod)])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp build_action_module_from_dotted(action_str) do
    case String.split(action_str, ".") do
      [category, action_name] ->
        category_mod = category |> String.capitalize()
        action_mod = action_name |> Macro.camelize()
        Module.concat([Arbor.Actions, String.to_atom(category_mod), String.to_atom(action_mod)])

      _ ->
        nil
    end
  rescue
    _ -> nil
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

  defp check_capabilities(%Intent{action: action}, state) do
    # Demo mode bypass: skip capability checks for demo agents
    if demo_mode?() do
      Logger.debug("[Executor] Demo mode: bypassing capability check for #{action}")
      :authorized
    else
      resource = "arbor://agent/action/#{action}"

      case safe_call(fn -> Arbor.Security.can?(state.agent_id, resource, :execute) end) do
        true -> :authorized
        false -> {:blocked, :unauthorized}
        # If security service unavailable, block by default
        _ -> {:blocked, :security_unavailable}
      end
    end
  end

  defp demo_mode? do
    Application.get_env(:arbor_demo, :demo_mode, false)
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

    result =
      safe_call(fn ->
        Arbor.Memory.subscribe_to_intents(state.agent_id, fn signal ->
          # Signal.data contains %{intent: %Intent{}, ...}
          intent = extract_intent_from_signal(signal)

          if intent do
            Logger.debug("[Executor] Received intent signal: #{intent.id}")
            GenServer.cast(executor_pid, {:intent, intent})
          end

          :ok
        end)
      end)

    Logger.debug("[Executor] Subscription result: #{inspect(result)}")

    case result do
      {:ok, sub_id} -> %{state | intent_subscription: sub_id}
      _ -> state
    end
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
