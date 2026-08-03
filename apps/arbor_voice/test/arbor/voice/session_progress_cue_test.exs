defmodule Arbor.Voice.SessionProgressCueTest do
  @moduledoc """
  Progress cue proofs for VP-05B / VOICE-11: threshold, at-most-once, races,
  and cancel cleanup.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.TranscriptRecorder

  alias Arbor.Voice.Test.SessionFakes.{
    ControllableTurnBackend,
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  defmodule BlockingRouter do
    @moduledoc false
    @table :arbor_voice_progress_blocking_router

    def tools, do: []

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def report_to(pid) do
      ensure!()
      :ets.insert(@table, {:report_to, pid})
      :ok
    end

    def release_all do
      ensure!()

      workers =
        case :ets.lookup(@table, :workers) do
          [{:workers, list}] -> list
          _ -> []
        end

      Enum.each(workers, fn pid -> send(pid, :release) end)
      :ok
    end

    def invoke(%{name: "block"} = ctx, _authority) do
      ensure!()

      report_to =
        case :ets.lookup(@table, :report_to) do
          [{:report_to, pid}] -> pid
          _ -> nil
        end

      case :ets.lookup(@table, :workers) do
        [{:workers, list}] -> :ets.insert(@table, {:workers, [self() | list]})
        _ -> :ets.insert(@table, {:workers, [self()]})
      end

      if is_pid(report_to), do: send(report_to, {:worker_pid, self(), ctx.call_id})

      receive do
        :release -> {:ok, %{"done" => true}}
      after
        60_000 -> {:error, :release_timeout}
      end
    end

    def invoke(%{name: "instant"}, _authority), do: {:ok, %{"fast" => true}}
    def invoke(_, _), do: {:error, :unknown_tool}
  end

  # Exact source-owned progress filler (Session @progress_working_cue).
  @working_cue "I'm still working on that."

  defmodule SpeechProbe do
    @moduledoc false
    @table :arbor_voice_progress_speech_probe
    @working_cue "I'm still working on that."

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:spoken, []})
      :ok
    end

    def spoken do
      ensure!()

      case :ets.lookup(@table, :spoken) do
        [{:spoken, list}] -> list
        _ -> []
      end
    end

    def working_cue_count do
      Enum.count(spoken(), &(&1 == @working_cue))
    end

    def has_exact?(text) when is_binary(text) do
      text in spoken()
    end

    def callback do
      ensure!()

      fn text ->
        case :ets.lookup(@table, :spoken) do
          [{:spoken, list}] -> :ets.insert(@table, {:spoken, list ++ [text]})
          _ -> :ets.insert(@table, {:spoken, [text]})
        end

        :ok
      end
    end
  end

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"user_prog_#{n}", "agent_prog_#{n}"}
  end

  defp turn_opts(extra) do
    ControllableTurnBackend.ensure_table!()
    ControllableTurnBackend.reset()
    BlockingRouter.ensure!()
    :ets.insert(:arbor_voice_progress_blocking_router, {:workers, []})
    SpeechProbe.reset()

    {:ok, _eng} =
      FakeEngagementStore.start(result: {:ok, %{id: "eng_progress", agent_id: "agent_x"}})

    {:ok, _ledger} = FakeLedger.start()
    {:ok, signals} = FakeSignals.start()
    {:ok, _recorder} = FakeCommsSession.start_recorder()

    opts =
      [
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: FakeLedger,
        signals: FakeSignals,
        backend: ControllableTurnBackend,
        backend_opts: [],
        transcript_recorder: TranscriptRecorder,
        transcript_opts: [],
        tool_router: BlockingRouter,
        tool_router_timeout_ms: 5_000,
        progress_threshold_ms: 50,
        speech_output: SpeechProbe.callback(),
        speech_output_timeout_ms: 100,
        session_budget_ms: 60_000,
        daily_budget_ms: 3_600_000,
        resource_owner_opts: [
          close_timeout_ms: 1_000,
          cleanup_ready_timeout_ms: 200,
          cleanup_attempts: 2,
          cleanup_per_attempt_timeout_ms: 200,
          max_recv_timeout_ms: 100
        ],
        wall_clock: fn -> DateTime.utc_now() end,
        monotonic_clock: fn -> System.monotonic_time(:millisecond) end
      ]
      |> Keyword.merge(extra)

    %{opts: opts, signals: signals}
  end

  setup do
    assert is_pid(Process.whereis(Arbor.Voice.SessionSupervisor))
    :ok
  end

  defp tool_wave_then_final(events, final_text) do
    events ++
      [
        {:turn_done, %{text: ""}},
        {:turn_done, %{text: final_text}}
      ]
  end

  @tag spec: "VOICE-11"
  test "slow tool emits exactly one working cue while worker remains alive" do
    # Valid config: threshold (50) <= tool timeout (5000).
    ctx = turn_opts([])
    BlockingRouter.report_to(self())

    ControllableTurnBackend.enqueue(
      tool_wave_then_final(
        [{:tool_call, %{id: "slow1", name: "block", arguments: %{}}}],
        "done after wait"
      )
    )

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    task = Task.async(fn -> Voice.text_turn(user_id, agent_id, "slow please") end)

    assert_receive {:worker_pid, worker, "slow1"}, 1_000
    assert Process.alive?(worker)

    [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    state = :sys.get_state(session_pid)
    generation = state.turn.generation
    entry = Map.fetch!(state.turn.pending, "slow1")
    fence_token = entry.token
    assert is_reference(fence_token)

    # Wait past progress threshold
    Process.sleep(120)
    assert Process.alive?(worker)

    # Exact source-owned working cue only (not substring/fallback).
    assert SpeechProbe.working_cue_count() == 1
    assert SpeechProbe.has_exact?(@working_cue)

    emissions = FakeSignals.emissions(ctx.signals)

    progress =
      Enum.filter(emissions, fn
        {:voice, :tool_progress, _data, _opts} -> true
        _ -> false
      end)

    assert length(progress) == 1
    [{:voice, :tool_progress, data, []}] = progress
    assert data.cue == :working
    assert data.speech_output == :accepted
    assert data.user_id == user_id
    assert data.agent_id == agent_id
    assert data.engagement_id == "eng_progress"
    refute Map.has_key?(data, :call_id)
    refute Map.has_key?(data, :name)
    refute Map.has_key?(data, :arguments)

    # Exact matching duplicate timer (same generation/call_id/fence token) cannot
    # double-cue; forged/stale messages also cannot.
    send(session_pid, {:tool_progress, generation, "slow1", fence_token})
    send(session_pid, {:tool_progress, generation, "slow1", fence_token})
    send(session_pid, {:tool_progress, generation, "slow1", make_ref()})
    send(session_pid, {:tool_progress, generation + 1, "slow1", fence_token})
    send(session_pid, {:tool_progress, generation, "other", fence_token})
    Process.sleep(50)
    assert SpeechProbe.working_cue_count() == 1

    assert length(
             Enum.filter(FakeSignals.emissions(ctx.signals), fn
               {:voice, :tool_progress, _, _} -> true
               _ -> false
             end)
           ) == 1

    send(worker, :release)
    assert {:ok, "done after wait"} = Task.await(task, 5_000)

    # Working cue stays exactly once; final assistant speech is present separately.
    assert SpeechProbe.working_cue_count() == 1
    assert SpeechProbe.has_exact?("done after wait")

    assert :ok = Voice.stop_session(key)
  end

  @tag spec: "VOICE-11"
  test "fast tool emits no progress cue" do
    ctx = turn_opts(progress_threshold_ms: 2_000)

    ControllableTurnBackend.enqueue(
      tool_wave_then_final(
        [{:tool_call, %{id: "fast1", name: "instant", arguments: %{}}}],
        "fast done"
      )
    )

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    assert {:ok, "fast done"} = Voice.text_turn(user_id, agent_id, "quick")

    # No working cue; final assistant speech is offered separately.
    assert SpeechProbe.working_cue_count() == 0
    refute SpeechProbe.has_exact?(@working_cue)
    assert SpeechProbe.has_exact?("fast done")

    progress =
      Enum.filter(FakeSignals.emissions(ctx.signals), fn
        {:voice, :tool_progress, _, _} -> true
        _ -> false
      end)

    assert progress == []
    assert :ok = Voice.stop_session(key)
  end

  @tag spec: "VOICE-11"
  test "stop cancels progress timer without double cue or live work" do
    ctx = turn_opts([])
    BlockingRouter.report_to(self())

    ControllableTurnBackend.enqueue([
      {:tool_call, %{id: "stop1", name: "block", arguments: %{}}}
    ])

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    task = Task.async(fn -> Voice.text_turn(user_id, agent_id, "will stop") end)

    assert_receive {:worker_pid, worker, "stop1"}, 1_000
    assert Process.alive?(worker)

    # Stop before threshold
    assert :ok = Voice.stop_session(key)
    assert {:error, :session_stopped} = Task.await(task, 5_000)

    Process.sleep(150)
    assert SpeechProbe.working_cue_count() == 0
    refute SpeechProbe.has_exact?(@working_cue)
    refute Process.alive?(worker)

    progress =
      Enum.filter(FakeSignals.emissions(ctx.signals), fn
        {:voice, :tool_progress, _, _} -> true
        _ -> false
      end)

    assert progress == []
  end

  @tag spec: "VOICE-11"
  test "timeout settles at-most-once progress and leaves no live timer work" do
    # Valid config only: threshold (40) <= tool timeout (120). Invalid pairs
    # such as timeout=80/threshold=200 must fail start and are not used here.
    # Threshold fires well before tool timeout so cue count is exactly 1.
    ctx = turn_opts(tool_router_timeout_ms: 200, progress_threshold_ms: 40)
    BlockingRouter.report_to(self())

    ControllableTurnBackend.enqueue(
      tool_wave_then_final(
        [{:tool_call, %{id: "to1", name: "block", arguments: %{}}}],
        "after timeout"
      )
    )

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

    [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    task = Task.async(fn -> Voice.text_turn(user_id, agent_id, "timeout path") end)

    assert_receive {:worker_pid, worker, "to1"}, 1_000
    state = :sys.get_state(session_pid)
    generation = state.turn.generation
    fence_token = Map.fetch!(state.turn.pending, "to1").token

    assert {:ok, "after timeout"} = Task.await(task, 5_000)

    results = ControllableTurnBackend.tool_results()
    assert [{"to1", output}] = results
    assert Jason.decode!(output) == %{"code" => "tool_timeout"}
    refute Process.alive?(worker)

    # Exactly one working cue (threshold before timeout); final speech separate.
    assert SpeechProbe.working_cue_count() == 1
    assert SpeechProbe.has_exact?(@working_cue)
    assert SpeechProbe.has_exact?("after timeout")

    progress_count =
      Enum.count(FakeSignals.emissions(ctx.signals), fn
        {:voice, :tool_progress, _, _} -> true
        _ -> false
      end)

    assert progress_count == 1

    # Post-settlement: exact matching and forged timer messages are no-ops.
    send(session_pid, {:tool_progress, generation, "to1", fence_token})
    send(session_pid, {:tool_progress, generation, "to1", make_ref()})
    Process.sleep(150)
    assert SpeechProbe.working_cue_count() == 1

    assert Enum.count(FakeSignals.emissions(ctx.signals), fn
             {:voice, :tool_progress, _, _} -> true
             _ -> false
           end) == 1

    # Pending cleared — no live timer/work retained for the call.
    state_after = :sys.get_state(session_pid)
    assert state_after.turn == nil

    assert :ok = Voice.stop_session(key)
  end

  @tag spec: "VOICE-11"
  test "invalid progress_threshold above tool timeout fails start closed" do
    {user_id, agent_id} = unique_ids()
    # Explicit invalid pair from the correction note: must not start.
    ctx =
      turn_opts(
        tool_router_timeout_ms: 80,
        progress_threshold_ms: 200
      )

    assert {:error, :invalid_opts} = Voice.start_session(user_id, agent_id, ctx.opts)
  end

  @tag spec: "VOICE-11"
  test "hard exhaustion cancels progress timer/owner without late or duplicate cue" do
    # Budget expires well before the progress threshold so no cue can fire on
    # the live path; post-exhaustion timer messages must also be no-ops.
    ctx =
      turn_opts(
        tool_router_timeout_ms: 30_000,
        progress_threshold_ms: 5_000,
        session_budget_ms: 400,
        wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
        monotonic_clock: fn -> System.monotonic_time(:millisecond) end
      )

    BlockingRouter.report_to(self())

    ControllableTurnBackend.enqueue([
      {:tool_call, %{id: "exh1", name: "block", arguments: %{}}}
    ])

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    task = Task.async(fn -> Voice.text_turn(user_id, agent_id, "will exhaust") end)

    assert_receive {:worker_pid, worker, "exh1"}, 1_000
    assert Process.alive?(worker)

    [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    state = :sys.get_state(session_pid)
    generation = state.turn.generation
    fence_token = Map.fetch!(state.turn.pending, "exh1").token

    assert {:error, :budget_exhausted} = Task.await(task, 5_000)

    # Session terminates on hard timeout; worker/owner must not remain live.
    assert :ok = wait_until(fn -> not Process.alive?(worker) end, 2_000)
    assert :ok = wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)

    # No working cue before or after exhaustion (threshold was not reached).
    assert SpeechProbe.working_cue_count() == 0
    refute SpeechProbe.has_exact?(@working_cue)

    progress =
      Enum.filter(FakeSignals.emissions(ctx.signals), fn
        {:voice, :tool_progress, _, _} -> true
        _ -> false
      end)

    assert progress == []

    # Late/forged progress messages against a dead/stopped session are no-ops.
    # Process may already be gone; send is best-effort and must not raise.
    _ =
      try do
        send(session_pid, {:tool_progress, generation, "exh1", fence_token})
        send(session_pid, {:tool_progress, generation, "exh1", make_ref()})
        :ok
      catch
        _, _ -> :ok
      end

    Process.sleep(100)
    assert SpeechProbe.working_cue_count() == 0

    assert Enum.filter(FakeSignals.emissions(ctx.signals), fn
             {:voice, :tool_progress, _, _} -> true
             _ -> false
           end) == []
  end

  @tag spec: "VOICE-11"
  test "owner DOWN before threshold settles once without late progress cue" do
    # Threshold well above the kill window so the only settlement path is DOWN.
    ctx = turn_opts(tool_router_timeout_ms: 30_000, progress_threshold_ms: 5_000)
    BlockingRouter.report_to(self())

    ControllableTurnBackend.enqueue(
      tool_wave_then_final(
        [{:tool_call, %{id: "down1", name: "block", arguments: %{}}}],
        "after owner down"
      )
    )

    {user_id, agent_id} = unique_ids()
    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    task = Task.async(fn -> Voice.text_turn(user_id, agent_id, "owner dies") end)

    assert_receive {:worker_pid, worker, "down1"}, 1_000
    assert Process.alive?(worker)

    [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    state = :sys.get_state(session_pid)
    generation = state.turn.generation
    entry = Map.fetch!(state.turn.pending, "down1")
    fence_token = entry.token
    owner_pid = entry.owner_pid
    assert is_pid(owner_pid)
    assert Process.alive?(owner_pid)

    # Unexpected ToolCallOwner death before the progress threshold.
    Process.exit(owner_pid, :kill)

    assert {:ok, "after owner down"} = Task.await(task, 5_000)
    refute Process.alive?(worker)
    refute Process.alive?(owner_pid)

    assert [{"down1", output}] = ControllableTurnBackend.tool_results()
    assert Jason.decode!(output) == %{"code" => "tool_failed"}

    # Exactly one settlement; no working cue (threshold never reached).
    assert SpeechProbe.working_cue_count() == 0
    refute SpeechProbe.has_exact?(@working_cue)
    assert SpeechProbe.has_exact?("after owner down")

    progress_count =
      Enum.count(FakeSignals.emissions(ctx.signals), fn
        {:voice, :tool_progress, _, _} -> true
        _ -> false
      end)

    assert progress_count == 0

    # Late matching/forged progress messages cannot cue after settle.
    send(session_pid, {:tool_progress, generation, "down1", fence_token})
    send(session_pid, {:tool_progress, generation, "down1", make_ref()})
    Process.sleep(100)
    assert SpeechProbe.working_cue_count() == 0

    assert Enum.count(FakeSignals.emissions(ctx.signals), fn
             {:voice, :tool_progress, _, _} -> true
             _ -> false
           end) == 0

    state_after = :sys.get_state(session_pid)
    assert state_after.turn == nil

    assert :ok = Voice.stop_session(key)
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(20)
        do_wait_until(fun, deadline)
      end
    end
  end
end
