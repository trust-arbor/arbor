defmodule Arbor.Actions.ExecutionBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.TestFixtures.{
    BoundBatchCompositeAction,
    BoundCompositeAction,
    BoundNestedInnerAction,
    BoundNestedOtherAction,
    BoundParallelCompositeAction,
    BoundStrippedTaskCompositeAction
  }

  alias Arbor.Actions.Coding.ProduceReviewableChange
  alias Arbor.Actions.Coding.Workspace.Acquire

  test "security regression: nested composite cannot strip the active binding" do
    context = bound_context([BoundCompositeAction])

    assert {:error, {:execution_binding_rejected, :nested_action_binding_removed}} =
             Arbor.Actions.execute_action(BoundCompositeAction, %{}, context)

    refute_receive :bound_nested_inner_executed
  end

  test "security regression: execute_batch cannot drop a composite action's active binding" do
    context = bound_context([BoundBatchCompositeAction])

    assert {:error, {:execution_binding_rejected, :nested_action_binding_removed}} =
             Arbor.Actions.execute_action(BoundBatchCompositeAction, %{}, context)
  end

  test "security regression: nested composite cannot execute an action absent from the bound manifest" do
    context = bound_context([BoundCompositeAction])

    assert {:error,
            {:execution_binding_rejected, {:missing_action_binding, "bound_nested_inner_action"}}} =
             Arbor.Actions.execute_action(
               BoundCompositeAction,
               %{strip_context: false},
               context
             )

    refute_receive :bound_nested_inner_executed
  end

  test "security regression: parallel nested action calls each enforce the full bound index" do
    context = bound_context([BoundParallelCompositeAction])

    assert {:ok, %{results: results}} =
             Arbor.Actions.execute_action(BoundParallelCompositeAction, %{}, context)

    assert [
             {:ok,
              {:error,
               {:execution_binding_rejected,
                {:missing_action_binding, "bound_nested_inner_action"}}}},
             {:ok,
              {:error,
               {:execution_binding_rejected,
                {:missing_action_binding, "bound_nested_other_action"}}}}
           ] = results

    refute_receive :bound_nested_inner_executed
    refute_receive :bound_nested_other_executed
  end

  test "security regression: task child cannot strip its caller's active binding" do
    context = bound_context([BoundStrippedTaskCompositeAction])

    assert {:error, {:execution_binding_rejected, :nested_action_binding_removed}} =
             Arbor.Actions.execute_action(BoundStrippedTaskCompositeAction, %{}, context)

    refute_receive :bound_nested_inner_executed
  end

  test "security regression: bound facade rejects module and BEAM drift before authorization" do
    {:ok, expected} = Arbor.Actions.runtime_descriptor(BoundNestedInnerAction)

    drifted =
      expected
      |> Map.put("module", Atom.to_string(BoundNestedOtherAction))
      |> Map.put("beam_sha256", String.duplicate("0", 64))

    context = binding_context(%{"bound_nested_inner_action" => drifted})

    assert {:error,
            {:execution_binding_rejected,
             {:action_binding_mismatch, "bound_nested_inner_action", fields}}} =
             Arbor.Actions.authorize_and_execute(
               "system",
               BoundNestedInnerAction,
               %{},
               context
             )

    assert "module" in fields
    assert "beam_sha256" in fields
  end

  test "security regression: same-module hot reload is rejected before action execution" do
    module = BoundNestedInnerAction
    {:ok, descriptor} = Arbor.Actions.runtime_descriptor(module)
    context = binding_context(%{descriptor["name"] => descriptor})
    env_key = :execution_binding_hot_reload_test_pid
    previous_pid = Application.get_env(:arbor_actions, env_key)

    {^module, original_beam, original_filename} = :code.get_object_code(module)

    on_exit(fn ->
      restore_loaded_module!(module, original_filename, original_beam)

      if is_nil(previous_pid) do
        Application.delete_env(:arbor_actions, env_key)
      else
        Application.put_env(:arbor_actions, env_key, previous_pid)
      end
    end)

    Application.put_env(:arbor_actions, env_key, self())

    replacement_source = """
    defmodule #{inspect(module)} do
      def to_tool, do: %{name: "bound_nested_inner_action"}

      def run(_params, _context) do
        if pid = Application.get_env(:arbor_actions, :execution_binding_hot_reload_test_pid) do
          send(pid, :hot_reloaded_action_executed)
        end

        {:ok, %{replacement: true}}
      end
    end
    """

    [{^module, _replacement_beam}] = Code.compile_string(replacement_source)

    assert {:error, {:execution_binding_rejected, :action_loaded_code_mismatch}} =
             Arbor.Actions.execute_action(module, %{}, context)

    refute_receive :hot_reloaded_action_executed
  end

  test "security regression: ProduceReviewableChange cannot directly run an absent child action" do
    context = bound_context([ProduceReviewableChange])

    assert {:error,
            {:execution_binding_rejected, {:missing_action_binding, "coding_workspace_acquire"}}} =
             Arbor.Actions.execute_action(
               ProduceReviewableChange,
               %{task: "must not execute", repo_path: System.tmp_dir!()},
               context
             )
  end

  test "security regression: ProduceReviewableChange cannot directly run a drifted child action" do
    {:ok, outer} = Arbor.Actions.runtime_descriptor(ProduceReviewableChange)
    {:ok, child} = Arbor.Actions.runtime_descriptor(Acquire)
    drifted_child = Map.put(child, "beam_sha256", String.duplicate("0", 64))

    context =
      binding_context(%{
        outer["name"] => outer,
        drifted_child["name"] => drifted_child
      })

    assert {:error,
            {:execution_binding_rejected,
             {:action_binding_mismatch, "coding_workspace_acquire", ["beam_sha256"]}}} =
             Arbor.Actions.execute_action(
               ProduceReviewableChange,
               %{task: "must not execute", repo_path: System.tmp_dir!()},
               context
             )
  end

  defp bound_context(modules) do
    bindings =
      Map.new(modules, fn module ->
        {:ok, descriptor} = Arbor.Actions.runtime_descriptor(module)
        {descriptor["name"], descriptor}
      end)

    bindings
    |> binding_context()
    |> Map.merge(%{agent_id: "system", test_pid: self()})
  end

  defp binding_context(bindings) do
    manifest = %{"actions" => bindings |> Map.values() |> Enum.sort_by(& &1["name"])}
    {:ok, manifest_digest} = Arbor.Actions.execution_binding_digest(manifest)
    {:ok, bindings_digest} = Arbor.Actions.execution_binding_digest(bindings)

    %{
      execution_manifest: manifest,
      execution_manifest_digest: manifest_digest,
      pinned_action_bindings: bindings,
      pinned_action_bindings_digest: bindings_digest
    }
  end

  defp restore_loaded_module!(module, filename, beam) do
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, filename, beam)
    :code.purge(module)
    :ok
  end
end
