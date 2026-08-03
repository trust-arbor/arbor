defmodule Arbor.Voice.SessionTextTurnTest do
  @moduledoc """
  Message-driven Session text-turn proofs for VP-04E1 using the real supervised
  ResourceOwner and a controllable backend.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Session.TurnCore
  alias Arbor.Voice.TranscriptRecorder

  alias Arbor.Voice.Test.SessionFakes.{
    ControllableTurnBackend,
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  defmodule MalformedOkRecorder do
    @moduledoc false
    # Defective recorder returning a non-contract success envelope.
    def record(_agent_id, _msg, _raw, _completed_at, _opts), do: {:ok, :not_recorded}
  end

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"user_#{n}", "agent_#{n}"}
  end

  defp turn_opts(extra \\ []) do
    ControllableTurnBackend.ensure_table!()
    ControllableTurnBackend.reset()

    {:ok, eng} =
      FakeEngagementStore.start(result: {:ok, %{id: "eng_turn_1", agent_id: "agent_x"}})

    {:ok, ledger} = FakeLedger.start()
    {:ok, signals} = FakeSignals.start()
    {:ok, recorder_agent} = FakeCommsSession.start_recorder()

    wall_ms = :atomics.new(1, signed: true)
    mono_ms = :atomics.new(1, signed: true)
    :atomics.put(wall_ms, 1, 0)
    :atomics.put(mono_ms, 1, 1_000_000)

    # Wall clock advances by 1s each read so sent_at != completed_at.
    wall_clock = fn ->
      n = :atomics.add_get(wall_ms, 1, 1)
      DateTime.add(~U[2026-08-02 12:00:00.000000Z], n - 1, :second)
    end

    mono_clock = fn ->
      :atomics.add_get(mono_ms, 1, 25)
    end

    opts =
      [
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: FakeLedger,
        ledger_opts: [],
        resource_owner: Arbor.Voice.ResourceOwner,
        resource_owner_opts: [
          close_timeout_ms: 1_000,
          cleanup_ready_timeout_ms: 200,
          cleanup_attempts: 2,
          cleanup_per_attempt_timeout_ms: 200,
          max_recv_timeout_ms: 100
        ],
        backend: ControllableTurnBackend,
        backend_opts: [],
        signals: FakeSignals,
        transcript_recorder: TranscriptRecorder,
        transcript_opts: [],
        session_budget_ms: 60_000,
        daily_budget_ms: 3_600_000,
        wall_clock: wall_clock,
        monotonic_clock: mono_clock
      ]
      |> Keyword.merge(extra)

    %{
      opts: opts,
      eng: eng,
      ledger: ledger,
      signals: signals,
      recorder_agent: recorder_agent,
      mono_ms: mono_ms
    }
  end

  setup do
    assert is_pid(Process.whereis(Arbor.Voice.SessionSupervisor))
    assert is_pid(Process.whereis(Arbor.Voice.ResourceSupervisor))
    :ok
  end

  describe "successful text turn" do
    @tag spec: "VOICE-2,VOICE-3,VOICE-4,VOICE-5"
    test "persists engagement-tagged raw pair before success and emits one turn_completed" do
      ctx = turn_opts()

      ControllableTurnBackend.enqueue([
        :timeout,
        {:input_transcript, "ignored input"},
        {:output_audio, <<9, 9>>},
        {:output_text_delta, "Hel"},
        {:output_text_delta, "lo!"},
        {:turn_done, %{text: ""}}
      ])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      assert {:ok, "Hello!"} = Voice.text_turn(user_id, agent_id, "hi there")

      # Persistence before public success: Comms was called with full raw text.
      calls = FakeCommsSession.record_calls(ctx.recorder_agent)
      assert length(calls) == 1

      assert [
               {^agent_id, "eng_turn_1", user_entry, assistant_entry, forwarded_opts}
             ] = calls

      assert user_entry.content == "hi there"
      assert %DateTime{} = user_entry.sent_at
      assert user_entry.metadata["transport"] == "voice"
      assert user_entry.metadata["backend"] == "controllable_turn"
      assert user_entry.metadata["mode"] == "local"

      assert assistant_entry.content == "Hello!"
      assert %DateTime{} = assistant_entry.completed_at
      assert DateTime.compare(assistant_entry.completed_at, user_entry.sent_at) in [:gt, :eq]
      assert assistant_entry.metadata == user_entry.metadata
      # Session source-owns persistence opts; only :persistence is forwardable.
      assert forwarded_opts == []

      emissions = FakeSignals.emissions(ctx.signals)
      completed = Enum.filter(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)
      assert length(completed) == 1
      assert [{_, _, payload, []}] = completed
      assert payload.user_id == user_id
      assert payload.agent_id == agent_id
      assert payload.engagement_id == "eng_turn_1"
      assert payload.backend == :controllable_turn
      assert payload.mode == :local
      assert is_integer(payload.duration_ms) and payload.duration_ms >= 0

      refute Enum.any?(emissions, fn {_, t, _, _} -> t == :"transcript.record_failed" end)

      # Backend received the user text; finite timeout polling happened.
      assert ControllableTurnBackend.sent_texts() == ["hi there"]
      assert ControllableTurnBackend.recv_timeouts() >= 1

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3"
    test "nonblank terminal text wins over accumulated deltas" do
      ctx = turn_opts()

      ControllableTurnBackend.enqueue([
        {:output_text_delta, "partial"},
        {:turn_done, %{text: "authoritative"}}
      ])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, "authoritative"} = Voice.text_turn(user_id, agent_id, "q")
      assert :ok = Voice.stop_session(key)
    end
  end

  describe "busy / stop / hard timeout" do
    @tag spec: "VOICE-5"
    test "second concurrent turn returns :busy while first is in flight" do
      ctx = turn_opts()
      # Never completes until we enqueue later — busy window.
      ControllableTurnBackend.enqueue([:timeout, :timeout, :timeout])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      parent = self()

      t1 =
        Task.async(fn ->
          send(parent, :t1_started)
          Voice.text_turn(user_id, agent_id, "first")
        end)

      assert_receive :t1_started, 1_000
      # Allow first turn to enter poll loop.
      Process.sleep(50)

      assert {:error, :busy} = Voice.text_turn(user_id, agent_id, "second")

      ControllableTurnBackend.enqueue([{:turn_done, %{text: "done"}}])
      assert {:ok, "done"} = Task.await(t1, 5_000)
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5,VOICE-7"
    test "stop during in-flight turn replies :session_stopped then settles" do
      ctx = turn_opts()
      ControllableTurnBackend.enqueue([:timeout, :timeout, :timeout, :timeout])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      parent = self()

      t1 =
        Task.async(fn ->
          send(parent, :turn_started)
          Voice.text_turn(user_id, agent_id, "hanging")
        end)

      assert_receive :turn_started, 1_000
      Process.sleep(30)

      assert :ok = Voice.stop_session(key)
      assert {:error, :session_stopped} = Task.await(t1, 5_000)

      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)
    end

    @tag spec: "VOICE-24"
    test "hard timeout during in-flight turn replies :budget_exhausted" do
      ctx =
        turn_opts(
          session_budget_ms: 80,
          wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
          monotonic_clock: fn -> System.monotonic_time(:millisecond) end
        )

      ControllableTurnBackend.enqueue([:timeout, :timeout, :timeout, :timeout, :timeout])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      parent = self()

      t1 =
        Task.async(fn ->
          send(parent, :turn_started)
          Voice.text_turn(user_id, agent_id, "slow")
        end)

      assert_receive :turn_started, 1_000
      assert {:error, :budget_exhausted} = Task.await(t1, 5_000)

      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :budget_exhausted end)
    end
  end

  describe "stale generation / backend errors" do
    @tag spec: "VOICE-5"
    test "backend protocol error ends the turn with :turn_failed" do
      ctx = turn_opts()
      ControllableTurnBackend.enqueue([{:error, :connection_dropped}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "x")
      # Session remains ready after a failed turn.
      assert {:ok, %{state: :ready}} = Voice.session_status(key)
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5"
    test "malformed backend event ends the turn with :turn_failed" do
      ctx = turn_opts()
      ControllableTurnBackend.enqueue([:not_a_valid_event])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "x")
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5"
    test "stale-generation polls do not affect a later turn" do
      ctx = turn_opts()

      ControllableTurnBackend.enqueue([{:turn_done, %{text: "first"}}])
      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, "first"} = Voice.text_turn(user_id, agent_id, "a")

      ControllableTurnBackend.enqueue([
        {:output_text_delta, "sec"},
        {:turn_done, %{text: "second"}}
      ])

      assert {:ok, "second"} = Voice.text_turn(user_id, agent_id, "b")
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5"
    test "injected stale {:turn_poll, old_generation} cannot consume an active later turn" do
      ctx = turn_opts()
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "first"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, "first"} = Voice.text_turn(user_id, agent_id, "a")

      assert [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)

      # Second turn hangs on empty windows so we can inject a stale poll mid-flight.
      ControllableTurnBackend.enqueue([:timeout, :timeout, :timeout])
      parent = self()

      t2 =
        Task.async(fn ->
          send(parent, :second_started)
          Voice.text_turn(user_id, agent_id, "b")
        end)

      assert_receive :second_started, 1_000
      # Let the active turn enter its poll loop (generation > first turn's).
      Process.sleep(40)

      timeouts_before = ControllableTurnBackend.recv_timeouts()

      # Old generation from the completed first turn — must not call recv.
      send(session_pid, {:turn_poll, 1})
      send(session_pid, {:turn_poll, 0})
      Process.sleep(30)

      # Stale polls ignored: no extra empty-window recvs from those messages alone.
      assert ControllableTurnBackend.recv_timeouts() - timeouts_before <= 2

      ControllableTurnBackend.enqueue([{:turn_done, %{text: "second-live"}}])
      assert {:ok, "second-live"} = Task.await(t2, 5_000)

      # Only the live turn's terminal text was recorded as the second assistant reply.
      calls = FakeCommsSession.record_calls(ctx.recorder_agent)
      assistant_texts = Enum.map(calls, fn {_a, _e, _u, asst, _o} -> asst.content end)
      assert "first" in assistant_texts
      assert "second-live" in assistant_texts
      refute "poison" in assistant_texts

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5"
    test "owner max_recv_timeout_ms below 100 still polls successfully" do
      owner_opts = [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 200,
        # Tighter than Session's 100 ms packet ceiling — must clamp, not fail.
        max_recv_timeout_ms: 40
      ]

      ctx = turn_opts(resource_owner_opts: owner_opts)

      ControllableTurnBackend.enqueue([
        :timeout,
        {:turn_done, %{text: "clamped-poll-ok"}}
      ])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, "clamped-poll-ok"} = Voice.text_turn(user_id, agent_id, "hi")
      assert ControllableTurnBackend.recv_timeouts() >= 1
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5"
    test "send_text failure returns stable :turn_failed" do
      ctx = turn_opts()
      ControllableTurnBackend.set_send_text_mode(:error)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "should-not-run"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "hi")
      assert FakeCommsSession.record_calls(ctx.recorder_agent) == []
      refute Enum.any?(FakeSignals.emissions(ctx.signals), fn {c, t, _, _} ->
               c == :voice and t == :turn_completed
             end)

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-5"
    test "security regression: oversized output_audio ends the turn with :turn_failed" do
      ctx = turn_opts()
      over = :binary.copy(<<0>>, TurnCore.max_audio_bytes() + 1)

      ControllableTurnBackend.enqueue([
        {:output_audio, over},
        {:turn_done, %{text: "should-not-complete"}}
      ])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "hi")
      assert FakeCommsSession.record_calls(ctx.recorder_agent) == []
      refute Enum.any?(FakeSignals.emissions(ctx.signals), fn {c, t, _, _} ->
               c == :voice and t == :turn_completed
             end)

      assert :ok = Voice.stop_session(key)
    end
  end

  describe "transcript recorder integration" do
    @tag spec: "VOICE-3,VOICE-4"
    test "caller stays blocked until durable record is released (transcript-before-success)" do
      ctx = turn_opts()
      FakeCommsSession.set_record_waiter(ctx.recorder_agent, self())
      FakeCommsSession.set_record_mode(ctx.recorder_agent, :block)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "blocked-raw"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, :turn_call_started)
          Voice.text_turn(user_id, agent_id, "user-blocked")
        end)

      assert_receive :turn_call_started, 1_000
      assert_receive {:record_entered, session_pid}, 3_000
      assert is_pid(session_pid)

      # Public success must not complete while durable write is held.
      assert Task.yield(task, 150) == nil

      emissions_mid = FakeSignals.emissions(ctx.signals)
      refute Enum.any?(emissions_mid, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)

      # Durable path already observed the full raw pair before public reply.
      assert length(FakeCommsSession.record_calls(ctx.recorder_agent)) == 1

      send(session_pid, :release_record)
      assert {:ok, "blocked-raw"} = Task.await(task, 5_000)

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3,VOICE-4"
    test "returned recorder failure emits transcript.record_failed and no completion" do
      ctx = turn_opts()
      FakeCommsSession.set_record_mode(ctx.recorder_agent, :error)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :transcript_record_failed} = Voice.text_turn(user_id, agent_id, "u")

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, _, _} ->
               c == :voice and t == :"transcript.record_failed"
             end)

      refute Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3"
    test "raised/thrown/exited recorder failure is caught and normalized" do
      for mode <- [:raise, :throw, :exit] do
        ctx = turn_opts()
        FakeCommsSession.set_record_mode(ctx.recorder_agent, mode)
        ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw"}}])

        {user_id, agent_id} = unique_ids()
        assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

        assert {:error, :transcript_record_failed} = Voice.text_turn(user_id, agent_id, "u"),
               "mode #{mode}"

        emissions = FakeSignals.emissions(ctx.signals)

        assert Enum.any?(emissions, fn {c, t, _, _} ->
                 c == :voice and t == :"transcript.record_failed"
               end),
               "mode #{mode}"

        refute Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end),
               "mode #{mode}"

        assert :ok = Voice.stop_session(key)
      end
    end

    @tag spec: "VOICE-3"
    test "malformed recorder {:ok, ...} envelope is not treated as durable success" do
      ctx = turn_opts(transcript_recorder: MalformedOkRecorder)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-malformed-ok"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :transcript_record_failed} = Voice.text_turn(user_id, agent_id, "u")

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, _, _} ->
               c == :voice and t == :"transcript.record_failed"
             end)

      refute Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)
      # Injected recorder never hit Comms; no durable pair claimed.
      assert FakeCommsSession.record_calls(ctx.recorder_agent) == []

      assert :ok = Voice.stop_session(key)
    end
  end

  describe "empty-catalog tool path" do
    @tag spec: "VOICE-8"
    test "one no_tools_installed output per id; duplicates suppressed" do
      ctx = turn_opts()

      call = %{id: "tc_1", name: "consult_agent", arguments: %{"q" => "x"}}

      ControllableTurnBackend.enqueue([
        {:tool_call, call},
        {:tool_call, call},
        {:turn_done, %{text: "after tools"}}
      ])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, "after tools"} = Voice.text_turn(user_id, agent_id, "hi")

      results = ControllableTurnBackend.tool_results()
      assert length(results) == 1
      assert [{"tc_1", output}] = results
      assert {:ok, %{"code" => "no_tools_installed"}} = Jason.decode(output)
      assert output == TurnCore.no_tools_installed_output()

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-8"
    test "malformed tool call ends turn with :turn_failed" do
      ctx = turn_opts()
      ControllableTurnBackend.enqueue([{:tool_call, %{id: "x"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "hi")
      assert ControllableTurnBackend.tool_results() == []
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-8"
    test "failed tool-result send ends turn with :turn_failed" do
      ctx = turn_opts()
      ControllableTurnBackend.set_tool_result_mode(:error)

      ControllableTurnBackend.enqueue([
        {:tool_call, %{id: "tc_fail", name: "x", arguments: %{}}}
      ])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :turn_failed} = Voice.text_turn(user_id, agent_id, "hi")
      # Mark-before-send: one attempt was recorded even though send failed.
      assert length(ControllableTurnBackend.tool_results()) == 1
      assert :ok = Voice.stop_session(key)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
