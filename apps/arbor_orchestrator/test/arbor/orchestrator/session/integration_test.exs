defmodule Arbor.Orchestrator.Session.IntegrationTest do
  @moduledoc """
  Integration tests for Session GenServer features added in Phase 3:
  - execution_mode config flag (strangler fig migration)
  - checkpoint restore (crash recovery)
  - contract struct integration (Config/State/Behavior)
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Handlers.SessionHandler
  alias Arbor.Orchestrator.Session

  @moduletag :session_integration

  @session_types ~w(
    session.classify session.memory_recall session.mode_select
    session.llm_call session.tool_dispatch session.format
    session.memory_update session.checkpoint session.background_checks
    session.process_results session.route_actions session.update_goals
  )

  setup_all do
    case Elixir.Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Session types are resolved via alias path: session.* → ComposeHandler → SessionHandler
    # No custom handler registration needed since Phase 4 wired aliases into the executor.

    :ok
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_int_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    turn_dot = """
    digraph Turn {
      graph [goal="Test turn"]
      start [shape=Mdiamond]
      classify [type="session.classify"]
      call_llm [type="session.llm_call"]
      format [type="session.format"]
      done [shape=Msquare]
      start -> classify -> call_llm -> format -> done
    }
    """

    heartbeat_dot = """
    digraph Heartbeat {
      graph [goal="Test heartbeat"]
      start [shape=Mdiamond]
      select_mode [type="session.mode_select"]
      done [shape=Msquare]
      start -> select_mode -> done
    }
    """

    turn_path = Path.join(tmp_dir, "turn.dot")
    heartbeat_path = Path.join(tmp_dir, "heartbeat.dot")
    File.write!(turn_path, turn_dot)
    File.write!(heartbeat_path, heartbeat_dot)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    counter = :counters.new(1, [:atomics])

    adapters = %{
      llm_call: fn _messages, _mode, _opts ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        {:ok, %{content: "response #{n}"}}
      end
    }

    %{turn_path: turn_path, heartbeat_path: heartbeat_path, adapters: adapters}
  end

  defp start_session(ctx, overrides \\ []) do
    id = "int-test-#{:erlang.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          session_id: id,
          agent_id: "agent_int_test",
          trust_tier: :established,
          turn_dot: ctx.turn_path,
          heartbeat_dot: ctx.heartbeat_path,
          adapters: ctx.adapters,
          start_heartbeat: false
        ],
        overrides
      )

    {:ok, pid} = Session.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, pid}
  end

  # ── execution_mode ────────────────────────────────────────────

  describe "execution_mode" do
    test "defaults to :session", ctx do
      {:ok, pid} = start_session(ctx)
      assert Session.execution_mode(pid) == :session
    end

    test "can be set to :legacy", ctx do
      {:ok, pid} = start_session(ctx, execution_mode: :legacy)
      assert Session.execution_mode(pid) == :legacy
    end

    test "can be set to :graph", ctx do
      {:ok, pid} = start_session(ctx, execution_mode: :graph)
      assert Session.execution_mode(pid) == :graph
    end

    test ":legacy mode rejects send_message", ctx do
      {:ok, pid} = start_session(ctx, execution_mode: :legacy)
      assert {:error, :legacy_mode} = Session.send_message(pid, "hello")
    end

    test ":session mode accepts send_message", ctx do
      {:ok, pid} = start_session(ctx)
      assert {:ok, _response} = Session.send_message(pid, "hello")
    end

    test ":graph mode accepts send_message", ctx do
      {:ok, pid} = start_session(ctx, execution_mode: :graph)
      assert {:ok, _response} = Session.send_message(pid, "hello")
    end

    test "execution_mode is visible in get_state", ctx do
      {:ok, pid} = start_session(ctx, execution_mode: :graph)
      state = Session.get_state(pid)
      assert state.execution_mode == :graph
    end
  end

  # ── checkpoint restore ────────────────────────────────────────

  describe "checkpoint restore via restore_checkpoint/2" do
    test "restores messages", ctx do
      {:ok, pid} = start_session(ctx)
      messages = [%{"role" => "user", "content" => "saved msg"}]

      :ok = Session.restore_checkpoint(pid, %{"session.messages" => messages})
      state = Session.get_state(pid)
      assert state.messages == messages
    end

    test "restores working_memory", ctx do
      {:ok, pid} = start_session(ctx)
      wm = %{"key" => "restored_value"}

      :ok = Session.restore_checkpoint(pid, %{"session.working_memory" => wm})
      state = Session.get_state(pid)
      assert state.working_memory == wm
    end

    test "restores goals", ctx do
      {:ok, pid} = start_session(ctx)
      goals = [%{"id" => "g1", "description" => "test goal"}]

      :ok = Session.restore_checkpoint(pid, %{"session.goals" => goals})
      state = Session.get_state(pid)
      assert state.goals == goals
    end

    test "restores turn_count", ctx do
      {:ok, pid} = start_session(ctx)

      :ok = Session.restore_checkpoint(pid, %{"session.turn_count" => 42})
      state = Session.get_state(pid)
      assert state.turn_count == 42
    end

    test "restores cognitive_mode from string", ctx do
      {:ok, pid} = start_session(ctx)

      :ok = Session.restore_checkpoint(pid, %{"session.cognitive_mode" => "goal_pursuit"})
      state = Session.get_state(pid)
      assert state.cognitive_mode == :goal_pursuit
    end

    test "restores multiple fields at once", ctx do
      {:ok, pid} = start_session(ctx)

      checkpoint = %{
        "session.messages" => [%{"role" => "system", "content" => "restored"}],
        "session.turn_count" => 10,
        "session.goals" => [%{"id" => "g1"}],
        "session.cognitive_mode" => "consolidation"
      }

      :ok = Session.restore_checkpoint(pid, checkpoint)
      state = Session.get_state(pid)

      assert length(state.messages) == 1
      assert state.turn_count == 10
      assert length(state.goals) == 1
      assert state.cognitive_mode == :consolidation
    end

    test "ignores nil values in checkpoint", ctx do
      {:ok, pid} = start_session(ctx)

      # Send a message first to have some state
      {:ok, _} = Session.send_message(pid, "before checkpoint")
      state_before = Session.get_state(pid)

      # Checkpoint with only turn_count — other fields should be unchanged
      :ok = Session.restore_checkpoint(pid, %{"session.turn_count" => 99})
      state_after = Session.get_state(pid)

      assert state_after.turn_count == 99
      assert state_after.messages == state_before.messages
    end
  end

  describe "checkpoint restore via init option" do
    test "restores state from checkpoint during init", ctx do
      checkpoint = %{
        "session.messages" => [%{"role" => "user", "content" => "recovered"}],
        "session.turn_count" => 5,
        "session.cognitive_mode" => "goal_pursuit"
      }

      {:ok, pid} = start_session(ctx, checkpoint: checkpoint)
      state = Session.get_state(pid)

      assert state.turn_count == 5
      assert state.cognitive_mode == :goal_pursuit
      assert length(state.messages) == 1
    end

    test "session works normally after checkpoint restore", ctx do
      checkpoint = %{
        "session.messages" => [
          %{"role" => "user", "content" => "previous"},
          %{"role" => "assistant", "content" => "before crash"}
        ],
        "session.turn_count" => 3
      }

      {:ok, pid} = start_session(ctx, checkpoint: checkpoint)

      # Send a new message — should work on top of restored state
      assert {:ok, _response} = Session.send_message(pid, "after recovery")
      state = Session.get_state(pid)

      # turn_count should be 3 (restored) + 1 (new turn) = 4
      assert state.turn_count == 4
      # messages: 2 restored + 1 new user + 1 new assistant = 4
      assert length(state.messages) == 4
    end
  end

  # ── contract integration ──────────────────────────────────────

  describe "contract struct integration" do
    test "builds contract structs when available", ctx do
      {:ok, pid} = start_session(ctx)
      state = Session.get_state(pid)

      if Session.contracts_available?() do
        assert state.session_config != nil
        assert state.session_state != nil
        assert state.behavior != nil
      end
    end

    test "session_state.turn_count increments after send_message", ctx do
      {:ok, pid} = start_session(ctx)

      if Session.contracts_available?() do
        state0 = Session.get_state(pid)
        assert state0.session_state.turn_count == 0

        {:ok, _} = Session.send_message(pid, "first")
        state1 = Session.get_state(pid)
        assert state1.session_state.turn_count == 1

        {:ok, _} = Session.send_message(pid, "second")
        state2 = Session.get_state(pid)
        assert state2.session_state.turn_count == 2
      end
    end

    test "flat fields stay in sync with contract state", ctx do
      {:ok, pid} = start_session(ctx)

      {:ok, _} = Session.send_message(pid, "sync test")
      state = Session.get_state(pid)

      if Session.contracts_available?() do
        assert state.turn_count == state.session_state.turn_count
        assert state.messages == state.session_state.messages
      end
    end

    test "checkpoint restore syncs to session_state", ctx do
      {:ok, pid} = start_session(ctx)

      checkpoint = %{
        "session.turn_count" => 15,
        "session.goals" => [%{"id" => "g1"}]
      }

      :ok = Session.restore_checkpoint(pid, checkpoint)
      state = Session.get_state(pid)

      if Session.contracts_available?() do
        assert state.session_state.turn_count == 15
        assert state.session_state.goals == [%{"id" => "g1"}]
      end
    end
  end
end
