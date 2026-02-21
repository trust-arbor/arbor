defmodule Arbor.Agent.CycleController do
  @moduledoc """
  Manages the Mind's action cycle — unlimited mental actions, one physical.

  The cycle controller orchestrates a loop where the Mind LLM reasons
  through mental actions (memory, goals, planning, thinking) before
  committing to a single physical action or choosing to wait.

  ## Flow

  1. Build context (current goal, last percept, capabilities)
  2. Call Mind LLM with mental tools
  3. Parse response for mental actions and/or physical intent
  4. Execute all mental actions via `MentalExecutor`
  5. If Mind emitted a physical intent → return it
  6. If Mind chose to wait → return `:wait`
  7. Otherwise → loop (up to `max_iterations`)

  ## Response Format

  The Mind LLM responds with JSON:

  ```json
  {
    "mental_actions": [
      {"capability": "memory", "op": "recall", "params": {"query": "..."}}
    ],
    "intent": {"capability": "fs", "op": "read", "target": "/path", "reason": "..."},
    "wait": false
  }
  ```

  - `mental_actions` — zero or more mental ops to execute this iteration
  - `intent` — physical action to take (null if still thinking)
  - `wait` — true to exit cycle without action
  """

  alias Arbor.Agent.{Capabilities, MentalExecutor, PerceptFormatter}
  alias Arbor.Contracts.Memory.{Intent, Percept}

  require Logger

  @default_max_iterations 20
  @default_timeout 30_000

  @type agent_id :: String.t()
  @type cycle_result ::
          {:intent, Intent.t(), [Percept.t()]}
          | {:wait, [Percept.t()]}
          | {:error, term()}

  @type cycle_opts :: [
          max_iterations: pos_integer(),
          timeout: pos_integer(),
          llm_fn: (map() -> {:ok, map()} | {:error, term()}),
          goal: map() | nil,
          last_percept: Percept.t() | nil,
          context: map()
        ]

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Run a single action cycle for the given agent.

  The cycle loops through mental actions until the Mind emits a physical
  intent or chooses to wait. Returns the physical intent (for Host
  execution) along with all mental percepts generated during the cycle.

  ## Options

  - `:max_iterations` — safety limit on mental loop iterations (default: 20)
  - `:timeout` — overall cycle timeout in ms (default: 30_000)
  - `:llm_fn` — function `(context_map) -> {:ok, response_map} | {:error, term()}`
  - `:goal` — current active goal (map with :description, :id, :progress)
  - `:last_percept` — most recent percept from previous cycle
  - `:context` — additional context map merged into LLM input
  """
  @spec run(agent_id(), cycle_opts()) :: cycle_result()
  def run(agent_id, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    llm_fn = Keyword.get(opts, :llm_fn)

    if is_nil(llm_fn) do
      {:error, :no_llm_fn}
    else
      task =
        Task.async(fn ->
          do_cycle(agent_id, opts, llm_fn, max_iterations, 0, [])
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> {:error, :cycle_timeout}
      end
    end
  end

  # ── Core Loop ─────────────────────────────────────────────────────────

  defp do_cycle(_agent_id, _opts, _llm_fn, max_iterations, iteration, percepts)
       when iteration >= max_iterations do
    Logger.warning("Mental loop hit max iterations (#{max_iterations})")
    {:wait, Enum.reverse(percepts)}
  end

  defp do_cycle(agent_id, opts, llm_fn, max_iterations, iteration, percepts) do
    context = build_context(agent_id, opts, percepts, iteration)

    case llm_fn.(context) do
      {:ok, response} ->
        process_response(agent_id, opts, llm_fn, max_iterations, iteration, percepts, response)

      {:error, reason} ->
        Logger.error("Mind LLM error in cycle iteration #{iteration}: #{inspect(reason)}")
        {:error, {:llm_error, reason}}
    end
  end

  defp process_response(agent_id, opts, llm_fn, max_iterations, iteration, percepts, response) do
    # 1. Execute mental actions
    mental_actions = extract_mental_actions(response)
    new_percepts = execute_mental_actions(agent_id, mental_actions)

    all_percepts = new_percepts ++ percepts

    # 2. Check for physical intent
    case extract_intent(response) do
      {:ok, intent} ->
        {:intent, intent, Enum.reverse(all_percepts)}

      :wait ->
        {:wait, Enum.reverse(all_percepts)}

      :continue ->
        if mental_actions == [] do
          # Mind returned nothing — don't infinite loop
          Logger.debug("Mind returned no actions and no intent at iteration #{iteration}")
          {:wait, Enum.reverse(all_percepts)}
        else
          # Continue mental loop
          do_cycle(agent_id, opts, llm_fn, max_iterations, iteration + 1, all_percepts)
        end
    end
  end

  # ── Context Building ──────────────────────────────────────────────────

  @doc false
  def build_context(agent_id, opts, percepts, iteration) do
    goal = Keyword.get(opts, :goal)
    last_percept = Keyword.get(opts, :last_percept)
    extra_context = Keyword.get(opts, :context, %{})

    base = %{
      agent_id: agent_id,
      iteration: iteration,
      capabilities: Capabilities.prompt(1),
      mental_capabilities: mental_capabilities_detail(),
      goal: format_goal(goal),
      last_percept: format_percept(last_percept),
      recent_percepts: format_recent_percepts(percepts),
      response_format: response_format()
    }

    Map.merge(base, extra_context)
  end

  defp mental_capabilities_detail do
    Capabilities.mental_capabilities()
    |> Enum.map_join("\n", fn cap ->
      ops = Capabilities.ops(cap)
      "#{cap}: #{Enum.join(ops, ", ")}"
    end)
  end

  defp format_goal(nil), do: nil

  defp format_goal(goal) when is_map(goal) do
    %{
      id: Map.get(goal, :id) || Map.get(goal, "id"),
      description: Map.get(goal, :description) || Map.get(goal, "description"),
      progress: Map.get(goal, :progress) || Map.get(goal, "progress", 0.0)
    }
  end

  defp format_percept(nil), do: nil

  defp format_percept(%Percept{} = p) do
    %{
      outcome: p.outcome,
      summary: p.summary,
      intent_id: p.intent_id
    }
  end

  defp format_percept(_), do: nil

  defp format_recent_percepts(percepts) do
    percepts
    |> Enum.take(5)
    |> Enum.map(fn p ->
      %{outcome: p.outcome, summary: p.summary}
    end)
  end

  defp response_format do
    """
    Respond with JSON:
    {
      "mental_actions": [{"capability": "...", "op": "...", "params": {...}}],
      "intent": {"capability": "...", "op": "...", "target": "...", "reason": "..."} | null,
      "wait": false
    }

    mental_actions: zero or more mental ops (memory, goal, plan, proposal, compute, think).
    intent: one physical action to take, or null to keep thinking.
    wait: true to exit the cycle without acting.
    """
  end

  # ── Response Parsing ──────────────────────────────────────────────────

  @doc false
  def extract_mental_actions(response) when is_map(response) do
    response
    |> Map.get("mental_actions", Map.get(response, :mental_actions, []))
    |> List.wrap()
    |> Enum.filter(fn action ->
      is_map(action) and
        (Map.get(action, "capability") || Map.get(action, :capability)) != nil and
        (Map.get(action, "op") || Map.get(action, :op)) != nil
    end)
  end

  def extract_mental_actions(_), do: []

  @doc false
  def extract_intent(response) when is_map(response) do
    wait = Map.get(response, "wait", Map.get(response, :wait, false))

    if wait do
      :wait
    else
      response
      |> Map.get("intent", Map.get(response, :intent))
      |> resolve_intent_data()
    end
  end

  def extract_intent(_), do: :continue

  defp resolve_intent_data(nil), do: :continue
  defp resolve_intent_data(data) when not is_map(data), do: :continue

  defp resolve_intent_data(data) do
    cap = Map.get(data, "capability") || Map.get(data, :capability)
    op_str = Map.get(data, "op") || Map.get(data, :op)

    if cap && op_str do
      resolve_physical_intent(cap, op_str, data)
    else
      :continue
    end
  end

  defp resolve_physical_intent(cap, op_str, data) do
    op = safe_op(op_str)
    target = Map.get(data, "target") || Map.get(data, :target)
    reason = Map.get(data, "reason") || Map.get(data, :reason)

    case Capabilities.resolve(cap, op) do
      {:ok, {:action, _module}} ->
        {:ok, Intent.capability_intent(cap, op, target, reasoning: reason)}

      {:ok, {:mental, _}} ->
        :continue

      {:ok, {:host_only, _}} ->
        :continue

      {:error, _} ->
        Logger.warning("Mind requested unknown capability: #{cap}.#{op_str}")
        :continue
    end
  end

  # ── Mental Action Execution ───────────────────────────────────────────

  defp execute_mental_actions(agent_id, actions) do
    Enum.flat_map(actions, fn action ->
      cap = Map.get(action, "capability") || Map.get(action, :capability)
      op_str = Map.get(action, "op") || Map.get(action, :op)
      params = Map.get(action, "params") || Map.get(action, :params, %{})

      op = safe_op(op_str)

      case Capabilities.resolve(cap, op) do
        {:ok, {:mental, handler}} ->
          result = MentalExecutor.execute_handler(handler, agent_id, params)
          intent = Intent.capability_intent(cap, op, nil, reasoning: "mental action")
          [PerceptFormatter.from_mental_result(intent, result)]

        {:ok, {:action, module}} ->
          # Action-backed mental capability — execute directly
          intent = Intent.capability_intent(cap, op, nil, reasoning: "mental action")
          result = execute_action_backed_mental(agent_id, module, params)
          [PerceptFormatter.from_mental_result(intent, result)]

        _ ->
          Logger.debug("Skipping non-mental action: #{cap}.#{op_str}")
          []
      end
    end)
  end

  defp execute_action_backed_mental(agent_id, module, params) do
    if Code.ensure_loaded?(Arbor.Actions) do
      try do
        apply(Arbor.Actions, :authorize_and_execute, [module, agent_id, params, []])
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:action_unavailable, reason}}
      end
    else
      {:error, :actions_not_available}
    end
  end

  # ── Utility ───────────────────────────────────────────────────────────

  defp safe_op(op) when is_atom(op), do: op

  defp safe_op(op) when is_binary(op) do
    # Only convert to atoms that already exist in the VM
    # (all capability ops are defined at compile time in Capabilities)
    String.to_existing_atom(op)
  rescue
    ArgumentError ->
      Logger.warning("Unknown op atom: #{op}")
      :unknown
  end
end
