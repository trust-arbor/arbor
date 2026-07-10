defmodule Arbor.Actions.TaintEnforcementPublicApiTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  alias Arbor.Contracts.Security.Taint

  setup do
    unique = System.unique_integer([:positive])
    principal = "agent_param_taint_regression_#{unique}"
    workspace = Path.join(File.cwd!(), ".arbor_param_taint_test_#{unique}")

    File.mkdir_p!(workspace)

    {:ok, capability} =
      Arbor.Security.grant(
        principal: principal,
        resource: "arbor://fs/write#{workspace}/**"
      )

    on_exit(fn ->
      Arbor.Security.revoke(capability.id)
      File.rm_rf!(workspace)
    end)

    {:ok, principal: principal, workspace: workspace}
  end

  test "security regression: sanitizer evidence cannot transfer between action parameters", %{
    principal: principal,
    workspace: workspace
  } do
    target = Path.join(workspace, "blocked-write.txt")

    path_sanitization = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    sanitized_content = %Taint{level: :trusted, sanitizations: path_sanitization}
    unsanitized_path = %Taint{level: :trusted, sanitizations: 0}

    assert {:error, {:missing_sanitization, :path, [:path_traversal]}} =
             Arbor.Actions.authorize_and_execute(
               principal,
               Arbor.Actions.File.Write,
               %{path: target, content: "safe test content"},
               %{
                 workspace: workspace,
                 taint: sanitized_content,
                 param_taint: %{
                   path: unsanitized_path,
                   content: sanitized_content
                 },
                 taint_policy: :permissive
               }
             )

    refute File.exists?(target)
  end

  test "security regression: strict aggregate blocks derived tuple control parameters", %{
    principal: principal,
    workspace: workspace
  } do
    target = Path.join(workspace, "strict-blocked-write.txt")
    path_sanitization = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    derived_path = %Taint{level: :derived, sanitizations: path_sanitization}

    assert {:error, {:taint_blocked, :path, :derived, :control}} =
             Arbor.Actions.authorize_and_execute(
               principal,
               Arbor.Actions.File.Write,
               %{path: target, content: "safe test content"},
               %{
                 workspace: workspace,
                 taint: derived_path,
                 taint_policy: :strict
               }
             )

    refute File.exists?(target)
  end
end
