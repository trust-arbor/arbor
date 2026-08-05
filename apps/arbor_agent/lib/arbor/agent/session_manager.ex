defmodule Arbor.Agent.SessionManager do
  @moduledoc """
  Manages persistent DOT sessions for agents.

  Each agent gets at most one long-lived Session that accumulates state,
  runs heartbeats via the DOT graph, and handles queries through turn.dot.
  This replaces the procedural execute_query and seed_heartbeat_cycle paths
  with graph-based execution.

  ## Architecture

  SessionManager owns an ETS table mapping `agent_id → session_pid`
  (`:protected` — concurrent reads open; writes owner-only).
  It monitors each session process and cleans up on crash/stop.
  Session creation is delegated to `Arbor.Orchestrator.Session` via
  runtime bridge (no compile-time dependency).
  """

  use GenServer

  require Logger

  @session_module Arbor.Orchestrator.Session
  @table __MODULE__
  @authenticated_call_grace_ms 1_000

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
  Cancel the in-flight agent turn for `agent_id`, if any.

  Unscoped user-cancel bridge to `Arbor.Orchestrator.Session.cancel_turn/1`.
  Prefer `cancel_task/2` for async orchestration cancellation so an unrelated
  interactive turn is not torn down.

  Looks up the live session pid from the owner-protected ETS table (reads open;
  writes owner-only), then applies the Session cancel contract
  (`GenServer.call(session, :cancel_turn)`).

  Returns `{:error, :no_session}` when the agent has no live session, or the
  underlying cancel result (`:ok` | `{:error, :no_turn_in_flight}`).
  """
  @spec cancel_turn(String.t()) :: :ok | {:error, term()}
  def cancel_turn(agent_id) when is_binary(agent_id) do
    with {:ok, session_pid} <- get_session(agent_id) do
      session_mod = session_module()

      if Code.ensure_loaded?(session_mod) and function_exported?(session_mod, :cancel_turn, 1) do
        apply(session_mod, :cancel_turn, [session_pid])
      else
        # Fall back to the Session.cancel_turn contract directly so the ETS
        # bridge still works when the orchestrator beam is not on the path
        # (e.g. isolated arbor_agent tests with a fake GenServer session).
        GenServer.call(session_pid, :cancel_turn)
      end
    end
  rescue
    e -> {:error, {:cancel_turn_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:cancel_turn_exit, reason}}
  end

  def cancel_turn(_agent_id), do: {:error, :invalid_agent_id}

  @doc """
  Cancel a specific async orchestration task on the agent's session.

  Bridges to `Arbor.Orchestrator.Session.cancel_task/2` (task-scoped, race-safe).
  Passes both `agent_id` (ETS session lookup) and `task_id` so an unrelated
  active/interactive turn is left running while matching queued/active turns
  for `task_id` are cancelled and tombstoned.

  Returns `{:error, :no_session}` when the agent has no live session, or the
  underlying cancel result.
  """
  @spec cancel_task(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_task(agent_id, task_id)
      when is_binary(agent_id) and is_binary(task_id) and task_id != "" do
    with {:ok, session_pid} <- get_session(agent_id) do
      session_mod = session_module()

      if Code.ensure_loaded?(session_mod) and function_exported?(session_mod, :cancel_task, 2) do
        apply(session_mod, :cancel_task, [session_pid, task_id])
      else
        # Fall back to the Session.cancel_task contract directly so the ETS
        # bridge still works when the orchestrator beam is not on the path
        # (e.g. isolated arbor_agent tests with a fake GenServer session).
        GenServer.call(session_pid, {:cancel_task, task_id})
      end
    end
  rescue
    e -> {:error, {:cancel_task_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:cancel_task_exit, reason}}
  end

  def cancel_task(_agent_id, _task_id), do: {:error, :invalid_args}

  @doc """
  Deliver an authenticated `UserMessage` + opaque delivery receipt to the live
  Session for `agent_id`.

  Looks up the session pid from the owner-protected ETS table (reads open;
  writes owner-only) and invokes the configured Session module's
  `send_authenticated_message/4` in a linked per-call Task. The Task is the
  process observed by Session's caller monitor and cannot outlive the real
  caller or the requested delivery timeout.

  The injected Session call receives a fixed bounded grace period beyond the
  public timeout. If the public timeout wins, the Task is brutally terminated
  before this function returns and the outcome is reported as ambiguous; a
  late Session reply is never admitted as success.

  Returns:
  - the Session module's result on success/error
  - `{:error, :no_session}` when no live session is registered
  - `{:error, :delivery_ambiguous}` when the per-call proxy reaches the
    requested timeout
  - `{:error, :session_unavailable}` when the runtime bridge is missing or the
    injected call raises/throws/exits
  - `{:error, :invalid_args}` for non-positive timeout or wrong argument shapes

  Does not create sessions, store the receipt, or fall back to APIAgent.
  """
  @spec send_authenticated_message(
          String.t(),
          Arbor.Contracts.Session.UserMessage.t(),
          Arbor.Contracts.Security.DeliveryReceipt.t(),
          pos_integer()
        ) ::
          {:ok, term()}
          | {:error,
             :no_session | :delivery_ambiguous | :session_unavailable | :invalid_args | term()}
  def send_authenticated_message(agent_id, message, receipt, timeout_ms)
      when is_binary(agent_id) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_struct(message, Arbor.Contracts.Session.UserMessage) and
             is_struct(receipt, Arbor.Contracts.Security.DeliveryReceipt) do
    with {:ok, session_pid} <- get_session(agent_id) do
      session_mod = session_module()

      if Code.ensure_loaded?(session_mod) and
           function_exported?(session_mod, :send_authenticated_message, 4) do
        send_authenticated_message_via_proxy(
          session_mod,
          session_pid,
          message,
          receipt,
          timeout_ms
        )
      else
        {:error, :session_unavailable}
      end
    end
  rescue
    _ -> {:error, :session_unavailable}
  catch
    :throw, _ -> {:error, :session_unavailable}
    :exit, _ -> {:error, :session_unavailable}
  end

  def send_authenticated_message(_agent_id, _message, _receipt, _timeout_ms),
    do: {:error, :invalid_args}

  defp send_authenticated_message_via_proxy(
         session_mod,
         session_pid,
         message,
         receipt,
         timeout_ms
       ) do
    session_timeout_ms = timeout_ms + @authenticated_call_grace_ms

    task =
      Task.async(fn ->
        invoke_authenticated_session(
          session_mod,
          session_pid,
          message,
          receipt,
          session_timeout_ms
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:session_result, result}} ->
        result

      {:ok, :session_unavailable} ->
        {:error, :session_unavailable}

      {:exit, _reason} ->
        {:error, :session_unavailable}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :delivery_ambiguous}
    end
  end

  defp invoke_authenticated_session(session_mod, session_pid, message, receipt, timeout_ms) do
    {:session_result,
     apply(session_mod, :send_authenticated_message, [
       session_pid,
       message,
       receipt,
       timeout_ms
     ])}
  rescue
    _ -> :session_unavailable
  catch
    :throw, _ -> :session_unavailable
    :exit, _ -> :session_unavailable
  end

  defp session_module do
    Application.get_env(:arbor_agent, :orchestrator_session_module, @session_module)
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
    # :protected — any process may read bindings; only this owner may write.
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
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
                  metadata: %{}
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
