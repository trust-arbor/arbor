defmodule Arbor.Agent.TemplateAuthorityPreviewFacadeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.TemplateAuthorityPreviewCore
  alias Arbor.Agent.TemplateAuthorityPreviewFacade

  defp valid_report do
    TemplateAuthorityPreviewCore.diagnostic_report(
      status: "unmanaged",
      target_agent_id: "agent_ok1",
      template_name: "scout",
      profile_version: 1,
      code: "test"
    )
  end

  test "rejects invalid ids and options" do
    fun = fn _, _ -> {:ok, valid_report()} end

    assert {:error, :invalid_caller_id} =
             TemplateAuthorityPreviewFacade.project("bad", "agent_ok1", [], fun)

    assert {:error, :invalid_agent_id} =
             TemplateAuthorityPreviewFacade.project("human_ok1", "nope", [], fun)

    # Targets are agent-only — human principals are rejected as target_agent_id.
    assert {:error, :invalid_agent_id} =
             TemplateAuthorityPreviewFacade.project("human_ok1", "human_ok1", [], fun)

    assert {:error, :invalid_opts} =
             TemplateAuthorityPreviewFacade.project(
               "human_ok1",
               "agent_ok1",
               [unknown: true],
               fun
             )

    assert {:error, :invalid_opts} =
             TemplateAuthorityPreviewFacade.project(
               "human_ok1",
               "agent_ok1",
               [session_token: ""],
               fun
             )

    assert {:error, :invalid_opts} =
             TemplateAuthorityPreviewFacade.project(
               "human_ok1",
               "agent_ok1",
               [session_token: "a", session_token: "b"],
               fun
             )

    assert {:error, :invalid_opts} =
             TemplateAuthorityPreviewFacade.project(
               "human_ok1",
               "agent_ok1",
               [authorize?: false],
               fun
             )
  end

  test "forwards only caller_id and optional session_token to orchestration" do
    parent = self()

    fun = fn agent_id, opts ->
      send(parent, {:orch, agent_id, opts})
      {:ok, valid_report()}
    end

    assert {:ok, _} =
             TemplateAuthorityPreviewFacade.project("human_ok1", "agent_ok1", [], fun)

    assert_received {:orch, "agent_ok1", opts}
    assert opts == [caller_id: "human_ok1"]
    refute Keyword.has_key?(opts, :session_token)
    refute Keyword.has_key?(opts, :security_module)
  end

  test "unauthorized is closed; session token is forwarded only in orch opts" do
    parent = self()

    fun = fn agent_id, opts ->
      send(parent, {:orch, agent_id, opts})
      {:error, {:unauthorized, :agent_dispatch_required}}
    end

    assert {:error, :unauthorized} =
             TemplateAuthorityPreviewFacade.project(
               "human_ok1",
               "agent_ok1",
               [session_token: "tok_secret_value"],
               fun
             )

    assert_received {:orch, "agent_ok1", opts}
    assert opts[:caller_id] == "human_ok1"
    assert opts[:session_token] == "tok_secret_value"
  end

  test "fixed collaborator path returns bounded report" do
    report = valid_report()
    fun = fn _, _ -> {:ok, report} end

    assert {:ok, ^report} =
             TemplateAuthorityPreviewFacade.project("human_ok1", "agent_ok1", [], fun)
  end

  test "malformed orch return fails closed" do
    fun = fn _, _ -> {:ok, %{atom: :bad}} end

    assert {:error, :preview_failed} =
             TemplateAuthorityPreviewFacade.project("human_ok1", "agent_ok1", [], fun)
  end

  test "public Arbor.Agent.template_authority_preview/3 validates inputs at the boundary" do
    assert {:error, :invalid_caller_id} =
             Arbor.Agent.template_authority_preview("bad", "agent_ok1", [])

    assert {:error, :invalid_agent_id} =
             Arbor.Agent.template_authority_preview("human_ok1", "nope", [])

    assert {:error, :invalid_agent_id} =
             Arbor.Agent.template_authority_preview("human_ok1", "human_ok1", [])

    assert {:error, :invalid_opts} =
             Arbor.Agent.template_authority_preview("human_ok1", "agent_ok1", unknown: true)

    assert {:error, :invalid_opts} =
             Arbor.Agent.template_authority_preview("human_ok1", "agent_ok1", authorize?: false)

    assert {:error, :invalid_opts} =
             Arbor.Agent.template_authority_preview(
               "human_ok1",
               "agent_ok1",
               session_token: nil
             )
  end

  test "public path never accepts dependency injection opts" do
    assert {:error, :invalid_opts} =
             Arbor.Agent.template_authority_preview(
               "human_ok1",
               "agent_ok1",
               security: Arbor.Security,
               profile_store: :fake
             )
  end
end
