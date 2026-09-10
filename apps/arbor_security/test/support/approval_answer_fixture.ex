Code.require_file("oidc_test_helper.ex", __DIR__)

defmodule Arbor.Security.TestSupport.ApprovalAnswerFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.Security
  alias Arbor.Security.SessionToken

  def setup! do
    assert :ok = Security.TestBootstrap.start!()

    settings = [
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      uri_registry_enforcement: false,
      session_token_module: SessionToken,
      session_token_secret: "approval-answer-test-secret-#{System.unique_integer([:positive])}"
    ]

    previous =
      Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:arbor_security, key)} end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:arbor_security, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    human = human!()
    {:ok, token} = SessionToken.generate(human)

    %{
      human_id: human,
      token: token,
      agent_id: "agent_answer_#{System.unique_integer([:positive])}"
    }
  end

  def human! do
    oidc = Security.OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    on_exit(fn ->
      assert :ok = Security.deregister_identity(oidc.identity.agent_id)
      oidc.cleanup.()
    end)

    oidc.identity.agent_id
  end

  def grant!(principal, resource, opts \\ []) do
    assert {:ok, cap} = Security.grant([principal: principal, resource: resource] ++ opts)
    on_exit(fn -> Security.revoke(cap.id) end)
    cap
  end
end
