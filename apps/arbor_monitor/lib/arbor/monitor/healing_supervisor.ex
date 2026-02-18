defmodule Arbor.Monitor.HealingSupervisor do
  @moduledoc """
  Supervises the self-healing infrastructure.

  This supervisor manages:
  - AnomalyQueue — queues anomalies for processing with deduplication
  - CascadeDetector — detects cascade failures and adjusts dedup windows
  - RejectionTracker — tracks proposal rejections for three-strike escalation
  - Verification — tracks fix verification during soak periods
  - HealingWorkers — DynamicSupervisor for healing agent workers

  ## Placement

  The HealingSupervisor starts ABOVE the monitoring components in the
  supervision tree. This ensures the healing infrastructure survives
  restarts of the components it heals.

  ## Configuration

  Each child can be configured via application env:

      config :arbor_monitor, :healing,
        anomaly_queue: [dedup_window_ms: 300_000],
        cascade_detector: [cascade_threshold: 5],
        rejection_tracker: [max_rejections: 3],
        verification: [soak_cycles: 5]
  """

  use Supervisor

  require Logger

  @doc """
  Starts the HealingSupervisor.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    healing_config =
      Keyword.get(opts, :healing, Application.get_env(:arbor_monitor, :healing, []))

    children =
      [
        # Queue must start first - other components may reference it
        {Arbor.Monitor.AnomalyQueue, Keyword.get(healing_config, :anomaly_queue, [])},
        {Arbor.Monitor.CascadeDetector, Keyword.get(healing_config, :cascade_detector, [])},
        {Arbor.Monitor.RejectionTracker, Keyword.get(healing_config, :rejection_tracker, [])},
        {Arbor.Monitor.Verification, Keyword.get(healing_config, :verification, [])},
        # DynamicSupervisor for healing worker processes
        {DynamicSupervisor, name: Arbor.Monitor.HealingWorkers, strategy: :one_for_one}
      ] ++ maybe_debug_agent_child(healing_config)

    Logger.info("[HealingSupervisor] Starting healing infrastructure")

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Start a healing worker under the DynamicSupervisor.

  Returns {:ok, pid} on success or {:error, reason} on failure.
  """
  @spec start_worker(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_worker(module, opts \\ []) do
    DynamicSupervisor.start_child(Arbor.Monitor.HealingWorkers, {module, opts})
  end

  @doc """
  Stop a healing worker.
  """
  @spec stop_worker(pid()) :: :ok | {:error, :not_found}
  def stop_worker(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(Arbor.Monitor.HealingWorkers, pid)
  end

  @doc """
  List all active healing workers.
  """
  @spec list_workers() :: [{:undefined, pid(), :worker | :supervisor, module()}]
  def list_workers do
    DynamicSupervisor.which_children(Arbor.Monitor.HealingWorkers)
  end

  @doc """
  Get the count of active healing workers.
  """
  @spec worker_count() :: non_neg_integer()
  def worker_count do
    DynamicSupervisor.count_children(Arbor.Monitor.HealingWorkers).active
  end

  # Runtime bridge: start DebugAgent if arbor_agent is loaded and enabled.
  # arbor_monitor is standalone (zero in-umbrella deps), so we use
  # Code.ensure_loaded? to avoid a compile-time dependency on arbor_agent.
  # Disable via: config :arbor_monitor, start_debug_agent: false
  defp maybe_debug_agent_child(healing_config) do
    enabled = Application.get_env(:arbor_monitor, :start_debug_agent, true)
    debug_agent_mod = Arbor.Agent.DebugAgent

    if enabled && Code.ensure_loaded?(debug_agent_mod) do
      opts = Keyword.get(healing_config, :debug_agent, [])
      opts = Keyword.put_new(opts, :display_name, "debug-agent")

      Logger.info("[HealingSupervisor] Starting DebugAgent (arbor_agent available)")
      [{debug_agent_mod, opts}]
    else
      unless enabled do
        Logger.debug("[HealingSupervisor] DebugAgent disabled via config")
      else
        Logger.debug("[HealingSupervisor] DebugAgent not available (arbor_agent not loaded)")
      end

      []
    end
  end
end
