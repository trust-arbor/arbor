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
    enabled = Keyword.get(
      opts,
      :enabled,
      Application.get_env(:arbor_orchestrator, :recovery_enabled, true)
    )

    max_concurrent = Keyword.get(
      opts,
      :max_concurrent,
      Application.get_env(:arbor_orchestrator, :recovery_max_concurrent, @default_max_concurrent)
    )

    delay_ms = Keyword.get(
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
      # Delay recovery to let the rest of the system stabilize
      Process.send_after(self(), :discover_interrupted, delay_ms)
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
      Logger.info(
        "[RecoveryCoordinator] Found #{length(interrupted)} interrupted pipeline(s)"
      )

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
              Logger.warning(
                "[RecoveryCoordinator] Cannot recover #{key}: #{inspect(reason)}"
              )

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

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp attempt_recovery(%Entry{} = entry) do
    key = entry.run_id || entry.pipeline_id

    # Validate that checkpoint and DOT source still exist
    with :ok <- validate_checkpoint_exists(entry),
         :ok <- validate_graph_unchanged(entry) do
      JobRegistry.mark_recovering(key)

      task =
        Task.Supervisor.async_nolink(
          Arbor.Orchestrator.Session.TaskSupervisor,
          fn -> do_resume(entry) end
        )

      {:ok, task.ref}
    end
  end

  defp validate_checkpoint_exists(%Entry{logs_root: nil}),
    do: {:error, :no_logs_root}

  defp validate_checkpoint_exists(%Entry{logs_root: logs_root}) do
    checkpoint_path = Path.join(logs_root, "checkpoint.json")

    if File.exists?(checkpoint_path) do
      :ok
    else
      {:error, :checkpoint_not_found}
    end
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
        # Can't verify — allow recovery (checkpoint has the state)
        :ok
    end
  end

  defp do_resume(%Entry{} = entry) do
    checkpoint_path = Path.join(entry.logs_root, "checkpoint.json")

    opts = [
      resume_from: checkpoint_path,
      run_id: entry.run_id,
      logs_root: entry.logs_root,
      recovery: true
    ]

    # Load the graph from DOT source if available, otherwise from checkpoint context
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

  @doc false
  def compute_graph_hash(dot_source) when is_binary(dot_source) do
    :crypto.hash(:sha256, dot_source) |> Base.encode16(case: :lower)
  end
end
