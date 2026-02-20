defmodule Arbor.Monitor.HealingSupervisor do
  @moduledoc """
  Supervises the self-healing infrastructure.

  This supervisor manages:
  - AnomalyQueue — queues anomalies for processing with deduplication
  - CascadeDetector — detects cascade failures and adjusts dedup windows
  - RejectionTracker — tracks proposal rejections for three-strike escalation
  - Verification — tracks fix verification during soak periods
  - HealingWorkers — DynamicSupervisor for healing agent workers
  - AnomalyForwarder — bridges anomaly signals to the ops chat room

  ## Ops Room Architecture

  Instead of running a custom DebugAgent GenServer, the healing system creates
  an ops chat room (GroupChat) with a standard diagnostician agent. The
  AnomalyForwarder subscribes to monitor signals and posts them as messages
  to the ops room. Humans and other agents can join the room to collaborate.

  The diagnostician agent is started via `Manager.start_or_resume` (runtime bridge)
  using a deferred Task to wait for agent infrastructure to be available.

  ## Configuration

  Each child can be configured via application env:

      config :arbor_monitor, :healing,
        anomaly_queue: [dedup_window_ms: 300_000],
        cascade_detector: [cascade_threshold: 5],
        rejection_tracker: [max_rejections: 3],
        verification: [soak_cycles: 5]

      config :arbor_monitor, :start_ops_room, true
  """

  use Supervisor

  alias Arbor.Monitor.AnomalyForwarder

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

  # Deferred ops room setup — waits for agent infrastructure then creates
  # the diagnostician agent and ops room GroupChat.
  defp maybe_schedule_ops_room do
    enabled = Application.get_env(:arbor_monitor, :start_ops_room, true)

    if enabled do
      Task.start(fn ->
        # Wait for agent infrastructure to be available
        Process.sleep(5_000)
        setup_ops_room()
      end)
    end
  end

  defp setup_ops_room do
    manager_mod = Arbor.Agent.Manager
    group_chat_mod = Arbor.Agent.GroupChat
    lifecycle_mod = Arbor.Agent.Lifecycle
    template_mod = Arbor.Agent.Templates.Diagnostician
    api_agent_mod = Arbor.Agent.APIAgent

    with true <- Code.ensure_loaded?(manager_mod),
         true <- Code.ensure_loaded?(group_chat_mod),
         true <- Code.ensure_loaded?(template_mod),
         true <- Code.ensure_loaded?(api_agent_mod) do
      # Start or resume the diagnostician agent
      agent_result =
        try do
          apply(manager_mod, :start_or_resume, [
            api_agent_mod,
            "diagnostician",
            [
              template: template_mod,
              start_host: true
            ]
          ])
        rescue
          error ->
            Logger.warning("[HealingSupervisor] Failed to start diagnostician: #{inspect(error)}")
            {:error, error}
        catch
          :exit, reason ->
            Logger.warning(
              "[HealingSupervisor] Failed to start diagnostician (exit): #{inspect(reason)}"
            )

            {:error, reason}
        end

      case agent_result do
        {:ok, agent_id, _pid} ->
          create_ops_room(agent_id, group_chat_mod, lifecycle_mod, manager_mod)

        {:ok, agent_id} ->
          create_ops_room(agent_id, group_chat_mod, lifecycle_mod, manager_mod)

        {:error, reason} ->
          Logger.warning("[HealingSupervisor] Could not start diagnostician: #{inspect(reason)}")
      end
    else
      false ->
        Logger.debug(
          "[HealingSupervisor] Agent infrastructure not available, ops room disabled"
        )
    end
  end

  defp create_ops_room(agent_id, group_chat_mod, lifecycle_mod, _manager_mod) do
    # Look up the host process for the agent
    host_pid =
      try do
        case apply(lifecycle_mod, :get_host, [agent_id]) do
          {:ok, pid} -> pid
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    participants = [
      %{id: agent_id, name: "Diagnostician", type: :agent, host_pid: host_pid}
    ]

    case apply(group_chat_mod, :create, ["ops-room", [participants: participants]]) do
      {:ok, group_pid} ->
        # Wire the forwarder to the new group
        try do
          AnomalyForwarder.set_group(group_pid)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        Logger.info(
          "[HealingSupervisor] Ops room created with diagnostician agent #{agent_id}"
        )

      {:error, reason} ->
        Logger.warning("[HealingSupervisor] Failed to create ops room: #{inspect(reason)}")
    end
  end
end
