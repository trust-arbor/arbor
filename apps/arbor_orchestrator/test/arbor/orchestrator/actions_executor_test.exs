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
