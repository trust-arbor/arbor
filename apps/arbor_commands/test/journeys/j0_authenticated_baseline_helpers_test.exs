defmodule Arbor.Commands.Journeys.J0AuthenticatedBaselineHelpersTest do
  @moduledoc """
  Deterministic regressions for J0 fixture helpers.

  These tests fail against the original 4dd1fc4d helper code: TraceHub.drain
  acknowledged an ordinary mailbox message before Erlang trace delivery, and
  start_suite!/start_case! stored cleanup state in processes linked to the
  test owner (dead before ExUnit 1.19.5 on_exit). They do not claim product
  success and do not boot the full authenticated journey.

  Exact command:

      ./bin/mix test apps/arbor_commands/test/journeys/j0_authenticated_baseline_helpers_test.exs
  """

  use ExUnit.Case, async: false

  alias Arbor.Commands.J0AuthenticatedBaseline
  alias Arbor.Commands.J0AuthenticatedBaseline.TraceHub

  @moduletag :fast
  @moduletag timeout: 10_000

  setup do
    _ = ensure_memory_registry!()
    {started_task_sup?, task_sup_pid} = ensure_session_task_supervisor!()

    on_exit(fn ->
      if started_task_sup? do
        stop_owned_task_supervisor(task_sup_pid)
      end
    end)

    :ok
  end

  describe "late/cross-process trace delivery" do
    test "drain cannot succeed from an empty mailbox while a recall trace is in flight" do
      agent_id = unique_agent_id("late-drain")
      query = "j0-helper-late-trace-query"
      hub = TraceHub.install!(self(), [agent_id], [])
      tracer = hub.tracer

      try do
        true = :erlang.suspend_process(tracer)

        parent = self()

        drain_pid =
          spawn(fn ->
            events = TraceHub.drain(hub)
            send(parent, {:j0_helper_drain, events})
          end)

        drain_ref = Process.monitor(drain_pid)
        await_drain_queued!(tracer)

        _ = call_recall(agent_id, query)
        await_trace_delivery!(self())

        true = :erlang.resume_process(tracer)

        events = await_drain_events!(drain_ref, drain_pid)

        assert Enum.any?(events, fn
                 {:j0_dispatched_recall, ^agent_id, ^query, _result} -> true
                 _ -> false
               end),
               "late recall was lost to drain-before-delivery: #{inspect(events)}"
      after
        resume_if_suspended(tracer)
        TraceHub.uninstall(hub)
      end
    end
  end

  describe "cleanup owner and tracer lifetime" do
    test "cleanup owner survives the test-owner :shutdown that ExUnit runs before on_exit" do
      sentinel = unique_sentinel()
      Application.put_env(:arbor_commands, sentinel, :original)

      on_exit(fn ->
        Application.delete_env(:arbor_commands, sentinel)
      end)

      parent = self()

      {:ok, owner} =
        Task.start(fn ->
          bag =
            J0AuthenticatedBaseline.start_cleanup_owner!(%{
              env_snapshot: %{{:arbor_commands, sentinel} => {:ok, :original}},
              previous_home: System.get_env("ARBOR_HOME")
            })

          Application.put_env(:arbor_commands, sentinel, :mutated)
          send(parent, {:j0_helper_bag, bag})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:j0_helper_bag, bag} when is_pid(bag), 1_000

      bag_links =
        case Process.info(bag, :links) do
          {:links, links} -> links
          _ -> []
        end

      refute owner in bag_links,
             "cleanup owner must not be linked to the test process; ExUnit on_exit runs after :shutdown"

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :shutdown)
      assert_down!(owner_ref, owner)

      assert Process.alive?(bag),
             "cleanup owner died with the test process; on_exit cannot restore env"

      state = J0AuthenticatedBaseline.cleanup_owner_state(bag)
      J0AuthenticatedBaseline.stop_suite!(state)
      J0AuthenticatedBaseline.stop_cleanup_owner(bag)

      assert Application.get_env(:arbor_commands, sentinel) == :original
    end

    test "TraceHub tracer is unlinked so the final drain can run after owner shutdown" do
      parent = self()

      {:ok, owner} =
        Task.start(fn ->
          hub = TraceHub.install!(self(), [unique_agent_id("owner-trace")], [])
          send(parent, {:j0_helper_hub, hub})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:j0_helper_hub, %TraceHub{} = hub}, 1_000
      owner_ref = Process.monitor(owner)
      Process.exit(owner, :shutdown)
      assert_down!(owner_ref, owner)

      try do
        assert Process.alive?(hub.tracer),
               "tracer died with the test owner; final drain cannot synchronize"

        assert [] = TraceHub.drain(hub)
      after
        TraceHub.uninstall(hub)
      end
    end

    test "stop_suite! restores env even when an earlier cleanup step fails" do
      sentinel = unique_sentinel()
      Application.put_env(:arbor_commands, sentinel, :original)

      on_exit(fn ->
        Application.delete_env(:arbor_commands, sentinel)
      end)

      Application.put_env(:arbor_commands, sentinel, :mutated)

      dead = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead)
      assert_down!(dead_ref, dead)

      state = %{
        env_snapshot: %{{:arbor_commands, sentinel} => {:ok, :original}},
        agent_children: [{:j0_helper_missing_supervisor, :child, true}],
        orchestrator_children: [{dead, :already_dead, true}]
      }

      _ =
        try do
          J0AuthenticatedBaseline.stop_suite!(state)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      assert Application.get_env(:arbor_commands, sentinel) == :original
    end

    test "cleanup_owner_state fails closed when a created owner is dead" do
      bag = J0AuthenticatedBaseline.start_cleanup_owner!(%{marker: true})
      :ok = J0AuthenticatedBaseline.stop_cleanup_owner(bag)

      assert_raise ExUnit.AssertionError, fn ->
        J0AuthenticatedBaseline.cleanup_owner_state(bag)
      end
    end

    test "TraceHub.drain fails closed when a created tracer is dead" do
      agent_id = unique_agent_id("dead-tracer")
      hub = TraceHub.install!(self(), [agent_id], [])
      tracer = hub.tracer
      ref = Process.monitor(tracer)
      Process.exit(tracer, :kill)

      receive do
        {:DOWN, ^ref, :process, ^tracer, _} -> :ok
      after
        1_000 -> flunk("created tracer did not die")
      end

      try do
        assert_raise ExUnit.AssertionError, fn ->
          TraceHub.drain(hub)
        end
      after
        TraceHub.uninstall(hub)
      end
    end
  end

  describe "supervised Session-turn spawning coverage" do
    test "tracing only a session pid misses Task.Supervisor.start_child recall" do
      agent_id = unique_agent_id("session-only")
      query = "j0-helper-session-only-miss"
      task_sup = TraceHub.require_task_supervisor!()

      {:ok, session_like} =
        Task.start(fn ->
          receive do
            :never -> :ok
          end
        end)

      hub =
        TraceHub.install!(self(), [agent_id], [session_like], trace_task_supervisor: false)

      try do
        refute task_sup in hub.traced_pids
        assert is_nil(hub.task_supervisor)

        assert_raise ExUnit.AssertionError, fn ->
          TraceHub.assert_supervised_turn_owner_traced!(hub)
        end

        parent = self()

        {:ok, _worker} =
          Task.Supervisor.start_child(task_sup, fn ->
            result =
              Arbor.Actions.SessionMemory.bridge(
                Arbor.Memory,
                :recall,
                [agent_id, query],
                {:ok, []}
              )

            send(parent, {:j0_helper_session_only_done, result})
          end)

        assert_receive {:j0_helper_session_only_done, _result}, 1_000
        events = TraceHub.drain(hub)

        refute Enum.any?(events, fn
                 {:j0_dispatched_recall, ^agent_id, ^query, _result} -> true
                 _ -> false
               end),
               """
               Session-pid + set_on_spawn coverage observed a start_child recall.
               That would hide the do_send_message_async/5 supervised turn owner gap.
               Events: #{inspect(events)}
               """
      after
        TraceHub.uninstall(hub)
        Process.exit(session_like, :kill)
      end
    end

    test "Task.Supervisor.start_child workers are traced, not only Task.start children" do
      agent_id = unique_agent_id("supervised-turn")
      query = "j0-helper-supervised-turn-query"

      hub = TraceHub.install!(self(), [agent_id], [])

      try do
        task_sup = TraceHub.assert_supervised_turn_owner_traced!(hub).task_supervisor
        parent = self()

        {:ok, _worker} =
          Task.Supervisor.start_child(task_sup, fn ->
            result = call_recall(agent_id, query)
            send(parent, {:j0_helper_turn_done, result})
          end)

        assert_receive {:j0_helper_turn_done, _result}, 1_000

        events = TraceHub.drain(hub)

        assert Enum.any?(events, fn
                 {:j0_dispatched_recall, ^agent_id, ^query, _result} -> true
                 _ -> false
               end),
               """
               Supervised start_child recall was not traced. The production Session
               path uses Task.Supervisor.start_child, not Task.start.
               Events: #{inspect(events)}
               """
      after
        TraceHub.uninstall(hub)
      end
    end

    test "session_memory.recall bridge/apply from a start_child worker is observed" do
      agent_id = unique_agent_id("bridge-turn")
      query = "j0-helper-session-memory-bridge-query"
      Code.ensure_loaded!(Arbor.Actions.SessionMemory)

      hub = TraceHub.install!(self(), [agent_id], [])

      try do
        task_sup = TraceHub.assert_supervised_turn_owner_traced!(hub).task_supervisor
        parent = self()

        {:ok, _worker} =
          Task.Supervisor.start_child(task_sup, fn ->
            result =
              Arbor.Actions.SessionMemory.bridge(
                Arbor.Memory,
                :recall,
                [agent_id, query],
                {:ok, []}
              )

            send(parent, {:j0_helper_bridge_done, result})
          end)

        assert_receive {:j0_helper_bridge_done, _result}, 1_000

        events = TraceHub.drain(hub)

        assert Enum.any?(events, fn
                 {:j0_dispatched_recall, ^agent_id, ^query, _result} -> true
                 _ -> false
               end),
               """
               apply(Arbor.Memory, :recall, [agent_id, query]) from a
               Task.Supervisor.start_child worker was not observed as
               Arbor.Memory.recall/2,3. Events: #{inspect(events)}
               """
      after
        TraceHub.uninstall(hub)
      end
    end

    test "recall evidence regression: repeated real calls are not discarded by query" do
      agent_id = unique_agent_id("repeated-recall")
      query = "j0-helper-repeat-the-real-call"
      hub = TraceHub.install!(self(), [agent_id], [])

      try do
        parent = self()

        {:ok, _worker} =
          Task.Supervisor.start_child(hub.task_supervisor, fn ->
            call_recall(agent_id, query)
            call_recall(agent_id, query)
            send(parent, :j0_repeated_calls_finished)
          end)

        assert_receive :j0_repeated_calls_finished, 1_000

        observations =
          Enum.filter(TraceHub.drain(hub), fn
            {:j0_dispatched_recall, ^agent_id, ^query, _result} -> true
            _ -> false
          end)

        assert length(observations) >= 2,
               "query-only deduplication erased a real recall; later results must remain observable"
      after
        TraceHub.uninstall(hub)
      end
    end

    test "bridge fallback without Memory.recall is not dispatched-recall evidence" do
      agent_id = unique_agent_id("bridge-fallback")
      query = "j0-helper-bridge-fallback-query"
      Code.ensure_loaded!(Arbor.Actions.SessionMemory)
      Code.ensure_loaded!(Arbor.Memory)

      hub = TraceHub.install!(self(), [agent_id], [])

      try do
        task_sup = TraceHub.assert_supervised_turn_owner_traced!(hub).task_supervisor
        parent = self()

        refute function_exported?(Arbor.Memory, :recall, 4)

        {:ok, _worker} =
          Task.Supervisor.start_child(task_sup, fn ->
            result =
              Arbor.Actions.SessionMemory.bridge(
                Arbor.Memory,
                :recall,
                [agent_id, query, :unused, :unused],
                {:ok, []}
              )

            send(parent, {:j0_helper_bridge_fallback, result})
          end)

        assert_receive {:j0_helper_bridge_fallback, result}, 1_000
        assert result == {:ok, []}

        events = TraceHub.drain(hub)

        refute Enum.any?(events, fn
                 {:j0_dispatched_recall, ^agent_id, ^query, _result} -> true
                 _ -> false
               end),
               """
               SessionMemory.bridge returned its fallback without calling
               Arbor.Memory.recall; that must not count as dispatched recall.
               Events: #{inspect(events)}
               """
      after
        TraceHub.uninstall(hub)
      end
    end

    test "uninstall clears tracing so a later case cannot observe prior recall patterns" do
      agent_id = unique_agent_id("no-leak")
      hub = TraceHub.install!(self(), [agent_id], [])
      TraceHub.uninstall(hub)

      refute Process.alive?(hub.tracer)

      _ = call_recall(agent_id, "j0-helper-after-uninstall")
      refute_receive {:j0_dispatched_recall, ^agent_id, _, _}, 50
    end

    test "failed install rolls back the tracer and global trace patterns" do
      dead = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead)

      receive do
        {:DOWN, ^dead_ref, :process, ^dead, _} -> :ok
      after
        1_000 -> flunk("dead pid did not exit")
      end

      assert_raise ArgumentError, fn ->
        TraceHub.install!(self(), [unique_agent_id("install-rollback")], [dead])
      end

      assert {:traced, false} = :erlang.trace_info({Arbor.Memory, :recall, 2}, :traced)
      assert {:traced, false} = :erlang.trace_info({Arbor.Memory, :recall, 3}, :traced)
    end
  end

  defp unique_agent_id(label) do
    "agent_j0_helper_#{label}_#{System.unique_integer([:positive])}"
  end

  defp unique_sentinel do
    :"j0_helper_sentinel_#{System.unique_integer([:positive])}"
  end

  defp call_recall(agent_id, query) do
    Arbor.Memory.recall(agent_id, query)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ensure_memory_registry! do
    case alive_named(Arbor.Memory.Registry) do
      pid when is_pid(pid) ->
        false

      nil ->
        case Registry.start_link(keys: :unique, name: Arbor.Memory.Registry) do
          {:ok, _} ->
            true

          {:error, {:already_started, pid}} ->
            Process.alive?(pid)
        end
    end
  end

  defp ensure_session_task_supervisor! do
    name = Arbor.Orchestrator.Session.TaskSupervisor

    case alive_named(name) do
      pid when is_pid(pid) ->
        {false, pid}

      nil ->
        case Task.Supervisor.start_link(name: name) do
          {:ok, pid} ->
            {true, pid}

          {:error, {:already_started, pid}} ->
            if Process.alive?(pid) do
              {false, pid}
            else
              flunk("#{inspect(name)} is registered but dead")
            end

          {:error, reason} ->
            flunk("failed to start {Task.Supervisor, name: #{inspect(name)}}: #{inspect(reason)}")
        end
    end
  end

  defp alive_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: nil

      _ ->
        nil
    end
  end

  defp stop_owned_task_supervisor(pid) when is_pid(pid) do
    name = Arbor.Orchestrator.Session.TaskSupervisor

    if Process.whereis(name) == pid and Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp stop_owned_task_supervisor(_), do: :ok

  defp await_drain_queued!(tracer) do
    deadline = System.monotonic_time(:millisecond) + 500
    await_drain_queued!(tracer, deadline)
  end

  defp await_drain_queued!(tracer, deadline) do
    messages =
      case Process.info(tracer, :messages) do
        {:messages, msgs} -> msgs
        _ -> []
      end

    queued? =
      Enum.any?(messages, fn
        {:drain, _from, _ref} -> true
        _ -> false
      end)

    cond do
      queued? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("drain request never appeared in the suspended tracer mailbox")

      true ->
        receive do
        after
          5 -> await_drain_queued!(tracer, deadline)
        end
    end
  end

  defp await_trace_delivery!(tracee) do
    delivery = :erlang.trace_delivered(tracee)

    receive do
      {:trace_delivered, ^tracee, ^delivery} -> :ok
    after
      1_000 -> flunk("Erlang trace delivery barrier timed out for #{inspect(tracee)}")
    end
  end

  defp await_drain_events!(drain_ref, drain_pid) do
    receive do
      {:j0_helper_drain, events} ->
        Process.demonitor(drain_ref, [:flush])
        events

      {:DOWN, ^drain_ref, :process, ^drain_pid, reason} ->
        flunk("drain process exited before returning events: #{inspect(reason)}")
    after
      2_000 ->
        flunk("drain did not complete after tracer resume")
    end
  end

  defp assert_down!(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> flunk("process #{inspect(pid)} did not exit")
    end
  end

  defp resume_if_suspended(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      case Process.info(pid, :status) do
        {:status, :suspended} -> :erlang.resume_process(pid)
        _ -> :ok
      end
    else
      :ok
    end
  end
end
