defmodule Arbor.Agent.Orchestration.TemplateAuthorityPreviewTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.TemplateAuthorityPreviewCore

  defmodule FakeSecurity do
    def authorize(actor, resource_uri, action, opts) do
      send(self(), {:authorize, actor, resource_uri, action, opts})
      Process.get({__MODULE__, :result}, {:ok, :authorized})
    end

    def grant(opts) do
      send(self(), {:grant, opts})
      flunk("template authority preview must not grant")
    end

    def revoke(id) do
      send(self(), {:revoke, id})
      flunk("template authority preview must not revoke")
    end

    def list_capabilities(principal_id, opts \\ []) do
      send(self(), {:list_capabilities, principal_id, opts})
      flunk("orchestration must not reach security list via preview double")
    end
  end

  defmodule ScopedThenGlobalSecurity do
    def authorize(actor, resource_uri, action, opts) do
      send(self(), {:authorize, actor, resource_uri, action, opts})

      case resource_uri do
        "arbor://agent/dispatch/agent_preview1" ->
          {:error, :no_capability}

        "arbor://agent/dispatch" ->
          {:ok, :authorized}

        _ ->
          {:error, :no_capability}
      end
    end
  end

  defmodule PreviewDouble do
    def project(target_agent_id, opts) do
      send(self(), {:preview_project, target_agent_id, opts})

      {:ok,
       TemplateAuthorityPreviewCore.diagnostic_report(
         status: "unavailable",
         target_agent_id: target_agent_id,
         code: "test_double"
       )}
    end
  end

  defmodule MutatingPreviewDouble do
    def project(target_agent_id, opts) do
      send(self(), {:preview_project, target_agent_id, opts})
      # If this double is selected, it must still be read-only from orch's view.
      {:ok,
       TemplateAuthorityPreviewCore.diagnostic_report(
         status: "unmanaged",
         target_agent_id: target_agent_id,
         code: "mutating_double"
       )}
    end
  end

  setup do
    Process.delete({FakeSecurity, :result})
    :ok
  end

  test "scoped dispatch authorization succeeds without falling through to global" do
    Process.put({FakeSecurity, :result}, {:ok, :authorized})

    assert {:ok, report} =
             Orchestration.template_authority_preview("agent_preview1",
               caller_id: "human_1",
               security_module: FakeSecurity,
               template_authority_preview_module: PreviewDouble
             )

    assert_received {:authorize, "human_1", "arbor://agent/dispatch/agent_preview1", :execute, _}
    refute_received {:authorize, "human_1", "arbor://agent/dispatch", :execute, _}
    assert report["kind"] == "template_authority_preview"
    assert report["target_agent_id"] == "agent_preview1"
  end

  test "global dispatch authorization is the fallback when scoped is denied" do
    assert {:ok, report} =
             Orchestration.template_authority_preview("agent_preview1",
               caller_id: "human_1",
               security_module: ScopedThenGlobalSecurity,
               template_authority_preview_module: PreviewDouble
             )

    assert_received {:authorize, "human_1", "arbor://agent/dispatch/agent_preview1", :execute, _}
    assert_received {:authorize, "human_1", "arbor://agent/dispatch", :execute, _}
    assert report["status"] == "unavailable"
  end

  test "authorization denial never invokes the preview shell" do
    Process.put({FakeSecurity, :result}, {:error, :no_capability})

    assert {:error, {:unauthorized, :agent_dispatch_required}} =
             Orchestration.template_authority_preview("agent_preview1",
               caller_id: "human_1",
               security_module: FakeSecurity,
               template_authority_preview_module: PreviewDouble
             )

    assert_received {:authorize, "human_1", "arbor://agent/dispatch/agent_preview1", :execute, _}
    assert_received {:authorize, "human_1", "arbor://agent/dispatch", :execute, _}
    refute_received {:preview_project, _, _}
  end

  test "session token reaches authorize only; shell receives caller_id alone" do
    Process.put({FakeSecurity, :result}, {:ok, :authorized})

    assert {:ok, _report} =
             Orchestration.template_authority_preview("agent_preview1",
               caller_id: "human_1",
               session_token: "secret_proof_token",
               security_module: FakeSecurity,
               template_authority_preview_module: PreviewDouble,
               # Selectors must not leak into the shell opts either.
               audit_module: FakeSecurity
             )

    assert_received {:authorize, "human_1", "arbor://agent/dispatch/agent_preview1", :execute,
                     auth_opts}

    assert Keyword.get(auth_opts, :session_token) == "secret_proof_token"

    assert_received {:preview_project, "agent_preview1", shell_opts}
    assert shell_opts == [caller_id: "human_1"]
    refute Keyword.has_key?(shell_opts, :session_token)
    refute Keyword.has_key?(shell_opts, :security_module)
    refute Keyword.has_key?(shell_opts, :template_authority_preview_module)
    refute Keyword.has_key?(shell_opts, :audit_module)
    refute inspect(shell_opts) =~ "secret_proof_token"
  end

  test "preview module injection is confined to the test-doubles gate truth table" do
    # Pure compile-gate table — production beams cannot enable per-call selectors.
    assert Orchestration.orchestration_test_doubles_allowed?(false, true) == false
    assert Orchestration.orchestration_test_doubles_allowed?(false, false) == false
    assert Orchestration.orchestration_test_doubles_allowed?(true, true) == true
    assert Orchestration.orchestration_test_doubles_allowed?(true, false) == false
  end

  test "authorized preview path performs zero grants, revokes, or list side effects" do
    Process.put({FakeSecurity, :result}, {:ok, :authorized})

    assert {:ok, report} =
             Orchestration.template_authority_preview("agent_preview1",
               caller_id: "human_1",
               security_module: FakeSecurity,
               template_authority_preview_module: MutatingPreviewDouble
             )

    assert report["kind"] == "template_authority_preview"
    refute_received {:grant, _}
    refute_received {:revoke, _}
    refute_received {:list_capabilities, _, _}
  end
end
