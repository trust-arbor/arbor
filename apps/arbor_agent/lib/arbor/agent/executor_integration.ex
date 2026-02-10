defmodule Arbor.Agent.ExecutorIntegration do
  @moduledoc """
  Helpers for wiring the Executor (Body) into the Claude agent's heartbeat.

  Converts heartbeat actions into Intents, routes them through the Executor
  via the Bridge, and processes percept results back into agent state.
  """

  alias Arbor.Agent.Executor
  alias Arbor.Contracts.Memory.Intent

  require Logger

  @doc """
  Start an Executor for the given agent.

  Returns `{:ok, pid}` or `{:error, reason}`. Non-fatal — the agent can
  run without an Executor (actions just won't go through reflex/capability
  checks).
  """
  @spec start_executor(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_executor(agent_id, opts \\ []) do
    trust_tier = Keyword.get(opts, :trust_tier, :established)

    case Executor.start(agent_id, trust_tier: trust_tier) do
      {:ok, pid} ->
        Logger.info("Executor started for agent #{agent_id}", trust_tier: trust_tier)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Executor already running for #{agent_id}")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.warning("Failed to start Executor: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("Executor start exception: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Route a list of action maps through the Executor via Intent emission.

  Each action map should have:
  - `:type` — atom like `:shell_execute`, `:file_read`, etc.
  - `:params` — map of parameters
  - `:reasoning` — optional string explaining why

  Returns the list of emitted Intent IDs.
  """
  @spec route_actions(String.t(), [map()]) :: [String.t()]
  def route_actions(agent_id, actions) when is_list(actions) do
    Enum.map(actions, fn action ->
      intent = build_intent(action)

      # Record in IntentStore
      safe_call(fn -> Arbor.Memory.record_intent(agent_id, intent) end)

      # Emit via Bridge — Executor subscribes to these
      safe_call(fn -> Arbor.Memory.emit_intent(agent_id, intent) end)

      Logger.debug("Routed action #{action[:type]} as intent #{intent.id}",
        agent_id: agent_id
      )

      intent.id
    end)
  end

  @doc """
  Subscribe to percept results for the given agent.

  Percepts arrive asynchronously after the Executor processes intents.
  The callback receives the percept struct.
  """
  @spec subscribe_to_percepts(String.t(), pid()) :: {:ok, String.t()} | {:error, term()}
  def subscribe_to_percepts(agent_id, agent_pid) do
    safe_call(fn ->
      Arbor.Memory.subscribe_to_percepts(agent_id, &forward_percept(&1, agent_pid))
    end)
  end

  defp forward_percept(signal, agent_pid) do
    data = Map.get(signal, :data) || %{}
    percept = data[:percept] || data["percept"]

    if percept, do: send(agent_pid, {:percept_result, percept})

    :ok
  end

  @doc """
  Route pending intentions from IntentStore to the Executor.

  Implements pull-based routing:
  1. Unlock stale intents (locked > 60s — likely crashed)
  2. Peek pending intents (sorted by urgency, limit 3)
  3. Lock each intent
  4. Emit via Bridge for Executor to pick up

  Returns the list of routed intent IDs.
  """
  @spec route_pending_intentions(String.t(), keyword()) :: [String.t()]
  def route_pending_intentions(agent_id, opts \\ []) do
    timeout_ms = Keyword.get(opts, :stale_timeout_ms, 60_000)
    limit = Keyword.get(opts, :limit, 3)

    # 1. Unlock stale locks
    unlocked = safe_call(fn -> Arbor.Memory.unlock_stale_intents(agent_id, timeout_ms) end) || 0

    if unlocked > 0 do
      Logger.debug("Unlocked #{unlocked} stale intents", agent_id: agent_id)
    end

    # 2. Get pending intents
    pending =
      safe_call(fn -> Arbor.Memory.pending_intentions(agent_id, limit: limit) end) || []

    # 3. Lock and route each
    Enum.flat_map(pending, fn {intent, _status} ->
      lock_and_route_intent(agent_id, intent)
    end)
  end

  defp lock_and_route_intent(agent_id, intent) do
    case safe_call(fn -> Arbor.Memory.lock_intent(agent_id, intent.id) end) do
      {:ok, locked_intent} ->
        safe_call(fn -> Arbor.Memory.emit_intent(agent_id, locked_intent) end)

        Logger.debug("Routed pending intent #{intent.id} (#{intent.action})",
          agent_id: agent_id,
          goal_id: intent.goal_id
        )

        [intent.id]

      _ ->
        []
    end
  end

  # -- Private --

  defp build_intent(%{type: type} = action) do
    params = Map.get(action, :params, %{})
    reasoning = Map.get(action, :reasoning, "Heartbeat action: #{type}")

    case type do
      t when t in [:think, :reflect, :introspect] ->
        Intent.think(reasoning)

      :wait ->
        Intent.wait(reasoning)

      _ ->
        Intent.action(type, params, reasoning: reasoning)
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("ExecutorIntegration safe_call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("ExecutorIntegration safe_call caught exit: #{inspect(reason)}")
      nil
  end
end
