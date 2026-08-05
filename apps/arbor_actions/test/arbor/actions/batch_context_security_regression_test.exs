defmodule Arbor.Actions.BatchContextSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.SessionExecution
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest, Taint}

  @parse_resource "arbor://action/coding/design_checkpoint/parse"
  @orchestrator_resource "arbor://orchestrator/execute"
  @shell_capability "arbor://shell/exec/**"
  @shell_rule "arbor://shell/exec"

  @moduletag :fast
  @moduletag :security_regression

  setup do
    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    unique = System.unique_integer([:positive])
    {:ok, identity} = Arbor.Security.generate_identity(name: "batch-context-#{unique}")
    :ok = Arbor.Security.register_identity(identity)
    principal = identity.agent_id
    workspace = Path.join(File.cwd!(), ".arbor_batch_context_test_#{unique}")
    File.mkdir_p!(workspace)

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(principal)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules:
            Map.merge(profile.rules, %{
              "arbor://fs/write" => :auto,
              @orchestrator_resource => :ask,
              @parse_resource => :auto,
              @shell_rule => :auto
            })
      })

    for resource <- [
          "arbor://fs/write#{workspace}/**",
          @orchestrator_resource,
          @parse_resource,
          @shell_capability
        ] do
      assert {:ok, _capability} =
               Arbor.Security.grant(
                 principal: principal,
                 resource: resource
               )
    end

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(principal)
      end

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(principal)
      end

      if Process.whereis(Arbor.Security.Identity.Registry) do
        Arbor.Security.deregister_identity(principal)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, identity: identity, principal: principal, workspace: workspace}
  end

  test "security regression: batch strips parent node elevation from dynamic internal child", %{
    principal: principal
  } do
    internal_action = Arbor.Actions.Coding.DesignCheckpoint.Parse
    context = elevated_binding_context(internal_action, principal)
    spec = %{"type" => "coding_design_envelope_parse", "params" => %{text: "not-json"}}

    assert [{^spec, {:error, :pipeline_internal_not_exposed}}] =
             Arbor.Actions.execute_batch([spec], agent_id: principal, context: context)
  end

  test "security regression: batch cannot replay parent approved invocation for selected children",
       %{principal: principal} do
    previous_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    previous_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

    on_exit(fn ->
      restore_env(:arbor_trust, :approval_guard_enabled, previous_guard)
      restore_env(:arbor_security, :consensus_escalation_enabled, previous_escalation)
    end)

    approval = %{
      request_id: "irq_parent_route_actions_once",
      principal_id: principal,
      resource_uri: @orchestrator_resource,
      decision: :approved
    }

    spec = %{
      "type" => "session_exec_route_actions",
      "params" => %{"agent_id" => principal, "actions" => []}
    }

    results =
      Enum.map([:approved_invocation, "approved_invocation"], fn key ->
        context = %{
          key => approval,
          task_id: "task_audit_provenance",
          session_id: "session_audit_provenance",
          node_id: "parent_route_node",
          approval_provenance: %{request_id: approval.request_id}
        }

        {key,
         Arbor.Actions.execute_batch(List.duplicate(spec, 2),
           agent_id: principal,
           context: context
         )}
      end)

    unauthorized_children = [
      {spec, {:error, :unauthorized}},
      {spec, {:error, :unauthorized}}
    ]

    assert [
             {:approved_invocation, ^unauthorized_children},
             {"approved_invocation", ^unauthorized_children}
           ] = results
  end

  test "batch preserves a matching verified SignedRequest and AuthContext for authenticated child",
       %{identity: identity, principal: principal} do
    command = "echo batch-auth-context"
    {:ok, resource} = Arbor.Actions.Shell.Execute.authorization_resource(%{command: command})
    {:ok, signed_request} = SignedRequest.sign(resource, principal, identity.private_key)

    auth_context =
      principal
      |> AuthContext.new(signed_request: signed_request)
      |> AuthContext.mark_verified()

    spec = %{"type" => "shell.execute", "params" => %{command: command}}

    assert [{^spec, {:ok, %{stdout: stdout, exit_code: 0}}}] =
             Arbor.Actions.execute_batch(
               [spec],
               agent_id: principal,
               context: %{
                 agent_id: principal,
                 signed_request: signed_request,
                 auth_context: auth_context
               }
             )

    assert stdout =~ "batch-auth-context"
  end

  test "batch rejects mismatched SignedRequest proof for authenticated child", %{
    identity: identity,
    principal: principal
  } do
    command = "echo must-not-run"
    {:ok, resource} = Arbor.Actions.Shell.Execute.authorization_resource(%{command: command})
    {:ok, signed_request} = SignedRequest.sign(resource, principal, identity.private_key)

    auth_context =
      principal
      |> AuthContext.new(signed_request: signed_request)
      |> AuthContext.mark_verified()

    mismatched_request = %{signed_request | agent_id: "agent_mismatched_batch_proof"}
    spec = %{"type" => "shell.execute", "params" => %{command: command}}

    assert [{^spec, {:error, :authenticated_principal_required}}] =
             Arbor.Actions.execute_batch(
               [spec],
               agent_id: principal,
               context: %{
                 agent_id: principal,
                 signed_request: mismatched_request,
                 auth_context: auth_context
               }
             )
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
    assert_raise ArgumentError, ":context must be a plain map", fn ->
      Arbor.Actions.execute_batch(
        [%{"type" => "session_classify", "params" => %{"input" => "ignored"}}],
        agent_id: principal,
        context: [taint: :trusted]
      )
    end
  end

  test "execute_batch rejects a struct as the top-level context", %{principal: principal} do
    assert_raise ArgumentError, ":context must be a plain map", fn ->
      Arbor.Actions.execute_batch(
        [%{"type" => "session_classify", "params" => %{"input" => "ignored"}}],
        agent_id: principal,
        context: AuthContext.new(principal)
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

  defp elevated_binding_context(action_module, principal) do
    {:ok, binding} = Arbor.Actions.runtime_descriptor(action_module)
    bindings = %{binding["name"] => binding}
    manifest = %{"actions" => [binding]}
    {:ok, manifest_digest} = Arbor.Actions.execution_binding_digest(manifest)
    {:ok, bindings_digest} = Arbor.Actions.execution_binding_digest(bindings)

    %{
      "pinned_action_binding" => %{"name" => "string_parent_node_only"},
      "allow_pipeline_internal" => true,
      "action_authorization" => %{"action_module" => inspect(__MODULE__)},
      {Arbor.Actions, :action_authorization_resource} => "arbor://action/parent/current",
      agent_id: principal,
      execution_manifest: manifest,
      execution_manifest_digest: manifest_digest,
      pinned_action_bindings: bindings,
      pinned_action_bindings_digest: bindings_digest,
      pinned_action_binding: %{"name" => "parent_node_only"},
      allow_pipeline_internal: true,
      action_authorization: %{action_module: __MODULE__}
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
