defmodule Arbor.Orchestrator.Session.StreamingPartialTest do
  @moduledoc """
  Streaming partial preservation: when a streaming turn is interrupted (task
  crash, user cancel, or turn-timeout), whatever the assistant streamed so far is
  persisted as an :interrupted / :cancelled AssistantMessage instead of being lost.

  Covers the accumulator (`{:stream_chunk}`), the finalize logic
  (`Builders.apply_turn_interruption/3`), and all three trigger handlers via direct
  callback calls (no live streaming turn needed).
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Builders

  # In-memory SessionStore stand-in (same pattern as persistence_fresh_session_test).
  defmodule FakeSessionStore do
    use Agent

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{sessions: %{}, entries: []} end, name: __MODULE__)

    def stop do
      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    catch
      :exit, _ -> :ok
    end

    def available?, do: true

    def get_session(session_id) do
      Agent.get(__MODULE__, fn s ->
        case Map.get(s.sessions, session_id) do
          nil -> {:error, :not_found}
          uuid -> {:ok, %{id: uuid}}
        end
      end)
    end

    def create_session(agent_id, opts) do
      session_id = Keyword.fetch!(opts, :session_id)
      uuid = "uuid_#{session_id}"
      Agent.update(__MODULE__, fn s -> %{s | sessions: Map.put(s.sessions, session_id, uuid)} end)
      {:ok, %{id: uuid, agent_id: agent_id, session_id: session_id}}
    end

    def append_entry(uuid, attrs) do
      Agent.update(__MODULE__, fn s -> %{s | entries: [{uuid, attrs} | s.entries]} end)
      :ok
    end

    def entries, do: Agent.get(__MODULE__, & &1.entries) |> Enum.reverse()

    def entry(type),
      do: Enum.find_value(entries(), fn {_u, a} -> if a[:entry_type] == type, do: a end)
  end

  setup do
    prev = Application.get_env(:arbor_orchestrator, :session_store_module)
    Application.put_env(:arbor_orchestrator, :session_store_module, FakeSessionStore)
    {:ok, _} = FakeSessionStore.start_link()

    on_exit(fn ->
      FakeSessionStore.stop()

      if prev,
        do: Application.put_env(:arbor_orchestrator, :session_store_module, prev),
        else: Application.delete_env(:arbor_orchestrator, :session_store_module)
    end)

    :ok
  end

  @started ~U[2026-06-15 09:00:00.000000Z]

  defp buffer(content), do: %{content: content, started_at: @started, first_token_at: @started}

  defp session(overrides) do
    base = %Session{
      session_id: "agent-session-stream_#{System.unique_integer([:positive])}",
      agent_id: "stream_agent",
      phase: :processing,
      turn_count: 0,
      messages: [],
      turn_in_flight: true,
      turn_from: nil,
      turn_caller_ref: nil,
      turn_started_at: System.monotonic_time(),
      turn_user_message: UserMessage.from_string("explain the thing"),
      config: %{},
      session_state: nil,
      behavior: nil
    }

    struct(base, overrides)
  end

  # persist_turn_entries spawns a Task — give it a moment to land
  defp settle, do: :timer.sleep(60)

  describe "{:stream_chunk} accumulation" do
    test "appends chunks and stamps first_token_at on the first non-empty chunk" do
      state = session(streaming_buffer: buffer(""))

      {:noreply, s1} = Session.handle_info({:stream_chunk, "Hel"}, state)
      assert s1.streaming_buffer.content == "Hel"
      assert %DateTime{} = s1.streaming_buffer.first_token_at
      first_ts = s1.streaming_buffer.first_token_at

      {:noreply, s2} = Session.handle_info({:stream_chunk, "lo"}, s1)
      assert s2.streaming_buffer.content == "Hello"
      # first_token_at is sticky — set once, never moved
      assert s2.streaming_buffer.first_token_at == first_ts
    end

    test "drops chunks when there is no active buffer (late chunk after finalize)" do
      state = session(streaming_buffer: nil)
      assert {:noreply, ^state} = Session.handle_info({:stream_chunk, "ignored"}, state)
    end
  end

  describe "Builders.apply_turn_interruption/3" do
    test ":interrupted persists the partial assistant content + the user message" do
      state =
        session(streaming_buffer: buffer("partial reasoning so f"))
        |> Map.from_struct()

      :ok = Builders.apply_turn_interruption(state, :interrupted, :task_crashed)
      settle()

      assert %{content: user_content} = FakeSessionStore.entry("user")
      assert flatten_text(user_content) =~ "explain the thing"

      assistant = FakeSessionStore.entry("assistant")
      assert assistant, "the partial assistant entry must be persisted"
      assert flatten_text(assistant[:content]) =~ "partial reasoning so f"
      # status persists so restored history / eval-replay can distinguish it
      assert assistant[:metadata]["status"] == "interrupted"
      assert assistant[:metadata]["interrupted_reason"] =~ "task_crashed"
    end

    test ":cancelled persists the partial too, distinguishable from a system interruption" do
      state =
        session(streaming_buffer: buffer("half an answer"))
        |> Map.from_struct()

      :ok = Builders.apply_turn_interruption(state, :cancelled, :user_cancelled)
      settle()

      assistant = FakeSessionStore.entry("assistant")
      assert flatten_text(assistant[:content]) =~ "half an answer"

      assert assistant[:metadata]["status"] == "cancelled",
             "a user cancel must persist as :cancelled, NOT :interrupted — that's the " <>
               "whole point of distinguishing benign cancels from system failures"
    end

    test "no-op-safe path: empty buffer still persists what little content there is" do
      # apply_turn_interruption itself does not guard on emptiness (the caller
      # does); with empty content it persists an empty assistant entry.
      state = session(streaming_buffer: buffer("")) |> Map.from_struct()
      :ok = Builders.apply_turn_interruption(state, :interrupted, :timeout)
      settle()
      assert FakeSessionStore.entry("assistant")
    end
  end

  describe "trigger paths finalize the partial and reset the turn" do
    test "turn-task crash ({:DOWN}) preserves the partial as :interrupted" do
      ref = make_ref()
      state = session(turn_task_ref: ref, streaming_buffer: buffer("crashed mid-thought"))

      {:noreply, new_state} =
        Session.handle_info({:DOWN, ref, :process, self(), :killed}, state)

      settle()
      assert flatten_text(FakeSessionStore.entry("assistant")[:content]) =~ "crashed mid-thought"
      assert new_state.streaming_buffer == nil
      assert new_state.turn_in_flight == false
      assert new_state.turn_task_ref == nil
    end

    test "turn-timeout preserves the partial as :interrupted and unblocks the session" do
      ref = make_ref()

      state =
        session(
          turn_task_ref: ref,
          turn_task_pid: nil,
          streaming_buffer: buffer("timed out partway")
        )

      {:noreply, new_state} = Session.handle_info({:turn_timeout, ref}, state)

      settle()
      assert flatten_text(FakeSessionStore.entry("assistant")[:content]) =~ "timed out partway"
      assert new_state.streaming_buffer == nil
      assert new_state.turn_in_flight == false
    end

    test "a stale turn-timeout (ref no longer the active turn) is ignored" do
      state = session(turn_task_ref: make_ref(), streaming_buffer: buffer("keep me"))
      stale = make_ref()

      assert {:noreply, ^state} = Session.handle_info({:turn_timeout, stale}, state)
      settle()
      # nothing persisted, buffer intact
      assert FakeSessionStore.entry("assistant") == nil
      assert state.streaming_buffer.content == "keep me"
    end

    test "cancel_turn preserves the partial as :cancelled and replies :ok" do
      ref = make_ref()

      state =
        session(turn_task_ref: ref, turn_task_pid: nil, streaming_buffer: buffer("user bailed"))

      {:reply, reply, new_state} =
        Session.handle_call(:cancel_turn, {self(), make_ref()}, state)

      assert reply == :ok
      settle()
      assert flatten_text(FakeSessionStore.entry("assistant")[:content]) =~ "user bailed"
      assert new_state.streaming_buffer == nil
      assert new_state.turn_in_flight == false
    end

    test "cancel_turn with no turn in flight returns {:error, :no_turn_in_flight}" do
      state = session(turn_in_flight: false, streaming_buffer: nil)

      assert {:reply, {:error, :no_turn_in_flight}, ^state} =
               Session.handle_call(:cancel_turn, {self(), make_ref()}, state)
    end
  end

  # SessionEntry content is a list of content blocks (text + optional tool_use);
  # flatten to a string for substring assertions.
  defp flatten_text(content) when is_binary(content), do: content

  defp flatten_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => t} -> t
      %{text: t} -> t
      other -> to_string(inspect(other))
    end)
    |> Enum.join(" ")
  end

  defp flatten_text(other), do: to_string(inspect(other))
end
