defmodule Arbor.Memory.Bridge do
  @moduledoc """
  Mind-Body Bridge for signal-based communication.

  The Bridge connects the Mind (Seed) and Body (Host) via the Arbor signal bus.
  The Mind emits intents describing what it wants to do, the Body subscribes and
  executes them, then emits percepts back with the results.

  ## Communication Pattern

      Mind                     Bridge                      Body
       │                         │                          │
       ├─ emit_intent ──────────►│                          │
       │                         ├─ signal ────────────────►│
       │                         │                          ├─ executes
       │                         │◄───────── emit_percept ──┤
       │◄── signal ──────────────┤                          │
       │                         │                          │

  ## Request-Response

  For synchronous operations, use `execute_and_wait/3` which:
  1. Emits an intent
  2. Subscribes to percepts for that intent
  3. Waits for a matching percept (or timeout)

  ## Signal Topics

  - `{:bridge, :intent, agent_id}` — Mind → Body intent channel
  - `{:bridge, :percept, agent_id}` — Body → Mind percept channel
  """

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Memory.Percept

  require Logger

  @doc """
  Emit an intent from Mind to Body.

  Publishes the intent to the signal bus so the Body can pick it up
  and execute it.

  ## Examples

      intent = Intent.action(:shell_execute, %{command: "mix test"})
      :ok = Bridge.emit_intent("agent_001", intent)
  """
  @spec emit_intent(String.t(), Intent.t()) :: :ok
  def emit_intent(agent_id, %Intent{} = intent) do
    Arbor.Signals.emit(:bridge, :intent, %{
      agent_id: agent_id,
      intent: intent,
      intent_id: intent.id,
      intent_type: intent.type,
      action: intent.action,
      emitted_at: DateTime.utc_now()
    })

    Logger.debug("Bridge: intent emitted for #{agent_id}: #{intent.id}")
    :ok
  end

  @doc """
  Subscribe to intents for a specific agent (Body subscribes).

  The handler function receives the signal data map containing the intent.

  ## Examples

      Bridge.subscribe_to_intents("agent_001", fn signal ->
        intent = signal.data.intent
        # ... execute intent ...
        :ok
      end)
  """
  @spec subscribe_to_intents(String.t(), (map() -> :ok)) :: {:ok, String.t()} | {:error, term()}
  def subscribe_to_intents(agent_id, handler) when is_function(handler, 1) do
    topic = "bridge.intent"

    Arbor.Signals.subscribe(topic, fn signal ->
      if signal.data[:agent_id] == agent_id do
        handler.(signal)
      end

      :ok
    end)
  end

  @doc """
  Emit a percept from Body to Mind.

  Publishes the execution result so the Mind can integrate it.

  ## Examples

      percept = Percept.success("int_abc", %{exit_code: 0, output: "OK"})
      :ok = Bridge.emit_percept("agent_001", percept)
  """
  @spec emit_percept(String.t(), Percept.t()) :: :ok
  def emit_percept(agent_id, %Percept{} = percept) do
    Arbor.Signals.emit(:bridge, :percept, %{
      agent_id: agent_id,
      percept: percept,
      percept_id: percept.id,
      intent_id: percept.intent_id,
      outcome: percept.outcome,
      emitted_at: DateTime.utc_now()
    })

    Logger.debug("Bridge: percept emitted for #{agent_id}: #{percept.id}")
    :ok
  end

  @doc """
  Subscribe to percepts for a specific agent (Mind subscribes).

  The handler function receives the signal data map containing the percept.

  ## Examples

      Bridge.subscribe_to_percepts("agent_001", fn signal ->
        percept = signal.data.percept
        # ... integrate result ...
        :ok
      end)
  """
  @spec subscribe_to_percepts(String.t(), (map() -> :ok)) :: {:ok, String.t()} | {:error, term()}
  def subscribe_to_percepts(agent_id, handler) when is_function(handler, 1) do
    topic = "bridge.percept"

    Arbor.Signals.subscribe(topic, fn signal ->
      if signal.data[:agent_id] == agent_id do
        handler.(signal)
      end

      :ok
    end)
  end

  @doc """
  Execute an intent and wait for the percept response.

  This is the request-response pattern: emit an intent, then block until
  a percept with a matching `intent_id` arrives, or timeout.

  ## Options

  - `:timeout` — maximum wait time in milliseconds (default: 30_000)

  ## Examples

      intent = Intent.action(:shell_execute, %{command: "mix test"})
      case Bridge.execute_and_wait("agent_001", intent) do
        {:ok, percept} -> IO.puts("Result: \#{percept.outcome}")
        {:error, :timeout} -> IO.puts("Timed out waiting for response")
      end
  """
  @spec execute_and_wait(String.t(), Intent.t(), keyword()) ::
          {:ok, Percept.t()} | {:error, :timeout}
  def execute_and_wait(agent_id, %Intent{} = intent, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    caller = self()
    intent_id = intent.id

    # Subscribe to percepts for this specific intent
    {:ok, sub_id} =
      Arbor.Signals.subscribe("bridge.percept", fn signal ->
        if signal.data[:agent_id] == agent_id and
             signal.data[:intent_id] == intent_id do
          send(caller, {:bridge_percept, intent_id, signal.data[:percept]})
        end

        :ok
      end)

    # Emit the intent
    :ok = emit_intent(agent_id, intent)

    # Wait for the percept
    result =
      receive do
        {:bridge_percept, ^intent_id, percept} ->
          {:ok, percept}
      after
        timeout ->
          {:error, :timeout}
      end

    # Unsubscribe
    Arbor.Signals.unsubscribe(sub_id)

    result
  end
end
