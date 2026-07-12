defmodule Arbor.Agent.ActionCycleServer do
  @moduledoc """
  Event-driven action cycle GenServer — the sole state mutator for agent data.

  Unlike MaintenanceServer (timer-based), ActionCycleServer runs only when
  percepts arrive. It processes a queue of percepts through the CycleController
  (Mind LLM), which may produce mental actions (read/write memory) and
  optionally a physical intent (execute a tool).

  ## Percept Sources

  - User chat messages (forwarded from Session)
  - Heartbeat notification percepts ("3 proposals waiting")
  - Maintenance awareness percepts ("5 entries deduped")
  - Action execution results (tool output → new percept)

  ## Processing Model

  1. Percept arrives → enqueued
  2. If no cycle in flight → dequeue oldest percept, start cycle
  3. CycleController runs mental loop (unlimited mental actions, one physical)
  4. Physical intent dispatched → result becomes new percept (currently
     no-op, see `.arbor/roadmap/0-inbox/physical-intent-dispatch-not-implemented.md`)
  5. Repeat until queue empty or throttle limit hit

  ## Throttling

  After `:action_cycle_max_consecutive` cycles without an empty queue, the
  server pauses and resets — waiting for the next percept to resume. This
  prevents runaway loops.

  ## Configuration

  All limits are configurable via `Application.get_env(:arbor_agent, key, default)`.
  """

  use GenServer

  alias Arbor.Agent.MindPrompt
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest, SigningAuthority}

  require Logger

  @default_max_consecutive 10
  @default_cycle_timeout 60_000
  @default_queue_max 50

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Start an ActionCycleServer linked to the caller.

  ## Required options

    * `:agent_id` — the agent this server serves

  ## Optional

    * `:name` — GenServer name registration
    * `:llm_fn` — injectable LLM function for testing
    * `:action_cycle_max_consecutive` — max cycles before throttle (default #{@default_max_consecutive})
    * `:action_cycle_timeout` — per-cycle timeout in ms (default #{@default_cycle_timeout})
    * `:action_cycle_queue_max` — max queued percepts (default #{@default_queue_max})
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Enqueue a percept for processing.

  The percept map should have at least a `:type` key.
  """
  @spec enqueue_percept(pid() | String.t(), map()) :: :ok
  def enqueue_percept(pid, percept) when is_pid(pid) do
    send(pid, {:percept, percept})
    :ok
  end

  def enqueue_percept(agent_id, percept) when is_binary(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} ->
        send(pid, {:percept, percept})
        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Get action cycle statistics.
  """
  @spec stats(pid() | String.t()) :: map()
  def stats(pid) when is_pid(pid), do: GenServer.call(pid, :stats)

  def stats(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :stats)
      :error -> %{error: :not_running}
    end
  end

  @doc """
  Drain the queue by processing all pending percepts. For testing.
  """
  @spec drain_queue(pid()) :: :ok
  def drain_queue(pid) when is_pid(pid), do: GenServer.call(pid, :drain_queue, 30_000)

  @doc false
  @spec close_bootstrap(pid()) :: :ok | {:error, term()}
  def close_bootstrap(pid) when is_pid(pid), do: GenServer.call(pid, :close_bootstrap)

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    with {:ok, {signing_authority, legacy_signer, bootstrap}} <-
           authenticate_cycle_credential(agent_id, opts) do
      llm_fn = Keyword.get(opts, :llm_fn) || make_default_llm_fn(agent_id, opts)

      state = %{
        agent_id: agent_id,
        signing_authority: signing_authority,
        signer: legacy_signer,
        signing_authority_bootstrap: bootstrap,
        queue: :queue.new(),
        cycle_in_flight: false,
        cycle_count: 0,
        consecutive_cycles: 0,
        config: build_config(opts),
        llm_fn: llm_fn
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:action_cycle_authentication_failed, reason}}
    end
  end

  defp authenticate_cycle_credential(agent_id, opts) do
    case Keyword.fetch(opts, :signing_authority_bootstrap) do
      {:ok, bootstrap} ->
        with :ok <- reject_mixed_signer(Keyword.get(opts, :signer)),
             {:ok, authority} <- claim_signing_authority(bootstrap) do
          {:ok, {authority, nil, bootstrap}}
        end

      :error ->
        with {:ok, signer} <- authenticate_cycle_signer(agent_id, Keyword.get(opts, :signer)) do
          {:ok, {nil, signer, nil}}
        end
    end
  end

  defp reject_mixed_signer(nil), do: :ok
  defp reject_mixed_signer(_), do: {:error, :mixed_signing_credentials}

  @authority_claim_attempts 3
  @authority_claim_delay_ms 10

  defp claim_signing_authority(bootstrap, attempts_left \\ @authority_claim_attempts) do
    case Arbor.Security.claim_signing_authority(bootstrap) do
      {:ok, authority} ->
        {:ok, authority}

      {:error, :authority_already_claimed} when attempts_left > 1 ->
        Process.sleep(@authority_claim_delay_ms)
        claim_signing_authority(bootstrap, attempts_left - 1)

      {:error, reason} ->
        {:error, {:signing_authority_claim_failed, reason}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      agent_id: state.agent_id,
      queue_depth: :queue.len(state.queue),
      cycle_in_flight: state.cycle_in_flight,
      cycle_count: state.cycle_count,
      consecutive_cycles: state.consecutive_cycles,
      config: state.config
    }

    {:reply, stats, state}
  end

  def handle_call(:close_bootstrap, _from, state) do
    case close_bootstrap_state(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:drain_queue, _from, state) do
    state = drain_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:percept, percept}, state) do
    emit_signal(state.agent_id, :percept_received, %{
      agent_id: state.agent_id,
      percept_type: Map.get(percept, :type)
    })

    state = enqueue(state, percept)
    state = maybe_start_cycle(state)
    {:noreply, state}
  end

  def handle_info({:cycle_result, result}, state) do
    state = handle_cycle_result(state, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Cycle task crashed — reset in_flight and try next
    state = %{state | cycle_in_flight: false, consecutive_cycles: 0}
    state = maybe_start_cycle(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) when reason in [:normal, :shutdown] do
    _ = close_bootstrap_state(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp close_bootstrap_state(%{signing_authority_bootstrap: nil} = state), do: {:ok, state}

  defp close_bootstrap_state(%{signing_authority_bootstrap: bootstrap} = state) do
    case Arbor.Security.close_signing_authority_bootstrap(bootstrap) do
      :ok -> {:ok, %{state | signing_authority_bootstrap: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Queue Management ────────────────────────────────────────────

  defp enqueue(state, percept) do
    max = config_val(state, :queue_max, @default_queue_max)
    queue = state.queue

    if :queue.len(queue) >= max do
      # Drop oldest to make room
      {{:value, _dropped}, queue} = :queue.out(queue)
      Logger.debug("[ActionCycle] #{state.agent_id}: queue overflow, dropping oldest percept")
      %{state | queue: :queue.in(percept, queue)}
    else
      %{state | queue: :queue.in(percept, queue)}
    end
  end

  # ── Cycle Control ───────────────────────────────────────────────

  defp maybe_start_cycle(%{cycle_in_flight: true} = state), do: state

  defp maybe_start_cycle(%{queue: queue} = state) do
    if :queue.is_empty(queue) do
      %{state | consecutive_cycles: 0}
    else
      max = config_val(state, :max_consecutive, @default_max_consecutive)

      if state.consecutive_cycles >= max do
        Logger.warning(
          "[ActionCycle] #{state.agent_id}: throttled after #{max} consecutive cycles"
        )

        emit_signal(state.agent_id, :action_cycle_throttled, %{
          agent_id: state.agent_id,
          count: max,
          queue_depth: :queue.len(queue)
        })

        %{state | consecutive_cycles: 0}
      else
        start_cycle(state)
      end
    end
  end

  defp start_cycle(state) do
    {{:value, percept}, queue} = :queue.out(state.queue)
    agent_id = state.agent_id
    timeout = config_val(state, :cycle_timeout, @default_cycle_timeout)
    llm_fn = state.llm_fn
    signing_credential = state.signing_authority || state.signer

    emit_signal(agent_id, :action_cycle_started, %{
      agent_id: agent_id,
      percept_type: Map.get(percept, :type),
      queue_depth: :queue.len(queue)
    })

    parent = self()

    Task.start(fn ->
      result = run_cycle(agent_id, parent, percept, llm_fn, signing_credential, timeout)
      send(parent, {:cycle_result, result})
    end)

    %{state | queue: queue, cycle_in_flight: true}
  end

  defp run_cycle(agent_id, owner_pid, percept, llm_fn, signing_credential, timeout) do
    controller = Arbor.Agent.CycleController

    if Code.ensure_loaded?(controller) and function_exported?(controller, :run, 2) do
      opts = [timeout: timeout, last_percept: percept]
      opts = if llm_fn, do: Keyword.put(opts, :llm_fn, llm_fn), else: opts

      try do
        case apply(controller, :run, [agent_id, opts]) do
          {:intent, intent, percepts} ->
            exec_result =
              dispatch_physical_intent(agent_id, owner_pid, intent, signing_credential)

            {:completed, %{intent: intent, percepts: percepts, exec_result: exec_result}}

          {:wait, percepts} ->
            {:completed, %{intent: nil, percepts: percepts, exec_result: nil}}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e -> {:error, {:cycle_crash, Exception.message(e)}}
      catch
        :exit, reason -> {:error, {:cycle_exit, reason}}
      end
    else
      {:error, :cycle_controller_unavailable}
    end
  end

  defp handle_cycle_result(state, {:completed, result}) do
    agent_id = state.agent_id

    emit_signal(agent_id, :action_cycle_completed, %{
      agent_id: agent_id,
      had_intent: result.intent != nil,
      cycle_count: state.cycle_count + 1
    })

    # If physical intent was executed, its result becomes a new percept
    state =
      case result.exec_result do
        {:ok, exec_percept} when is_map(exec_percept) ->
          enqueue(state, exec_percept)

        _ ->
          state
      end

    state = %{
      state
      | cycle_in_flight: false,
        cycle_count: state.cycle_count + 1,
        consecutive_cycles: state.consecutive_cycles + 1
    }

    maybe_start_cycle(state)
  end

  defp handle_cycle_result(state, {:error, reason}) do
    Logger.warning("[ActionCycle] #{state.agent_id}: cycle error: #{inspect(reason)}")

    emit_signal(state.agent_id, :action_cycle_error, %{
      agent_id: state.agent_id,
      reason: inspect(reason)
    })

    state = %{state | cycle_in_flight: false, consecutive_cycles: 0}
    maybe_start_cycle(state)
  end

  # ── Physical Intent Dispatch ────────────────────────────────────

  defp dispatch_physical_intent(agent_id, owner_pid, intent, signing_credential) do
    normalized = normalize_intent(intent)

    emit_signal(agent_id, :intent_dispatched, %{
      agent_id: agent_id,
      capability: normalized.capability,
      op: normalized.op,
      action: normalized.action
    })

    case Registry.lookup(Arbor.Agent.ActionCycleRegistry, agent_id) do
      [{^owner_pid, _value}] ->
        with {:ok, prepared} <- Arbor.Agent.IntentDispatcher.prepare(normalized),
             {:ok, authority_context} <-
               sign_action_context(agent_id, prepared.resource, signing_credential) do
          Arbor.Agent.IntentDispatcher.dispatch(
            agent_id,
            prepared.intent,
            dispatcher_opts(agent_id, authority_context)
          )
        end

      _other ->
        {:error, :action_cycle_principal_unbound}
    end
  end

  # Tolerate either a real %Intent{} or a plain map — CycleController
  # may emit either depending on harness. Convert via `Intent.from_map/1`
  # when a plain map is received.
  defp normalize_intent(%Arbor.Contracts.Memory.Intent{} = intent), do: intent
  defp normalize_intent(map) when is_map(map), do: Arbor.Contracts.Memory.Intent.from_map(map)

  # Workspace lookup is best-effort — we want the dispatcher to thread
  # `context[:workspace]` into file actions when available, but a
  # missing/unavailable profile shouldn't block intent execution. The
  # action will run without workspace bounding in that case.
  defp dispatcher_opts(agent_id, authority_context) do
    [context: authority_context]
    |> maybe_put_dispatcher_workspace(workspace_for_agent(agent_id))
  end

  defp maybe_put_dispatcher_workspace(opts, nil), do: opts

  defp maybe_put_dispatcher_workspace(opts, workspace),
    do: Keyword.put(opts, :workspace, workspace)

  defp authenticate_cycle_signer(_agent_id, nil), do: {:ok, nil}

  defp authenticate_cycle_signer(agent_id, signer)
       when is_binary(agent_id) and is_function(signer, 1) do
    payload = cycle_authentication_payload(agent_id)

    with {:ok, %SignedRequest{} = signed_request} <- call_signer(signer, payload),
         :ok <- validate_signed_request_binding(signed_request, agent_id, payload),
         {:ok, ^agent_id} <- Arbor.Security.verify_request(signed_request) do
      {:ok, signer}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_cycle_signer}
    end
  end

  defp authenticate_cycle_signer(_agent_id, _signer), do: {:error, :invalid_cycle_signer}

  defp sign_action_context(_agent_id, _resource, nil),
    do: {:error, :authenticated_principal_required}

  defp sign_action_context(agent_id, resource, %SigningAuthority{} = authority) do
    with {:ok, %SignedRequest{} = signed_request} <-
           Arbor.Security.sign_with_authority(authority, resource),
         :ok <- validate_signed_request_binding(signed_request, agent_id, resource),
         {:ok, ^agent_id} <- Arbor.Security.verify_request(signed_request) do
      auth_context =
        AuthContext.new(agent_id, signed_request: signed_request)
        |> AuthContext.mark_verified()

      {:ok, %{agent_id: agent_id, signed_request: signed_request, auth_context: auth_context}}
    else
      {:error, reason} -> {:error, {:action_cycle_authority_signing_failed, reason}}
      _other -> {:error, {:action_cycle_authority_signing_failed, :invalid_signed_request}}
    end
  end

  defp sign_action_context(agent_id, resource, signer) when is_function(signer, 1) do
    with {:ok, %SignedRequest{} = signed_request} <- call_signer(signer, resource),
         :ok <- validate_signed_request_binding(signed_request, agent_id, resource),
         {:ok, ^agent_id} <- Arbor.Security.verify_request(signed_request) do
      auth_context =
        AuthContext.new(agent_id, signed_request: signed_request)
        |> AuthContext.mark_verified()

      {:ok, %{agent_id: agent_id, signed_request: signed_request, auth_context: auth_context}}
    else
      {:error, reason} -> {:error, {:action_cycle_identity_verification_failed, reason}}
      _other -> {:error, {:action_cycle_identity_verification_failed, :invalid_signed_request}}
    end
  end

  defp call_signer(signer, payload) do
    signer.(payload)
  rescue
    exception -> {:error, {:signer_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:signer_failure, kind, reason}}
  end

  defp validate_signed_request_binding(
         %SignedRequest{agent_id: agent_id, payload: payload},
         agent_id,
         payload
       ),
       do: :ok

  defp validate_signed_request_binding(_signed_request, _agent_id, _payload),
    do: {:error, :signed_request_binding_mismatch}

  defp cycle_authentication_payload(agent_id) do
    "arbor://agent/action-cycle/authenticate/#{agent_id}/#{inspect(self())}"
  end

  defp workspace_for_agent(agent_id) do
    if Code.ensure_loaded?(Arbor.Agent.Lifecycle) and
         function_exported?(Arbor.Agent.Lifecycle, :restore, 1) do
      case apply(Arbor.Agent.Lifecycle, :restore, [agent_id]) do
        {:ok, profile} ->
          get_in(profile.metadata || %{}, [:workspace]) ||
            get_in(profile.metadata || %{}, ["workspace"])

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # ── Drain (Testing) ─────────────────────────────────────────────

  defp drain_all(%{queue: queue} = state) do
    if :queue.is_empty(queue) and not state.cycle_in_flight do
      state
    else
      # Wait briefly for any in-flight cycle
      if state.cycle_in_flight do
        Process.sleep(100)
      end

      state
    end
  end

  # ── Signal Emission ─────────────────────────────────────────────

  defp emit_signal(agent_id, event, data) do
    if Process.whereis(Arbor.Signals.Bus) != nil do
      Arbor.Signals.emit(:agent, event, data, metadata: %{agent_id: agent_id})
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Configuration ───────────────────────────────────────────────

  defp build_config(opts) do
    %{
      max_consecutive: config(:action_cycle_max_consecutive, @default_max_consecutive, opts),
      cycle_timeout: config(:action_cycle_timeout, @default_cycle_timeout, opts),
      queue_max: config(:action_cycle_queue_max, @default_queue_max, opts)
    }
  end

  defp config(key, default, opts) do
    Keyword.get(opts, key) ||
      Application.get_env(:arbor_agent, key, default)
  end

  defp config_val(state, key, default) do
    Map.get(state.config, key, default)
  end

  # ── LLM Function Factory ──────────────────────────────────────

  @doc """
  Build a default LLM function for the Mind's action cycle.

  Creates a closure that calls `Arbor.AI.generate_text/2` with the
  agent's model/provider config, builds a prompt via MindPrompt,
  and parses the JSON response into a map.

  The function signature matches CycleController's expectation:
  `(context_map) -> {:ok, response_map} | {:error, term()}`
  """
  def make_default_llm_fn(_agent_id, opts) do
    model = Keyword.get(opts, :model) || mind_model()
    provider = Keyword.get(opts, :provider) || mind_provider()

    fn context ->
      system_prompt = MindPrompt.build(Map.to_list(context))

      user_msg =
        MindPrompt.build_iteration(recent_percepts: Map.get(context, :recent_percepts, []))

      ai_opts = [
        model: model,
        provider: provider,
        max_tokens: 2000,
        runtime: :arbor,
        system_prompt: system_prompt
      ]

      case Arbor.AI.generate_text(user_msg, ai_opts) do
        {:ok, %{text: text}} ->
          parse_json_response(text)

        {:ok, response} when is_map(response) ->
          text = response[:text] || Map.get(response, "text", "")
          parse_json_response(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_json_response(text) when is_binary(text) do
    # Extract JSON from inside code fences (handles trailing text after closing fence)
    cleaned =
      case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?```/s, text) do
        [_, json] -> String.trim(json)
        nil -> String.trim(text)
      end

    case Jason.decode(cleaned) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, {:invalid_json, String.slice(text, 0, 200)}}
    end
  end

  defp parse_json_response(_), do: {:error, :empty_response}

  defp mind_model do
    Arbor.Agent.LLMDefaults.default_model(
      agent_model_key: :mind_model,
      fallback_key: :heartbeat_model
    )
  end

  defp mind_provider do
    Arbor.Agent.LLMDefaults.default_provider(
      agent_provider_key: :mind_provider,
      fallback_key: :heartbeat_provider
    )
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp lookup(agent_id) do
    registry = Arbor.Agent.ActionCycleRegistry

    case Registry.lookup(registry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  rescue
    _ -> :error
  end
end
