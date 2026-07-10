defmodule Arbor.Orchestrator.ActionsExecutorExecutionBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.TestFixtures.SessionClassifyReplacementAction
  alias Arbor.Common.ActionRegistry
  alias Arbor.Orchestrator.ActionsExecutor

  @action_name "session_classify"

  setup_all do
    ensure_action_registry_started!()
    ensure_session_classify_registered!()
    :ok
  end

  setup do
    registry_snapshot = ActionRegistry.snapshot()
    previous_pid = Application.get_env(:arbor_orchestrator, :phase5_action_binding_test_pid)
    Application.put_env(:arbor_orchestrator, :phase5_action_binding_test_pid, self())

    on_exit(fn ->
      :ok = ActionRegistry.restore(registry_snapshot)
      restore_env(:phase5_action_binding_test_pid, previous_pid)
    end)

    :ok
  end

  test "security regression: actual action invocation rejects a missing pinned binding" do
    assert {:error, message} =
             ActionsExecutor.execute(
               @action_name,
               %{"input" => "hello"},
               File.cwd!(),
               [agent_id: "system"] ++ binding_opts(%{})
             )

    assert message =~ "missing_action_binding"
  end

  test "security regression: actual action invocation rejects same-schema registry module drift" do
    {:ok, original_binding} = Arbor.Actions.runtime_descriptor(Arbor.Actions.Session.Classify)
    replace_session_classify_with_fixture!()

    assert {:error, message} =
             ActionsExecutor.execute(
               @action_name,
               %{"input" => "hello"},
               File.cwd!(),
               [agent_id: "system"] ++ binding_opts(%{@action_name => original_binding})
             )

    assert message =~ "action_binding_mismatch"
    assert message =~ "beam_sha256"
    assert message =~ "module"
    refute_receive :replacement_action_executed
  end

  defp replace_session_classify_with_fixture! do
    {entries, locked?} = ActionRegistry.snapshot()

    {replaced, count} =
      Enum.map_reduce(entries, 0, fn
        {name, _module, metadata, failures, core?}, count
        when name in ["session.classify", "session_classify"] ->
          {{name, SessionClassifyReplacementAction, metadata, failures, core?}, count + 1}

        entry, count ->
          {entry, count}
      end)

    assert count == 2
    :ok = ActionRegistry.restore({replaced, locked?})
  end

  defp ensure_action_registry_started! do
    unless Process.whereis(ActionRegistry) do
      start_supervised!(ActionRegistry)
    end
  end

  defp ensure_session_classify_registered! do
    for name <- ["session.classify", "session_classify"] do
      case ActionRegistry.resolve(name) do
        {:ok, _module} ->
          :ok

        {:error, :not_found} ->
          :ok = ActionRegistry.register(name, Arbor.Actions.Session.Classify)
      end
    end
  end

  defp binding_opts(bindings) do
    manifest = %{"actions" => bindings |> Map.values() |> Enum.sort_by(& &1["name"])}
    {:ok, manifest_digest} = Arbor.Actions.execution_binding_digest(manifest)

    [
      execution_manifest: manifest,
      execution_manifest_digest: manifest_digest,
      pinned_action_bindings: bindings
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
