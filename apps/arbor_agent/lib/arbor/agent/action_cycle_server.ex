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
  4. Physical intent dispatched to ToolBridge → result becomes new percept
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

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    llm_fn = Keyword.get(opts, :llm_fn) || make_default_llm_fn(agent_id, opts)

    state = %{
      agent_id: agent_id,
      queue: :queue.new(),
      cycle_in_flight: false,
      cycle_count: 0,
      consecutive_cycles: 0,
      config: build_config(opts),
      llm_fn: llm_fn
    }

    {:ok, state}
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

    emit_signal(agent_id, :action_cycle_started, %{
      agent_id: agent_id,
      percept_type: Map.get(percept, :type),
      queue_depth: :queue.len(queue)
    })

    parent = self()

    Task.start(fn ->
      result = run_cycle(agent_id, percept, llm_fn, timeout)
      send(parent, {:cycle_result, result})
    end)

    %{state | queue: queue, cycle_in_flight: true}
  end

  defp run_cycle(agent_id, percept, llm_fn, timeout) do
    controller = Arbor.Agent.CycleController

    if Code.ensure_loaded?(controller) and function_exported?(controller, :run, 2) do
      opts = [timeout: timeout, last_percept: percept]
      opts = if llm_fn, do: Keyword.put(opts, :llm_fn, llm_fn), else: opts

      try do
        case apply(controller, :run, [agent_id, opts]) do
          {:intent, intent, percepts} ->
            exec_result = dispatch_physical_intent(agent_id, intent)
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

  defp dispatch_physical_intent(agent_id, intent) do
    capability = Map.get(intent, :capability, Map.get(intent, "capability"))
    op = Map.get(intent, :op, Map.get(intent, "op"))
    params = Map.get(intent, :params, Map.get(intent, "params", %{}))

    emit_signal(agent_id, :intent_dispatched, %{
      agent_id: agent_id,
      capability: capability,
      op: op
    })

    tool_bridge = Arbor.Agent.ToolBridge

    if Code.ensure_loaded?(tool_bridge) and
         function_exported?(tool_bridge, :authorize_and_execute, 4) do
      start_time = System.monotonic_time(:millisecond)

      try do
        result = apply(tool_bridge, :authorize_and_execute, [agent_id, capability, op, params])
        duration = System.monotonic_time(:millisecond) - start_time
        percept = format_exec_percept(intent, result, duration)
        {:ok, percept}
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    else
      {:error, :tool_bridge_unavailable}
    end
  end

  defp format_exec_percept(intent, result, duration_ms) do
    formatter = Arbor.Agent.PerceptFormatter

    if Code.ensure_loaded?(formatter) and
         function_exported?(formatter, :from_result, 3) do
      apply(formatter, :from_result, [intent, result, duration_ms])
    else
      # Fallback: simple percept map
      %{
        type: :action_result,
        intent: intent,
        result: result,
        duration_ms: duration_ms
      }
    end
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
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) and
         Process.whereis(Arbor.Signals.Bus) != nil do
      apply(Arbor.Signals, :emit, [:agent, event, data, [metadata: %{agent_id: agent_id}]])
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
        MindPrompt.build_iteration(
          iteration: Map.get(context, :iteration, 0),
          recent_percepts: Map.get(context, :recent_percepts, [])
        )

      ai_opts = [
        model: model,
        provider: provider,
        max_tokens: 2000,
        backend: :api,
        system_prompt: system_prompt
      ]

      if ai_available?() do
        case apply(Arbor.AI, :generate_text, [user_msg, ai_opts]) do
          {:ok, %{text: text}} ->
            parse_json_response(text)

          {:ok, response} when is_map(response) ->
            text = response[:text] || Map.get(response, "text", "")
            parse_json_response(text)

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :ai_unavailable}
      end
    end
  end

  defp parse_json_response(text) when is_binary(text) do
    # Strip markdown code fences if present
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, {:invalid_json, String.slice(text, 0, 200)}}
    end
  end

  defp parse_json_response(_), do: {:error, :empty_response}

  defp ai_available? do
    Code.ensure_loaded?(Arbor.AI) and
      function_exported?(Arbor.AI, :generate_text, 2)
  end

  defp mind_model do
    Application.get_env(:arbor_agent, :mind_model) ||
      Application.get_env(:arbor_agent, :heartbeat_model) ||
      "arcee-ai/trinity-large-preview:free"
  end

  defp mind_provider do
    Application.get_env(:arbor_agent, :mind_provider) ||
      Application.get_env(:arbor_agent, :heartbeat_provider) ||
      :openrouter
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
