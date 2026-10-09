Code.require_file("oidc_test_helper.ex", __DIR__)

defmodule Arbor.Security.TestSupport.ApprovalAnswerFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.Security
  alias Arbor.Security.SessionToken

  def setup!(opts \\ []) do
    assert :ok = Security.TestBootstrap.start!()

    settings = [
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      uri_registry_enforcement: false,
      session_token_module: SessionToken,
      session_token_secret: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
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

    human = human!(opts)
    {:ok, token} = SessionToken.generate(human)

    %{
      human_id: human,
      token: token,
      agent_id: "agent_answer_#{System.unique_integer([:positive])}"
    }
  end

  def human!(opts \\ []) do
    oidc = Security.OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    # OIDC registration proves the human and keeps the private key out of the
    # store. Session lifecycle mutations open that stored key, so only the
    # caller that will exercise them deposits the fixture key.
    if Keyword.get(opts, :store_signing_key, false) do
      assert :ok =
               Security.store_signing_key_fixture(
                 oidc.identity.agent_id,
                 oidc.identity.private_key
               )

      on_exit(fn -> Security.delete_signing_key_fixture(oidc.identity.agent_id) end)
    end

    on_exit(fn ->
      assert :ok = Security.deregister_identity_fixture(oidc.identity.agent_id)
      oidc.cleanup.()
    end)

    oidc.identity.agent_id
  end

  def grant!(principal, resource, opts \\ []) do
    assert {:ok, cap} = Security.grant_fixture([principal: principal, resource: resource] ++ opts)
    on_exit(fn -> Security.revoke_fixture(cap.id) end)
    cap
  end
end
