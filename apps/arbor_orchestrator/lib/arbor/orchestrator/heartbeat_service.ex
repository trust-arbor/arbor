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

  Started by BranchSupervisor AFTER Session. Receives agent_id and a
  restartable signing-authority bootstrap,
  and heartbeat config at init. Schedules the first heartbeat
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

  # After this many CONSECUTIVE heartbeat failures with no known-terminal reason, disable the
  # heartbeat as a flood backstop. Terminal errors (see terminal_heartbeat_error?/1) disable it
  # immediately regardless of this count.
  @max_consecutive_heartbeat_failures 5

  # (B) An agent with no registered identity can never pass the capability gate. We skip its beats
  # (running nothing — no flood) and tolerate this many in case identity registration is briefly
  # racing at startup; after that it's a real orphan and the loop is disabled.
  @max_no_identity_beats 3

  # A5 (first beat at startup): the first heartbeat fires after a short jittered
  # delay rather than a full @default_interval, so an agent begins autonomous
  # activity ~immediately on boot (the intended UX) instead of ~30s later. The
  # jitter spreads fleet starts so many agents booting at once don't thunder-herd
  # the LLM providers on their first beat.
  @first_beat_max_ms 2_000

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
    legacy_signer = Keyword.get(opts, :signer)

    with {:ok, signing_authority} <- claim_signing_authority(opts),
         :ok <- reject_mixed_credentials(signing_authority, legacy_signer) do
      init_with_authority(opts, agent_id, signing_authority, legacy_signer)
    else
      {:error, reason} -> {:stop, {:heartbeat_init_failed, reason}}
    end
  end

  defp init_with_authority(opts, agent_id, signing_authority, legacy_signer) do
    heartbeat_config = Keyword.get(opts, :heartbeat_config, %{})
    interval = Map.get(heartbeat_config, :interval, @default_interval)
    graph_path = Map.get(heartbeat_config, :graph)

    # Parse the heartbeat DOT graph
    {graph, dot_path} = load_heartbeat_graph(graph_path, opts)

    state = %{
      agent_id: agent_id,
      signer: if(signing_authority, do: nil, else: legacy_signer),
      signing_authority: signing_authority,
      heartbeat_graph: graph,
      heartbeat_dot_path: dot_path,
      heartbeat_interval: interval,
      heartbeat_ref: nil,
      heartbeat_in_flight: false,
      heartbeat_failures: 0,
      heartbeat_no_identity_beats: 0,
      heartbeat_disabled: false,
      # (B) Injectable so tests can simulate an orphan; defaults to the real Identity.Registry check.
      identity_checker: Keyword.get(opts, :identity_checker, &identity_registered?/1)
    }

    # A5: fire the first beat soon (short jittered delay), not a full interval
    # later — autonomous activity should begin right after boot, before any user
    # message. Subsequent beats use the configured interval.
    state = schedule_heartbeat(state, first_beat_delay())

    {:ok, state}
  end

  @authority_claim_attempts 3
  @authority_claim_delay_ms 10

  defp claim_signing_authority(opts) do
    case Keyword.fetch(opts, :signing_authority_bootstrap) do
      :error -> {:ok, nil}
      {:ok, bootstrap} -> claim_signing_authority(bootstrap, @authority_claim_attempts)
    end
  end

  defp claim_signing_authority(bootstrap, attempts_left) do
    case Arbor.Security.claim_signing_authority(bootstrap) do
      {:ok, authority} ->
        {:ok, authority}

      {:error, :authority_already_claimed} when attempts_left > 1 ->
        Process.sleep(@authority_claim_delay_ms)
        claim_signing_authority(bootstrap, attempts_left - 1)

      {:error, reason} ->
        {:error, {:signing_authority_claim_failed, reason}}
    end
  end

  defp reject_mixed_credentials(nil, _legacy_signer), do: :ok
  defp reject_mixed_credentials(_authority, nil), do: :ok

  defp reject_mixed_credentials(_authority, _legacy_signer),
    do: {:error, :mixed_signing_credentials}

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
  def handle_info(:heartbeat, %{heartbeat_disabled: true} = state) do
    # Heartbeat was disabled after a terminal/repeated failure — do not run or reschedule.
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    if state.identity_checker.(state.agent_id) do
      state = start_heartbeat_task(state)
      state = schedule_heartbeat(state)
      {:noreply, %{state | heartbeat_no_identity_beats: 0}}
    else
      # (B) No registered identity — do NOT run the beat (skipping means zero pipelines, so no
      # flood). Reschedule to re-check (tolerates a startup registration race); after
      # @max_no_identity_beats misses it's a real orphan and we stop the loop entirely.
      misses = state.heartbeat_no_identity_beats + 1

      if misses >= @max_no_identity_beats do
        disable_heartbeat(state, "no registered identity after #{misses} beats (orphaned agent)")
      else
        Logger.warning(
          "[HeartbeatService] #{state.agent_id} has no registered identity; " <>
            "skipping heartbeat #{misses}/#{@max_no_identity_beats} (not running the pipeline)."
        )

        state = schedule_heartbeat(state)
        {:noreply, %{state | heartbeat_no_identity_beats: misses}}
      end
    end
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

    {:noreply, %{state | heartbeat_in_flight: false, heartbeat_failures: 0}}
  end

  def handle_info({:heartbeat_result, {:error, reason}}, state) do
    Logger.warning(
      "[HeartbeatService] Heartbeat failed for #{state.agent_id}: #{inspect(reason)}"
    )

    emit_heartbeat_failed_signal(state, reason)

    failures = state.heartbeat_failures + 1

    cond do
      # A permanent auth/identity failure will recur identically every beat — retrying just
      # floods the orchestrator with doomed pipelines. This was the 2026-07-04 node-crash root
      # cause: orphaned agents (no registered identity) heartbeating on {:unauthorized,
      # :unknown_identity} ramped to ~50 pipelines/sec until the BEAM collapsed. Fail STOP.
      terminal_heartbeat_error?(reason) ->
        disable_heartbeat(state, "terminal error #{inspect(reason)}")

      # General backstop: any error that persists for @max_consecutive_heartbeat_failures beats
      # is treated as stuck, so we never flood indefinitely even on an unrecognized failure.
      failures >= @max_consecutive_heartbeat_failures ->
        disable_heartbeat(state, "#{failures} consecutive heartbeat failures")

      true ->
        {:noreply, %{state | heartbeat_in_flight: false, heartbeat_failures: failures}}
    end
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
          Logger.warning(
            "[HeartbeatService] Heartbeat blocked: unauthorized (#{inspect(reason)})"
          )

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

  defp schedule_heartbeat(state), do: schedule_heartbeat(state, state.heartbeat_interval)

  defp schedule_heartbeat(state, delay_ms) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    ref = Process.send_after(self(), :heartbeat, delay_ms)
    %{state | heartbeat_ref: ref}
  end

  # Stop the heartbeat loop: cancel the already-scheduled next beat and mark disabled so no future
  # beat runs or reschedules. The agent process stays up (it can still serve turns); only the
  # autonomous loop is halted. Returns a GenServer :noreply tuple.
  defp disable_heartbeat(state, why) do
    Logger.error(
      "[HeartbeatService] Disabling heartbeat for #{state.agent_id}: #{why}. " <>
        "Refusing to reschedule (prevents the orphaned-agent pipeline flood)."
    )

    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    {:noreply,
     %{state | heartbeat_in_flight: false, heartbeat_ref: nil, heartbeat_disabled: true}}
  end

  # A heartbeat that fails on identity/authorization will fail identically forever: the agent has
  # no registered identity (`:unknown_identity`) or lacks a required capability (`:unauthorized`) —
  # neither is fixed by retrying. Treat these as terminal so the loop stops instead of flooding.
  defp terminal_heartbeat_error?(reason) do
    s = inspect(reason)
    String.contains?(s, "unknown_identity") or String.contains?(s, ":unauthorized")
  end

  # (B) True if the agent has a registered identity (any status). No identity → the auth gate
  # rejects every beat, so the autonomous loop must not run. Fail-OPEN on a registry error so a
  # transient Identity.Registry hiccup can't silence a legitimate agent (#1 still catches a genuine
  # orphan reactively via the terminal-error path).
  defp identity_registered?(agent_id) do
    match?({:ok, _}, Arbor.Security.identity_status(agent_id))
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # First-beat delay (A5): a jittered delay in (0, @first_beat_max_ms], always far
  # below @default_interval, so the first heartbeat fires soon after init rather
  # than a full interval later. Public for testing the invariant; internal otherwise.
  @doc false
  @spec first_beat_delay() :: pos_integer()
  def first_beat_delay, do: :rand.uniform(@first_beat_max_ms)

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
          signer: state.signer,
          signing_authority: state.signing_authority,
          session_id: "heartbeat:#{state.agent_id}",
          adapters: %{},
          config: %{"stream" => false},
          pid: nil
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
          signer: state.signer,
          signing_authority: state.signing_authority,
          session_id: "heartbeat:#{state.agent_id}",
          adapters: %{},
          config: %{"stream" => false},
          pid: nil
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
          agent_id: state.agent_id
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
  # Authorization (delegates to centralized fail-closed gate)
  # ===========================================================================

  defp authorize_orchestrator(state) do
    Arbor.Orchestrator.Authorization.check_orchestrator_access(
      state.agent_id,
      state.signing_authority || state.signer
    )
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
    base =
      Path.join([
        "apps",
        "arbor_orchestrator",
        "specs",
        "pipelines",
        "session"
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
    # Canonical: abandon active runs for this session via PipelineStatus.
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
