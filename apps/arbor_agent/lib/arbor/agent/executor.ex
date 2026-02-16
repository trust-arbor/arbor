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

  # H3: Shadow mode disabled — authorize/4 is now the sole authority for
  # capability decisions. can?/3 is still called for divergence logging
  # during the transition period but no longer drives the decision.
  @shadow_mode false

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

  # H5: Enforce sandbox level on action execution. The sandbox_level computed
  # from the agent's trust tier is passed into the action dispatch context.
  defp do_execute(%Intent{type: :act, action: action, params: params}, sandbox_level) do
    Logger.info("Executor: dispatching action=#{inspect(action)} sandbox=#{sandbox_level}")

    # Inject sandbox level into params so actions can respect it
    params_with_sandbox = Map.put(params || %{}, :sandbox, sandbox_level)
    dispatch_action(action, params_with_sandbox)
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
    ai_opts = build_ai_opts()

    Logger.debug("[Executor] AI analyze with opts: #{inspect(ai_opts)}")

    prompt
    |> call_ai_generate(ai_opts)
    |> normalize_ai_result()
  end

  # Proposal submission — map to Proposal.Submit action (runtime call to avoid Level 2 cycle)
  defp dispatch_action(:proposal_submit, params) do
    proposal = params[:proposal] || params["proposal"] || %{}
    submit_params = build_submit_params(proposal)

    # Runtime call to avoid compile-time dependency on arbor_actions
    action_mod = Module.concat([Arbor, Actions, Proposal, Submit])
    run_runtime_action(action_mod, submit_params, :proposal_submit_failed, :consensus_unavailable)
  end

  # Code hot-load — map to Code.HotLoad action (runtime call to avoid Level 2 cycle)
  defp dispatch_action(:code_hot_load, params) do
    module = params[:module] || params["module"]
    code = params[:code] || params[:source] || params["code"] || params["source"]
    do_hot_load(module, code, params)
  end

  # Proposal status — query the status of a submitted proposal
  defp dispatch_action(:proposal_status, params) do
    proposal_id = params[:proposal_id] || params["proposal_id"]
    do_proposal_status(proposal_id)
  end

  # Generic action dispatch — try to find a matching action module
  defp dispatch_action(action, params) when is_atom(action) do
    # Try to find an action module by name convention
    action_module = find_action_module(action)
    run_discovered_action(action_module, action, params)
  end

  defp dispatch_action(action, params) do
    Logger.warning("Executor: invalid action type #{inspect(action)}")
    {:ok, %{action: action, status: :invalid_action_type, params: params}}
  end

  # ============================================================================
  # Action Dispatch Helpers
  # ============================================================================

  # Build AI options based on demo mode configuration
  defp build_ai_opts do
    if demo_mode?() do
      demo_ai_opts()
    else
      [max_tokens: 2000]
    end
  end

  defp demo_ai_opts do
    case get_demo_llm_config() do
      %{provider: provider, model: model} ->
        [max_tokens: 2000, backend: :api, provider: provider, model: model]

      _ ->
        [max_tokens: 2000]
    end
  end

  defp call_ai_generate(prompt, ai_opts) do
    safe_call(fn -> Arbor.AI.generate_text(prompt, ai_opts) end)
  end

  defp normalize_ai_result({:ok, %{text: text}}) do
    {:ok, %{analysis: text, raw_response: text}}
  end

  defp normalize_ai_result({:ok, response}) when is_map(response) do
    text = response[:text] || response["text"] || inspect(response)
    {:ok, %{analysis: text, raw_response: response}}
  end

  defp normalize_ai_result({:error, reason}) do
    {:error, {:ai_analysis_failed, reason}}
  end

  defp normalize_ai_result(nil) do
    {:error, :ai_service_unavailable}
  end

  # Transform DebugAgent proposal format to Submit action format
  defp build_submit_params(proposal) do
    %{
      title: proposal[:title] || "Fix for detected anomaly",
      description: proposal[:description] || proposal[:rationale] || "Auto-generated fix",
      branch: proposal[:branch] || "main",
      evidence: proposal[:evidence] || [],
      urgency: proposal[:urgency] || "high",
      change_type: proposal[:change_type] || "code_modification"
    }
  end

  # Run an action module at runtime via apply, normalizing the result
  defp run_runtime_action(action_mod, params, error_tag, unavailable_tag) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case safe_call(fn -> apply(action_mod, :run, [params, %{}]) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {error_tag, reason}}
      nil -> {:error, unavailable_tag}
    end
  end

  defp do_hot_load(module, code, _params) when is_nil(module) or is_nil(code) do
    {:error, :missing_module_or_code}
  end

  defp do_hot_load(module, code, params) do
    hot_load_params = %{
      module: to_string(module),
      source: code,
      verify_fn: params[:verify_fn],
      rollback_timeout_ms: params[:timeout] || 30_000
    }

    action_mod = Module.concat([Arbor, Actions, Code, HotLoad])
    run_runtime_action(action_mod, hot_load_params, :hot_load_failed, :code_service_unavailable)
  end

  defp do_proposal_status(nil), do: {:error, :missing_proposal_id}

  defp do_proposal_status(proposal_id) do
    consensus_mod = Module.concat([Arbor, Consensus])

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case safe_call(fn -> apply(consensus_mod, :get_status, [proposal_id]) end) do
      {:ok, status} -> {:ok, %{proposal_id: proposal_id, status: status}}
      {:error, reason} -> {:error, {:status_query_failed, reason}}
      nil -> {:error, :consensus_unavailable}
    end
  end

  defp run_discovered_action(nil, action, params) do
    Logger.warning("Executor: unknown action #{inspect(action)}, returning stub result")
    {:ok, %{action: action, status: :no_handler, params: params}}
  end

  defp run_discovered_action(action_module, action, params) do
    case safe_call(fn -> action_module.run(params, %{}) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {action, reason}}
      nil -> {:error, {:action_failed, action}}
    end
  end

  # Get the demo LLM configuration (runtime call to avoid dependency cycle)
  defp get_demo_llm_config do
    Application.get_env(:arbor_demo, :evaluator_llm_config, %{})
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
    Enum.map_join(context, "\n", fn {k, v} -> "- #{k}: #{inspect(v)}" end)
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

  # M12: Use String.to_existing_atom to prevent atom table exhaustion
  defp build_action_module_name(action_str) do
    parts = action_str |> String.split("_")

    case parts do
      [category | rest] when rest != [] ->
        category_mod = category |> String.capitalize()
        action_mod = Enum.map_join(rest, "", &String.capitalize/1)

        module =
          Module.concat([
            Arbor.Actions,
            String.to_existing_atom(category_mod),
            String.to_existing_atom(action_mod)
          ])

        if Code.ensure_loaded?(module), do: module, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
    _ -> nil
  end

  defp build_action_module_from_dotted(action_str) do
    case String.split(action_str, ".") do
      [category, action_name] ->
        category_mod = category |> String.capitalize()
        action_mod = action_name |> Macro.camelize()

        module =
          Module.concat([
            Arbor.Actions,
            String.to_existing_atom(category_mod),
            String.to_existing_atom(action_mod)
          ])

        if Code.ensure_loaded?(module), do: module, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
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
    # Check agent has capability to execute this action
    resource = "arbor://agent/action/#{action}"
    agent_id = state.agent_id

    can_result = check_can(agent_id, resource)
    authorize_result = check_authorize(agent_id, resource)
    maybe_log_shadow_divergence(agent_id, resource, can_result, authorize_result)

    if @shadow_mode, do: can_result, else: authorize_result
  end

  # Fast ETS-only capability check (boolean → :authorized | {:blocked, _})
  defp check_can(agent_id, resource) do
    case safe_call(fn -> Arbor.Security.can?(agent_id, resource, :execute) end) do
      true -> :authorized
      false -> {:blocked, :unauthorized}
      _ -> {:blocked, :security_unavailable}
    end
  end

  # Full authorization pipeline (reflexes, identity, constraints, escalation, audit)
  defp check_authorize(agent_id, resource) do
    case safe_call(fn -> Arbor.Security.authorize(agent_id, resource, :execute) end) do
      {:ok, :authorized} -> :authorized
      {:ok, :pending_approval, _ref} -> {:blocked, :pending_approval}
      {:error, reason} -> {:blocked, reason}
      _ -> {:blocked, :security_unavailable}
    end
  end

  defp maybe_log_shadow_divergence(agent_id, resource, can_result, authorize_result) do
    if can_result != authorize_result do
      Logger.warning(
        "[Executor] Security shadow-mode divergence for agent=#{agent_id} resource=#{resource}: " <>
          "can?=#{inspect(can_result)} authorize=#{inspect(authorize_result)}"
      )
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
