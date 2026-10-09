defmodule Arbor.Dashboard.Live.AgentsManagementSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false
  alias Arbor.Agent.Test.ManagementSessionFixture, as: Fixture
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  setup_all do
    Fixture.initialize!()
  end

  setup %{root: root} do
    Fixture.setup!(root)
  end

  for {event, operation} <- [{"stop-agent", :stop}, {"delete-agent", :destroy}] do
    test "mounted browser exact-target proof permits #{operation} exactly once", ctx do
      operation = unquote(operation)
      require_browser_auth!()
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)
      {:ok, view, _} = live(session(ctx), "/agents")
      {html, effects} = click(view, unquote(event), target.target)
      assert Enum.count(effects, &(&1 == {operation, target.target})) == 1
      refute Process.alive?(target.pid)
      refute html =~ ctx.token
      Fixture.deleted_if_destroy!(operation, target.target)
    end

    test "security regression: mounted #{operation} cannot select target outside current capability",
         ctx do
      operation = unquote(operation)
      require_browser_auth!()
      permitted = Fixture.target!()
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, permitted.target)
      {:ok, view, _} = live(session(ctx), "/agents")
      {html, effects} = click(view, unquote(event), target.target)
      assert effects == []
      assert html =~ "Agent management was refused."
      Fixture.preserved!(target)
      Fixture.preserved!(permitted)
    end

    test "security regression: mounted #{operation} ignores event proof and dev operator claims",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)

      {:ok, view, _} =
        live(init_test_session(ctx.conn, %{"local_dev_operator" => true}), "/agents")

      params = %{
        "id" => target.target,
        "caller_id" => ctx.human_id,
        "session_token" => ctx.token,
        "identity_verified" => true,
        "local_dev_operator" => true
      }

      {html, effects} =
        Fixture.observe!(view.pid, fn -> render_click(view, unquote(event), params) end)

      assert effects == []
      assert html =~ "Agent management was refused."
      Fixture.preserved!(target)
    end

    test "security regression: mounted #{operation} rejects missing forged mismatched expired and terminal-only sessions",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)
      other = Humans.human!()
      {:ok, mismatch} = Security.SessionToken.generate(other)
      {:ok, expired} = Security.SessionToken.generate_expired_fixture(ctx.human_id)
      {:ok, terminal} = Security.issue_conversation_session_fixture(ctx.human_id, target.target)

      for token <- [nil, "forged", mismatch, expired, terminal] do
        {:ok, view, _} = live(session(%{ctx | token: token}), "/agents")
        {html, effects} = click(view, unquote(event), target.target)
        assert effects == []
        assert html =~ "Agent management was refused."
        Fixture.preserved!(target)
        GenServer.stop(view.pid)
      end
    end

    test "security regression: mounted #{operation} rechecks revoked capability after rendering",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      cap = Fixture.grant!(ctx.human_id, operation, target.target)
      {:ok, view, _} = live(session(ctx), "/agents")
      assert :ok = Security.revoke_fixture(cap.id)
      {html, effects} = click(view, unquote(event), target.target)
      assert effects == []
      assert html =~ "Agent management was refused."
      Fixture.preserved!(target)
    end

    test "security regression: mounted #{operation} reports pending approval without lifecycle effect",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()

      Fixture.grant!(ctx.human_id, operation, target.target,
        constraints: %{requires_approval: true}
      )

      {:ok, view, _} = live(session(ctx), "/agents")
      {html, effects} = click(view, unquote(event), target.target)
      assert effects == []
      assert html =~ "Agent management needs approval."
      Fixture.preserved!(target)
    end
  end

  test "security regression: mounted deletion rechecks revoked human identity", ctx do
    target = Fixture.target!()
    Fixture.grant!(ctx.human_id, :destroy, target.target)
    {:ok, view, _} = live(session(ctx), "/agents")
    assert :ok = Security.revoke_identity_fixture(ctx.human_id, "private mounted fixture")
    {html, effects} = click(view, "delete-agent", target.target)
    assert effects == []
    assert html =~ "Agent management was refused."
    Fixture.preserved!(target)
  end

  defp require_browser_auth! do
    Fixture.set_env(:arbor_security, :oidc,
      providers: [%{issuer: "https://management-session.fixture", client_id: "dashboard"}]
    )

    Fixture.set_env(:arbor_dashboard, :require_auth, true)
    Fixture.set_env(:arbor_dashboard, :session_auth_api, Arbor.Security)
  end

  defp click(view, event, target),
    do: Fixture.observe!(view.pid, fn -> render_click(view, event, %{"id" => target}) end)

  defp session(ctx),
    do: init_test_session(ctx.conn, %{"agent_id" => ctx.human_id, "session_token" => ctx.token})
end
