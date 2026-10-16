defmodule Arbor.Security.Identity.DefaultRegistrationPolicySecurityRegressionTest do
  @moduledoc """
  Exercises the default policy through public registration, with a supplemental
  agent-policy assertion. At this revision public agent registration rejects
  unauthenticated actors before the policy is reached; changing only the policy
  to allow cannot reopen that earlier gate. The OIDC case reaches the real
  default policy and is falsifiable by an allow-all policy implementation.
  """
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.Identity.DefaultRegistrationPolicy

  @moduletag :fast

  setup do
    for key <- [:registration_policy, :oidc_registration_mode, :oidc] do
      previous = Application.fetch_env(:arbor_security, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_security, key, value)
          :error -> Application.delete_env(:arbor_security, key)
        end
      end)
    end

    Application.delete_env(:arbor_security, :registration_policy)
    Application.put_env(:arbor_security, :oidc_registration_mode, :allowlist)
    Application.put_env(:arbor_security, :oidc, providers: [])
    :ok
  end

  test "security regression: DefaultRegistrationPolicy refuses unverified agent registration" do
    {:ok, identity} = Security.generate_identity()

    assert {:error, :identity_registration_unauthorized} = Security.register_identity(identity)
    assert {:error, _} = Security.register_identity(identity, %{})
    assert {:error, :not_found} = Security.lookup_public_key(identity.agent_id)

    assert {:error, :registration_actor_required} =
             DefaultRegistrationPolicy.authorize_registration(identity, [])
  end

  test "security regression: public OIDC registration enforces DefaultRegistrationPolicy allowlist" do
    oidc = Security.OIDCTestHelper.issue_identity()

    on_exit(fn ->
      oidc.cleanup.()
      Security.deregister_identity_fixture(oidc.identity.agent_id)
    end)

    assert {:error, {:registration_denied, :oidc_subject_not_allowlisted}} =
             Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    assert {:error, :not_found} = Security.lookup_public_key(oidc.identity.agent_id)
  end
end
