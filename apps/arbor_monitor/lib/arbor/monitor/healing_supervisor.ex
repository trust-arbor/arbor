defmodule Arbor.Monitor.HealingSupervisor do
  @moduledoc """
  Supervises the self-healing infrastructure.

  This supervisor manages:
  - AnomalyQueue — queues anomalies for processing with deduplication
  - CascadeDetector — detects cascade failures and adjusts dedup windows
  - RejectionTracker — tracks proposal rejections for three-strike escalation
  - Verification — tracks fix verification during soak periods
  - HealingWorkers — DynamicSupervisor for healing agent workers
  - AnomalyForwarder — bridges anomaly signals to the ops channel

  ## Ops Room Architecture

  Instead of running a custom DebugAgent GenServer, the healing system creates
  an ops channel through the configured channel-bridge provider with a
  standard diagnostician agent. The AnomalyForwarder posts monitor signals
  as messages to that channel. Humans and other agents can join to collaborate.

  Diagnostician lookup uses the configured agent-directory provider. The
  diagnostician agent itself is started outside this supervisor.

  Fallback lookup is deferred on an unsupervised Task so supervisor init is
  not blocked. That Task lifecycle is unchanged.

  ## Configuration

  Each child can be configured via application env:

      config :arbor_kernel, monitor: [
        healing: [
          anomaly_queue: [dedup_window_ms: 300_000],
          cascade_detector: [cascade_threshold: 5],
          rejection_tracker: [max_rejections: 3],
          verification: [soak_cycles: 5]
        ],
        start_ops_room: true
      ]
  """

  use Supervisor

  alias Arbor.Monitor.AnomalyForwarder
  alias Arbor.Monitor.Config
  alias Arbor.Monitor.Provider

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
      Keyword.get(opts, :healing, Config.healing())

    children =
      [
        # Queue must start first - other components may reference it
        {Arbor.Monitor.AnomalyQueue, Keyword.get(healing_config, :anomaly_queue, [])},
        {Arbor.Monitor.CascadeDetector, Keyword.get(healing_config, :cascade_detector, [])},
        {Arbor.Monitor.RejectionTracker, Keyword.get(healing_config, :rejection_tracker, [])},
        {Arbor.Monitor.Verification, Keyword.get(healing_config, :verification, [])},
        # DynamicSupervisor for healing worker processes
        {DynamicSupervisor, name: Arbor.Monitor.HealingWorkers, strategy: :one_for_one},
        # Forwards anomaly signals to the ops chat room
        {AnomalyForwarder, []}
      ]

    Logger.info("[HealingSupervisor] Starting healing infrastructure")

    # Schedule deferred ops room setup after children start
    maybe_schedule_ops_room()

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

  @doc false
  def setup_ops_room_fallback do
    case Provider.list_agents() do
      {:ok, agents} ->
        case Enum.find(agents, &(&1.display_name == "diagnostician")) do
          %{agent_id: agent_id} ->
            setup_ops_room_for_agent(agent_id)

          nil ->
            Logger.debug("[HealingSupervisor] No diagnostician agent found, ops room disabled")
        end

      {:skip, :absent} ->
        Logger.debug(
          "[HealingSupervisor] agent directory not configured, ops room lookup skipped"
        )

      {:skip, :provider_raised, exception_struct} ->
        Logger.warning(
          "[HealingSupervisor] directory skipped: provider_raised #{inspect(exception_struct)}"
        )

      {:skip, reason} ->
        Logger.warning("[HealingSupervisor] directory skipped: #{reason}")

      {:error, reason} ->
        Logger.warning("[HealingSupervisor] directory skipped: #{reason}")
    end
  end

  # Deferred ops room setup — subscribes to Bootstrap signal, with fallback poll.
  # The diagnostician agent is started outside this supervisor.
  defp maybe_schedule_ops_room do
    enabled = Config.start_ops_room?()

    if enabled do
      Task.start(fn ->
        subscribe_to_bootstrap_signal()
        # Fallback: if no signal within 30s, poll for existing diagnostician
        Process.sleep(30_000)
        setup_ops_room_fallback()
      end)
    end
  end

  defp subscribe_to_bootstrap_signal do
    signals_mod = Arbor.Signals

    if Code.ensure_loaded?(signals_mod) do
      try do
        apply(signals_mod, :subscribe, [
          "agent.bootstrap_completed",
          fn signal ->
            agents = get_in(signal.data, [:agents]) || []

            case Enum.find(agents, &(&1[:display_name] == "diagnostician")) do
              %{agent_id: agent_id} ->
                setup_ops_room_for_agent(agent_id)

              _ ->
                Logger.debug("[HealingSupervisor] Bootstrap completed but no diagnostician found")
            end

            :ok
          end
        ])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp setup_ops_room_for_agent(agent_id) do
    participants = [
      %{id: agent_id, name: "Diagnostician", type: :agent},
      %{id: "anomaly_forwarder", name: "Monitor", type: :system}
    ]

    case Provider.create_ops_room("ops-room", participants) do
      {:ok, channel_id} ->
        try do
          AnomalyForwarder.set_channel(channel_id)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        Logger.info("[HealingSupervisor] Ops room created with diagnostician agent #{agent_id}")

      {:skip, :absent} ->
        Logger.debug("[HealingSupervisor] channel bridge not configured, ops room create skipped")

      {:skip, :provider_raised, exception_struct} ->
        Logger.warning(
          "[HealingSupervisor] Failed to create ops room: provider_raised #{inspect(exception_struct)}"
        )

      {:skip, reason} ->
        Logger.warning("[HealingSupervisor] Failed to create ops room: #{reason}")

      {:error, reason} ->
        Logger.warning("[HealingSupervisor] Failed to create ops room: #{inspect(reason)}")
    end
  end
end
