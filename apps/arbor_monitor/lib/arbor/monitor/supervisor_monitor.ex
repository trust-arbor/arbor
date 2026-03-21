defmodule Arbor.Monitor.SupervisorMonitor do
  @moduledoc """
  Monitors supervisor health by periodically polling child counts and states.

  Tracks a set of supervisors and emits signals when:
  - A supervisor's active child count drops (process died between polls)
  - A child is in `:restarting` state (restart in progress)

  ## Usage

      SupervisorMonitor.monitor_supervisor(Arbor.Agent.Supervisor)
      SupervisorMonitor.monitor_supervisor(pid)

  ## Configuration

      config :arbor_monitor, :supervisor_monitor,
        interval: 5_000    # Poll every 5s (default)
  """

  use GenServer

  require Logger

  @default_interval 5_000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add a supervisor to the monitored set."
  @spec monitor_supervisor(pid() | atom()) :: :ok
  def monitor_supervisor(pid_or_name) do
    GenServer.cast(__MODULE__, {:monitor, pid_or_name})
  end

  @doc "Remove a supervisor from the monitored set."
  @spec unmonitor_supervisor(pid() | atom()) :: :ok
  def unmonitor_supervisor(pid_or_name) do
    GenServer.cast(__MODULE__, {:unmonitor, pid_or_name})
  end

  @doc "List all monitored supervisors and their last known child counts."
  @spec list_monitored() :: map()
  def list_monitored do
    GenServer.call(__MODULE__, :list_monitored)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_check(interval)

    {:ok,
     %{
       supervisors: %{},
       interval: interval
     }}
  end

  @impl true
  def handle_call(:list_monitored, _from, state) do
    {:reply, state.supervisors, state}
  end

  @impl true
  def handle_cast({:monitor, pid_or_name}, state) do
    key = resolve_key(pid_or_name)

    case key do
      nil ->
        {:noreply, state}

      _ ->
        # Take initial snapshot
        snapshot = take_snapshot(pid_or_name)

        if snapshot do
          # Monitor the supervisor process itself
          pid = resolve_pid(pid_or_name)
          if pid, do: Process.monitor(pid)

          supervisors = Map.put(state.supervisors, key, %{
            ref: pid_or_name,
            snapshot: snapshot,
            monitored_at: System.system_time(:millisecond)
          })

          {:noreply, %{state | supervisors: supervisors}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:unmonitor, pid_or_name}, state) do
    key = resolve_key(pid_or_name)
    {:noreply, %{state | supervisors: Map.delete(state.supervisors, key)}}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = check_supervisors(state)
    schedule_check(state.interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # A monitored supervisor itself died
    case find_supervisor_by_pid(state.supervisors, pid) do
      {key, _info} ->
        Logger.warning(
          "[SupervisorMonitor] Monitored supervisor #{inspect(key)} terminated: #{sanitize_reason(reason)}"
        )

        emit_signal(:supervisor_terminated, %{
          supervisor: inspect(key),
          reason: sanitize_reason(reason)
        })

        {:noreply, %{state | supervisors: Map.delete(state.supervisors, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────

  defp check_supervisors(state) do
    updated_supervisors =
      Enum.reduce(state.supervisors, %{}, fn {key, info}, acc ->
        case take_snapshot(info.ref) do
          nil ->
            # Supervisor no longer accessible — skip, will be cleaned up by DOWN
            Map.put(acc, key, info)

          new_snapshot ->
            old_snapshot = info.snapshot

            # Detect active child count drop
            if new_snapshot.active < old_snapshot.active do
              dropped = old_snapshot.active - new_snapshot.active

              emit_signal(:supervisor_child_crashed, %{
                supervisor: inspect(key),
                previous_active: old_snapshot.active,
                current_active: new_snapshot.active,
                children_lost: dropped,
                total_specs: new_snapshot.specs
              })
            end

            # Detect children in :restarting state
            check_restarting_children(key, info.ref)

            Map.put(acc, key, %{info | snapshot: new_snapshot})
        end
      end)

    %{state | supervisors: updated_supervisors}
  end

  defp check_restarting_children(key, ref) do
    children =
      try do
        Supervisor.which_children(ref)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    restarting =
      Enum.filter(children, fn
        {_id, :restarting, _type, _modules} -> true
        _ -> false
      end)

    unless restarting == [] do
      restarting_ids =
        Enum.map(restarting, fn {id, _, _, _} -> inspect(id) end)

      emit_signal(:supervisor_child_restarting, %{
        supervisor: inspect(key),
        restarting_children: restarting_ids,
        restarting_count: length(restarting)
      })
    end
  end

  defp take_snapshot(ref) do
    try do
      counts = Supervisor.count_children(ref)

      %{
        specs: Keyword.get(counts, :specs, 0),
        active: Keyword.get(counts, :active, 0),
        supervisors: Keyword.get(counts, :supervisors, 0),
        workers: Keyword.get(counts, :workers, 0)
      }
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp resolve_key(name) when is_atom(name), do: name
  defp resolve_key(pid) when is_pid(pid), do: pid

  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_pid(pid) when is_pid(pid), do: pid

  defp find_supervisor_by_pid(supervisors, pid) do
    Enum.find(supervisors, fn {key, info} ->
      resolve_pid(info.ref) == pid or key == pid
    end)
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check, interval)
  end

  defp emit_signal(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :durable_emit, 3) do
      apply(Arbor.Signals, :durable_emit, [:supervisor, type, data])
    end
  rescue
    _ -> :ok
  end

  defp sanitize_reason(:normal), do: "normal"
  defp sanitize_reason(:shutdown), do: "shutdown"
  defp sanitize_reason({:shutdown, _}), do: "shutdown"
  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason(_reason), do: "abnormal"
end
