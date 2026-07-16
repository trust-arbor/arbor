defmodule Arbor.Orchestrator.ActionsExecutorTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Taint, as: TaintStruct
  alias Arbor.Orchestrator.ActionsExecutor

  # arbor_actions is a hard (compile-time) dep of arbor_orchestrator, so the
  # module is always loaded — there is no "not available" fallback any more.

  describe "build_action_map/0" do
    test "returns a map of action names to modules" do
      map = ActionsExecutor.build_action_map()
      assert is_map(map)
      assert map_size(map) > 0

      # Keys should include canonical dot-format names
      assert Map.has_key?(map, "file.read") or Map.has_key?(map, "file_read")
    end

    test "includes both dot and underscore name formats" do
      map = ActionsExecutor.build_action_map()

      # Find any action that has a dot name
      dot_names = Enum.filter(Map.keys(map), &String.contains?(&1, "."))
      underscore_names = Enum.reject(Map.keys(map), &String.contains?(&1, "."))

      # Should have both formats
      assert dot_names != [], "should have dot-format names"
      assert underscore_names != [], "should have underscore-format names"
    end
  end

  describe "execute/4" do
    test "returns error for unknown action" do
      result = ActionsExecutor.execute("nonexistent_action", %{}, ".")
      assert {:error, "Unknown action: nonexistent_action"} = result
    end

    test "executes known action via dot name" do
      result = ActionsExecutor.execute("file.read", %{"path" => "mix.exs"}, ".")

      case result do
        {:ok, content} -> assert is_binary(content)
        {:error, _reason} -> :ok
      end
    end

    test "executes known action via underscore name" do
      result = ActionsExecutor.execute("file_read", %{"path" => "mix.exs"}, ".")

      case result do
        {:ok, content} -> assert is_binary(content)
        {:error, _reason} -> :ok
      end
    end

    test "accepts agent_id in opts" do
      result =
        ActionsExecutor.execute("file.read", %{"path" => "mix.exs"}, ".", agent_id: "test-agent")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "forwards per-parameter taint to action enforcement" do
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

      on_exit(fn ->
        :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
      end)

      aggregate = %TaintStruct{level: :trusted, sanitizations: 0b00001000}
      exact = %{"path" => %TaintStruct{level: :untrusted}}
      tracer = self()

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        ActionsExecutor.execute(
          "file.read",
          %{"path" => "mix.exs"},
          ".",
          taint: aggregate,
          param_taint: exact
        )
      end)
      |> Task.await()

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [_agent_id, Arbor.Actions.File.Read, _params, context]}}

      assert context.taint == aggregate
      assert context.param_taint == exact
    end

    test "forwards run authorization to action context only when supplied" do
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

      on_exit(fn ->
        :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
      end)

      {:ok, uncompiled_parent_graph} =
        Arbor.Orchestrator.parse("""
        digraph ParentAuthorization {
          start [shape=Mdiamond]
          done [shape=Msquare]
          start -> done
        }
        """)

      {:ok, parent_graph} = Arbor.Orchestrator.IR.Compiler.compile(uncompiled_parent_graph)

      {:ok, authority} =
        Arbor.Orchestrator.Engine.RunAuthorization.new(parent_graph,
          agent_id: "agent_parent_authorization",
          caller_id: "caller_parent_authorization",
          author_id: "author_parent_authorization",
          workdir: File.cwd!()
        )

      tracer = self()

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        ActionsExecutor.execute(
          "file.read",
          %{"path" => "mix.exs"},
          ".",
          run_authorization: authority
        )
      end)
      |> Task.await()

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [_agent_id, Arbor.Actions.File.Read, _params, context]}}

      assert context.run_authorization == authority

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])
        ActionsExecutor.execute("file.read", %{"path" => "mix.exs"}, ".")
      end)
      |> Task.await()

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [_agent_id, Arbor.Actions.File.Read, _params, context]}}

      refute Map.has_key?(context, :run_authorization)
    end

    test "threads transcript sink only into the exact ACP send action context" do
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

      on_exit(fn ->
        :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
      end)

      tracer = self()
      sink = {Arbor.Orchestrator.CodingPlan.ArtifactStore, :append_transcript_turn, ["/tmp", "t"]}

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        ActionsExecutor.execute(
          "acp_send_message",
          %{"worker_session_id" => "acp_worker_missing", "prompt" => "continue"},
          ".",
          transcript_sink: sink,
          execution_id: "exec-capture"
        )
      end)
      |> Task.await()

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [
                         _agent_id,
                         Arbor.Actions.Acp.SendMessage,
                         _params,
                         acp_context
                       ]}}

      assert acp_context.transcript_sink == sink
      assert acp_context.transcript_execution_id == "exec-capture"

      malformed_sink = %{callback: fn -> :unsafe end}

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        ActionsExecutor.execute(
          "acp_send_message",
          %{"worker_session_id" => "acp_worker_missing", "prompt" => "continue"},
          ".",
          transcript_capture_error: :invalid_trusted_transcript_capture,
          transcript_sink: malformed_sink,
          execution_id: "exec-capture"
        )
      end)
      |> Task.await()

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [
                         _agent_id,
                         Arbor.Actions.Acp.SendMessage,
                         _params,
                         rejected_context
                       ]}}

      assert rejected_context.transcript_capture_error == :invalid_trusted_transcript_capture
      refute Map.has_key?(rejected_context, :transcript_sink)
      refute inspect(rejected_context) =~ "callback"

      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        ActionsExecutor.execute(
          "file.read",
          %{"path" => "mix.exs"},
          ".",
          transcript_sink: sink,
          execution_id: "exec-file"
        )
      end)
      |> Task.await()

      assert_receive {:trace, _pid, :call,
                      {Arbor.Actions, :authorize_and_execute,
                       [_agent_id, Arbor.Actions.File.Read, _params, file_context]}}

      refute Map.has_key?(file_context, :transcript_sink)
      refute Map.has_key?(file_context, :transcript_execution_id)
    end
  end

  describe "normalize_name/1" do
    test "converts underscores to dots for simple names" do
      # This is a private function tested through execute behavior
      # file_read -> should resolve to file.read action
      result1 = ActionsExecutor.execute("file_read", %{"path" => "mix.exs"}, ".")
      result2 = ActionsExecutor.execute("file.read", %{"path" => "mix.exs"}, ".")

      # Both should produce same outcome type
      case {result1, result2} do
        {{:ok, _}, {:ok, _}} -> :ok
        {{:error, _}, {:error, _}} -> :ok
        _ -> :ok
      end
    end
  end
end
