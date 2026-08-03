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

      completed =
        Enum.filter(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)

      assert length(completed) == 1
      assert [{_, _, payload, []}] = completed
      assert payload.user_id == user_id
      assert payload.agent_id == agent_id
      assert payload.engagement_id == "eng_turn_1"
      assert payload.backend == :controllable_turn
      assert payload.mode == :local
      assert is_integer(payload.duration_ms) and payload.duration_ms >= 0
      # Default speech_output is nil → :disabled; no content/callback fields.
      assert payload.speech_output == :disabled
      refute Map.has_key?(payload, :spoken_text)
      refute Map.has_key?(payload, :raw_text)
      refute Map.has_key?(payload, :error)

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

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :budget_exhausted and payload.speech_output == :disabled
             end)
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

  # ---------------------------------------------------------------------------
  # VP-04E2 — Speakable-only output after durable transcript success
  # ---------------------------------------------------------------------------

  defmodule TrackingSpeakable do
    @moduledoc false
    @table :arbor_voice_tracking_speakable

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :bag])
        _tid -> :ok
      end

      :ok
    end

    def reset do
      ensure_table!()
      :ets.delete_all_objects(@table)
      :ok
    end

    def calls do
      ensure_table!()
      @table |> :ets.lookup(:call) |> Enum.map(&elem(&1, 1))
    end

    def render(text, opts) do
      ensure_table!()
      :ets.insert(@table, {:call, {:render, text, opts}})
      {:speak, "spoken:#{text}"}
    end

    def tts_guard!(verdict) do
      ensure_table!()
      :ets.insert(@table, {:call, {:tts_guard, verdict}})
      Arbor.Voice.Speakable.tts_guard!(verdict)
    end
  end

  defmodule RaisingSpeakable do
    @moduledoc false
    def render(_text, _opts), do: raise("speakable render secret")
    def tts_guard!(_), do: "should-not-run"
  end

  defmodule ThrowingSpeakable do
    @moduledoc false
    def render(_text, _opts), do: throw(:speakable_throw)
    def tts_guard!(_), do: "should-not-run"
  end

  defmodule ExitingSpeakable do
    @moduledoc false
    def render(_text, _opts), do: exit(:speakable_exit)
    def tts_guard!(_), do: "should-not-run"
  end

  defmodule GuardRaisingSpeakable do
    @moduledoc false
    def render(text, _opts), do: {:speak, text}
    def tts_guard!(_), do: raise("guard secret")
  end

  defmodule GuardThrowingSpeakable do
    @moduledoc false
    def render(text, _opts), do: {:speak, text}
    def tts_guard!(_), do: throw(:guard_throw)
  end

  defmodule GuardExitingSpeakable do
    @moduledoc false
    def render(text, _opts), do: {:speak, text}
    def tts_guard!(_), do: exit(:guard_exit)
  end

  defmodule MalformedVerdictSpeakable do
    @moduledoc false
    def render(_text, _opts), do: {:bad, "x"}
    def tts_guard!(v), do: Arbor.Voice.Speakable.tts_guard!(v)
  end

  defmodule BlankGuardSpeakable do
    @moduledoc false
    def render(_text, _opts), do: {:speak, "x"}
    def tts_guard!(_), do: "   "
  end

  defmodule OversizedGuardSpeakable do
    @moduledoc false
    def render(_text, _opts), do: {:speak, "x"}
    def tts_guard!(_), do: String.duplicate("a", 8193)
  end

  defmodule InvalidUtf8GuardSpeakable do
    @moduledoc false
    def render(_text, _opts), do: {:speak, "x"}
    def tts_guard!(_), do: <<0xFF, 0xFE>>
  end

  defmodule NonBinaryGuardSpeakable do
    @moduledoc false
    def render(_text, _opts), do: {:speak, "x"}
    # Bypass tts_guard! contract shape deliberately for Session rejection proof.
    def tts_guard!(_), do: :not_a_string
  end

  @budget_exhaustion_notice "This voice session has reached its time limit. Continue on your screen."
  @sensitive_pointer "That's sensitive. I've put it on your screen."
  @default_escalation "the rest is on your screen"

  describe "speakable output after durable success" do
    @tag spec: "VOICE-3,VOICE-13,VOICE-15"
    test "blocking recorder then blocking speech: persistence → output → public success" do
      TrackingSpeakable.reset()
      parent = self()
      spoken_agent = start_spoken_collector()

      # Speech callback runs under SpeechOutputTaskSupervisor (distinct from
      # Session). Blocks until the test releases it so public success and
      # :turn_completed stay pending while acceptance is held.
      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        send(parent, {:speech_entered, self(), spoken})

        receive do
          :release_speech -> :ok
        after
          15_000 ->
            raise "speech_output block timed out waiting for :release_speech"
        end
      end

      ctx =
        turn_opts(
          speakable: TrackingSpeakable,
          speech_output: speech_output,
          # Ceiling bound so the test can hold then release within the window.
          speech_output_timeout_ms: 250
        )

      FakeCommsSession.set_record_waiter(ctx.recorder_agent, self())
      FakeCommsSession.set_record_mode(ctx.recorder_agent, :block)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-blocked-speech"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      task =
        Task.async(fn ->
          send(parent, :turn_call_started)
          Voice.text_turn(user_id, agent_id, "user-blocked")
        end)

      assert_receive :turn_call_started, 1_000
      assert_receive {:record_entered, session_pid}, 3_000
      assert is_pid(session_pid)

      # 1) While persistence is held: no Speakable, no callback, no public success.
      assert Task.yield(task, 150) == nil
      assert TrackingSpeakable.calls() == []
      assert Agent.get(spoken_agent, & &1) == []
      refute_receive {:speech_entered, _, _}, 50

      emissions_mid = FakeSignals.emissions(ctx.signals)
      refute Enum.any?(emissions_mid, fn {c, t, _, _} -> c == :voice and t == :turn_completed end)

      # 2) Release durable write first — speech may enter only after persistence.
      send(session_pid, :release_record)

      assert_receive {:speech_entered, speech_pid, "spoken:raw-blocked-speech"}, 3_000
      # Callback runs in a dedicated task process, not the Session process.
      assert speech_pid != session_pid
      assert Process.alive?(speech_pid)

      # Speakable ran after persistence; public success still pending while output holds.
      assert {:render, "raw-blocked-speech", []} in TrackingSpeakable.calls()
      assert {:tts_guard, {:speak, "spoken:raw-blocked-speech"}} in TrackingSpeakable.calls()
      assert Agent.get(spoken_agent, & &1) == ["spoken:raw-blocked-speech"]
      assert Task.yield(task, 50) == nil

      emissions_held = FakeSignals.emissions(ctx.signals)

      refute Enum.any?(emissions_held, fn {c, t, _, _} ->
               c == :voice and t == :turn_completed
             end)

      # 3) Release speech output within the 250 ms acceptance bound — only then
      # public success and completion audit with :accepted disposition.
      send(speech_pid, :release_speech)
      assert {:ok, "raw-blocked-speech"} = Task.await(task, 1_000)

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :turn_completed and payload.speech_output == :accepted
             end)

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3,VOICE-13,VOICE-15"
    test "production Speakable: long raw persists/returns; callback gets truncated+escalation" do
      raw = 1..70 |> Enum.map_join(" ", &"word#{&1}")
      spoken_agent = start_spoken_collector()

      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        :ok
      end

      ctx = turn_opts(speech_output: speech_output)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: raw}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, ^raw} = Voice.text_turn(user_id, agent_id, "ask long")

      # Durable raw unchanged.
      assert [
               {_agent, _eng, _user, assistant, _opts}
             ] = FakeCommsSession.record_calls(ctx.recorder_agent)

      assert assistant.content == raw

      [spoken] = Agent.get(spoken_agent, & &1)
      assert spoken != raw
      assert String.ends_with?(spoken, @default_escalation)
      assert length(String.split(spoken, ~r/\s+/, trim: true)) <= 60
      refute String.contains?(spoken, "word70")

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :turn_completed and payload.speech_output == :accepted
             end)

      # Signal must not carry raw or spoken content.
      encoded = inspect(emissions)
      refute encoded =~ "word70"
      refute encoded =~ @default_escalation

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3,VOICE-13,VOICE-16"
    test "production Speakable: sensitive raw persists/returns; callback gets screen pointer only" do
      raw = "use key sk-ant-api1234567890abcdefghij to call the API"
      spoken_agent = start_spoken_collector()

      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        :ok
      end

      ctx = turn_opts(speech_output: speech_output)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: raw}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, ^raw} = Voice.text_turn(user_id, agent_id, "secret q")

      assert [
               {_agent, _eng, _user, assistant, _opts}
             ] = FakeCommsSession.record_calls(ctx.recorder_agent)

      assert assistant.content == raw

      assert Agent.get(spoken_agent, & &1) == [@sensitive_pointer]

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :turn_completed and payload.speech_output == :accepted
             end)

      encoded = inspect(emissions)
      refute encoded =~ "sk-ant"
      refute encoded =~ @sensitive_pointer

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3,VOICE-13"
    test "recorder returned/raised/thrown/exited failure invokes neither Speakable nor output" do
      TrackingSpeakable.reset()
      spoken_agent = start_spoken_collector()

      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        :ok
      end

      for mode <- [:error, :raise, :throw, :exit] do
        TrackingSpeakable.reset()
        Agent.update(spoken_agent, fn _ -> [] end)

        ctx =
          turn_opts(
            speakable: TrackingSpeakable,
            speech_output: speech_output
          )

        FakeCommsSession.set_record_mode(ctx.recorder_agent, mode)
        ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-#{mode}"}}])

        {user_id, agent_id} = unique_ids()
        assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

        assert {:error, :transcript_record_failed} =
                 Voice.text_turn(user_id, agent_id, "u"),
               "mode #{mode}"

        assert TrackingSpeakable.calls() == [], "mode #{mode}"
        assert Agent.get(spoken_agent, & &1) == [], "mode #{mode}"

        emissions = FakeSignals.emissions(ctx.signals)

        refute Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :turn_completed end),
               "mode #{mode}"

        assert :ok = Voice.stop_session(key)
      end
    end

    @tag spec: "VOICE-3,VOICE-13"
    test "malformed recorder success envelope skips Speakable and output" do
      TrackingSpeakable.reset()
      spoken_agent = start_spoken_collector()

      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        :ok
      end

      ctx =
        turn_opts(
          transcript_recorder: MalformedOkRecorder,
          speakable: TrackingSpeakable,
          speech_output: speech_output
        )

      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-malformed"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:error, :transcript_record_failed} = Voice.text_turn(user_id, agent_id, "u")
      assert TrackingSpeakable.calls() == []
      assert Agent.get(spoken_agent, & &1) == []
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3,VOICE-13,VOICE-15,VOICE-16"
    test "Speakable raise/throw/exit/malformed never leaks raw, keeps durable success, reports :failed" do
      cases = [
        RaisingSpeakable,
        ThrowingSpeakable,
        ExitingSpeakable,
        GuardRaisingSpeakable,
        GuardThrowingSpeakable,
        GuardExitingSpeakable,
        MalformedVerdictSpeakable,
        BlankGuardSpeakable,
        OversizedGuardSpeakable,
        InvalidUtf8GuardSpeakable,
        NonBinaryGuardSpeakable
      ]

      for speakable <- cases do
        spoken_agent = start_spoken_collector()

        speech_output = fn spoken ->
          Agent.update(spoken_agent, &(&1 ++ [spoken]))
          :ok
        end

        raw = "public raw for #{inspect(speakable)}"
        ctx = turn_opts(speakable: speakable, speech_output: speech_output)
        ControllableTurnBackend.enqueue([{:turn_done, %{text: raw}}])

        {user_id, agent_id} = unique_ids()
        assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

        # Durable public success even when presentation fails — never raw fallback.
        assert {:ok, ^raw} = Voice.text_turn(user_id, agent_id, "q"), inspect(speakable)
        assert Agent.get(spoken_agent, & &1) == [], inspect(speakable)

        assert [
                 {_a, _e, _u, assistant, _o}
               ] = FakeCommsSession.record_calls(ctx.recorder_agent)

        assert assistant.content == raw

        emissions = FakeSignals.emissions(ctx.signals)

        assert Enum.any?(emissions, fn {c, t, payload, _} ->
                 c == :voice and t == :turn_completed and payload.speech_output == :failed
               end),
               inspect(speakable)

        # Session still ready.
        assert {:ok, %{state: :ready}} = Voice.session_status(key), inspect(speakable)
        assert :ok = Voice.stop_session(key)
      end
    end

    @tag spec: "VOICE-3,VOICE-13"
    test "blocking speech callback times out as :failed with durable raw success and task kill" do
      parent = self()

      speech_output = fn spoken ->
        send(parent, {:speech_entered, self(), spoken})

        receive do
          :never_release -> :ok
        after
          60_000 -> :ok
        end
      end

      ctx =
        turn_opts(
          speech_output: speech_output,
          speech_output_timeout_ms: 50
        )

      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-timeout-bound"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)

      started_ms = System.monotonic_time(:millisecond)
      assert {:ok, "raw-timeout-bound"} = Voice.text_turn(user_id, agent_id, "q")
      elapsed_ms = System.monotonic_time(:millisecond) - started_ms

      # Bound is enforced; hang cannot postpone public durable success.
      assert elapsed_ms < 1_000

      assert_receive {:speech_entered, speech_pid, spoken}, 1_000
      assert is_binary(spoken)
      assert String.trim(spoken) != ""
      assert speech_pid != session_pid
      wait_until(fn -> not Process.alive?(speech_pid) end, 2_000)
      refute Process.alive?(speech_pid)

      # Durable raw pair recorded.
      assert [
               {_a, _e, _u, assistant, _o}
             ] = FakeCommsSession.record_calls(ctx.recorder_agent)

      assert assistant.content == "raw-timeout-bound"

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :turn_completed and payload.speech_output == :failed
             end)

      assert {:ok, %{state: :ready}} = Voice.session_status(key)
      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-3,VOICE-13"
    test "SpeechOutputTaskSupervisor unavailability still yields durable success as :failed" do
      spoken_agent = start_spoken_collector()

      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        :ok
      end

      ctx = turn_opts(speech_output: speech_output)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-sup-down"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      # Terminate the dedicated supervisor; leave it down for the turn.
      assert :ok =
               Supervisor.terminate_child(
                 Arbor.Voice.Supervisor,
                 Arbor.Voice.SpeechOutputTaskSupervisor
               )

      on_exit(fn ->
        _ =
          Supervisor.restart_child(
            Arbor.Voice.Supervisor,
            Arbor.Voice.SpeechOutputTaskSupervisor
          )

        :ok
      end)

      assert Process.whereis(Arbor.Voice.SpeechOutputTaskSupervisor) == nil

      assert {:ok, "raw-sup-down"} = Voice.text_turn(user_id, agent_id, "q")
      assert Agent.get(spoken_agent, & &1) == []

      assert [
               {_a, _e, _u, assistant, _o}
             ] = FakeCommsSession.record_calls(ctx.recorder_agent)

      assert assistant.content == "raw-sup-down"

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :turn_completed and payload.speech_output == :failed
             end)

      assert {:ok, %{state: :ready}} = Voice.session_status(key)
      assert :ok = Voice.stop_session(key)

      # Restore for later tests in this process.
      assert {:ok, _pid} =
               Supervisor.restart_child(
                 Arbor.Voice.Supervisor,
                 Arbor.Voice.SpeechOutputTaskSupervisor
               )
    end

    @tag spec: "VOICE-3,VOICE-13"
    test "speech_output returned/malformed/raised/thrown/exited failures report :failed without raw leak" do
      failure_callbacks = [
        {:error_tuple, fn _s -> {:error, :tts_down} end},
        {:malformed, fn _s -> :not_ok end},
        {:raise, fn _s -> raise "output secret boom" end},
        {:throw, fn _s -> throw(:output_throw) end},
        {:exit, fn _s -> exit(:output_exit) end}
      ]

      for {name, callback} <- failure_callbacks do
        expected_raw = "raw-output-#{name}"
        ctx = turn_opts(speech_output: callback)
        ControllableTurnBackend.enqueue([{:turn_done, %{text: expected_raw}}])

        {user_id, agent_id} = unique_ids()
        assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
        assert {:ok, ^expected_raw} = Voice.text_turn(user_id, agent_id, "q"), inspect(name)

        emissions = FakeSignals.emissions(ctx.signals)

        assert Enum.any?(emissions, fn {c, t, payload, _} ->
                 c == :voice and t == :turn_completed and payload.speech_output == :failed
               end),
               inspect(name)

        encoded = inspect(emissions)
        refute encoded =~ "output secret", inspect(name)
        refute encoded =~ expected_raw, inspect(name)

        assert {:ok, %{state: :ready}} = Voice.session_status(key), inspect(name)
        status = elem(Voice.session_status(key), 1)
        refute Map.has_key?(status, :speech_output)
        refute Map.has_key?(status, :speakable)
        assert :ok = Voice.stop_session(key)
      end
    end

    @tag spec: "VOICE-3,VOICE-13"
    test "disabled output reports :disabled; status/crash inspection hide speakable and output" do
      ctx = turn_opts(speech_output: nil)
      ControllableTurnBackend.enqueue([{:turn_done, %{text: "raw-disabled"}}])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, "raw-disabled"} = Voice.text_turn(user_id, agent_id, "q")

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :turn_completed and payload.speech_output == :disabled
             end)

      assert {:ok, status} = Voice.session_status(key)
      refute Map.has_key?(status, :speakable)
      refute Map.has_key?(status, :speech_output)
      refute Map.has_key?(status, :engagement_id)

      assert [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
      {:status, ^pid, _server, status_info} = :sys.get_status(pid)
      encoded = inspect(status_info)
      # Closed whitelist: no Speakable module, speech callback, or turn content.
      refute encoded =~ "Arbor.Voice.Speakable"
      refute encoded =~ "speech_output"
      refute encoded =~ "raw-disabled"
      refute encoded =~ "#Function<"
      refute encoded =~ "spoken:"

      assert :ok = Voice.stop_session(key)
    end
  end

  describe "hard-timeout exhaustion notice through Speakable" do
    @tag spec: "VOICE-13,VOICE-24"
    test "exact notice is rendered/guarded before callback; disposition audited; cleanup converges" do
      TrackingSpeakable.reset()
      parent = self()
      spoken_agent = start_spoken_collector()

      speech_output = fn spoken ->
        Agent.update(spoken_agent, &(&1 ++ [spoken]))
        send(parent, {:exhaustion_spoken, spoken})
        :ok
      end

      ctx =
        turn_opts(
          session_budget_ms: 80,
          wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
          monotonic_clock: fn -> System.monotonic_time(:millisecond) end,
          speakable: TrackingSpeakable,
          speech_output: speech_output
        )

      ControllableTurnBackend.enqueue([:timeout, :timeout, :timeout, :timeout, :timeout])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      t1 =
        Task.async(fn ->
          send(parent, :turn_started)
          Voice.text_turn(user_id, agent_id, "slow")
        end)

      assert_receive :turn_started, 1_000
      assert {:error, :budget_exhausted} = Task.await(t1, 5_000)

      assert_receive {:exhaustion_spoken, spoken}, 3_000
      assert spoken == "spoken:#{@budget_exhaustion_notice}"

      assert {:render, @budget_exhaustion_notice, []} in TrackingSpeakable.calls()

      assert {:tts_guard, {:speak, "spoken:#{@budget_exhaustion_notice}"}} in TrackingSpeakable.calls()

      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :budget_exhausted and payload.speech_output == :accepted
             end)

      # No content/callback errors in the audit signal.
      exhaust =
        Enum.find(emissions, fn {c, t, _, _} -> c == :voice and t == :budget_exhausted end)

      {_c, _t, payload, opts} = exhaust
      assert opts == []
      assert Map.keys(payload) -- [:user_id, :agent_id, :backend, :mode, :speech_output] == []
      refute Map.has_key?(payload, :error)
      refute Map.has_key?(payload, :spoken_text)
    end

    @tag spec: "VOICE-13,VOICE-24"
    test "output failure on hard timeout cannot suppress settlement, close, signal, or termination" do
      speech_output = fn _spoken -> raise "exhaustion output secret" end

      ctx =
        turn_opts(
          session_budget_ms: 80,
          wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
          monotonic_clock: fn -> System.monotonic_time(:millisecond) end,
          speech_output: speech_output
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

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :budget_exhausted and payload.speech_output == :failed
             end)

      # Settlement still ran (ledger consume via FakeLedger).
      wait_until(
        fn ->
          Enum.any?(FakeLedger.calls(ctx.ledger), &match?({:consume, _, _, _}, &1))
        end,
        2_000
      )

      encoded = inspect(emissions)
      refute encoded =~ "exhaustion output secret"
      refute encoded =~ @budget_exhaustion_notice
    end

    @tag spec: "VOICE-13,VOICE-24"
    test "blocking exhaustion callback is killed; settlement/close/termination stay bounded" do
      parent = self()

      speech_output = fn spoken ->
        send(parent, {:exhaustion_entered, self(), spoken})

        receive do
          :never_release -> :ok
        after
          60_000 -> :ok
        end
      end

      ctx =
        turn_opts(
          session_budget_ms: 80,
          wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
          monotonic_clock: fn -> System.monotonic_time(:millisecond) end,
          speech_output: speech_output,
          speech_output_timeout_ms: 50
        )

      ControllableTurnBackend.enqueue([:timeout, :timeout, :timeout, :timeout, :timeout])

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)

      t1 =
        Task.async(fn ->
          send(parent, :turn_started)
          Voice.text_turn(user_id, agent_id, "slow")
        end)

      assert_receive :turn_started, 1_000
      started_ms = System.monotonic_time(:millisecond)

      assert {:error, :budget_exhausted} = Task.await(t1, 5_000)

      assert_receive {:exhaustion_entered, speech_pid, _spoken}, 2_000
      assert speech_pid != session_pid

      # Task was brutally terminated at the acceptance bound.
      wait_until(fn -> not Process.alive?(speech_pid) end, 2_000)
      refute Process.alive?(speech_pid)

      # Ledger settlement and backend close complete before the elapsed bound.
      wait_until(
        fn ->
          Enum.any?(FakeLedger.calls(ctx.ledger), &match?({:consume, _, _, _}, &1))
        end,
        2_000
      )

      wait_until(fn -> ControllableTurnBackend.close_count() == 1 end, 2_000)
      assert ControllableTurnBackend.close_count() == 1

      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)
      refute Process.alive?(session_pid)

      elapsed_ms = System.monotonic_time(:millisecond) - started_ms
      # Generous vs former unbounded hang; well under multi-second sleep.
      assert elapsed_ms < 2_000

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, payload, _} ->
               c == :voice and t == :budget_exhausted and payload.speech_output == :failed
             end)
    end
  end

  defp start_spoken_collector do
    {:ok, agent} =
      Arbor.Voice.Test.SessionFakes.start_owned_agent(fn -> [] end)

    agent
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
