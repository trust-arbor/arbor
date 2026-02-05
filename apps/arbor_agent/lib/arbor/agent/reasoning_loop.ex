defmodule Arbor.Agent.ReasoningLoop do
  @moduledoc """
  Coordinates think → intent → percept → think cycles.

  The ReasoningLoop drives the agent's cognitive cycle. It reads goals and
  context, forms intents, waits for percepts, and integrates results.

  ## Modes

  - `:continuous` — runs until explicitly stopped
  - `:stepped` — advances one cycle per `step/1` call
  - `{:bounded, n}` — runs at most n cycles then stops

  ## Example

      {:ok, pid} = ReasoningLoop.start("agent-1", :stepped)
      {:ok, result} = ReasoningLoop.step("agent-1")
      :ok = ReasoningLoop.stop("agent-1")
  """

  use GenServer

  alias Arbor.Contracts.Memory.Intent

  require Logger

  @type loop_mode :: :continuous | :stepped | {:bounded, pos_integer()}

  # -- Public API --

  @doc """
  Start a reasoning loop for the given agent.
  """
  @spec start(String.t(), loop_mode(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(agent_id, mode, opts \\ []) do
    GenServer.start(__MODULE__, {agent_id, mode, opts}, name: via(agent_id))
  end

  @doc """
  Advance one cycle in stepped mode.
  """
  @spec step(String.t()) :: {:ok, map()} | {:done, term()} | {:error, term()}
  def step(agent_id) do
    case GenServer.whereis(via(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :step, 30_000)
    end
  end

  @doc """
  Stop the reasoning loop.
  """
  @spec stop(String.t()) :: :ok
  def stop(agent_id) do
    case GenServer.whereis(via(agent_id)) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc """
  Get the current status of the reasoning loop.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(agent_id) do
    case GenServer.whereis(via(agent_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :status)
    end
  end

  # -- GenServer Callbacks --

  @impl true
  def init({agent_id, mode, opts}) do
    state = %{
      agent_id: agent_id,
      mode: mode,
      status: :idle,
      iteration: 0,
      max_iterations: max_iterations(mode),
      think_fn: Keyword.get(opts, :think_fn, &default_think/2),
      intent_timeout: Keyword.get(opts, :intent_timeout, 30_000),
      last_percept: nil,
      last_intent: nil
    }

    # Subscribe to percepts for this agent (non-fatal if unavailable)
    safe_call(fn ->
      Arbor.Memory.subscribe_to_percepts(agent_id, fn percept ->
        GenServer.cast(self(), {:percept, percept})
        :ok
      end)
    end)

    # Auto-start continuous mode
    case mode do
      :continuous -> send(self(), :run_cycle)
      {:bounded, _} -> send(self(), :run_cycle)
      :stepped -> :ok
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:step, from, %{mode: :stepped} = state) do
    state = %{state | status: :thinking}
    state = run_one_cycle(state, from)
    {:noreply, state}
  end

  def handle_call(:step, _from, state) do
    {:reply, {:error, :not_stepped_mode}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      agent_id: state.agent_id,
      mode: state.mode,
      status: state.status,
      iteration: state.iteration
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info(:run_cycle, state) do
    if state.max_iterations && state.iteration >= state.max_iterations do
      safe_emit(:agent, :loop_completed, %{
        agent_id: state.agent_id,
        iterations: state.iteration,
        final_outcome: :bounded_limit
      })

      {:stop, :normal, state}
    else
      state = %{state | status: :thinking}
      state = run_one_cycle(state, nil)
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:percept, percept}, state) do
    state = %{state | last_percept: percept, status: :idle}

    # In continuous/bounded mode, schedule next cycle
    case state.mode do
      :continuous -> send(self(), :run_cycle)
      {:bounded, _} -> send(self(), :run_cycle)
      :stepped -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    safe_emit(:agent, :loop_completed, %{
      agent_id: state.agent_id,
      iterations: state.iteration,
      final_outcome: :stopped
    })

    :ok
  end

  # -- Private --

  defp run_one_cycle(state, reply_to) do
    agent_id = state.agent_id
    iteration = state.iteration + 1

    # 1. Think: generate intent based on goals, context, last percept
    intent = state.think_fn.(agent_id, state.last_percept)

    # 2. Record thinking (non-fatal if memory unavailable)
    safe_call(fn ->
      Arbor.Memory.record_thinking(agent_id, intent.reasoning || "Cycle #{iteration}")
    end)

    # 3. Record and emit intent
    safe_call(fn -> Arbor.Memory.record_intent(agent_id, intent) end)
    safe_call(fn -> Arbor.Memory.emit_intent(agent_id, intent) end)

    safe_emit(:agent, :loop_iteration, %{
      agent_id: agent_id,
      iteration: iteration,
      intent_id: intent.id
    })

    # 4. In stepped mode, reply immediately with the intent info
    if reply_to do
      GenServer.reply(reply_to, {:ok, %{iteration: iteration, intent: intent}})
    end

    # In continuous/bounded mode, schedule next cycle immediately
    # (percepts will interrupt if they arrive)
    case state.mode do
      :continuous -> send(self(), :run_cycle)
      {:bounded, _} -> send(self(), :run_cycle)
      :stepped -> :ok
    end

    %{state | iteration: iteration, last_intent: intent, status: :awaiting_percept}
  end

  defp default_think(agent_id, last_percept) do
    # Default think function: check goals and form a basic intent
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    reasoning =
      case {goals, last_percept} do
        {[], nil} ->
          "No active goals. Waiting for direction."

        {[goal | _], nil} ->
          "Working on goal: #{goal.description}"

        {_, percept} ->
          "Processing result from previous action: #{inspect(percept)}"
      end

    Intent.think(reasoning)
  end

  defp max_iterations(:continuous), do: nil
  defp max_iterations(:stepped), do: nil
  defp max_iterations({:bounded, n}) when is_integer(n) and n > 0, do: n

  defp safe_emit(category, type, data) do
    safe_call(fn -> Arbor.Signals.emit(category, type, data) end)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp via(agent_id) do
    {:via, Registry, {Arbor.Agent.ReasoningLoopRegistry, agent_id}}
  end
end
