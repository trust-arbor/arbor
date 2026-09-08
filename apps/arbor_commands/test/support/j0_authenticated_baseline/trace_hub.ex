defmodule Arbor.Commands.J0AuthenticatedBaseline.TraceHub do
  @moduledoc false

  # One tracer for the journey. Pending recall calls are stacked per traced
  # pid so concurrent Session tasks cannot mispair call/return_from.
  #
  # Dispatched-recall evidence is only Arbor.Memory.recall/2,3 call+return
  # (or exception). SessionMemory.bridge/4 may return its fallback without
  # calling the facade; IndexOps.recall is an internal defdelegate target.
  # Neither is interchangeable with a public facade observation. Production
  # session_memory.recall apply/3 of Memory.recall/2 is traced as that MFA.
  #
  # Arbor.Orchestrator.Session.do_send_message_async/5 uses
  # Task.Supervisor.start_child(Arbor.Orchestrator.Session.TaskSupervisor)
  # whenever that name is registered — Application starts it — and only
  # falls back to Task.start when it is absent. Tracing parent + Session
  # pids with set_on_spawn therefore misses the real turn owner. install!/4
  # requires that supervisor (unless explicitly disabled for a negative
  # regression) and must run before any turn starts.
  #
  # Drain uses :erlang.trace_delivered/1 inside the tracer so an ordinary
  # {:drain, ...} message cannot acknowledge an empty mailbox while call
  # traces are still in flight. One drain at a time: a nested drain is
  # rejected with {:error, :drain_in_progress}. Preserve every facade
  # observation: repeated queries can return different results. The tracer
  # is unlinked: ExUnit 1.19.5 test processes exit
  # :shutdown before on_exit, and a linked tracer would die before the
  # final drain.

  import ExUnit.Assertions

  @req_llm Arbor.LLM.Adapter.ReqLLM
  @acp Module.concat([Arbor, AI, LLM, Adapter, Acp])
  @drain_timeout_ms 2_000
  @delivery_timeout_ms 1_000
  @recall_match [{:_, [], [{:return_trace}, {:exception_trace}]}]

  defstruct [:tracer, :parent, :agent_ids, :traced_pids, :task_supervisor]

  def install!(parent, agent_ids, session_pids, opts \\ [])
      when is_pid(parent) and is_list(agent_ids) and is_list(session_pids) and is_list(opts) do
    # Validate the required turn owner before allocating an unlinked tracer
    # or installing process-global trace patterns.
    task_sup = maybe_task_supervisor!(opts)

    Code.ensure_loaded!(Arbor.Memory)
    Code.ensure_loaded!(@req_llm)

    tracer = spawn(fn -> loop(parent, MapSet.new(agent_ids), %{}, []) end)

    try do
      install_trace_patterns!()

      traced_pids =
        [parent, task_sup | session_pids]
        |> Enum.filter(&is_pid/1)
        |> Enum.uniq()

      enable_call_tracing!(tracer, traced_pids)

      hub = %__MODULE__{
        tracer: tracer,
        parent: parent,
        agent_ids: agent_ids,
        traced_pids: traced_pids,
        task_supervisor: task_sup
      }

      if is_pid(task_sup) do
        assert_supervised_turn_owner_traced!(hub)
      else
        hub
      end
    rescue
      exception ->
        rollback_install(tracer, [parent, task_sup | session_pids])
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        rollback_install(tracer, [parent, task_sup | session_pids])
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def trace_pids!(%__MODULE__{tracer: tracer, traced_pids: traced_pids} = hub, pids)
      when is_list(pids) do
    unless is_pid(tracer) and Process.alive?(tracer) do
      flunk("TraceHub tracer is dead; cannot extend turn coverage")
    end

    extra =
      pids
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()
      |> Enum.filter(&Process.alive?/1)
      |> Enum.reject(&(&1 in traced_pids))

    Enum.each(extra, fn pid ->
      :erlang.trace(pid, true, [:call, :set_on_spawn, tracer: tracer])
    end)

    %{hub | traced_pids: traced_pids ++ extra}
  end

  def require_task_supervisor! do
    case Process.whereis(Arbor.Orchestrator.Session.TaskSupervisor) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          flunk(missing_task_supervisor_message())
        end

      _ ->
        flunk(missing_task_supervisor_message())
    end
  end

  def assert_supervised_turn_owner_traced!(%__MODULE__{} = hub) do
    owner = require_task_supervisor!()

    assert hub.task_supervisor == owner,
           "TraceHub.task_supervisor is #{inspect(hub.task_supervisor)}, live owner is #{inspect(owner)}"

    assert owner in hub.traced_pids,
           """
           Session.TaskSupervisor #{inspect(owner)} is not in traced_pids.
           Session.start_child turns will not be observed; tracing only parent/Session
           pids covers the Task.start fallback. Traced: #{inspect(hub.traced_pids)}
           """

    hub
  end

  def drain(%__MODULE__{tracer: tracer}) when is_pid(tracer) do
    mon = Process.monitor(tracer)

    try do
      unless Process.alive?(tracer) do
        flunk("TraceHub tracer is dead; traces cannot be synchronized")
      end

      ref = make_ref()
      send(tracer, {:drain, self(), ref})

      receive do
        {:DOWN, ^mon, :process, ^tracer, reason} ->
          flunk("TraceHub tracer died while draining: #{inspect(reason)}")

        {:j0_trace_drain, ^ref, {:error, :trace_delivery_timeout}} ->
          flunk("timed out waiting for Erlang trace delivery barrier")

        {:j0_trace_drain, ^ref, {:error, :drain_in_progress}} ->
          flunk("TraceHub drain already in progress")

        {:j0_trace_drain, ^ref, events} when is_list(events) ->
          events
      after
        @drain_timeout_ms ->
          flunk("timed out draining TraceHub; outbound/recall traces were not synchronized")
      end
    after
      Process.demonitor(mon, [:flush])
    end
  end

  def uninstall(%__MODULE__{tracer: tracer, traced_pids: traced_pids}) when is_pid(tracer) do
    disable_call_tracing(traced_pids)
    clear_trace_patterns()
    stop_tracer(tracer)
    :ok
  end

  def uninstall(_), do: :ok

  def escape_event?({:req_llm, _fun}), do: true
  def escape_event?({:acp, _fun}), do: true
  def escape_event?({:j0_req_llm_escape, _fun, _args}), do: true
  def escape_event?({:j0_acp_escape, _fun, _args}), do: true
  def escape_event?(_), do: false

  defp maybe_task_supervisor!(opts) do
    if Keyword.get(opts, :trace_task_supervisor, true) do
      require_task_supervisor!()
    else
      nil
    end
  end

  defp missing_task_supervisor_message do
    """
    Arbor.Orchestrator.Session.TaskSupervisor is not running.
    Arbor.Orchestrator.Session.do_send_message_async/5 uses
    Task.Supervisor.start_child/2 whenever that name is registered
    (apps/arbor_orchestrator/lib/arbor/orchestrator/session.ex) and Application
    starts it. Tracing only parent + Session pids with set_on_spawn covers the
    Task.start fallback, not the production supervised turn owner.
    """
  end

  defp install_trace_patterns! do
    _ = :erlang.trace_pattern({Arbor.Memory, :recall, 2}, @recall_match, [:local])
    _ = :erlang.trace_pattern({Arbor.Memory, :recall, 3}, @recall_match, [:local])
    _ = :erlang.trace_pattern({@req_llm, :complete, 1}, true, [:local])
    _ = :erlang.trace_pattern({@req_llm, :complete, 2}, true, [:local])
    _ = :erlang.trace_pattern({@req_llm, :stream, 2}, true, [:local])

    if Code.ensure_loaded?(@acp) do
      _ = :erlang.trace_pattern({@acp, :complete, 1}, true, [:local])
      _ = :erlang.trace_pattern({@acp, :complete, 2}, true, [:local])
    end

    :ok
  end

  defp enable_call_tracing!(tracer, pids) do
    Enum.each(pids, fn pid ->
      :erlang.trace(pid, true, [:call, :set_on_spawn, tracer: tracer])
    end)
  end

  defp rollback_install(tracer, pids) do
    uninstall(%__MODULE__{
      tracer: tracer,
      traced_pids: Enum.filter(List.wrap(pids), &is_pid/1)
    })
  end

  defp disable_call_tracing(traced_pids) do
    Enum.each(List.wrap(traced_pids), fn pid ->
      try do
        :erlang.trace(pid, false, [:call, :set_on_spawn])
      rescue
        ArgumentError -> :ok
      catch
        :error, _ -> :ok
      end
    end)
  end

  defp clear_trace_patterns do
    _ = :erlang.trace_pattern({Arbor.Memory, :recall, 2}, false, [:local])
    _ = :erlang.trace_pattern({Arbor.Memory, :recall, 3}, false, [:local])
    _ = :erlang.trace_pattern({@req_llm, :complete, 1}, false, [:local])
    _ = :erlang.trace_pattern({@req_llm, :complete, 2}, false, [:local])
    _ = :erlang.trace_pattern({@req_llm, :stream, 2}, false, [:local])

    if Code.ensure_loaded?(@acp) do
      _ = :erlang.trace_pattern({@acp, :complete, 1}, false, [:local])
      _ = :erlang.trace_pattern({@acp, :complete, 2}, false, [:local])
    end

    :ok
  end

  defp stop_tracer(tracer) when is_pid(tracer) do
    if Process.alive?(tracer) do
      send(tracer, :stop)
      ref = Process.monitor(tracer)

      receive do
        {:DOWN, ^ref, :process, ^tracer, _} -> :ok
      after
        500 ->
          Process.exit(tracer, :kill)
          :ok
      end
    else
      :ok
    end
  end

  defp stop_tracer(_), do: :ok

  defp loop(parent, agent_ids, pending, completed) do
    receive do
      {:drain, from, ref} ->
        delivery = :erlang.trace_delivered(:all)
        drain_loop(parent, agent_ids, pending, completed, from, ref, delivery)

      :stop ->
        :ok

      msg ->
        {pending, completed} = handle_trace(msg, parent, agent_ids, pending, completed)
        loop(parent, agent_ids, pending, completed)
    end
  end

  defp drain_loop(parent, agent_ids, pending, completed, from, ref, delivery) do
    receive do
      {:trace_delivered, :all, ^delivery} ->
        send(from, {:j0_trace_drain, ref, Enum.reverse(completed)})
        loop(parent, agent_ids, pending, [])

      {:drain, later_from, later_ref} ->
        send(later_from, {:j0_trace_drain, later_ref, {:error, :drain_in_progress}})
        drain_loop(parent, agent_ids, pending, completed, from, ref, delivery)

      :stop ->
        send(from, {:j0_trace_drain, ref, Enum.reverse(completed)})
        :ok

      {:trace, _, _, _} = msg ->
        {pending, completed} = handle_trace(msg, parent, agent_ids, pending, completed)
        drain_loop(parent, agent_ids, pending, completed, from, ref, delivery)

      {:trace, _, _, _, _} = msg ->
        {pending, completed} = handle_trace(msg, parent, agent_ids, pending, completed)
        drain_loop(parent, agent_ids, pending, completed, from, ref, delivery)
    after
      @delivery_timeout_ms ->
        send(from, {:j0_trace_drain, ref, {:error, :trace_delivery_timeout}})
        loop(parent, agent_ids, pending, completed)
    end
  end

  defp handle_trace(
         {:trace, pid, :call, {Arbor.Memory, :recall, [agent_id, query | rest]}},
         _parent,
         _agent_ids,
         pending,
         completed
       ) do
    {push_pending(pending, pid, {:recall, 2 + length(rest), agent_id, query}), completed}
  end

  defp handle_trace(
         {:trace, pid, :return_from, {Arbor.Memory, :recall, arity}, result},
         parent,
         agent_ids,
         pending,
         completed
       ) do
    pair_return(parent, agent_ids, pending, completed, pid, {:recall, arity}, result)
  end

  defp handle_trace(
         {:trace, pid, :exception_from, {Arbor.Memory, :recall, arity}, reason},
         parent,
         agent_ids,
         pending,
         completed
       ) do
    pair_return(parent, agent_ids, pending, completed, pid, {:recall, arity}, {:error, reason})
  end

  defp handle_trace(
         {:trace, _pid, :call, {@req_llm, fun, args}},
         parent,
         _agent_ids,
         pending,
         completed
       ) do
    payload = {:j0_req_llm_escape, fun, args}
    send(parent, payload)
    {pending, [{:req_llm, fun} | completed]}
  end

  defp handle_trace(
         {:trace, _pid, :call, {@acp, fun, args}},
         parent,
         _agent_ids,
         pending,
         completed
       ) do
    payload = {:j0_acp_escape, fun, args}
    send(parent, payload)
    {pending, [{:acp, fun} | completed]}
  end

  defp handle_trace(_other, _parent, _agent_ids, pending, completed) do
    {pending, completed}
  end

  defp push_pending(pending, pid, entry) do
    Map.put(pending, pid, [entry | Map.get(pending, pid, [])])
  end

  defp pair_return(parent, agent_ids, pending, completed, pid, {kind, arity}, result) do
    case Map.get(pending, pid, []) do
      [{^kind, ^arity, agent_id, query} | rest] ->
        pending =
          if rest == [] do
            Map.delete(pending, pid)
          else
            Map.put(pending, pid, rest)
          end

        completed =
          if MapSet.member?(agent_ids, agent_id) do
            record_dispatched_recall(parent, completed, agent_id, query, result)
          else
            completed
          end

        {pending, completed}

      _other ->
        {pending, completed}
    end
  end

  defp record_dispatched_recall(parent, completed, agent_id, query, result) do
    payload = {:j0_dispatched_recall, agent_id, query, result}
    send(parent, payload)
    [payload | completed]
  end
end
