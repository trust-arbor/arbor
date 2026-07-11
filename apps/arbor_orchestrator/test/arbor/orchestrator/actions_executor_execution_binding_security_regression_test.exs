defmodule Arbor.Orchestrator.ActionsExecutorExecutionBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.TestFixtures.SessionClassifyReplacementAction
  alias Arbor.Common.ActionRegistry
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Orchestrator.Engine.RunAuthorization
  alias Arbor.Orchestrator.Graph

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

  test "projects binding lineage and only child-safe ephemeral Engine options" do
    {:ok, binding} = Arbor.Actions.runtime_descriptor(Arbor.Actions.Session.Classify)
    bindings = %{@action_name => binding}
    opts = binding_opts(bindings)
    manifest = Keyword.fetch!(opts, :execution_manifest)
    manifest_digest = Keyword.fetch!(opts, :execution_manifest_digest)
    parent_digest = lineage_digest("parent-authority")
    binding_digest = lineage_digest("current-authority")

    authority =
      manifest
      |> authority_for_binding(manifest_digest, bindings)
      |> Map.put(:parent_binding_digest, parent_digest)
      |> Map.put(:binding_digest, binding_digest)

    signer = fn _resource -> {:error, :signing_disabled_for_test} end
    authorizer = fn _principal, _resource, _operation, _opts -> {:error, :test_only} end
    parent_auth_context = %{source: :parent_engine}
    on_event = fn _event -> :ok end

    opts =
      Keyword.merge(opts,
        agent_id: "system",
        authorization: true,
        run_authorization: authority,
        signer: signer,
        authorizer: authorizer,
        auth_context: parent_auth_context,
        identity_private_key: <<1, 2, 3>>,
        on_event: on_event,
        logs_root: "/tmp/arbor-binding-projection",
        resumable: false,
        max_depth: 8,
        actions_executor: :injectable_executor_must_not_cross,
        middleware: [:injectable_middleware_must_not_cross],
        tool_executor: :injectable_tool_executor_must_not_cross
      )

    {params, context} = capture_action_invocation(opts)

    assert context.execution_authority_binding_digest == binding_digest
    assert context.execution_authority_parent_binding_digest == parent_digest
    assert context.run_authorization == authority
    refute Map.has_key?(params, :nested_engine_opts)
    refute Map.has_key?(params, "nested_engine_opts")

    nested_opts = context.nested_engine_opts
    assert Keyword.get(nested_opts, :authorization) == true
    assert Keyword.get(nested_opts, :signer) == signer
    assert Keyword.get(nested_opts, :authorizer) == authorizer
    assert Keyword.get(nested_opts, :auth_context) == parent_auth_context
    assert Keyword.get(nested_opts, :identity_private_key) == <<1, 2, 3>>
    assert Keyword.get(nested_opts, :on_event) == on_event
    assert Keyword.get(nested_opts, :logs_root) == "/tmp/arbor-binding-projection"
    assert Keyword.get(nested_opts, :resumable) == false
    assert Keyword.get(nested_opts, :max_depth) == 7

    refute Keyword.has_key?(nested_opts, :run_authorization)
    refute Keyword.has_key?(nested_opts, :actions_executor)
    refute Keyword.has_key?(nested_opts, :middleware)
    refute Keyword.has_key?(nested_opts, :tool_executor)
  end

  test "security regression: authority lineage cannot be projected onto a different manifest" do
    {:ok, binding} = Arbor.Actions.runtime_descriptor(Arbor.Actions.Session.Classify)
    bindings = %{@action_name => binding}
    opts = binding_opts(bindings)
    manifest = Keyword.fetch!(opts, :execution_manifest)
    manifest_digest = Keyword.fetch!(opts, :execution_manifest_digest)

    authority =
      manifest
      |> authority_for_binding(manifest_digest, bindings)
      |> Map.put(:execution_manifest_digest, lineage_digest("different-manifest"))

    assert {:error, message} =
             ActionsExecutor.execute(
               @action_name,
               %{"input" => "hello"},
               File.cwd!(),
               Keyword.put(opts, :run_authorization, authority)
             )

    assert message =~ "run_authorization_execution_binding_mismatch"
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

  defp authority_for_binding(manifest, manifest_digest, bindings) do
    {:ok, authority} =
      RunAuthorization.new(%Graph{id: "ActionsExecutorProjection", compiled: true},
        agent_id: "system",
        workdir: File.cwd!()
      )

    %{
      authority
      | execution_manifest: manifest,
        execution_manifest_digest: manifest_digest,
        pinned_action_bindings: bindings
    }
  end

  defp capture_action_invocation(opts) do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    tracer = self()

    Task.async(fn ->
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])

      ActionsExecutor.execute(
        @action_name,
        %{"input" => "hello"},
        File.cwd!(),
        opts
      )
    end)
    |> Task.await()

    assert_receive {:trace, _pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [_agent_id, Arbor.Actions.Session.Classify, params, context]}}

    {params, context}
  end

  defp lineage_digest(label) do
    :crypto.hash(:sha256, label)
    |> Base.encode16(case: :lower)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_orchestrator, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_orchestrator, key, value)
end
