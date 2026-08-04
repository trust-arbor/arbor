defmodule Arbor.Orchestrator.SessionManagerIntegrationTest do
  @moduledoc """
  Integration tests for SessionManager + Session (full lifecycle).

  These tests create real DOT sessions and verify messaging works.
  They require both arbor_orchestrator and arbor_agent modules.

  Tagged :integration — excluded by default in most configs.
  Run with: `mix test --include integration` from the umbrella root
  with all apps loaded.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session

  @moduletag :integration

  @session_manager Arbor.Agent.SessionManager
  @session_available Code.ensure_loaded?(Arbor.Agent.SessionManager)

  if @session_available do
    setup_all do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "arbor_session_manager_integration_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      turn_path = Path.join(tmp_dir, "turn.dot")

      File.write!(turn_path, """
      digraph SessionManagerIntegration {
        graph [goal="Exercise SessionManager through a hermetic DOT turn"]
        start [shape=Mdiamond]
        respond [type="compute", simulate="true"]
        format [type="transform", transform="identity", source_key="last_response", output_key="session.response"]
        done [shape=Msquare]
        start -> respond -> format -> done
      }
      """)

      prior_turn_dot = Application.get_env(:arbor_ai, :session_turn_dot)
      Application.put_env(:arbor_ai, :session_turn_dot, turn_path)

      on_exit(fn ->
        restore_env(:arbor_ai, :session_turn_dot, prior_turn_dot)
        File.rm_rf(tmp_dir)
      end)

      :ok
    end

    setup do
      # Ensure EventRegistry is running
      case Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Start SessionManager if not running
      case Process.whereis(@session_manager) do
        nil ->
          {:ok, pid} = @session_manager.start_link([])
          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

        _pid ->
          :ok
      end

      agent_id = "agent_int_#{:erlang.unique_integer([:positive])}"
      Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(agent_id)

      on_exit(fn ->
        try do
          @session_manager.stop_session(agent_id)
        catch
          :exit, _ -> :ok
        end

        Arbor.Orchestrator.TestCapabilities.revoke_all(agent_id)
      end)

      %{agent_id: agent_id}
    end

    describe "ensure_session/2" do
      test "creates a real session and returns pid", %{agent_id: agent_id} do
        assert {:ok, pid} = ensure_test_session(agent_id)
        assert is_pid(pid)
        assert Process.alive?(pid)
      end

      test "is idempotent — second call returns same pid", %{agent_id: agent_id} do
        assert {:ok, pid1} = ensure_test_session(agent_id)
        assert {:ok, pid2} = ensure_test_session(agent_id)
        assert pid1 == pid2
      end
    end

    describe "session messaging" do
      test "send_message works through the DOT graph", %{agent_id: agent_id} do
        {:ok, pid} = ensure_test_session(agent_id)

        result = Session.send_message(pid, "Hello from integration test")
        assert {:ok, %{content: text}} = result
        assert is_binary(text)
      end

      test "session state accumulates across turns", %{agent_id: agent_id} do
        {:ok, pid} = ensure_test_session(agent_id)

        {:ok, _} = Session.send_message(pid, "First message")
        state1 = Session.get_state(pid)

        {:ok, _} = Session.send_message(pid, "Second message")
        state2 = Session.get_state(pid)

        assert state2.turn_count == state1.turn_count + 1
        assert length(state2.messages) > length(state1.messages)
      end
    end

    describe "crash cleanup" do
      test "DOWN monitor cleans up ETS entry", %{agent_id: agent_id} do
        {:ok, pid} = ensure_test_session(agent_id)
        assert @session_manager.has_session?(agent_id)

        Process.exit(pid, :kill)
        Process.sleep(100)

        refute @session_manager.has_session?(agent_id)
      end
    end

    defp ensure_test_session(agent_id) do
      @session_manager.ensure_session(agent_id,
        trust_tier: :established,
        start_heartbeat: false,
        provider: :lmstudio,
        model: "session-manager-integration"
      )
    end

    defp restore_env(app, key, nil), do: Application.delete_env(app, key)
    defp restore_env(app, key, value), do: Application.put_env(app, key, value)
  else
    @tag :skip
    test "skipped — SessionManager not available in this test context" do
      :ok
    end
  end
end
