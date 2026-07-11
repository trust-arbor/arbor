defmodule Arbor.Actions.ExecutionBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.TestFixtures.{
    BoundBatchCompositeAction,
    BoundCompositeAction,
    BoundLineageCompositeAction,
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

  test "legacy nested calls retain the same active binding" do
    modules = [BoundLineageCompositeAction, BoundNestedInnerAction]
    nested_context = bound_context(modules)

    context =
      modules
      |> bound_context()
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: nested_context
      })

    assert {:ok, %{inner: true}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, context)

    assert_receive :bound_nested_inner_executed
  end

  test "security regression: authorized child bindings preserve recursive Engine lineage" do
    parent_digest = lineage_digest("parent")
    child_digest = lineage_digest("child")
    grandchild_digest = lineage_digest("grandchild")

    grandchild_context =
      lineage_bound_context([BoundNestedInnerAction], grandchild_digest, child_digest)

    child_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(child_digest, parent_digest)
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: grandchild_context
      })

    parent_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction, BoundNestedOtherAction]
      |> lineage_bound_context(parent_digest, nil)
      |> Map.merge(%{
        nested_action_module: BoundLineageCompositeAction,
        nested_execution_binding_context: child_context
      })

    assert {:ok, %{inner: true}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, parent_context)

    assert_receive :bound_nested_inner_executed
  end

  test "security regression: Task child inherits and transitions its caller's Engine lineage" do
    parent_digest = lineage_digest("task-parent")
    child_digest = lineage_digest("task-child")

    child_context =
      lineage_bound_context([BoundNestedInnerAction], child_digest, parent_digest)

    parent_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(parent_digest, nil)
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: child_context,
        nested_in_task: true
      })

    assert {:ok, %{inner: true}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, parent_context)

    assert_receive :bound_nested_inner_executed
  end

  test "security regression: replacement binding without authority lineage is rejected" do
    parent_digest = lineage_digest("lineage-parent")
    child_context = bound_context([BoundNestedInnerAction])

    parent_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(parent_digest, nil)
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: child_context
      })

    assert {:error, {:execution_binding_rejected, :nested_action_binding_lineage_missing}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, parent_context)

    refute_receive :bound_nested_inner_executed
  end

  test "security regression: sibling authority lineage cannot replace the active child" do
    parent_digest = lineage_digest("sibling-parent")
    child_digest = lineage_digest("sibling-child")
    sibling_digest = lineage_digest("sibling")

    sibling_context =
      lineage_bound_context([BoundNestedInnerAction], sibling_digest, parent_digest)

    child_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(child_digest, parent_digest)
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: sibling_context
      })

    parent_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(parent_digest, nil)
      |> Map.merge(%{
        nested_action_module: BoundLineageCompositeAction,
        nested_execution_binding_context: child_context
      })

    assert {:error, {:execution_binding_rejected, :nested_action_binding_lineage_mismatch}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, parent_context)

    refute_receive :bound_nested_inner_executed
  end

  test "security regression: child authority cannot expand the parent's action bindings" do
    parent_digest = lineage_digest("subset-parent")
    child_digest = lineage_digest("subset-child")

    child_context =
      lineage_bound_context(
        [BoundNestedInnerAction, BoundNestedOtherAction],
        child_digest,
        parent_digest
      )

    parent_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(parent_digest, nil)
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: child_context
      })

    assert {:error,
            {:execution_binding_rejected,
             {:nested_action_binding_expanded, "bound_nested_other_action"}}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, parent_context)

    refute_receive :bound_nested_inner_executed
    refute_receive :bound_nested_other_executed
  end

  test "security regression: child authority cannot replace a parent's exact code binding" do
    parent_digest = lineage_digest("code-parent")
    child_digest = lineage_digest("code-child")
    {:ok, inner_binding} = Arbor.Actions.runtime_descriptor(BoundNestedInnerAction)

    child_context =
      inner_binding
      |> Map.put("beam_sha256", String.duplicate("0", 64))
      |> then(&binding_context(%{&1["name"] => &1}))
      |> put_lineage(child_digest, parent_digest)
      |> Map.merge(%{agent_id: "system", test_pid: self()})

    parent_context =
      [BoundLineageCompositeAction, BoundNestedInnerAction]
      |> lineage_bound_context(parent_digest, nil)
      |> Map.merge(%{
        nested_action_module: BoundNestedInnerAction,
        nested_execution_binding_context: child_context
      })

    assert {:error,
            {:execution_binding_rejected,
             {:nested_action_binding_changed, "bound_nested_inner_action"}}} =
             Arbor.Actions.execute_action(BoundLineageCompositeAction, %{}, parent_context)

    refute_receive :bound_nested_inner_executed
  end

  test "security regression: malformed authority lineage digest fails closed" do
    context =
      [BoundNestedInnerAction]
      |> bound_context()
      |> Map.put(:execution_authority_binding_digest, "not-a-sha256")

    assert {:error, {:execution_binding_rejected, :invalid_execution_binding_lineage}} =
             Arbor.Actions.execute_action(BoundNestedInnerAction, %{}, context)

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

  defp lineage_bound_context(modules, binding_digest, parent_binding_digest) do
    modules
    |> bound_context()
    |> put_lineage(binding_digest, parent_binding_digest)
  end

  defp put_lineage(context, binding_digest, parent_binding_digest) do
    context
    |> Map.put(:execution_authority_binding_digest, binding_digest)
    |> Map.put(:execution_authority_parent_binding_digest, parent_binding_digest)
  end

  defp lineage_digest(label) do
    :crypto.hash(:sha256, label)
    |> Base.encode16(case: :lower)
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
