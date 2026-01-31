defmodule Arbor.Signals do
  @moduledoc """
  Core signal infrastructure for the Arbor platform.

  Arbor.Signals provides the foundational primitives for emitting, storing,
  and subscribing to signals. Other libraries (arbor_shell, arbor_security,
  arbor_core) build domain-specific APIs on top of this core.

  ## Quick Start

      # Emit a signal
      :ok = Arbor.Signals.emit(:activity, :agent_started, %{agent_id: "agent_001"})

      # Subscribe to signals
      {:ok, sub_id} = Arbor.Signals.subscribe("activity.*", fn signal ->
        IO.inspect(signal, label: "Activity")
        :ok
      end)

      # Query recent signals
      {:ok, signals} = Arbor.Signals.recent(limit: 10, category: :activity)

  ## Subscription Patterns

  - `"activity.*"` - All signals with category :activity
  - `"*.agent_started"` - All signals with type :agent_started
  - `"activity.agent_started"` - Specific category and type
  - `"*"` - All signals

  ## Architecture

  Signals flow through:
  1. **Emission** - `emit/3,4` creates and dispatches signals
  2. **Storage** - In-memory buffer with TTL and size limits
  3. **Bus** - Pub/sub delivery to subscribers
  4. **Telemetry** - Integration with Erlang telemetry

  ## Building On Top

  Other libraries should create their own domain-specific helpers:

      # In arbor_shell
      def emit_command_executed(cmd, result, opts \\\\ []) do
        Arbor.Signals.emit(:shell, :command_executed, %{
          command: cmd,
          result: result
        }, opts)
      end
  """

  @behaviour Arbor.Contracts.API.Signals

  alias Arbor.Signals.{Bus, Signal, Store}

  # ===========================================================================
  # Public API — short, human-friendly names
  # ===========================================================================

  @doc """
  Emit a signal with the given category, type, and data.

  ## Options

  - `:source` - Identifier of the signal source
  - `:cause_id` - ID of the signal that caused this one
  - `:correlation_id` - ID for correlating related signals
  - `:metadata` - Additional metadata map
  - `:async` - Don't wait for storage/delivery (default: true)

  ## Examples

      :ok = Arbor.Signals.emit(:activity, :agent_started, %{agent_id: "agent_001"})
  """
  @spec emit(atom(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def emit(category, type, data \\ %{}, opts \\ []),
    do: emit_signal_for_category_and_type(category, type, data, opts)

  @doc "Emit a pre-constructed signal."
  @spec emit_signal(Signal.t()) :: :ok | {:error, term()}
  def emit_signal(%Signal{} = signal), do: emit_preconstructed_signal(signal)

  @doc """
  Subscribe to signals matching a pattern.

  ## Patterns

  - `"activity.*"` - All activity signals
  - `"*.agent_started"` - Agent started from any category
  - `"*"` - All signals
  """
  @spec subscribe(String.t(), (Signal.t() -> :ok | {:error, term()}), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe(pattern, handler, opts \\ []),
    do: subscribe_to_signals_matching_pattern(pattern, handler, opts)

  @doc "Unsubscribe from signals."
  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  def unsubscribe(subscription_id),
    do: unsubscribe_from_signals_by_subscription_id(subscription_id)

  @doc "Get a signal by ID."
  @spec get_signal(String.t()) :: {:ok, Signal.t()} | {:error, :not_found}
  def get_signal(signal_id), do: get_signal_by_id(signal_id)

  @doc "Query signals with filters."
  @spec query(keyword()) :: {:ok, [Signal.t()]} | {:error, term()}
  def query(filters \\ []), do: query_signals_with_filters(filters)

  @doc "Get recent signals."
  @spec recent(keyword()) :: {:ok, [Signal.t()]} | {:error, term()}
  def recent(opts \\ []), do: get_recent_signals_from_buffer(opts)

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl true
  def emit_signal_for_category_and_type(category, type, data, opts) do
    signal = Signal.new(category, type, data, opts)
    emit_preconstructed_signal(signal)
  end

  @impl true
  def emit_preconstructed_signal(%Signal{} = signal) do
    if healthy?() do
      Store.put(signal)
      Bus.publish(signal)

      :telemetry.execute(
        [:arbor, :signals, :emitted],
        %{count: 1},
        %{category: signal.category, type: signal.type}
      )

      :ok
    else
      {:error, :signal_system_not_ready}
    end
  end

  @impl true
  def subscribe_to_signals_matching_pattern(pattern, handler, opts) do
    Bus.subscribe(pattern, handler, opts)
  end

  @impl true
  def unsubscribe_from_signals_by_subscription_id(subscription_id) do
    Bus.unsubscribe(subscription_id)
  end

  @impl true
  def get_signal_by_id(signal_id) do
    Store.get(signal_id)
  end

  @impl true
  def query_signals_with_filters(filters) do
    Store.query(filters)
  end

  @impl true
  def get_recent_signals_from_buffer(opts) do
    Store.recent(opts)
  end

  # System API

  @doc """
  Start the signals system.

  Normally started automatically by the application supervisor.
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Signals.Application.start(:normal, opts)
  end

  @doc """
  Check if the signals system is healthy.
  """
  @impl true
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(Store) != nil and Process.whereis(Bus) != nil
  end

  @doc """
  Get system statistics.

  Returns combined stats from store and bus.
  """
  @spec stats() :: map()
  def stats do
    store_stats = Store.stats()
    bus_stats = Bus.stats()

    %{
      store: store_stats,
      bus: bus_stats,
      healthy: healthy?()
    }
  end
end
