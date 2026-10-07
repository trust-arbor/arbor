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
    deps: [Arbor.Common, Arbor.Contracts, Arbor.Identifiers, Jason, Logger, TypedStruct],
    exports: :all

  @behaviour Arbor.Contracts.API.Signals

  alias Arbor.Signals.{Bus, Config, DurableSink, Relay, Signal, Store, Taint, TopicKeys}

  if Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false) do
    @runtime_fixture_children [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.SubscriptionRegistry, []},
      {Arbor.Signals.TelemetryBridge, []},
      {Arbor.Signals.Bus, []},
      {Arbor.Signals.Relay, []}
    ]

    @doc false
    def build_signal_fixture(category, type, data, opts \\ []),
      do: Signal.new(category, type, data, opts)

    @doc false
    def receive_relay_batch_fixture(signals, from_node),
      do: Relay.receive_batch_fixture(signals, from_node)

    @doc false
    def list_subscriptions_fixture, do: Bus.list_subscriptions()

    @doc false
    def bus_pid_fixture do
      with supervisor when is_pid(supervisor) <- Process.whereis(Arbor.Signals.Supervisor),
           {:ok, bus} <- runtime_fixture_child_pid(supervisor, Bus) do
        bus
      else
        _unavailable_or_unowned -> nil
      end
    catch
      :exit, _reason -> nil
    end

    @doc false
    def restart_bus_fixture do
      supervisor = Process.whereis(Arbor.Signals.Supervisor)

      with true <- is_pid(supervisor),
           {:ok, old_bus} <- runtime_fixture_child_pid(supervisor, Bus),
           :ok <- Supervisor.terminate_child(supervisor, Bus),
           restart_result <- Supervisor.restart_child(supervisor, Bus),
           {:ok, new_bus} <- normalize_fixture_restart(restart_result),
           {:ok, ^new_bus} <- runtime_fixture_child_pid(supervisor, Bus) do
        {:ok, old_bus, new_bus}
      else
        false -> {:error, :signals_bus_unavailable}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _reason -> {:error, :signals_bus_unavailable}
    end

    @doc false
    def restore_runtime_fixture do
      with {:ok, _apps} <- Application.ensure_all_started(:arbor_kernel_runtime),
           supervisor when is_pid(supervisor) <- Process.whereis(Arbor.Signals.Supervisor),
           :ok <- restore_runtime_fixture_children(supervisor, @runtime_fixture_children),
           ^supervisor <- Process.whereis(Arbor.Signals.Supervisor) do
        :ok
      else
        nil -> {:error, :signals_supervisor_unavailable}
        supervisor when is_pid(supervisor) -> {:error, :signals_supervisor_replaced}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _reason -> {:error, :signals_supervisor_unavailable}
    end

    defp restore_runtime_fixture_children(_supervisor, []), do: :ok

    defp restore_runtime_fixture_children(supervisor, [{module, _opts} = child | rest]) do
      with :ok <- start_runtime_fixture_child(supervisor, module, child),
           :ok <- verify_runtime_fixture_child(supervisor, module) do
        restore_runtime_fixture_children(supervisor, rest)
      end
    end

    defp start_runtime_fixture_child(supervisor, module, child) do
      case Supervisor.start_child(supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          case Supervisor.restart_child(supervisor, module) do
            {:ok, _pid} -> :ok
            {:ok, _pid, _info} -> :ok
            {:error, :running} -> :ok
            {:error, reason} -> {:error, {module, reason}}
          end

        {:error, reason} ->
          {:error, {module, reason}}
      end
    end

    defp verify_runtime_fixture_child(supervisor, module) do
      case runtime_fixture_child_pid(supervisor, module) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, {module, reason}}
      end
    end

    defp runtime_fixture_child_pid(supervisor, module) do
      child_pid =
        Enum.find_value(Supervisor.which_children(supervisor), fn
          {^module, pid, :worker, _modules} when is_pid(pid) -> pid
          _other -> nil
        end)

      case {child_pid, Process.whereis(module)} do
        {pid, pid} when is_pid(pid) ->
          if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_alive}

        {nil, registered} when is_pid(registered) ->
          {:error, :foreign_registered_name}

        {_owned, _registered} ->
          {:error, :ownership_mismatch}
      end
    end

    defp normalize_fixture_restart({:ok, pid}) when is_pid(pid), do: {:ok, pid}
    defp normalize_fixture_restart({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
    defp normalize_fixture_restart({:error, reason}), do: {:error, reason}
  end

  @doc """
  Return the enforced trust model for cluster signal transport.

  Every node that possesses the Erlang distribution cookie is a cluster root.
  Signal origin fields are attribution, not proof of a less-privileged peer.
  """
  @spec cluster_trust_boundary() :: :distribution_cookie_root
  def cluster_trust_boundary, do: Config.cluster_trust_boundary()

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
  the configured durable sink. Restricted categories fail closed at this
  boundary: their realtime signal is protected, but no durable sink receives
  the plaintext while the only available topic keys are node-local and
  ephemeral. A stable durable-encryption provider must be introduced before
  those categories can be persisted safely. Dispatch waits for the sink callback; a
  ready sink's `:ok` means persist was observed, not fire-and-forget.
  Best-effort at this layer: this function still returns `:ok` after a
  sink persist failure so the bus emit is not rolled back. Standalone
  and test default is no sink.

  Lineage options are forwarded as Signals-shaped primitives:
  `:correlation_id`, `:agent_id`, `:metadata`, and `:cause_id`. Absent
  optional values stay nil — no empty sentinels. The sink stamps a
  system-owned `source_node` after dropping any caller atom/string
  `source_node` keys so JSON admission cannot emit duplicate names;
  system value wins.
  """
  @spec durable_emit(atom(), atom(), map(), keyword()) ::
          :ok | {:error, :restricted_durable_encryption_unavailable}
  def durable_emit(category, type, data, opts \\ []) do
    if category in Config.restricted_topics() do
      # Preserve realtime delivery, but do not mark the event permanent. Topic
      # keys are process-local and cannot make a restart-safe checkpoint.
      case emit(category, type, data, opts) do
        :ok -> {:error, :restricted_durable_encryption_unavailable}
        error -> error
      end
    else
      case emit(category, type, Map.put(data, :permanent, true), opts) do
        :ok ->
          stream_id = Keyword.get(opts, :stream_id, "#{category}_events")
          DurableSink.dispatch(stream_id, type, data, opts)
          :ok

        error ->
          error
      end
    end
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
          {:ok, String.t(), pid(), reference()} | {:error, :unauthorized}
  def subscribe_security_sync(role, event),
    do: Bus.subscribe_security_sync(role, event)

  @doc false
  @spec security_sync_transport_configured?() :: boolean()
  def security_sync_transport_configured?, do: Config.security_sync_transport_configured?()

  @doc false
  @spec security_sync_role_configured?(atom()) :: boolean()
  def security_sync_role_configured?(role), do: Config.security_sync_role_configured?(role)

  @doc """
  Whether remote-origin security-sync mutations may be applied.

  False until an authenticated cluster transport exists. A configured
  `security_sync_subscribers` map is not authenticated transport.
  """
  @spec authenticated_security_sync_transport?() :: boolean()
  def authenticated_security_sync_transport?,
    do: Config.authenticated_security_sync_transport?()

  @doc """
  Whether a remote-origin security mutation of `type` may be applied.

  Authority-reducing mutations (revocation, suspension, deregistration) are
  always admitted; authority-granting ones require an authenticated sync
  transport. See `Arbor.Signals.Config.admit_remote_security_mutation?/1`.
  """
  @spec admit_remote_security_mutation?(atom()) :: boolean()
  def admit_remote_security_mutation?(type),
    do: Config.admit_remote_security_mutation?(type)

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
    # Event identity and attribution are owned by this boundary. A caller may
    # preserve lineage and metadata, but cannot inject an old/future timestamp,
    # collide with an existing ID, or impersonate another process/node.
    signal = restamp_local_signal(signal)

    if healthy?() do
      # Encrypt restricted-topic signals BEFORE storing to prevent
      # plaintext sensitive data in the Store. Bus.publish will skip
      # re-encryption if already encrypted (__encrypted__: true marker).
      protected = protect_restricted_signal(signal)

      case Bus.publish_canonical(protected) do
        {:ok, canonical} ->
          store_signal(canonical, async?)

          :telemetry.execute(
            [:arbor, :signals, :emitted],
            %{count: 1},
            %{category: canonical.category, type: canonical.type}
          )

          :ok

        {:error, _reason} = error ->
          error
      end
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

    if category in restricted_topics and data != %{} and not already_encrypted?(data) and
         not portable_security_sync_signal?(signal) do
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

  # TopicKeys are deliberately node-local. Encrypting the monotonic security
  # mutations that must cross the cluster makes them undecryptable on every
  # peer and silently defeats revocation. These events carry identifiers and
  # state transitions rather than secrets; cluster admission remains enforced
  # by Relay and the security consumers. Authority-adding events stay encrypted
  # and are rejected remotely while authenticated sync transport is absent.
  defp portable_security_sync_signal?(%Signal{category: category, type: type}) do
    category in [:security, :identity] and
      (type == :nonce_seen or type in Config.authority_reducing_security_mutations())
  end

  defp restamp_local_signal(%Signal{} = signal) do
    Signal.new(signal.category, signal.type, signal.data,
      source: signal.source,
      cause_id: signal.cause_id,
      correlation_id: signal.correlation_id,
      metadata: signal.metadata,
      scope: signal.scope
    )
    |> Map.put(:emitter_pid, self())
    |> Map.put(:origin_node, node())
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
