defmodule Arbor.Orchestrator.Session.TurnCommitAcknowledgementTest do
  @moduledoc """
  Security regression: a public Session success reply requires an acknowledged
  user/assistant pair append. Delayed, failed, malformed, raised, and timed-out
  persistence cannot produce completed-turn state. Parent-failing on fire-and-forget
  `Task.start` persist (`f9a06b5d`).

  This file does not start, stop, suspend, or message
  `Arbor.Orchestrator.Session.TaskSupervisor`.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Session.AssistantMessage
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Persistence
  alias Arbor.Orchestrator.TestCapabilities

  @commit_timeout_ms 150
  @timeout_slack_ms 2_500

  setup_all do
    case Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "delayed acknowledgement" do
    test "a held append cannot return final success until it acks, then one pair is stored" do
      parent = self()
      {:ok, probe} = Agent.start_link(fn -> %{pairs: []} end)

      append = fn _uuid, entries ->
        send(parent, {:append_started, self()})

        receive do
          :release ->
            Agent.update(probe, fn state -> %{state | pairs: state.pairs ++ [entries]} end)
            {:ok, 2}
        end
      end

      {pid, tmp_dir} = start_session(append_session_entries: append)

      caller =
        Task.async(fn ->
          Session.send_message(pid, "hello delayed")
        end)

      assert_receive {:append_started, writer}, 1_000
      assert Process.alive?(writer)
      assert Task.yield(caller, 80) == nil

      send(writer, :release)
      assert {:ok, _response} = Task.await(caller, 2_000)
      assert length(Agent.get(probe, & &1.pairs)) == 1

      stop_session(pid, tmp_dir)
    end
  end

  describe "timeout and process lifetime" do
    test "held writer times out with no success state, and writer and guard are reaped" do
      parent = self()
      checkpoint_calls = :counters.new(1, [:atomics])

      append = fn _uuid, _entries ->
        send(parent, {:append_started, self(), linked_guard(self())})
        Process.sleep(:infinity)
      end

      {pid, tmp_dir} =
        start_session(
          append_session_entries: append,
          checkpoint_save: fn _session_id, _data ->
            :counters.add(checkpoint_calls, 1, 1)
            :ok
          end
        )

      before = Session.get_state(pid)
      result = Session.send_message(pid, "held writer")

      assert {:error, :turn_commit_failed} = result
      assert_receive {:append_started, writer, guard}, 1_000
      assert_reaped(writer, guard)
      assert Process.alive?(pid)

      after_state = Session.get_state(pid)
      assert after_state.turn_count == before.turn_count
      assert after_state.messages == before.messages
      assert after_state.turn_in_flight == false
      assert :counters.get(checkpoint_calls, 1) == 0

      stop_session(pid, tmp_dir)
    end

    test "late tagged success is queued across the deadline and rejected" do
      parent = self()
      checkpoint_calls = :counters.new(1, [:atomics])

      append = fn _uuid, _entries ->
        send(parent, {:append_started, self(), linked_guard(self())})

        receive do
          :release -> {:ok, 2}
        end
      end

      {pid, tmp_dir} =
        start_session(
          append_session_entries: append,
          checkpoint_save: fn _session_id, _data ->
            :counters.add(checkpoint_calls, 1, 1)
            :ok
          end
        )

      on_exit(fn -> resume_if_suspended(pid) end)
      before = Session.get_state(pid)
      started = System.monotonic_time(:millisecond)

      caller = Task.async(fn -> Session.send_message(pid, "late success") end)

      assert_receive {:append_started, writer, guard}, 1_000
      persistence_started = System.monotonic_time(:millisecond)
      assert is_pid(writer)
      assert is_pid(guard)
      on_exit(fn -> resume_if_suspended(guard) end)

      true = :erlang.suspend_process(pid)
      true = :erlang.suspend_process(guard)

      wait_past_deadline(persistence_started, @commit_timeout_ms)
      crossed = System.monotonic_time(:millisecond) - persistence_started
      assert crossed >= @commit_timeout_ms

      send(writer, :release)
      wait_dead(writer)

      true = :erlang.resume_process(guard)
      wait_dead(guard)
      true = :erlang.resume_process(pid)

      assert {:error, :turn_commit_failed} = Task.await(caller, @timeout_slack_ms)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= @commit_timeout_ms
      assert elapsed <= @timeout_slack_ms

      assert_reaped(writer, guard)
      assert Process.alive?(pid)
      after_state = Session.get_state(pid)
      assert after_state.turn_count == before.turn_count
      assert after_state.messages == before.messages
      assert :counters.get(checkpoint_calls, 1) == 0
      stop_session(pid, tmp_dir)
    end

    test "Session death reaps the held writer and guard" do
      parent = self()

      append = fn _uuid, _entries ->
        send(parent, {:append_started, self(), linked_guard(self())})
        Process.sleep(:infinity)
      end

      {pid, tmp_dir} = start_session(append_session_entries: append)

      caller =
        spawn(fn ->
          Session.send_message(pid, "session death")
        end)

      Process.monitor(caller)
      assert_receive {:append_started, writer, guard}, 1_000
      assert is_pid(writer)
      assert is_pid(guard)
      true = Process.unlink(pid)
      Process.exit(pid, :kill)
      wait_dead(pid)
      wait_dead(writer)
      wait_dead(guard)
      File.rm_rf(tmp_dir)
    end

    test "guard failure reaps the writer; Session survives and a later turn succeeds" do
      parent = self()
      {:ok, probe} = Agent.start_link(fn -> :hang end)

      append = fn _uuid, entries ->
        case Agent.get(probe, & &1) do
          :hang ->
            send(parent, {:append_started, self(), linked_guard(self())})
            Process.sleep(:infinity)

          :ok ->
            send(parent, {:append_ok, entries})
            {:ok, 2}
        end
      end

      {pid, tmp_dir} = start_session(append_session_entries: append)

      caller = Task.async(fn -> Session.send_message(pid, "guard fail") end)
      assert_receive {:append_started, writer, guard}, 1_000
      assert is_pid(writer)
      assert is_pid(guard)
      Process.exit(guard, :kill)

      assert {:error, :turn_commit_failed} = Task.await(caller, @timeout_slack_ms)
      assert_reaped(writer, guard)
      assert Process.alive?(pid)

      Agent.update(probe, fn _ -> :ok end)
      assert {:ok, _} = Session.send_message(pid, "next turn")
      assert_receive {:append_ok, _entries}, 1_000
      assert Session.get_state(pid).turn_count == 1

      stop_session(pid, tmp_dir)
    end
  end

  describe "late arming, late results, and no early reply" do
    test "a suspended persist caller cannot emit an early success and reaps the writer" do
      parent = self()

      append = fn _uuid, _entries ->
        send(parent, {:append_started, self(), linked_guard(self())})
        Process.sleep(:infinity)
      end

      state = persist_state(append_session_entries: append)

      caller =
        spawn(fn ->
          result = persist_pair(state)
          send(parent, {:caller_done, result})
        end)

      assert_receive {:append_started, writer, guard}, 1_000
      true = :erlang.suspend_process(caller)
      on_exit(fn -> resume_if_suspended(caller) end)
      refute_received {:caller_done, _}
      Process.sleep(@commit_timeout_ms + 30)
      refute_received {:caller_done, _}
      true = :erlang.resume_process(caller)

      assert_receive {:caller_done, {:error, :turn_persistence_uncertain}}, @timeout_slack_ms
      assert_reaped(writer, guard)
    end

    test "a short deadline fails closed and leaves no observed writer alive" do
      parent = self()
      {:ok, probe} = Agent.start_link(fn -> %{calls: 0} end)

      append = fn _uuid, _entries ->
        Agent.update(probe, fn state -> %{state | calls: state.calls + 1} end)
        send(parent, {:append_started, self(), linked_guard(self())})
        Process.sleep(:infinity)
      end

      state = persist_state(append_session_entries: append, turn_commit_timeout_ms: 1)

      caller =
        spawn(fn ->
          send(parent, {:caller_ready, self()})
          result = persist_pair(state)
          send(parent, {:caller_done, result})
        end)

      assert_receive {:caller_ready, ^caller}, 1_000
      true = :erlang.suspend_process(caller)
      on_exit(fn -> resume_if_suspended(caller) end)
      Process.sleep(20)
      true = :erlang.resume_process(caller)

      assert_receive {:caller_done, {:error, reason}}, @timeout_slack_ms
      assert reason in [:turn_persistence_uncertain, :turn_persistence_raised]

      receive do
        {:append_started, writer, guard} ->
          assert_reaped(writer, guard)
      after
        50 ->
          assert Agent.get(probe, & &1.calls) == 0
      end
    end
  end

  describe "classified persistence failures" do
    test "ensure/append errors, malformed, raise, throw, and exit stay bounded" do
      variants = [
        {:ensure_error, fn -> {:error, :session_owner_mismatch} end, nil},
        {:append_error, nil, fn -> {:error, :simulated_append_failure} end},
        {:malformed_ok_1, nil, fn -> {:ok, 1} end},
        {:malformed_ok_atom, nil, fn -> :ok end},
        {:malformed_garbage, nil, fn -> {:ok, "nope"} end},
        {:raise, nil, fn -> raise "boom" end},
        {:throw, nil, fn -> throw(:nope) end},
        {:exit, nil, fn -> Process.exit(self(), :boom) end}
      ]

      Enum.each(variants, fn {name, ensure_fun, append_fun} ->
        ensure =
          if ensure_fun do
            fn session_id, agent_id, [] ->
              _ = {session_id, agent_id, name}
              ensure_fun.()
            end
          else
            fn session_id, agent_id, [] ->
              {:ok, %{id: "uuid_#{session_id}", session_id: session_id, agent_id: agent_id}}
            end
          end

        append =
          if append_fun do
            fn _uuid, _entries -> append_fun.() end
          else
            fn _uuid, _entries -> {:ok, 2} end
          end

        {pid, tmp_dir} =
          start_session(ensure_session: ensure, append_session_entries: append)

        assert {:error, :turn_commit_failed} = Session.send_message(pid, "fail #{name}"),
               "expected bounded commit failure for #{name}"

        assert Process.alive?(pid), "Session died after #{name}"
        assert Session.get_state(pid).turn_in_flight == false
        stop_session(pid, tmp_dir)
      end)
    end

    test "failed commit has no success effects and the next turn writes exactly one pair" do
      {:ok, probe} = Agent.start_link(fn -> %{mode: :fail, pairs: []} end)
      checkpoint_calls = :counters.new(1, [:atomics])

      append = fn _uuid, entries ->
        Agent.get_and_update(probe, fn state ->
          case state.mode do
            :fail ->
              {{:error, :simulated}, %{state | mode: :ok}}

            :ok ->
              {{:ok, 2}, %{state | pairs: state.pairs ++ [entries]}}
          end
        end)
      end

      {pid, tmp_dir} =
        start_session(
          append_session_entries: append,
          checkpoint_save: fn _session_id, _data ->
            :counters.add(checkpoint_calls, 1, 1)
            :ok
          end
        )

      before = Session.get_state(pid)
      assert {:error, :turn_commit_failed} = Session.send_message(pid, "first fails")
      failed = Session.get_state(pid)
      assert failed.turn_count == before.turn_count
      assert failed.messages == before.messages
      assert :counters.get(checkpoint_calls, 1) == 0
      assert Agent.get(probe, & &1.pairs) == []

      assert {:ok, _} = Session.send_message(pid, "second succeeds")
      succeeded = Session.get_state(pid)
      assert succeeded.turn_count == before.turn_count + 1
      assert length(Agent.get(probe, & &1.pairs)) == 1

      stop_session(pid, tmp_dir)
    end
  end

  defp linked_guard(writer) do
    case Process.info(writer, :links) do
      {:links, links} ->
        guard = Enum.find(links, fn pid -> is_pid(pid) and pid != writer end)

        assert is_pid(guard),
               "writer #{inspect(writer)} has no guard link: #{inspect(links)}"

        guard

      other ->
        flunk("writer #{inspect(writer)} links unavailable: #{inspect(other)}")
    end
  end

  defp assert_reaped(writer, guard) do
    assert is_pid(writer)
    assert is_pid(guard)
    refute Process.alive?(writer)
    refute Process.alive?(guard)
  end

  defp wait_past_deadline(started_mono, deadline_ms) do
    remaining = deadline_ms + 30 - (System.monotonic_time(:millisecond) - started_mono)
    if remaining > 0, do: Process.sleep(remaining)
    :ok
  end

  defp wait_dead(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    if Process.alive?(pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        @timeout_slack_ms -> flunk("process #{inspect(pid)} still alive")
      end
    else
      Process.demonitor(ref, [:flush])
      :ok
    end
  end

  defp resume_if_suspended(pid) when is_pid(pid) do
    :erlang.resume_process(pid)
  catch
    :error, _ -> :ok
  end

  defp persist_pair(state) do
    now = DateTime.utc_now()

    Persistence.persist_turn_entries(
      state,
      %{"role" => "user", "content" => "held"},
      %AssistantMessage{content: "reply", started_at: now, completed_at: now},
      %{},
      user_sent_at: now,
      assistant_completed_at: now
    )
  end

  defp persist_state(overrides) do
    timeout_ms = Keyword.get(overrides, :turn_commit_timeout_ms, @commit_timeout_ms)

    adapters =
      %{
        ensure_session: succeeding_ensure(),
        append_session_entries: fn _uuid, entries -> {:ok, length(entries)} end
      }
      |> Map.merge(Map.new(Keyword.delete(overrides, :turn_commit_timeout_ms)))

    %{
      session_id: "persist-ack-#{:erlang.unique_integer([:positive])}",
      agent_id: "agent_persist_ack",
      turn_count: 0,
      messages: [],
      config: %{turn_commit_timeout_ms: timeout_ms},
      adapters: adapters
    }
  end

  defp succeeding_ensure do
    fn session_id, agent_id, [] ->
      {:ok, %{id: "uuid_#{session_id}", session_id: session_id, agent_id: agent_id}}
    end
  end

  defp start_session(adapter_overrides) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_turn_commit_ack_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    turn_dot = """
    digraph Turn {
      graph [goal="Ack test turn"]
      start [shape=Mdiamond]
      classify [type="compute", simulate="true"]
      format [type="transform", transform="identity", source_key="last_response", output_key="session.response"]
      done [shape=Msquare]
      start -> classify -> format -> done
    }
    """

    heartbeat_dot = """
    digraph Heartbeat {
      graph [goal="Ack test heartbeat"]
      start [shape=Mdiamond]
      select_mode [type="compute", simulate="true"]
      done [shape=Msquare]
      start -> select_mode -> done
    }
    """

    turn_path = Path.join(tmp_dir, "turn.dot")
    heartbeat_path = Path.join(tmp_dir, "heartbeat.dot")
    File.write!(turn_path, turn_dot)
    File.write!(heartbeat_path, heartbeat_dot)

    adapters =
      %{
        ensure_session: succeeding_ensure(),
        append_session_entries: fn _uuid, entries -> {:ok, length(entries)} end
      }
      |> Map.merge(Map.new(adapter_overrides))

    agent_id = "agent_ack_#{:erlang.unique_integer([:positive])}"
    :ok = TestCapabilities.grant_orchestrator_access(agent_id)
    on_exit(fn -> TestCapabilities.revoke_all(agent_id) end)

    {:ok, pid} =
      Session.start_link(
        session_id: "ack-#{:erlang.unique_integer([:positive])}",
        agent_id: agent_id,
        trust_tier: :established,
        turn_dot: turn_path,
        heartbeat_dot: heartbeat_path,
        adapters: adapters,
        start_heartbeat: false,
        config: %{turn_commit_timeout_ms: @commit_timeout_ms}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(tmp_dir)
    end)

    {pid, tmp_dir}
  end

  defp stop_session(pid, tmp_dir) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    File.rm_rf(tmp_dir)
  end
end
