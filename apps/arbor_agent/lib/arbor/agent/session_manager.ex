defmodule Arbor.Agent.SessionManager do
  @moduledoc """
  Manages persistent DOT sessions for agents.

  Each agent gets at most one long-lived Session that accumulates state,
  runs heartbeats via the DOT graph, and handles queries through turn.dot.
  This replaces the procedural execute_query and seed_heartbeat_cycle paths
  with graph-based execution.

  ## Architecture

  SessionManager owns an ETS table mapping `agent_id → session_pid`.
  It monitors each session process and cleans up on crash/stop.
  Session creation is delegated to `Arbor.Orchestrator.Session` via
  runtime bridge (no compile-time dependency).
  """

  use GenServer

  require Logger

  @session_module Arbor.Orchestrator.Session
  @table __MODULE__

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Ensure a session exists for the given agent. Creates one if needed.

  Returns `{:ok, pid}` on success, `{:error, reason}` on failure.
  Idempotent — second call returns the existing session pid.
  """
  @spec ensure_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_session(agent_id, opts \\ []) do
    timeout = Keyword.get(opts, :session_timeout, 30_000)
    GenServer.call(__MODULE__, {:ensure_session, agent_id, opts}, timeout)
  end

  @doc """
  Get the session pid for an agent.

  Returns `{:ok, pid}` or `{:error, :no_session}`.
  """
  @spec get_session(String.t()) :: {:ok, pid()} | {:error, :no_session}
  def get_session(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :no_session}

      _ ->
        {:error, :no_session}
    end
  end

  @doc """
  Check whether an agent has an active session.
  """
  @spec has_session?(String.t()) :: boolean()
  def has_session?(agent_id) do
    match?({:ok, _}, get_session(agent_id))
  end

  @doc """
  Stop and clean up the session for an agent.
  """
  @spec stop_session(String.t()) :: :ok
  def stop_session(agent_id) do
    GenServer.call(__MODULE__, {:stop_session, agent_id})
  end

  @doc """
  Reload DOT pipeline graphs for all active sessions.

  Useful when DOT files change after sessions are already running — calls
  `Session.reload_dot/1` on every live session in the ETS table.

  Returns a map of `agent_id => :ok | {:error, reason}`.
  """
  @spec reload_all_dots() :: %{String.t() => :ok | {:error, term()}}
  def reload_all_dots do
    session_mod = @session_module

    :ets.tab2list(@table)
    |> Enum.filter(fn {_agent_id, pid} -> is_pid(pid) and Process.alive?(pid) end)
    |> Map.new(fn {agent_id, pid} ->
      result =
        if function_exported?(session_mod, :reload_dot, 1) do
          apply(session_mod, :reload_dot, [pid])
        else
          {:error, :reload_dot_not_available}
        end

      {agent_id, result}
    end)
  end

  # ── GenServer ───────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:ensure_session, agent_id, opts}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          # Stale entry — clean up and create new
          cleanup_entry(agent_id, state)
          create_session(agent_id, opts, state)
        end

      _ ->
        create_session(agent_id, opts, state)
    end
  end

  def handle_call({:stop_session, agent_id}, _from, state) do
    state = do_stop_session(agent_id, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_id, r} -> r == ref end) do
      {agent_id, ^ref} ->
        :ets.delete(@table, agent_id)
        {:noreply, %{state | monitors: Map.delete(state.monitors, agent_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────

  defp create_session(agent_id, opts, state) do
    if orchestrator_available?() do
      session_opts = build_session_opts(agent_id, opts)

      case GenServer.start(@session_module, session_opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          :ets.insert(@table, {agent_id, pid})
          new_state = %{state | monitors: Map.put(state.monitors, agent_id, ref)}

          # Create Postgres session record for durable persistence
          ensure_persistent_session(agent_id, opts)

          # Start companion servers (Phase 3: three-loop architecture)
          start_companion_servers(agent_id, opts)

          {:reply, {:ok, pid}, new_state}

        {:error, reason} ->
          {:reply, {:error, {:session_start_failed, reason}}, state}
      end
    else
      {:reply, {:error, :orchestrator_unavailable}, state}
    end
  end

  defp build_session_opts(agent_id, opts) do
    # Use shared SessionConfig builder — single source of truth
    # SessionManager adds session recovery for persistent sessions
    Arbor.Agent.SessionConfig.build(agent_id, Keyword.put(opts, :recover_session, true))
  end

  defp do_stop_session(agent_id, state) do
    # Stop companion servers first (Phase 3)
    stop_companion_servers(agent_id)

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, pid}] ->
        # Demonitor before stopping to avoid race
        case Map.get(state.monitors, agent_id) do
          nil -> :ok
          ref -> Process.demonitor(ref, [:flush])
        end

        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 5_000)
          catch
            :exit, _ -> :ok
          end
        end

        :ets.delete(@table, agent_id)
        %{state | monitors: Map.delete(state.monitors, agent_id)}

      _ ->
        state
    end
  end

  # ── Companion server lifecycle (Phase 3) ─────────────────────────

  defp start_companion_servers(agent_id, opts) do
    # Action Cycle Server
    if Code.ensure_loaded?(Arbor.Agent.ActionCycleSupervisor) do
      try do
        apply(Arbor.Agent.ActionCycleSupervisor, :start_server, [agent_id, opts])
      rescue
        e ->
          Logger.warning(
            "[SessionManager] Failed to start ActionCycleServer for #{agent_id}: #{Exception.message(e)}"
          )
      catch
        :exit, reason ->
          Logger.warning(
            "[SessionManager] ActionCycleServer start exited for #{agent_id}: #{inspect(reason)}"
          )
      end
    end

    # Maintenance Server
    if Code.ensure_loaded?(Arbor.Agent.MaintenanceSupervisor) do
      try do
        apply(Arbor.Agent.MaintenanceSupervisor, :start_server, [agent_id, opts])
      rescue
        e ->
          Logger.warning(
            "[SessionManager] Failed to start MaintenanceServer for #{agent_id}: #{Exception.message(e)}"
          )
      catch
        :exit, reason ->
          Logger.warning(
            "[SessionManager] MaintenanceServer start exited for #{agent_id}: #{inspect(reason)}"
          )
      end
    end
  end

  defp stop_companion_servers(agent_id) do
    if Code.ensure_loaded?(Arbor.Agent.ActionCycleSupervisor) do
      try do
        apply(Arbor.Agent.ActionCycleSupervisor, :stop_server, [agent_id])
      rescue
        e ->
          Logger.debug(
            "[SessionManager] ActionCycleServer stop failed for #{agent_id}: #{Exception.message(e)}"
          )
      catch
        :exit, _reason -> :ok
      end
    end

    if Code.ensure_loaded?(Arbor.Agent.MaintenanceSupervisor) do
      try do
        apply(Arbor.Agent.MaintenanceSupervisor, :stop_server, [agent_id])
      rescue
        e ->
          Logger.debug(
            "[SessionManager] MaintenanceServer stop failed for #{agent_id}: #{Exception.message(e)}"
          )
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp cleanup_entry(agent_id, state) do
    case Map.get(state.monitors, agent_id) do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush])
    end

    :ets.delete(@table, agent_id)
  end

  @session_store Arbor.Persistence.SessionStore

  defp ensure_persistent_session(agent_id, opts) do
    if session_store_available?() do
      session_id = "agent-session-#{agent_id}"

      Task.start(fn ->
        try do
          case apply(@session_store, :get_session, [session_id]) do
            {:ok, _} ->
              :ok

            {:error, :not_found} ->
              apply(@session_store, :create_session, [
                agent_id,
                [
                  session_id: session_id,
                  model: Keyword.get(opts, :model),
                  metadata: %{
                    "trust_tier" => to_string(Keyword.get(opts, :trust_tier, :established))
                  }
                ]
              ])
          end
        rescue
          e ->
            Logger.warning(
              "[SessionManager] Persistent session creation failed: #{Exception.message(e)}"
            )
        end
      end)
    end
  end

  defp session_store_available? do
    Code.ensure_loaded?(@session_store) and
      function_exported?(@session_store, :available?, 0) and
      apply(@session_store, :available?, [])
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp orchestrator_available? do
    Code.ensure_loaded?(@session_module)
  end
end
