defmodule Arbor.Trust.Supervisor do
  @moduledoc """
  Supervisor for the progressive trust system components.

  Manages the lifecycle of all trust-related processes:
  - Trust.Store - ETS-cached trust profile storage
  - Trust.Manager - Main trust coordination GenServer
  - Trust.EventHandler - PubSub event subscriber
  - Trust.CircuitBreaker - Anomaly detection
  - Trust.Decay - Scheduled trust decay
  - Trust.EventStore - Durable event storage
  - Trust.CapabilitySync - Trust↔capability bridge

  ## Startup Order

  Components are started in dependency order:
  1. Store (no dependencies)
  2. EventStore (writes to Persistence.EventLog when configured)
  3. Manager (depends on Store)
  4. CircuitBreaker (depends on Manager)
  5. EventHandler (depends on Manager)
  6. Decay (depends on Store)
  7. CapabilitySync (depends on Manager)

  ## Configuration

  The supervisor accepts the following options:

  - `:enabled` - Enable/disable the trust system (default: true)
  - `:decay_enabled` - Enable trust decay (default: true)
  - `:circuit_breaker_enabled` - Enable circuit breaker (default: true)
  - `:event_handler_enabled` - Enable event handler (default: true)
  - `:capability_sync_enabled` - Enable capability sync (default: true)
  - `:event_store_enabled` - Enable durable event store (default: true)

  ## Usage

      # Start with defaults
      {:ok, pid} = Trust.Supervisor.start_link()

      # Start with custom options
      {:ok, pid} = Trust.Supervisor.start_link(decay_enabled: false)
  """

  use Supervisor

  alias Arbor.Trust.{
    Store,
    Manager,
    EventHandler,
    CircuitBreaker,
    Decay,
    CapabilitySync,
    EventStore
  }

  require Logger

  @doc """
  Start the trust supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if the trust system is running.
  """
  @spec running?() :: boolean()
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Get the status of all trust components.
  """
  @spec status() :: %{
          supervisor: :stopped | {:running, pid()},
          store: :stopped | {:running, pid()},
          event_store: :stopped | {:running, pid()},
          manager: :stopped | {:running, pid()},
          event_handler: :stopped | {:running, pid()},
          circuit_breaker: :stopped | {:running, pid()},
          decay: :stopped | {:running, pid()},
          capability_sync: :stopped | {:running, pid()}
        }
  def status do
    %{
      supervisor: process_status(__MODULE__),
      store: process_status(Store),
      event_store: process_status(EventStore),
      manager: process_status(Manager),
      event_handler: process_status(EventHandler),
      circuit_breaker: process_status(CircuitBreaker),
      decay: process_status(Decay),
      capability_sync: process_status(CapabilitySync)
    }
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      children = build_children(opts)

      Logger.info("Starting Trust.Supervisor with #{length(children)} children")

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.info("Trust system disabled, not starting children")
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  # Private functions

  defp build_children(opts) do
    decay_enabled = Keyword.get(opts, :decay_enabled, true)
    circuit_breaker_enabled = Keyword.get(opts, :circuit_breaker_enabled, true)
    event_handler_enabled = Keyword.get(opts, :event_handler_enabled, true)
    capability_sync_enabled = Keyword.get(opts, :capability_sync_enabled, true)
    event_store_enabled = Keyword.get(opts, :event_store_enabled, true)

    # Core components (always started)
    children = [
      {Store, []},
      {EventStore, []},
      {Manager,
       [
         circuit_breaker: circuit_breaker_enabled,
         decay: decay_enabled,
         event_store: event_store_enabled
       ]}
    ]

    # Optional components
    children =
      if circuit_breaker_enabled do
        children ++ [{CircuitBreaker, []}]
      else
        children
      end

    children =
      if event_handler_enabled do
        children ++ [{EventHandler, [enabled: true]}]
      else
        children
      end

    children =
      if decay_enabled do
        children ++ [{Decay, [enabled: true]}]
      else
        children
      end

    children =
      if capability_sync_enabled do
        children ++ [{CapabilitySync, [enabled: true]}]
      else
        children
      end

    children
  end

  defp process_status(name) do
    case Process.whereis(name) do
      nil -> :stopped
      pid -> {:running, pid}
    end
  end
end
