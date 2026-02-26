defmodule Arbor.Orchestrator.Session.SupervisorTest do
  @moduledoc """
  Tests for Session.Supervisor lifecycle management.

  Validates DynamicSupervisor + Registry integration:
  start_session/stop_session/list_sessions/count.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Supervisor, as: SessionSupervisor

  @moduletag :session_lifecycle

  setup_all do
    ensure_started(Arbor.Orchestrator.SessionRegistry, fn ->
      Elixir.Registry.start_link(keys: :unique, name: Arbor.Orchestrator.SessionRegistry)
    end)

    ensure_started(SessionSupervisor, fn ->
      SessionSupervisor.start_link()
    end)

    ensure_started(Arbor.Orchestrator.EventRegistry, fn ->
      Elixir.Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry)
    end)

    :ok
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_sup_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Minimal DOTs using simulated compute nodes (no real LLM or action calls)
    turn_dot = """
    digraph Turn {
      graph [goal="Test turn"]
      start [shape=Mdiamond]
      classify [type="compute", simulate="true"]
      call_llm [type="compute", simulate="true"]
      done [shape=Msquare]
      start -> classify -> call_llm -> done
    }
    """

    heartbeat_dot = """
    digraph Heartbeat {
      graph [goal="Test heartbeat"]
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

    on_exit(fn ->
      # Clean up all test sessions
      for {_id, pid} <- SessionSupervisor.list_sessions() do
        try do
          SessionSupervisor.stop_session(pid)
        catch
          :exit, _ -> :ok
        end
      end

      # Don't unregister handler types — other async test files share them.
      # The application registers them on startup and they're harmless to leave.
      File.rm_rf(tmp_dir)
    end)

    adapters = %{
      llm_call: fn _messages, _mode, _opts ->
        {:ok, %{content: "test response"}}
      end
    }

    %{turn_path: turn_path, heartbeat_path: heartbeat_path, adapters: adapters}
  end

  defp session_opts(ctx, overrides \\ []) do
    id = "sup-test-#{:erlang.unique_integer([:positive])}"

    Keyword.merge(
      [
        session_id: id,
        agent_id: "agent_sup_test",
        trust_tier: :established,
        turn_dot: ctx.turn_path,
        heartbeat_dot: ctx.heartbeat_path,
        adapters: ctx.adapters,
        start_heartbeat: false
      ],
      overrides
    )
  end

  defp ensure_started(name, start_fn) do
    case Process.whereis(name) do
      nil ->
        case start_fn.() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  describe "start_session/1" do
    test "starts a session and registers it", ctx do
      opts = session_opts(ctx)
      session_id = Keyword.fetch!(opts, :session_id)

      assert {:ok, pid} = SessionSupervisor.start_session(opts)
      assert Process.alive?(pid)

      # Should appear in list
      sessions = SessionSupervisor.list_sessions()
      assert Enum.any?(sessions, fn {id, _pid} -> id == session_id end)
    end

    test "started session responds to send_message", ctx do
      opts = session_opts(ctx)
      assert {:ok, pid} = SessionSupervisor.start_session(opts)
      assert {:ok, %{text: text}} = Session.send_message(pid, "hello")
      assert is_binary(text)
    end

    test "rejects duplicate session_id", ctx do
      opts = session_opts(ctx)
      assert {:ok, _pid} = SessionSupervisor.start_session(opts)
      assert {:error, {:already_started, _}} = SessionSupervisor.start_session(opts)
    end
  end

  describe "stop_session/1" do
    test "stops by pid", ctx do
      opts = session_opts(ctx)
      {:ok, pid} = SessionSupervisor.start_session(opts)

      assert :ok = SessionSupervisor.stop_session(pid)
      refute Process.alive?(pid)
    end

    test "stops by session_id", ctx do
      opts = session_opts(ctx)
      session_id = Keyword.fetch!(opts, :session_id)
      {:ok, pid} = SessionSupervisor.start_session(opts)

      assert :ok = SessionSupervisor.stop_session(session_id)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for unknown session_id", _ctx do
      assert {:error, :not_found} = SessionSupervisor.stop_session("nonexistent-id")
    end

    test "removed from list after stop", ctx do
      opts = session_opts(ctx)
      session_id = Keyword.fetch!(opts, :session_id)
      {:ok, _pid} = SessionSupervisor.start_session(opts)

      SessionSupervisor.stop_session(session_id)
      Process.sleep(50)

      sessions = SessionSupervisor.list_sessions()
      refute Enum.any?(sessions, fn {id, _} -> id == session_id end)
    end
  end

  describe "count/0" do
    test "reflects active session count", ctx do
      initial = SessionSupervisor.count()

      opts1 = session_opts(ctx)
      opts2 = session_opts(ctx)
      {:ok, _} = SessionSupervisor.start_session(opts1)
      {:ok, _} = SessionSupervisor.start_session(opts2)

      assert SessionSupervisor.count() == initial + 2

      SessionSupervisor.stop_session(Keyword.fetch!(opts1, :session_id))
      Process.sleep(50)
      assert SessionSupervisor.count() == initial + 1
    end
  end

  describe "list_sessions/0" do
    test "returns all active sessions", ctx do
      initial_count = length(SessionSupervisor.list_sessions())

      opts1 = session_opts(ctx)
      opts2 = session_opts(ctx)
      opts3 = session_opts(ctx)
      {:ok, _} = SessionSupervisor.start_session(opts1)
      {:ok, _} = SessionSupervisor.start_session(opts2)
      {:ok, _} = SessionSupervisor.start_session(opts3)

      sessions = SessionSupervisor.list_sessions()
      assert length(sessions) == initial_count + 3

      ids = Enum.map(sessions, fn {id, _} -> id end)
      assert Keyword.fetch!(opts1, :session_id) in ids
      assert Keyword.fetch!(opts2, :session_id) in ids
      assert Keyword.fetch!(opts3, :session_id) in ids
    end
  end
end
