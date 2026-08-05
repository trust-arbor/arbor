defmodule Arbor.Actions.BatchContextSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.SessionExecution
  alias Arbor.Contracts.Security.Taint

  @moduletag :fast
  @moduletag :security_regression

  setup do
    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    unique = System.unique_integer([:positive])
    principal = "agent_batch_context_regression_#{unique}"
    workspace = Path.join(File.cwd!(), ".arbor_batch_context_test_#{unique}")
    File.mkdir_p!(workspace)

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(principal)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules: Map.put(profile.rules, "arbor://fs/write", :auto)
      })

    {:ok, capability} =
      Arbor.Security.grant(
        principal: principal,
        resource: "arbor://fs/write#{workspace}/**"
      )

    on_exit(fn ->
      Arbor.Security.revoke(capability.id)

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(principal)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, principal: principal, workspace: workspace}
  end

  test "security regression: execute_batch threads hostile operation taint to child authorization",
       %{principal: principal, workspace: workspace} do
    target = Path.join(workspace, "hostile-batch.txt")
    spec = file_write_spec(target)

    assert [{^spec, {:error, {:taint_blocked, :path, :hostile, :control}}}] =
             Arbor.Actions.execute_batch(
               [spec],
               agent_id: principal,
               context: %{
                 workspace: workspace,
                 taint: :hostile,
                 taint_policy: :permissive
               }
             )

    refute File.exists?(target)
  end

  test "security regression: RouteActions preserves hostile child context", %{
    principal: principal,
    workspace: workspace
  } do
    target = Path.join(workspace, "hostile-route.txt")

    assert {:ok, %{actions_routed: true}} =
             SessionExecution.RouteActions.run(
               %{agent_id: principal, actions: [file_write_spec(target)]},
               %{
                 workspace: workspace,
                 taint: :hostile,
                 taint_policy: :permissive
               }
             )

    refute File.exists?(target)
  end

  test "security regression: ExecuteActions preserves strict taint policy", %{
    principal: principal,
    workspace: workspace
  } do
    target = Path.join(workspace, "strict-execute.txt")
    path_sanitization = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    derived_path = %Taint{level: :derived, sanitizations: path_sanitization}

    assert {:ok,
            %{
              has_action_results: true,
              percepts: [%{outcome: :failure, error: error}],
              tool_turn: 1
            }} =
             SessionExecution.ExecuteActions.run(
               %{agent_id: principal, actions: [file_write_spec(target)]},
               %{
                 workspace: workspace,
                 taint: derived_path,
                 taint_policy: :strict
               }
             )

    assert error =~ "{:taint_blocked, :path, :derived, :control}"
    refute File.exists?(target)
  end

  test "security regression: batch principal remains authoritative over context and spec", %{
    principal: principal,
    workspace: workspace
  } do
    target = Path.join(workspace, "principal-mismatch.txt")

    spec =
      target
      |> file_write_spec()
      |> Map.put("context", %{agent_id: principal, taint: :trusted})

    asserted_principal = "agent_context_injection_#{System.unique_integer([:positive])}"

    assert [
             {^spec, {:error, {:principal_context_mismatch, ^principal, [^asserted_principal]}}}
           ] =
             Arbor.Actions.execute_batch(
               [spec],
               agent_id: principal,
               context: %{agent_id: asserted_principal, workspace: workspace}
             )

    refute File.exists?(target)
  end

  test "execute_batch rejects a non-map context before dispatch", %{principal: principal} do
    assert_raise ArgumentError, ":context must be a map", fn ->
      Arbor.Actions.execute_batch(
        [%{"type" => "session_classify", "params" => %{"input" => "ignored"}}],
        agent_id: principal,
        context: [taint: :trusted]
      )
    end
  end

  defp file_write_spec(path) do
    %{
      "type" => "file.write",
      "params" => %{
        path: path,
        content: "context threading regression",
        create_dirs: false
      }
    }
  end
end
