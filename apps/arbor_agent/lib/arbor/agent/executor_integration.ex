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
      Arbor.Memory.subscribe_to_percepts(agent_id, fn signal ->
        data = Map.get(signal, :data) || %{}
        percept = data[:percept] || data["percept"]

        if percept do
          send(agent_pid, {:percept_result, percept})
        end

        :ok
      end)
    end)
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
