defmodule Arbor.Orchestrator.ActionsExecutorCallerAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Orchestrator.ActionsExecutor

  defmodule CallerDenySecurity do
    def list_capabilities(_principal, _opts), do: {:ok, []}
    def capability_authorizes?(_capability, _resource, _opts), do: false

    def normalize_authorization_resource_uri(resource, opts) do
      Arbor.Security.normalize_authorization_resource_uri(resource, opts)
    end
  end

  setup do
    previous = Application.get_env(:arbor_orchestrator, :security_module)
    Application.put_env(:arbor_orchestrator, :security_module, CallerDenySecurity)

    root =
      Path.join(
        System.tmp_dir!(),
        "phase5_action_caller_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbor_orchestrator, :security_module, previous),
        else: Application.delete_env(:arbor_orchestrator, :security_module)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "security regression: high-authority target cannot act as confused deputy", %{root: root} do
    suffix = System.unique_integer([:positive])
    target = "agent_high_authority_#{suffix}"
    caller = "human_dispatch_only_#{suffix}"
    output = Path.join(root, "must-not-exist.txt")

    {:ok, target_capability} =
      Arbor.Security.grant(
        principal: target,
        resource: "arbor://fs/write/**",
        task_id: "task_confused_deputy"
      )

    {:ok, caller_lobby} =
      Arbor.Security.grant(
        principal: caller,
        resource: "arbor://orchestrator/execute/**",
        task_id: "task_confused_deputy"
      )

    on_exit(fn ->
      Arbor.Security.revoke(target_capability.id)
      Arbor.Security.revoke(caller_lobby.id)
    end)

    effective =
      Arbor.Security.authorization_resource_uri("arbor://fs/write", file_path: output)

    assert Arbor.Security.capability_authorizes?(
             target_capability,
             effective,
             task_id: "task_confused_deputy"
           )

    refute Arbor.Security.capability_authorizes?(
             caller_lobby,
             effective,
             task_id: "task_confused_deputy"
           )

    assert {:error, message} =
             ActionsExecutor.execute(
               "file.write",
               %{"path" => output, "content" => "confused deputy"},
               root,
               agent_id: target,
               caller_id: caller,
               task_id: "task_confused_deputy",
               session_id: "session_confused_deputy"
             )

    assert message =~ "Caller #{caller} lacks authority"
    assert message =~ "arbor://fs/write"
    refute File.exists?(output)
  end
end
