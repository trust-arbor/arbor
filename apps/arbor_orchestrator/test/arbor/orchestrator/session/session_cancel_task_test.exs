defmodule Arbor.Orchestrator.Session.CancelTaskTest do
  @moduledoc """
  Task-scoped Session cancellation: cancel task B must not tear down an
  unrelated active/interactive turn A; a later/queued message for a cancelled
  task must be rejected; matching active task turns are torn down.
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Orchestrator.Session

  defp user_message(content, task_id \\ nil) do
    base = UserMessage.from_string(content)

    if is_binary(task_id) and task_id != "" do
      %{base | transport_metadata: %{task_id: task_id}}
    else
      base
    end
  end

  defp session(overrides \\ []) do
    base = %Session{
      session_id: "agent-session-cancel_#{System.unique_integer([:positive])}",
      agent_id: "cancel_agent",
      phase: :idle,
      turn_count: 0,
      messages: [],
      turn_in_flight: false,
      turn_from: nil,
      turn_caller_ref: nil,
      turn_task_ref: nil,
      turn_task_pid: nil,
      turn_user_message: nil,
      streaming_buffer: nil,
      turn_queue: [],
      cancelled_task_ids: %{},
      cancelled_task_id_order: [],
      config: %{},
      session_state: nil,
      behavior: nil,
      steer_froms: []
    }

    struct(base, overrides)
  end

  defp active_task_turn(task_id, opts \\ []) do
    from = Keyword.get(opts, :from, {self(), make_ref()})
    content = Keyword.get(opts, :content, "task #{task_id} work")

    session(
      phase: :processing,
      turn_in_flight: true,
      turn_from: from,
      turn_user_message: user_message(content, task_id),
      turn_task_ref: make_ref(),
      turn_started_at: System.monotonic_time(),
      streaming_buffer: %{content: "", started_at: DateTime.utc_now(), first_token_at: nil}
    )
  end

  describe "cancel_task/2 vs cancel_turn/1" do
    test "cancel matching task A tears down that turn" do
      caller = {self(), make_ref()}
      state = active_task_turn("task_a", from: caller)

      {:reply, reply, new_state} =
        Session.handle_call({:cancel_task, "task_a"}, {self(), make_ref()}, state)

      assert reply == :ok
      assert new_state.turn_in_flight == false
      assert new_state.turn_user_message == nil
      assert new_state.turn_from == nil
      assert Map.get(new_state.cancelled_task_ids, "task_a") == true
    end

    test "cancel task B while task A is active leaves A running" do
      state = active_task_turn("task_a")

      {:reply, reply, new_state} =
        Session.handle_call({:cancel_task, "task_b"}, {self(), make_ref()}, state)

      assert reply == :ok
      # Unrelated active turn must not be cancelled.
      assert new_state.turn_in_flight == true
      assert new_state.turn_user_message.transport_metadata.task_id == "task_a"
      assert Map.get(new_state.cancelled_task_ids, "task_b") == true
      refute Map.has_key?(new_state.cancelled_task_ids, "task_a")
    end

    test "cancel task B while interactive turn (no task_id) is active leaves it running" do
      interactive =
        session(
          phase: :processing,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: user_message("hello operator"),
          turn_task_ref: make_ref(),
          turn_started_at: System.monotonic_time()
        )

      {:reply, :ok, new_state} =
        Session.handle_call({:cancel_task, "task_b"}, {self(), make_ref()}, interactive)

      assert new_state.turn_in_flight == true
      assert new_state.turn_user_message.content == "hello operator"
      assert Map.get(new_state.cancelled_task_ids, "task_b") == true
    end

    test "unscoped cancel_turn still cancels whatever is active" do
      state = active_task_turn("task_a")

      {:reply, reply, new_state} =
        Session.handle_call(:cancel_turn, {self(), make_ref()}, state)

      assert reply == :ok
      assert new_state.turn_in_flight == false
    end
  end

  describe "queued and late messages for cancelled tasks" do
    test "removes matching queued turn and replies cancelled to its caller" do
      queue_from = {self(), make_ref()}
      other_from = {self(), make_ref()}

      state =
        active_task_turn("task_a")
        |> Map.put(:turn_queue, [
          {user_message("task b body", "task_b"), queue_from},
          {user_message("interactive follow-up"), other_from}
        ])

      {:reply, :ok, new_state} =
        Session.handle_call({:cancel_task, "task_b"}, {self(), make_ref()}, state)

      # Active A remains; only B was purged from the queue.
      assert new_state.turn_in_flight == true
      assert length(new_state.turn_queue) == 1
      assert hd(new_state.turn_queue) |> elem(0) |> Map.get(:content) == "interactive follow-up"
    end

    test "later send_message for a cancelled task is rejected and does not run" do
      {:reply, :ok, state} =
        Session.handle_call({:cancel_task, "task_b"}, {self(), make_ref()}, session())

      msg = user_message("late arrival for B", "task_b")

      assert {:reply, {:error, :cancelled}, returned} =
               Session.handle_call({:send_message, msg}, {self(), make_ref()}, state)

      # Rejected at the entry boundary — no turn started, queue empty.
      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_user_message == nil
    end

    test "mid-turn queueing of a cancelled task is rejected immediately" do
      {:reply, :ok, state} =
        Session.handle_call(
          {:cancel_task, "task_b"},
          {self(), make_ref()},
          active_task_turn("task_a")
        )

      msg = user_message("queued B", "task_b")

      assert {:reply, {:error, :cancelled}, new_state} =
               Session.handle_call({:send_message, msg}, {self(), make_ref()}, state)

      assert new_state.turn_in_flight == true
      assert new_state.turn_queue == []
      assert user_message_task_id_for_assert(new_state.turn_user_message) == "task_a"
    end

    test "drain_queue skips a tombstoned task and does not start it" do
      from_b = {self(), make_ref()}
      from_c = {self(), make_ref()}
      msg_c = user_message("c work", "task_c")

      state =
        session(
          cancelled_task_ids: %{"task_b" => true},
          cancelled_task_id_order: ["task_b"],
          turn_queue: [
            {user_message("b work", "task_b"), from_b},
            {msg_c, from_c}
          ]
        )

      # First drain pops B, sees tombstone, replies cancelled, leaves C queued.
      assert {:noreply, after_b} = Session.handle_info(:drain_queue, state)
      assert length(after_b.turn_queue) == 1
      assert user_message_task_id_for_assert(elem(hd(after_b.turn_queue), 0)) == "task_c"
      refute after_b.turn_in_flight
      refute match?(%{turn_user_message: %{transport_metadata: %{task_id: "task_b"}}}, after_b)
    end

    test "cancellation tombstones are bounded" do
      state = session()

      state =
        Enum.reduce(1..70, state, fn i, acc ->
          tid = "task_#{i}"

          {:reply, :ok, next} =
            Session.handle_call({:cancel_task, tid}, {self(), make_ref()}, acc)

          next
        end)

      assert map_size(state.cancelled_task_ids) == 64
      assert length(state.cancelled_task_id_order) == 64
      # Newest kept, oldest dropped.
      assert Map.has_key?(state.cancelled_task_ids, "task_70")
      refute Map.has_key?(state.cancelled_task_ids, "task_1")
    end

    test "invalid task_id is rejected" do
      state = session()

      assert {:reply, {:error, :invalid_task_id}, ^state} =
               Session.handle_call({:cancel_task, ""}, {self(), make_ref()}, state)

      assert {:reply, {:error, :invalid_task_id}, ^state} =
               Session.handle_call({:cancel_task, nil}, {self(), make_ref()}, state)
    end
  end

  defp user_message_task_id_for_assert(%UserMessage{transport_metadata: metadata}) do
    Map.get(metadata, :task_id) || Map.get(metadata, "task_id")
  end

  defp user_message_task_id_for_assert(_), do: nil
end
