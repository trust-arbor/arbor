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

  ## Interrupt Protocol

  The Bridge supports an interrupt protocol for cancelling long-running operations.
  Interrupts are managed via `Arbor.Signals` (ETS-backed for fast synchronous lookups).

      # Mind side: interrupt a body
      Bridge.interrupt("agent_001", "body_123", :higher_priority)

      # Body side: check during long operations
      if Bridge.interrupted?("body_123"), do: :abort

      # Mind side: clear interrupt when done
      Bridge.clear_interrupt("body_123")

  ## Graceful Degradation

  All functions degrade gracefully when Arbor.Signals is unavailable:
  - Emit functions return `{:error, :signals_not_available}`
  - Subscribe functions return `{:error, :signals_not_available}`
  - Query functions return `{:ok, []}` (empty results)
  - `available?/0` returns `false`
  - Interrupt functions return safe defaults

  ## Signal Topics

  - `bridge.intent` — Mind → Body intent channel
  - `bridge.percept` — Body → Mind percept channel

  ## Typed Handlers

  Subscription handlers receive typed structs (`Intent.t()` or `Percept.t()`)
  rather than raw signal maps. The Bridge reconstructs structs from signal data
  automatically via `Intent.from_map/1` and `Percept.from_map/1`.
  """

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Memory.Percept

  require Logger

  # ============================================================================
  # Intent Emission
  # ============================================================================

  @doc """
  Emit an intent from Mind to Body.

  Publishes the intent to the signal bus so the Body can pick it up
  and execute it.

  ## Options

  - `:priority` — `:urgent`, `:normal`, or `:low` (default: `:normal`)
  - `:correlation_id` — For tracing request/response pairs

  ## Examples

      intent = Intent.action(:shell_execute, %{command: "mix test"})
      :ok = Bridge.emit_intent("agent_001", intent)
  """
  @spec emit_intent(String.t(), Intent.t(), keyword()) :: :ok | {:error, term()}
  def emit_intent(agent_id, %Intent{} = intent, opts \\ []) do
    with_signals(
      fn signals ->
        priority = Keyword.get(opts, :priority, :normal)

        signals.emit(:bridge, :intent, %{
          agent_id: agent_id,
          intent: intent,
          intent_id: intent.id,
          intent_type: intent.type,
          action: intent.action,
          priority: priority,
          emitted_at: DateTime.utc_now()
        }, [
          source: bridge_source(agent_id),
          correlation_id: Keyword.get(opts, :correlation_id),
          metadata: %{agent_id: agent_id, priority: priority}
        ])

        Logger.debug("Bridge: intent emitted for #{agent_id}: #{intent.id}")
        :ok
      end,
      fn ->
        Logger.warning("Bridge: Arbor.Signals not available, intent not emitted",
          agent_id: agent_id
        )
        {:error, :signals_not_available}
      end
    )
  end

  @doc """
  Emit an urgent intent that bypasses normal async dispatch.

  Urgent intents set the priority to `:urgent`, signaling the Body to
  process them immediately. Use for time-sensitive actions.

  ## Examples

      intent = Intent.action(:emergency_stop, %{})
      :ok = Bridge.emit_urgent_intent("agent_001", intent)
  """
  @spec emit_urgent_intent(String.t(), Intent.t(), keyword()) :: :ok | {:error, term()}
  def emit_urgent_intent(agent_id, %Intent{} = intent, opts \\ []) do
    emit_intent(agent_id, intent, Keyword.put(opts, :priority, :urgent))
  end

  # ============================================================================
  # Percept Emission
  # ============================================================================

  @doc """
  Emit a percept from Body to Mind.

  Publishes the execution result so the Mind can integrate it.

  ## Options

  - `:correlation_id` — Should match the intent's correlation_id for tracing
  - `:cause_id` — The intent signal ID that caused this percept

  ## Examples

      percept = Percept.success("int_abc", %{exit_code: 0, output: "OK"})
      :ok = Bridge.emit_percept("agent_001", percept)
  """
  @spec emit_percept(String.t(), Percept.t(), keyword()) :: :ok | {:error, term()}
  def emit_percept(agent_id, %Percept{} = percept, opts \\ []) do
    with_signals(
      fn signals ->
        signals.emit(:bridge, :percept, %{
          agent_id: agent_id,
          percept: percept,
          percept_id: percept.id,
          intent_id: percept.intent_id,
          outcome: percept.outcome,
          emitted_at: DateTime.utc_now()
        }, [
          source: bridge_source(agent_id),
          correlation_id: Keyword.get(opts, :correlation_id),
          cause_id: Keyword.get(opts, :cause_id),
          metadata: %{agent_id: agent_id}
        ])

        Logger.debug("Bridge: percept emitted for #{agent_id}: #{percept.id}")
        :ok
      end,
      fn ->
        Logger.warning("Bridge: Arbor.Signals not available, percept not emitted",
          agent_id: agent_id
        )
        {:error, :signals_not_available}
      end
    )
  end

  # ============================================================================
  # Subscriptions
  # ============================================================================

  @doc """
  Subscribe to intents for a specific agent (Body subscribes).

  The handler function receives a typed `Intent.t()` struct.

  ## Examples

      Bridge.subscribe_to_intents("agent_001", fn intent ->
        # intent is an %Intent{} struct
        IO.puts("Received intent: \#{intent.id}")
        :ok
      end)
  """
  @spec subscribe_to_intents(String.t(), (Intent.t() -> :ok)) :: {:ok, String.t()} | {:error, term()}
  def subscribe_to_intents(agent_id, handler) when is_function(handler, 1) do
    with_signals(
      fn signals ->
        signals.subscribe("bridge.intent", fn signal ->
          maybe_handle_intent(signal, agent_id, handler)
          :ok
        end)
      end,
      fn ->
        Logger.warning("Bridge: Arbor.Signals not available, cannot subscribe to intents")
        {:error, :signals_not_available}
      end
    )
  end

  @doc """
  Subscribe to percepts for a specific agent (Mind subscribes).

  The handler function receives a typed `Percept.t()` struct.

  ## Examples

      Bridge.subscribe_to_percepts("agent_001", fn percept ->
        # percept is a %Percept{} struct
        IO.puts("Outcome: \#{percept.outcome}")
        :ok
      end)
  """
  @spec subscribe_to_percepts(String.t(), (Percept.t() -> :ok)) :: {:ok, String.t()} | {:error, term()}
  def subscribe_to_percepts(agent_id, handler) when is_function(handler, 1) do
    with_signals(
      fn signals ->
        signals.subscribe("bridge.percept", fn signal ->
          maybe_handle_percept(signal, agent_id, handler)
          :ok
        end)
      end,
      fn ->
        Logger.warning("Bridge: Arbor.Signals not available, cannot subscribe to percepts")
        {:error, :signals_not_available}
      end
    )
  end

  @doc """
  Unsubscribe from a signal subscription.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(subscription_id) do
    with_signals(
      fn signals -> signals.unsubscribe(subscription_id) end,
      {:error, :signals_not_available}
    )
  end

  # ============================================================================
  # Request-Response
  # ============================================================================

  @doc """
  Execute an intent and wait for the percept response.

  This is the request-response pattern: emit an intent, then block until
  a percept with a matching `intent_id` arrives, or timeout.

  Returns a typed `Percept.t()` struct on success.

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
          {:ok, Percept.t()} | {:error, :timeout | :signals_not_available}
  def execute_and_wait(agent_id, %Intent{} = intent, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    caller = self()
    intent_id = intent.id

    with_signals(
      fn signals ->
        # Subscribe to percepts for this specific intent
        {:ok, sub_id} =
          signals.subscribe("bridge.percept", fn signal ->
            maybe_send_percept(signal, agent_id, intent_id, caller)
            :ok
          end)

        # Emit the intent
        :ok = emit_intent(agent_id, intent, opts)

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
        signals.unsubscribe(sub_id)

        result
      end,
      {:error, :signals_not_available}
    )
  end

  # ============================================================================
  # Interrupt Protocol
  # ============================================================================

  @doc """
  Signal an interrupt to a target (Body) executing an intent.

  Sends an interrupt signal that the Body should check during long-running
  operations. The Body can then gracefully stop its current work and respond
  to the new priority.

  Interrupts are managed via `Arbor.Signals.interrupt/3` (ETS-backed for
  fast synchronous lookups) and also emitted as observability signals.

  ## Options

  - `:replacement_intent_id` — ID of new intent that should take over
  - `:allow_resume` — Whether the interrupted work can be resumed later (default: false)

  ## Examples

      Bridge.interrupt("agent_001", "body_123", :higher_priority,
        replacement_intent_id: new_intent.id
      )
  """
  @spec interrupt(String.t(), String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def interrupt(agent_id, target_id, reason, opts \\ []) do
    with_signals(
      fn signals ->
        signals.interrupt(target_id, reason,
          replacement_intent_id: Keyword.get(opts, :replacement_intent_id),
          allow_resume: Keyword.get(opts, :allow_resume, false)
        )

        # Emit observability signal
        signals.emit(:bridge, :interrupt, %{
          agent_id: agent_id,
          target_id: target_id,
          reason: reason
        }, source: bridge_source(agent_id))
      end,
      :ok
    )

    # Emit memory signal if available
    emit_bridge_interrupt_signal(agent_id, target_id, reason)

    Logger.debug("Bridge: interrupt sent to #{target_id} from #{agent_id}: #{reason}")
    :ok
  end

  @doc """
  Check if a target has been interrupted.

  Bodies should call this periodically during long-running operations to
  check if they should stop and yield to higher priority work.

  Returns the interrupt data map if interrupted, `false` otherwise.

  ## Examples

      case Bridge.interrupted?("body_123") do
        false -> continue_work()
        %{reason: :higher_priority} -> abort_and_yield()
      end
  """
  @spec interrupted?(String.t()) :: map() | false
  def interrupted?(target_id) do
    with_signals(
      fn signals -> signals.interrupted?(target_id) end,
      false
    )
  end

  @doc """
  Clear an interrupt for a target, allowing it to continue normal operation.

  ## Examples

      Bridge.clear_interrupt("body_123")
  """
  @spec clear_interrupt(String.t()) :: :ok
  def clear_interrupt(target_id) do
    with_signals(
      fn signals ->
        signals.clear_interrupt(target_id)

        signals.emit(:bridge, :interrupt_cleared, %{target_id: target_id})
      end,
      :ok
    )

    Logger.debug("Bridge: interrupt cleared for #{target_id}")
    :ok
  end

  # ============================================================================
  # Query History
  # ============================================================================

  @doc """
  Query recent intents for an agent.

  Returns typed `Intent.t()` structs reconstructed from signal data.

  ## Options

  - `:limit` — Maximum number to return (default: 50)

  ## Examples

      {:ok, intents} = Bridge.recent_intents("agent_001", limit: 10)
  """
  @spec recent_intents(String.t(), keyword()) :: {:ok, [Intent.t()]} | {:error, term()}
  def recent_intents(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    with_signals(
      fn signals ->
        case signals.query(category: :bridge, type: :intent, limit: limit * 2) do
          {:ok, all_signals} ->
            {:ok, filter_and_convert_intents(all_signals, agent_id, limit)}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      {:ok, []}
    )
  end

  @doc """
  Query recent percepts for an agent.

  Returns typed `Percept.t()` structs reconstructed from signal data.

  ## Options

  - `:limit` — Maximum number to return (default: 50)

  ## Examples

      {:ok, percepts} = Bridge.recent_percepts("agent_001", limit: 10)
  """
  @spec recent_percepts(String.t(), keyword()) :: {:ok, [Percept.t()]} | {:error, term()}
  def recent_percepts(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    with_signals(
      fn signals ->
        case signals.query(category: :bridge, type: :percept, limit: limit * 2) do
          {:ok, all_signals} ->
            {:ok, filter_and_convert_percepts(all_signals, agent_id, limit)}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      {:ok, []}
    )
  end

  # ============================================================================
  # Availability
  # ============================================================================

  @doc """
  Check if the bridge can communicate (Arbor.Signals is available and healthy).

  ## Examples

      if Bridge.available?() do
        Bridge.emit_intent(agent_id, intent)
      else
        Logger.warning("Bridge offline, queuing intent")
      end
  """
  @spec available?() :: boolean()
  def available? do
    with_signals(fn signals -> signals.healthy?() end, false)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Dispatch intent to handler if signal matches the agent
  defp maybe_handle_intent(signal, agent_id, handler) do
    if signal.data[:agent_id] == agent_id do
      case signal_to_intent(signal) do
        nil -> :ok
        intent -> handler.(intent)
      end
    end
  end

  # Dispatch percept to handler if signal matches the agent
  defp maybe_handle_percept(signal, agent_id, handler) do
    if signal.data[:agent_id] == agent_id do
      case signal_to_percept(signal) do
        nil -> :ok
        percept -> handler.(percept)
      end
    end
  end

  # Send percept to caller if signal matches agent and intent
  defp maybe_send_percept(signal, agent_id, intent_id, caller) do
    if signal.data[:agent_id] == agent_id and signal.data[:intent_id] == intent_id do
      percept = signal_to_percept(signal)
      send(caller, {:bridge_percept, intent_id, percept})
    end
  end

  # Filter signals by agent and convert to intents
  defp filter_and_convert_intents(signals, agent_id, limit) do
    signals
    |> Enum.filter(fn signal -> signal.data[:agent_id] == agent_id end)
    |> Enum.take(limit)
    |> Enum.map(&signal_to_intent/1)
    |> Enum.reject(&is_nil/1)
  end

  # Filter signals by agent and convert to percepts
  defp filter_and_convert_percepts(signals, agent_id, limit) do
    signals
    |> Enum.filter(fn signal -> signal.data[:agent_id] == agent_id end)
    |> Enum.take(limit)
    |> Enum.map(&signal_to_percept/1)
    |> Enum.reject(&is_nil/1)
  end

  # Source URI for bridge signals, scoped to agent.
  defp bridge_source(agent_id), do: "arbor://bridge/#{agent_id}"

  # Reconstruct an Intent struct from signal data.
  defp signal_to_intent(signal) do
    case signal.data[:intent] do
      %Intent{} = intent -> intent
      map when is_map(map) -> Intent.from_map(map)
      _ -> nil
    end
  end

  # Reconstruct a Percept struct from signal data.
  defp signal_to_percept(signal) do
    case signal.data[:percept] do
      %Percept{} = percept -> percept
      map when is_map(map) -> Percept.from_map(map)
      _ -> nil
    end
  end

  # Graceful degradation helper — calls the callback with the Signals module
  # if available, otherwise returns the default value or calls the default function.
  defp with_signals(callback, default) when is_function(callback, 1) do
    case resolve_signals_module() do
      nil when is_function(default, 0) -> default.()
      nil -> default
      module when is_atom(module) -> callback.(module)
    end
  end

  defp resolve_signals_module do
    if Arbor.Common.LazyLoader.exported?(Arbor.Signals, :healthy?, 0) do
      Arbor.Signals
    else
      nil
    end
  end

  defp emit_bridge_interrupt_signal(agent_id, target_id, reason) do
    if Arbor.Common.LazyLoader.exported?(Arbor.Memory.Signals, :emit_bridge_interrupt, 3) do
      Arbor.Memory.Signals.emit_bridge_interrupt(agent_id, target_id, reason)
    end
  end
end
