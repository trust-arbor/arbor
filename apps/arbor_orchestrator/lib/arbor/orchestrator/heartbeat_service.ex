defmodule Arbor.Orchestrator.HeartbeatService do
  @moduledoc """
  Dedicated GenServer for agent heartbeat lifecycle management.

  Extracted from Session to give heartbeats their own supervision tree
  position, enabling:

  - **Clean lifecycle**: as child #4 of BranchSupervisor (rest_for_one),
    HeartbeatService dies with Session but doesn't kill Session when it
    crashes. No orphaned heartbeat timers.
  - **Optional by template**: agents that don't need heartbeats (one-shot,
    consultation, delegation) simply don't start this child.
  - **Independent monitoring**: heartbeat health is observable without
    touching Session internals.
  - **Runtime graph editing**: agents can modify their heartbeat DOT
    pipeline without recompiling — the graph is a file, not code.

  ## Configuration (from template)

      %{
        enabled: true,           # whether to start at all
        interval: 30_000,        # ms between heartbeat cycles
        graph: "heartbeat.dot"   # DOT graph relative to session pipeline dir
      }

  ## Lifecycle

  Started by BranchSupervisor AFTER Session. Receives agent_id, signer,
  trust_tier, and heartbeat config at init. Schedules the first heartbeat
  timer immediately. Each cycle:

  1. Check authorization (`arbor://orchestrator/execute`)
  2. Build heartbeat values from agent memory/goals
  3. Spawn a Task that calls Engine.run with the heartbeat graph
  4. Receive the result and apply it via Session's Builders
  5. Schedule the next heartbeat

  If a heartbeat is already in flight, the next timer tick is skipped
  (no stacking). If the Task crashes, the rescue logs the error and
  the next scheduled heartbeat retries cleanly.

  ## Context Isolation

  Per the completed `heartbeat-chat-context-isolation` design, heartbeat
  output MUST NOT contaminate chat query system prompts. The HeartbeatService
  emits structured events (signals) rather than directly modifying Session
  state. The Session's Builders module applies heartbeat results to memory
  stores that are isolated from the chat context window.
  """

  use GenServer

  alias Arbor.Orchestrator.Engine

  require Logger

  @default_interval 30_000
  @orchestrator_resource "arbor://orchestrator/execute"

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc "Start the HeartbeatService as a supervised child."
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the current heartbeat state (for testing/inspection)."
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Reload the heartbeat DOT graph from disk."
  def reload_dot(server) do
    GenServer.cast(server, :reload_dot)
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    signer = Keyword.get(opts, :signer)
    trust_tier = Keyword.get(opts, :trust_tier, :untrusted)

    heartbeat_config = Keyword.get(opts, :heartbeat_config, %{})
    interval = Map.get(heartbeat_config, :interval, @default_interval)
    graph_path = Map.get(heartbeat_config, :graph)

    # Parse the heartbeat DOT graph
    {graph, dot_path} = load_heartbeat_graph(graph_path, opts)

    state = %{
      agent_id: agent_id,
      signer: signer,
      trust_tier: trust_tier,
      heartbeat_graph: graph,
      heartbeat_dot_path: dot_path,
      heartbeat_interval: interval,
      heartbeat_ref: nil,
      heartbeat_in_flight: false
    }

    # Schedule the first heartbeat
    state = schedule_heartbeat(state)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:reload_dot, state) do
    case reload_graph(state.heartbeat_dot_path) do
      {:ok, graph} ->
        Logger.info("[HeartbeatService] Reloaded heartbeat graph for #{state.agent_id}")
        {:noreply, %{state | heartbeat_graph: graph}}

      {:error, reason} ->
        Logger.warning("[HeartbeatService] Failed to reload graph: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    state = start_heartbeat_task(state)
    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info({:heartbeat_result, {:ok, result}}, state) do
    completed = Map.get(result.context, "__completed_nodes__", [])
    llm_content = Map.get(result.context, "llm.content")

    Logger.info(
      "[HeartbeatService] Heartbeat completed for #{state.agent_id}: " <>
        "#{length(completed)} nodes, content=#{if llm_content, do: "#{String.length(to_string(llm_content))} chars", else: "nil"}"
    )

    # Apply heartbeat results to agent memory/goals via the Builders module.
    # This maintains context isolation — heartbeat results go to memory stores,
    # not directly into the chat context window.
    apply_heartbeat_result(state, result)

    {:noreply, %{state | heartbeat_in_flight: false}}
  end

  def handle_info({:heartbeat_result, {:error, reason}}, state) do
    Logger.warning("[HeartbeatService] Heartbeat failed for #{state.agent_id}: #{inspect(reason)}")

    emit_heartbeat_failed_signal(state, reason)

    {:noreply, %{state | heartbeat_in_flight: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Clean up any stale pipeline entries in both ETS and legacy JobRegistry
    cleanup_stale_pipelines(state)
    :ok
  end

  # ===========================================================================
  # Heartbeat execution
  # ===========================================================================

  defp start_heartbeat_task(state) do
    if state.heartbeat_in_flight do
      # Don't stack heartbeats
      state
    else
      case authorize_orchestrator(state) do
        :ok ->
          do_start_heartbeat_task(state)

        {:error, reason} ->
          Logger.warning("[HeartbeatService] Heartbeat blocked: unauthorized (#{inspect(reason)})")
          state
      end
    end
  end

  defp do_start_heartbeat_task(state) do
    service_pid = self()
    values = build_heartbeat_values(state)
    engine_opts = build_engine_opts(state, values)
    heartbeat_graph = state.heartbeat_graph

    task_sup = Arbor.Orchestrator.Session.TaskSupervisor

    task_fn = fn ->
      result =
        try do
          Engine.run(heartbeat_graph, engine_opts)
        rescue
          e ->
            Logger.error(
              "[HeartbeatService] Heartbeat engine crash for #{state.agent_id}: " <>
                "#{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
            )

            {:error, {:engine_crash, Exception.message(e)}}
        end

      send(service_pid, {:heartbeat_result, result})
    end

    {:ok, _pid} =
      if Process.whereis(task_sup) do
        Task.Supervisor.start_child(task_sup, task_fn)
      else
        Task.start(task_fn)
      end

    %{state | heartbeat_in_flight: true}
  end

  # ===========================================================================
  # Timer management
  # ===========================================================================

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end

  # ===========================================================================
  # Heartbeat values and engine opts
  # ===========================================================================

  # Build the initial values for the heartbeat pipeline context.
  # Reads from agent memory stores (ETS-backed, keyed by agent_id).
  defp build_heartbeat_values(state) do
    if Code.ensure_loaded?(Arbor.Orchestrator.Session.Builders) do
      try do
        # Builders.build_heartbeat_values expects a Session-like state map.
        # We provide the minimal subset it needs.
        session_like = %{
          agent_id: state.agent_id,
          trust_tier: state.trust_tier,
          signer: state.signer
        }

        apply(Arbor.Orchestrator.Session.Builders, :build_heartbeat_values, [session_like])
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end
    else
      %{}
    end
  end

  defp build_engine_opts(state, values) do
    if Code.ensure_loaded?(Arbor.Orchestrator.Session.Builders) do
      try do
        session_like = %{
          agent_id: state.agent_id,
          trust_tier: state.trust_tier,
          signer: state.signer
        }

        apply(Arbor.Orchestrator.Session.Builders, :build_engine_opts, [
          session_like,
          values,
          [source: :heartbeat]
        ])
        |> Keyword.put(:spawning_pid, self())
      rescue
        _ -> default_engine_opts(state)
      catch
        :exit, _ -> default_engine_opts(state)
      end
    else
      default_engine_opts(state)
    end
  end

  defp default_engine_opts(state) do
    [
      spawning_pid: self(),
      source: :heartbeat,
      agent_id: state.agent_id
    ]
  end

  # ===========================================================================
  # Heartbeat result application
  # ===========================================================================

  defp apply_heartbeat_result(state, result) do
    if Code.ensure_loaded?(Arbor.Orchestrator.Session.Builders) do
      try do
        session_like = %{
          agent_id: state.agent_id,
          trust_tier: state.trust_tier
        }

        apply(Arbor.Orchestrator.Session.Builders, :apply_heartbeat_result, [session_like, result])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Emit heartbeat completed signal for observability
    emit_heartbeat_completed_signal(state, result)
  end

  # ===========================================================================
  # Authorization
  # ===========================================================================

  defp authorize_orchestrator(state) do
    if Code.ensure_loaded?(Arbor.Security) and
         function_exported?(Arbor.Security, :authorize, 4) and
         Process.whereis(Arbor.Security.CapabilityStore) != nil do
      opts = if state.signer, do: [signer: state.signer], else: []

      case Arbor.Security.authorize(state.agent_id, @orchestrator_resource, :execute, opts) do
        {:ok, :authorized} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ===========================================================================
  # Graph loading
  # ===========================================================================

  defp load_heartbeat_graph(nil, opts) do
    # No graph path specified — try the default from SessionConfig
    default_path = resolve_default_dot_path(opts)
    load_heartbeat_graph(default_path, opts)
  end

  defp load_heartbeat_graph(graph_name, opts) when is_binary(graph_name) do
    # Resolve relative to the pipeline specs directory
    dot_path = resolve_dot_path(graph_name, opts)

    case reload_graph(dot_path) do
      {:ok, graph} ->
        {graph, dot_path}

      {:error, reason} ->
        Logger.warning(
          "[HeartbeatService] Failed to load heartbeat graph #{dot_path}: #{inspect(reason)}. " <>
            "Heartbeats will use a no-op fallback."
        )

        {nil, dot_path}
    end
  end

  defp reload_graph(nil), do: {:error, :no_dot_path}

  defp reload_graph(dot_path) do
    if Code.ensure_loaded?(Arbor.Orchestrator.Session.Builders) and
         function_exported?(Arbor.Orchestrator.Session.Builders, :parse_dot_file, 1) do
      try do
        apply(Arbor.Orchestrator.Session.Builders, :parse_dot_file, [dot_path])
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, reason}
      end
    else
      {:error, :builders_not_available}
    end
  end

  defp resolve_dot_path(graph_name, _opts) do
    # The heartbeat DOT files live alongside the session pipeline specs
    base = Path.join([
      "apps", "arbor_orchestrator", "specs", "pipelines", "session"
    ])

    Path.join(base, graph_name)
  end

  defp resolve_default_dot_path(opts) do
    # Check if the caller provided a heartbeat_dot path
    Keyword.get(opts, :heartbeat_dot) || "heartbeat.dot"
  end

  # ===========================================================================
  # Cleanup
  # ===========================================================================

  defp cleanup_stale_pipelines(_state) do
    # Primary: clean up via PipelineStatus Facade (ETS-backed)
    if Code.ensure_loaded?(Arbor.Orchestrator.PipelineStatus) do
      try do
        Arbor.Orchestrator.PipelineStatus.list_active()
        |> Enum.each(fn entry ->
          Arbor.Orchestrator.PipelineStatus.mark_abandoned(entry.run_id)
        end)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Legacy: also clean up in the JobRegistry BufferedStore
    if Code.ensure_loaded?(Arbor.Orchestrator.JobRegistry) do
      try do
        Arbor.Orchestrator.JobRegistry.list_stale_heartbeats()
        |> Enum.each(fn entry ->
          Arbor.Orchestrator.JobRegistry.mark_abandoned(entry.run_id)
        end)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ===========================================================================
  # Signal emission
  # ===========================================================================

  defp emit_heartbeat_completed_signal(state, result) do
    if Code.ensure_loaded?(Arbor.Orchestrator.Session.Builders) do
      try do
        session_like = %{agent_id: state.agent_id}
        apply(Arbor.Orchestrator.Session.Builders, :emit_heartbeat_signal, [session_like, result])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp emit_heartbeat_failed_signal(state, reason) do
    if Code.ensure_loaded?(Arbor.Orchestrator.Session.Builders) do
      try do
        apply(Arbor.Orchestrator.Session.Builders, :emit_signal, [
          :agent,
          :heartbeat_failed,
          %{
            agent_id: state.agent_id,
            reason: inspect(reason)
          }
        ])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end
end
