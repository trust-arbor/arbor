defmodule Arbor.Agent.HeartbeatLoopTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.HeartbeatLoop
  alias Arbor.Memory.ContextWindow

  # A test agent module that uses HeartbeatLoop
  defmodule TestAgent do
    use GenServer
    use Arbor.Agent.HeartbeatLoop

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      state = %{
        id: Keyword.get(opts, :id, "test-agent"),
        last_user_message_at: nil,
        last_assistant_output_at: nil,
        responded_to_last_user_message: true,
        heartbeat_cycles: 0
      }

      state = init_heartbeat(state, opts)
      {:ok, state}
    end

    @impl true
    def handle_info(msg, state) do
      case handle_heartbeat_info(msg, state) do
        {:noreply, new_state} ->
          {:noreply, new_state}

        {:heartbeat_triggered, new_state} ->
          # Run heartbeat cycle synchronously for testing
          host_pid = self()

          Task.start(fn ->
            result = run_heartbeat_cycle(new_state, %{})
            send(host_pid, {:heartbeat_complete, result})
          end)

          {:noreply, new_state}

        :not_handled ->
          {:noreply, state}
      end
    end

    @impl Arbor.Agent.HeartbeatLoop
    def run_heartbeat_cycle(state, _body) do
      {:ok, [], %{}, state[:context_window], nil, %{cycles: state.heartbeat_cycles + 1}}
    end

    # For testing: get the state
    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end

    def handle_call({:queue_msg, msg, opts}, _from, state) do
      state = queue_message(state, msg, opts)
      {:reply, :ok, state}
    end

    def handle_call(:set_busy, _from, state) do
      {:reply, :ok, %{state | busy: true}}
    end

    def handle_call(:set_idle, _from, state) do
      {:reply, :ok, %{state | busy: false}}
    end
  end

  describe "init_heartbeat/2" do
    test "initializes state with heartbeat fields" do
      state = %{id: "test"}
      result = HeartbeatLoop.init_heartbeat(state, [])

      assert result.heartbeat_enabled == true
      assert result.heartbeat_interval == 10_000
      assert result.busy == false
      assert result.last_heartbeat_at == nil
      assert result.pending_messages == []
      assert result.context_window == nil
      # Timer ref should be set when enabled
      assert result.heartbeat_timer_ref != nil
    end

    test "respects heartbeat_enabled: false option" do
      state = %{id: "test"}
      result = HeartbeatLoop.init_heartbeat(state, heartbeat_enabled: false)

      assert result.heartbeat_enabled == false
      assert result.heartbeat_timer_ref == nil
    end

    test "uses configured interval" do
      state = %{id: "test"}
      result = HeartbeatLoop.init_heartbeat(state, heartbeat_interval_ms: 5_000)

      assert result.heartbeat_interval == 5_000
    end

    test "preserves existing state fields" do
      state = %{id: "test", custom_field: "preserved"}
      result = HeartbeatLoop.init_heartbeat(state, heartbeat_enabled: false)

      assert result.custom_field == "preserved"
      assert result.id == "test"
    end

    test "accepts initial context_window" do
      window = %{entries: [], max_tokens: 10_000}
      state = %{id: "test"}

      result =
        HeartbeatLoop.init_heartbeat(state, heartbeat_enabled: false, context_window: window)

      assert result.context_window == window
    end
  end

  describe "handle_heartbeat_info/2" do
    test "skips heartbeat when busy" do
      state = %{
        busy: true,
        heartbeat_enabled: true,
        heartbeat_interval: 1_000,
        heartbeat_timer_ref: nil
      }

      assert {:noreply, new_state} = HeartbeatLoop.handle_heartbeat_info(:heartbeat, state)
      assert new_state.heartbeat_timer_ref != nil
    end

    test "skips when heartbeat disabled" do
      state = %{
        busy: false,
        heartbeat_enabled: false,
        heartbeat_interval: 1_000,
        heartbeat_timer_ref: nil
      }

      assert {:noreply, ^state} = HeartbeatLoop.handle_heartbeat_info(:heartbeat, state)
    end

    test "triggers heartbeat when ready" do
      state = %{
        busy: false,
        heartbeat_enabled: true,
        heartbeat_interval: 1_000,
        last_heartbeat_at: nil,
        heartbeat_timer_ref: nil
      }

      assert {:heartbeat_triggered, new_state} =
               HeartbeatLoop.handle_heartbeat_info(:heartbeat, state)

      assert new_state.busy == true
      assert %DateTime{} = new_state.last_heartbeat_at
    end

    test "processes heartbeat_complete result" do
      state = %{
        busy: true,
        heartbeat_enabled: true,
        heartbeat_interval: 1_000,
        heartbeat_timer_ref: nil,
        pending_messages: [],
        context_window: nil
      }

      result = {:ok, [], %{}}

      assert {:noreply, new_state} =
               HeartbeatLoop.handle_heartbeat_info({:heartbeat_complete, result}, state)

      assert new_state.busy == false
      assert new_state.heartbeat_timer_ref != nil
    end

    test "returns :not_handled for unknown messages" do
      assert :not_handled = HeartbeatLoop.handle_heartbeat_info(:unknown, %{})
    end
  end

  describe "message queueing" do
    test "queues messages" do
      state = %{
        id: "test",
        pending_messages: []
      }

      state = HeartbeatLoop.queue_message(state, "hello", [])
      assert length(state.pending_messages) == 1
      assert [{msg, _opts}] = state.pending_messages
      assert msg == "hello"
    end

    test "respects max queue size" do
      # Set a small queue size for testing
      Application.put_env(:arbor_agent, :message_queue_max_size, 2)

      state = %{
        id: "test",
        pending_messages: [{"first", []}, {"second", []}]
      }

      # Adding a third should drop the oldest
      state = HeartbeatLoop.queue_message(state, "third", [])
      assert length(state.pending_messages) == 2

      messages = Enum.map(state.pending_messages, fn {msg, _} -> msg end)
      assert "first" not in messages
      assert "second" in messages
      assert "third" in messages

      # Clean up
      Application.delete_env(:arbor_agent, :message_queue_max_size)
    end

    test "processes pending messages with context window" do
      # Only works when ContextWindow module is available
      if Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
        window = ContextWindow.new("test")

        state = %{
          pending_messages: [{"hello", [speaker: "User"]}],
          context_window: window
        }

        new_state = HeartbeatLoop.process_pending_messages(state)
        assert new_state.pending_messages == []
        assert new_state.context_window != nil
      end
    end

    test "clears pending messages when no context window" do
      state = %{
        pending_messages: [{"hello", []}],
        context_window: nil
      }

      new_state = HeartbeatLoop.process_pending_messages(state)
      assert new_state.pending_messages == []
    end

    test "no-op when no pending messages" do
      state = %{pending_messages: []}
      assert ^state = HeartbeatLoop.process_pending_messages(state)
    end
  end

  describe "schedule_heartbeat/1" do
    test "returns a timer reference" do
      ref = HeartbeatLoop.schedule_heartbeat(%{heartbeat_interval: 100})
      assert is_reference(ref)
      Process.cancel_timer(ref)
    end
  end

  describe "cancel_heartbeat/1" do
    test "cancels timer when ref exists" do
      ref = Process.send_after(self(), :test, 10_000)
      assert :ok = HeartbeatLoop.cancel_heartbeat(%{heartbeat_timer_ref: ref})
    end

    test "no-op when ref is nil" do
      assert :ok = HeartbeatLoop.cancel_heartbeat(%{heartbeat_timer_ref: nil})
    end
  end

  describe "integration with GenServer" do
    test "agent starts with heartbeat fields" do
      {:ok, pid} = TestAgent.start_link(heartbeat_enabled: false)
      state = GenServer.call(pid, :get_state)

      assert state.heartbeat_enabled == false
      assert state.busy == false
      assert state.pending_messages == []

      GenServer.stop(pid)
    end

    test "heartbeat fires and completes" do
      {:ok, pid} =
        TestAgent.start_link(heartbeat_enabled: true, heartbeat_interval_ms: 50)

      # Wait for at least one heartbeat cycle
      Process.sleep(150)

      state = GenServer.call(pid, :get_state)
      assert state.last_heartbeat_at != nil
      assert state.busy == false

      GenServer.stop(pid)
    end

    test "message queueing via GenServer" do
      {:ok, pid} = TestAgent.start_link(heartbeat_enabled: false)

      GenServer.call(pid, {:queue_msg, "test message", []})
      state = GenServer.call(pid, :get_state)

      assert length(state.pending_messages) == 1

      GenServer.stop(pid)
    end

    test "busy state prevents concurrent heartbeats" do
      {:ok, pid} = TestAgent.start_link(heartbeat_enabled: false)

      # Set busy
      GenServer.call(pid, :set_busy)
      state = GenServer.call(pid, :get_state)
      assert state.busy == true

      # Send heartbeat — should be skipped
      send(pid, :heartbeat)
      Process.sleep(50)

      state = GenServer.call(pid, :get_state)
      # Still busy (heartbeat was skipped, not run)
      assert state.busy == true

      GenServer.stop(pid)
    end
  end
end
