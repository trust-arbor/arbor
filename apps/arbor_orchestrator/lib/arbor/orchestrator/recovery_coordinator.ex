defmodule Arbor.Orchestrator.RecoveryCoordinator do
  @moduledoc """
  Discovers and resumes interrupted pipelines on boot.

  Starts after JobRegistry in the supervision tree. On init, queries for
  entries with `status: :interrupted` (set by JobRegistry when it detects
  orphaned `:running` entries from a previous life). Resumes them with
  throttled concurrency to prevent restart storms.

  ## Configuration

      config :arbor_orchestrator,
        recovery_enabled: true,
        recovery_max_concurrent: 3,
        recovery_delay_ms: 1000
  """

  use GenServer

  require Logger

  alias Arbor.Orchestrator.JobRegistry
  alias Arbor.Orchestrator.JobRegistry.Entry

  @default_max_concurrent 3
  @default_delay_ms 1_000
  @heartbeat_check_interval_ms 30_000
  @stale_heartbeat_ms 90_000
  @pg_group {:arbor, :recovery_coordinators}

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current recovery status."
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:arbor_orchestrator, :recovery_enabled, true)
      )

    max_concurrent =
      Keyword.get(
        opts,
        :max_concurrent,
        Application.get_env(
          :arbor_orchestrator,
          :recovery_max_concurrent,
          @default_max_concurrent
        )
      )

    delay_ms =
      Keyword.get(
        opts,
        :delay_ms,
        Application.get_env(:arbor_orchestrator, :recovery_delay_ms, @default_delay_ms)
      )

    state = %{
      enabled: enabled,
      max_concurrent: max_concurrent,
      delay_ms: delay_ms,
      recovering: %{},
      recovered: [],
      failed: [],
      pending: []
    }

    if enabled do
      # Join :pg group for cross-node coordinator discovery
      join_pg_group()

      # Monitor other nodes for crash detection
      :net_kernel.monitor_nodes(true)

      # Delay recovery to let the rest of the system stabilize
      Process.send_after(self(), :discover_interrupted, delay_ms)

      # Periodic heartbeat staleness check
      Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      recovering: map_size(state.recovering),
      recovered: length(state.recovered),
      failed: length(state.failed),
      pending: length(state.pending)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:discover_interrupted, state) do
    interrupted = JobRegistry.list_interrupted()

    if interrupted == [] do
      Logger.debug("[RecoveryCoordinator] No interrupted pipelines found")
      {:noreply, state}
    else
      Logger.info("[RecoveryCoordinator] Found #{length(interrupted)} interrupted pipeline(s)")

      state = %{state | pending: interrupted}
      send(self(), :recover_next)
      {:noreply, state}
    end
  end

  def handle_info(:recover_next, %{pending: []} = state) do
    if state.recovering == %{} do
      Logger.info(
        "[RecoveryCoordinator] Recovery complete. " <>
          "Recovered: #{length(state.recovered)}, " <>
          "Failed: #{length(state.failed)}"
      )
    end

    {:noreply, state}
  end

  def handle_info(:recover_next, state) do
    available_slots = state.max_concurrent - map_size(state.recovering)

    if available_slots <= 0 do
      {:noreply, state}
    else
      {to_recover, remaining} = Enum.split(state.pending, available_slots)

      recovering =
        Enum.reduce(to_recover, state.recovering, fn entry, acc ->
          key = entry.run_id || entry.pipeline_id

          case attempt_recovery(entry) do
            {:ok, task_ref} ->
              Map.put(acc, task_ref, key)

            {:error, reason} ->
              Logger.warning("[RecoveryCoordinator] Cannot recover #{key}: #{inspect(reason)}")

              acc
          end
        end)

      {:noreply, %{state | pending: remaining, recovering: recovering}}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completion
    Process.demonitor(ref, [:flush])

    case Map.pop(state.recovering, ref) do
      {nil, _} ->
        {:noreply, state}

      {pipeline_id, recovering} ->
        state =
          case result do
            {:ok, _} ->
              Logger.info("[RecoveryCoordinator] Recovered pipeline #{pipeline_id}")
              %{state | recovering: recovering, recovered: [pipeline_id | state.recovered]}

            {:error, reason} ->
              Logger.warning(
                "[RecoveryCoordinator] Failed to recover #{pipeline_id}: " <>
                  inspect(reason)
              )

              %{state | recovering: recovering, failed: [{pipeline_id, reason} | state.failed]}
          end

        # Schedule next batch after delay
        if state.pending != [] do
          Process.send_after(self(), :recover_next, state.delay_ms)
        end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.recovering, ref) do
      {nil, _} ->
        {:noreply, state}

      {pipeline_id, recovering} ->
        Logger.warning(
          "[RecoveryCoordinator] Recovery task crashed for #{pipeline_id}: " <>
            inspect(reason)
        )

        state = %{
          state
          | recovering: recovering,
            failed: [{pipeline_id, {:crashed, reason}} | state.failed]
        }

        if state.pending != [] do
          Process.send_after(self(), :recover_next, state.delay_ms)
        end

        {:noreply, state}
    end
  end

  def handle_info({:nodedown, dead_node}, state) do
    if state.enabled do
      Logger.info(
        "[RecoveryCoordinator] Node #{dead_node} went down, scanning for orphaned pipelines"
      )

      # Find pipelines owned by the dead node
      orphaned = JobRegistry.list_by_owner(dead_node)

      if orphaned != [] do
        Logger.info(
          "[RecoveryCoordinator] Found #{length(orphaned)} orphaned pipeline(s) from #{dead_node}"
        )

        # Mark them interrupted, then attempt claim
        claimable =
          Enum.flat_map(orphaned, fn entry ->
            key = entry.run_id || entry.pipeline_id

            if key do
              JobRegistry.mark_interrupted(key)

              case attempt_claim(entry) do
                {:ok, claimed_entry} -> [claimed_entry]
                {:error, _reason} -> []
              end
            else
              []
            end
          end)

        if claimable != [] do
          state = %{state | pending: state.pending ++ claimable}
          send(self(), :recover_next)
          {:noreply, state}
        else
          {:noreply, state}
        end
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  def handle_info(:check_stale_heartbeats, state) do
    if state.enabled do
      stale = JobRegistry.list_stale_heartbeats(@stale_heartbeat_ms)

      if stale != [] do
        # Only claim pipelines owned by this node (stale local pipelines)
        # or pipelines whose owner node is no longer connected
        connected = MapSet.new([Kernel.node() | Node.list()])

        claimable =
          Enum.flat_map(stale, fn entry ->
            owner_connected = MapSet.member?(connected, entry.owner_node)

            if not owner_connected do
              key = entry.run_id || entry.pipeline_id

              if key do
                JobRegistry.mark_interrupted(key)

                case attempt_claim(entry) do
                  {:ok, claimed} -> [claimed]
                  {:error, _} -> []
                end
              else
                []
              end
            else
              Logger.warning(
                "[RecoveryCoordinator] Pipeline #{entry.run_id} has stale heartbeat " <>
                  "but owner #{entry.owner_node} is still connected"
              )

              []
            end
          end)

        state =
          if claimable != [] do
            send(self(), :recover_next)
            %{state | pending: state.pending ++ claimable}
          else
            state
          end

        # Schedule next check
        Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
        {:noreply, state}
      else
        # No stale heartbeats
        Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
        {:noreply, state}
      end
    else
      Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp attempt_recovery(%Entry{} = entry) do
    key = entry.run_id || entry.pipeline_id

    # For cross-node recovery, try multiple checkpoint sources
    with {:ok, checkpoint_source} <- locate_checkpoint(entry),
         :ok <- validate_graph_unchanged(entry) do
      JobRegistry.mark_recovering(key)

      task =
        Task.Supervisor.async_nolink(
          Arbor.Orchestrator.Session.TaskSupervisor,
          fn -> do_resume(entry, checkpoint_source) end
        )

      {:ok, task.ref}
    end
  end

  # Locate a checkpoint, trying multiple sources:
  # 1. Local filesystem (same node or shared storage)
  # 2. BufferedStore (shared Postgres backend)
  # 3. RPC to the source node (if still reachable for other data)
  defp locate_checkpoint(%Entry{run_id: run_id, logs_root: logs_root}) do
    # Try local file first
    local_path = if logs_root, do: Path.join(logs_root, "checkpoint.json")

    cond do
      local_path && File.exists?(local_path) ->
        {:ok, {:file, local_path}}

      run_id != nil ->
        # Try BufferedStore (works when shared Postgres backend is configured)
        case Arbor.Persistence.BufferedStore.get(
               run_id,
               name: :arbor_orchestrator_checkpoints
             ) do
          {:ok, checkpoint_data} when checkpoint_data != nil ->
            {:ok, {:store, checkpoint_data}}

          _ ->
            # Try querying peer nodes for the checkpoint file content
            case fetch_checkpoint_from_peers(logs_root) do
              {:ok, data} -> {:ok, {:remote_data, data}}
              _ -> {:error, :checkpoint_not_found}
            end
        end

      true ->
        {:error, :no_checkpoint_source}
    end
  end

  defp fetch_checkpoint_from_peers(nil), do: {:error, :no_logs_root}

  defp fetch_checkpoint_from_peers(logs_root) do
    checkpoint_path = Path.join(logs_root, "checkpoint.json")

    # Try each connected node
    Enum.find_value(Node.list(), {:error, :checkpoint_not_on_peers}, fn node ->
      try do
        case :erpc.call(node, File, :read, [checkpoint_path], 5_000) do
          {:ok, data} -> {:ok, data}
          _ -> nil
        end
      catch
        _, _ -> nil
      end
    end)
  end

  defp validate_graph_unchanged(%Entry{graph_hash: nil}), do: :ok

  defp validate_graph_unchanged(%Entry{dot_source_path: nil}), do: :ok

  defp validate_graph_unchanged(%Entry{
         graph_hash: original_hash,
         dot_source_path: path
       }) do
    case File.read(path) do
      {:ok, source} ->
        current_hash = compute_graph_hash(source)

        if current_hash == original_hash do
          :ok
        else
          {:error, :graph_changed}
        end

      {:error, _} ->
        # Can't verify locally — allow recovery (checkpoint has the state)
        :ok
    end
  end

  defp do_resume(%Entry{} = entry, checkpoint_source) do
    # Set up local logs root for this node's execution
    logs_root = entry.logs_root || create_recovery_logs_root(entry.run_id)

    base_opts = [
      run_id: entry.run_id,
      logs_root: logs_root,
      recovery: true,
      graph_hash: entry.graph_hash
    ]

    # Build resume opts based on checkpoint source
    opts =
      case checkpoint_source do
        {:file, path} ->
          Keyword.put(base_opts, :resume_from, path)

        {:store, checkpoint_data} ->
          # Write checkpoint data to local file for the engine to load
          local_path = Path.join(logs_root, "checkpoint.json")
          File.mkdir_p!(logs_root)
          data = if is_binary(checkpoint_data), do: checkpoint_data, else: Jason.encode!(checkpoint_data)
          File.write!(local_path, data)
          Keyword.put(base_opts, :resume_from, local_path)

        {:remote_data, raw_data} ->
          # Write remote checkpoint data to local file
          local_path = Path.join(logs_root, "checkpoint.json")
          File.mkdir_p!(logs_root)
          File.write!(local_path, raw_data)
          Keyword.put(base_opts, :resume_from, local_path)
      end

    # Load the graph from DOT source if available
    case load_graph_for_resume(entry) do
      {:ok, graph} ->
        Arbor.Orchestrator.Engine.run(graph, opts)

      {:error, reason} ->
        {:error, {:cannot_load_graph, reason}}
    end
  end

  defp load_graph_for_resume(%Entry{dot_source_path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> Arbor.Orchestrator.parse(source)
      {:error, reason} -> {:error, {:dot_file_unavailable, reason}}
    end
  end

  defp load_graph_for_resume(_entry) do
    {:error, :no_dot_source_path}
  end

  defp create_recovery_logs_root(run_id) do
    root = Path.join(System.tmp_dir!(), "arbor_orchestrator/recovery_#{run_id || "unknown"}")
    File.mkdir_p!(root)
    root
  end

  defp attempt_claim(%Entry{} = entry) do
    key = entry.run_id || entry.pipeline_id

    # Trust zone check: only claim if our zone is <= the pipeline's origin zone
    my_zone = resolve_trust_zone()
    origin_zone = entry.origin_trust_zone || 0

    if my_zone > origin_zone do
      Logger.warning(
        "[RecoveryCoordinator] Cannot claim #{key}: " <>
          "our zone (#{my_zone}) > origin zone (#{origin_zone})"
      )

      {:error, :trust_zone_violation}
    else
      # Use leader-based claim: oldest coordinator in :pg group wins
      if am_i_leader?() do
        case JobRegistry.claim_for_recovery(key) do
          {:ok, claimed} ->
            Logger.info("[RecoveryCoordinator] Claimed pipeline #{key} for recovery")
            {:ok, claimed}

          {:error, reason} ->
            Logger.debug("[RecoveryCoordinator] Could not claim #{key}: #{inspect(reason)}")
            {:error, reason}
        end
      else
        Logger.debug("[RecoveryCoordinator] Not leader, skipping claim for #{key}")
        {:error, :not_leader}
      end
    end
  end

  defp am_i_leader? do
    case :pg.get_members(@pg_group) do
      [] ->
        # No group members — we're the only one
        true

      members ->
        # Leader = first PID sorted by node name (deterministic across nodes)
        sorted = Enum.sort_by(members, fn pid -> node(pid) end)
        List.first(sorted) == self()
    end
  rescue
    _ -> true
  end

  defp join_pg_group do
    # Ensure :pg is started (it's part of OTP kernel)
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :pg.join(@pg_group, self())
  rescue
    _ -> :ok
  end

  defp resolve_trust_zone do
    mod = Arbor.Cartographer.ClusterKeeper

    if Code.ensure_loaded?(mod) and function_exported?(mod, :trust_zone, 1) do
      apply(mod, :trust_zone, [Kernel.node()])
    else
      0
    end
  rescue
    _ -> 0
  end

  @doc false
  def compute_graph_hash(dot_source) when is_binary(dot_source) do
    :crypto.hash(:sha256, dot_source) |> Base.encode16(case: :lower)
  end
end
