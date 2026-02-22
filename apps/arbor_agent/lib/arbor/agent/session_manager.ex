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
  @adapters_module Arbor.Orchestrator.Session.Adapters
  @table __MODULE__

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Ensure a session exists for the given agent. Creates one if needed.

  Returns `{:ok, pid}` on success, `{:error, reason}` on failure.
  Idempotent — second call returns the existing session pid.
  """
  @spec ensure_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_session(agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:ensure_session, agent_id, opts})
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
    trust_tier = Keyword.get(opts, :trust_tier, :established)
    adapters = build_adapters(agent_id, trust_tier, opts)

    turn = turn_dot_path()
    hb = Keyword.get(opts, :heartbeat_dot, heartbeat_dot_path())

    session_id = "agent-session-#{agent_id}"

    base = [
      session_id: session_id,
      agent_id: agent_id,
      trust_tier: trust_tier,
      adapters: adapters,
      turn_dot: turn,
      heartbeat_dot: hb,
      start_heartbeat: Keyword.get(opts, :start_heartbeat, true),
      execution_mode: :session
    ]

    # Add compactor config if context management is enabled
    base =
      case build_compactor_config(opts) do
        nil -> base
        config -> Keyword.put(base, :compactor, config)
      end

    # Load saved session entries for recovery (restores messages from Postgres)
    # Falls back to checkpoint-based recovery if session store unavailable
    case load_session_entries(session_id) do
      {:ok, checkpoint} -> Keyword.put(base, :checkpoint, checkpoint)
      :none -> load_checkpoint_fallback(base, session_id)
    end
  end

  defp build_compactor_config(opts) do
    context_management = Keyword.get(opts, :context_management, :none)

    if context_management != :none do
      compactor_module = Arbor.Agent.ContextCompactor

      compactor_opts = [
        effective_window: Keyword.get(opts, :effective_window, 75_000),
        model: Keyword.get(opts, :model),
        enable_llm_compaction: context_management == :full
      ]

      {compactor_module, compactor_opts}
    end
  end

  defp build_adapters(agent_id, trust_tier, opts) do
    if Code.ensure_loaded?(@adapters_module) do
      apply(@adapters_module, :build, [
        [
          agent_id: agent_id,
          trust_tier: trust_tier,
          llm_provider: Keyword.get(opts, :provider),
          llm_model: Keyword.get(opts, :model),
          system_prompt: Keyword.get(opts, :system_prompt),
          tools: Keyword.get(opts, :tools, [])
        ]
      ])
    else
      %{}
    end
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
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Maintenance Server
    if Code.ensure_loaded?(Arbor.Agent.MaintenanceSupervisor) do
      try do
        apply(Arbor.Agent.MaintenanceSupervisor, :start_server, [agent_id, opts])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_companion_servers(agent_id) do
    if Code.ensure_loaded?(Arbor.Agent.ActionCycleSupervisor) do
      try do
        apply(Arbor.Agent.ActionCycleSupervisor, :stop_server, [agent_id])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    if Code.ensure_loaded?(Arbor.Agent.MaintenanceSupervisor) do
      try do
        apply(Arbor.Agent.MaintenanceSupervisor, :stop_server, [agent_id])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
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

  defp load_session_entries(session_id) do
    if session_store_available?() do
      case apply(@session_store, :get_session, [session_id]) do
        {:ok, session} ->
          entries =
            apply(@session_store, :load_entries, [
              session.id,
              [entry_types: ["user", "assistant"]]
            ])

          if entries != [] do
            messages = entries_to_messages(entries)
            user_count = Enum.count(entries, fn e -> e.role == "user" end)
            {:ok, %{"messages" => messages, "turn_count" => user_count}}
          else
            :none
          end

        {:error, _} ->
          :none
      end
    else
      :none
    end
  rescue
    _ -> :none
  catch
    :exit, _ -> :none
  end

  defp entries_to_messages(entries) do
    Enum.map(entries, fn entry ->
      content =
        case entry.content do
          items when is_list(items) ->
            # Extract text from content array
            items
            |> Enum.filter(fn item -> item["type"] == "text" end)
            |> Enum.map_join("\n", fn item -> item["text"] || "" end)

          text when is_binary(text) ->
            text

          _ ->
            ""
        end

      %{
        "role" => entry.role || entry.entry_type,
        "content" => content,
        "timestamp" => format_timestamp(entry.timestamp)
      }
    end)
  end

  defp format_timestamp(nil), do: nil
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp load_checkpoint_fallback(base, session_id) do
    case load_checkpoint(session_id) do
      nil -> base
      checkpoint -> Keyword.put(base, :checkpoint, checkpoint)
    end
  end

  defp load_checkpoint(session_id) do
    checkpoint_mod = Arbor.Persistence.Checkpoint

    if Code.ensure_loaded?(checkpoint_mod) and
         function_exported?(checkpoint_mod, :load, 2) do
      store =
        Application.get_env(
          :arbor_persistence,
          :checkpoint_store,
          Arbor.Persistence.Checkpoint.Store.ETS
        )

      case apply(checkpoint_mod, :load, [session_id, store]) do
        {:ok, checkpoint} when is_map(checkpoint) -> checkpoint
        _ -> nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

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
    Code.ensure_loaded?(@session_module) and
      Code.ensure_loaded?(@adapters_module)
  end

  defp turn_dot_path do
    Application.get_env(:arbor_agent, :session_turn_dot, default_turn_dot())
  end

  defp heartbeat_dot_path do
    Application.get_env(:arbor_agent, :session_heartbeat_dot, default_heartbeat_dot())
  end

  defp default_turn_dot do
    Path.join([orchestrator_app_dir(), "specs", "pipelines", "session", "turn.dot"])
  end

  defp default_heartbeat_dot do
    Path.join([orchestrator_app_dir(), "specs", "pipelines", "session", "heartbeat.dot"])
  end

  defp orchestrator_app_dir do
    # In an umbrella, specs/ lives in the source tree (not _build).
    # Try multiple resolution strategies since CWD varies:
    # - From umbrella root: CWD = /umbrella/
    # - From app tests: CWD = /umbrella/apps/arbor_orchestrator/
    # - In release mode: specs must be in priv/
    cwd = File.cwd!()

    candidates = [
      # Direct: CWD is umbrella root
      Path.join([cwd, "apps", "arbor_orchestrator"]),
      # Sibling: CWD is an app dir (e.g., apps/arbor_orchestrator or apps/arbor_agent)
      Path.join([cwd, "..", "arbor_orchestrator"]) |> Path.expand(),
      # Self: CWD IS the orchestrator dir
      cwd
    ]

    case Enum.find(candidates, fn path ->
           File.dir?(path) and File.exists?(Path.join(path, "specs"))
         end) do
      nil ->
        # Fallback for release mode
        case :code.priv_dir(:arbor_orchestrator) do
          {:error, _} -> List.first(candidates)
          priv_dir -> Path.dirname(to_string(priv_dir))
        end

      path ->
        path
    end
  end
end
