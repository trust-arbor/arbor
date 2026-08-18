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

  use Boundary,
    top_level?: true,
    deps: [Arbor.Contracts, Arbor.Identifiers, Jason, Logger, TypedStruct],
    exports: :all

  @behaviour Arbor.Contracts.API.Signals

  alias Arbor.Signals.{Bus, Config, DurableSink, Relay, Signal, Store, Taint, TopicKeys}

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
  - `:async` - When false, wait until the signal is stored before returning
    (default: true). Subscriber delivery remains bus-scheduled.

  ## Examples

      :ok = Arbor.Signals.emit(:activity, :agent_started, %{agent_id: "agent_001"})
  """
  @spec emit(atom(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def emit(category, type, data \\ %{}, opts \\ []),
    do: emit_signal_for_category_and_type(category, type, data, opts)

  @doc """
  Emit a durable signal — real-time bus plus the configured durable sink.

  Use this for events that must survive restarts and be queryable later:
  LLM call traces, worker lifecycle, security audit events.

  Same API as `emit/4` but additionally dispatches the original data to
  the configured durable sink (synchronous hot append, asynchronous
  durable append when the sink provides them). Best-effort: the signal
  always emits even if persistence fails. Standalone and test default
  is no sink.

  Lineage options are forwarded as Signals-shaped primitives:
  `:correlation_id`, `:agent_id`, `:metadata`, and `:cause_id`. Absent
  optional values stay nil — no empty sentinels. The sink stamps a
  system-owned `source_node` after dropping any caller atom/string
  `source_node` keys so JSON admission cannot emit duplicate names;
  system value wins.
  """
  @spec durable_emit(atom(), atom(), map(), keyword()) :: :ok
  def durable_emit(category, type, data, opts \\ []) do
    emit(category, type, Map.put(data, :permanent, true), opts)

    stream_id = Keyword.get(opts, :stream_id, "#{category}_events")
    DurableSink.dispatch(stream_id, type, data, opts)

    :ok
  end

  @doc """
  Emit a signal with taint metadata attached.

  This is like `emit/4` but automatically adds taint tracking metadata to the signal.
  Use this when emitting signals that carry data with known provenance.

  ## Options

  All options from `emit/4` are supported, plus:
  - `:taint_source` - Identifier of the taint source (e.g., "external_api", "llm_output")
  - `:taint_chain` - List of signal IDs in the taint propagation chain

  ## Examples

      :ok = Arbor.Signals.emit_tainted(:activity, :data_received, %{content: "..."},
        :untrusted,
        taint_source: "external_api"
      )
  """
  @spec emit_tainted(atom(), atom(), map(), Taint.level(), keyword()) :: :ok | {:error, term()}
  def emit_tainted(category, type, data, taint_level, opts \\ []) do
    taint_source = Keyword.get(opts, :taint_source)
    taint_chain = Keyword.get(opts, :taint_chain, [])
    taint_meta = Taint.to_metadata(taint_level, taint_source, taint_chain)

    merged_opts =
      Keyword.update(opts, :metadata, taint_meta, fn existing ->
        Taint.merge_metadata(existing, taint_meta)
      end)

    emit(category, type, data, merged_opts)
  end

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

  @doc false
  @spec subscribe_security_sync(atom(), atom()) ::
          {:ok, String.t(), pid()} | {:error, :unauthorized}
  def subscribe_security_sync(role, event),
    do: Bus.subscribe_security_sync(role, event)

  @doc """
  Whether remote-origin security-sync mutations may be applied.

  False until an authenticated cluster transport exists. A configured
  `security_sync_subscribers` map is not authenticated transport.
  """
  @spec authenticated_security_sync_transport?() :: boolean()
  def authenticated_security_sync_transport?,
    do: Config.authenticated_security_sync_transport?()

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

  @doc """
  Delete retained `:memory` signal content for exactly one agent id.

  See `delete_retained_memory_signal_content_for_agent/2`.
  """
  @spec delete_memory_agent_content(String.t(), keyword()) ::
          Arbor.Contracts.API.Signals.retained_memory_signal_delete_result()
  def delete_memory_agent_content(agent_id, opts \\ []),
    do: delete_retained_memory_signal_content_for_agent(agent_id, opts)

  @doc """
  Read-only check that retained `:memory` signal content for one agent is absent.

  See `check_retained_memory_signal_content_absent_for_agent/2`.
  """
  @spec memory_agent_content_absent?(String.t(), keyword()) ::
          Arbor.Contracts.API.Signals.retained_memory_signal_absence_result()
  def memory_agent_content_absent?(agent_id, opts \\ []),
    do: check_retained_memory_signal_content_absent_for_agent(agent_id, opts)

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl true
  def emit_signal_for_category_and_type(category, type, data, opts) do
    signal = Signal.new(category, type, data, opts)
    # Set emitter_pid and origin_node server-side so they can't be spoofed
    signal = %{signal | emitter_pid: self(), origin_node: node()}
    emit_preconstructed_signal(signal, Keyword.get(opts, :async, true))
  end

  @impl true
  def emit_preconstructed_signal(%Signal{} = signal),
    do: emit_preconstructed_signal(signal, true)

  defp emit_preconstructed_signal(%Signal{} = signal, async?) do
    # Stamp emitter_pid and origin_node if not already set
    signal = if signal.emitter_pid, do: signal, else: %{signal | emitter_pid: self()}
    signal = if signal.origin_node, do: signal, else: %{signal | origin_node: node()}

    if healthy?() do
      # Encrypt restricted-topic signals BEFORE storing to prevent
      # plaintext sensitive data in the Store. Bus.publish will skip
      # re-encryption if already encrypted (__encrypted__: true marker).
      protected = protect_restricted_signal(signal)
      store_signal(protected, async?)
      Bus.publish(protected)

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

  defp store_signal(signal, false), do: Store.put_sync(signal)
  defp store_signal(signal, _async), do: Store.put(signal)

  # Encrypt signal data for restricted topics before storage.
  # This prevents plaintext sensitive payloads from sitting in the Store.
  defp protect_restricted_signal(%Signal{category: category, data: data} = signal) do
    restricted_topics = Config.restricted_topics()

    if category in restricted_topics and data != %{} and not already_encrypted?(data) do
      try do
        with {:ok, json} <- Jason.encode(data),
             {:ok, encrypted} <- TopicKeys.encrypt(category, json) do
          %{signal | data: %{__encrypted__: true, payload: encrypted}}
        else
          {:error, _reason} ->
            # If encryption fails, redact data rather than store plaintext
            %{signal | data: %{__redacted__: true, reason: :encryption_failed}}
        end
      catch
        :exit, _ ->
          # TopicKeys process not running — redact rather than crash
          %{signal | data: %{__redacted__: true, reason: :encryption_unavailable}}
      end
    else
      signal
    end
  end

  defp already_encrypted?(%{__encrypted__: true}), do: true
  defp already_encrypted?(_), do: false

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

  @impl true
  def delete_retained_memory_signal_content_for_agent(agent_id, opts) do
    Store.delete_memory_agent_content(agent_id, opts)
  end

  @impl true
  def check_retained_memory_signal_content_absent_for_agent(agent_id, opts) do
    Store.memory_agent_content_absent?(agent_id, opts)
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

    relay_stats = Relay.stats()

    %{
      store: store_stats,
      bus: bus_stats,
      relay: relay_stats,
      healthy: healthy?()
    }
  end

  # ============================================================================
  # Interrupt Protocol
  # ============================================================================

  @doc """
  Signal an interrupt to a target.

  Bodies check for interrupts periodically during long-running operations.

  ## Options

  - `:replacement_intent_id` — ID of new intent that should take over
  - `:allow_resume` — Whether interrupted work can resume (default: false)
  """
  @impl true
  @spec interrupt(String.t(), atom(), keyword()) :: :ok
  def interrupt(target_id, reason, opts \\ []) do
    Store.interrupt(target_id, reason, opts)
  end

  @doc """
  Check if a target has been interrupted.

  Returns the interrupt data map if interrupted, `false` otherwise.
  """
  @impl true
  @spec interrupted?(String.t()) :: map() | false
  def interrupted?(target_id) do
    Store.interrupted?(target_id)
  end

  @doc """
  Clear an interrupt for a target, allowing normal operation to resume.
  """
  @impl true
  @spec clear_interrupt(String.t()) :: :ok
  def clear_interrupt(target_id) do
    Store.clear_interrupt(target_id)
  end
end
