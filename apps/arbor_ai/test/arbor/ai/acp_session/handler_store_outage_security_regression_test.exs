defmodule Arbor.AI.AcpSession.HandlerStoreOutageSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.AI.AcpSession.Handler
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    :ok = Security.TestBootstrap.start!()
  end

  test "security regression: missing capability store cannot authorize ACP file access" do
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    for operation <- [:read, :write] do
      assert {:ok, _} =
               Security.grant_fixture(
                 principal: identity.agent_id,
                 resource: "arbor://fs/#{operation}/private/tmp/**"
               )
    end

    previous = Application.fetch_env(:arbor_ai, :file_guard_module)
    Application.delete_env(:arbor_ai, :file_guard_module)

    assert :ok = Handler.authorize_file(identity.agent_id, "/private/tmp/synthetic-input", :read)

    assert :ok =
             Handler.authorize_file(identity.agent_id, "/private/tmp/synthetic-output", :write)

    :ok =
      Supervisor.terminate_child(
        Arbor.Security.Supervisor,
        Arbor.Security.CapabilityStore
      )

    on_exit(fn ->
      :ok = Security.TestBootstrap.start!()

      _ = Security.revoke_all_fixture(identity.agent_id)
      _ = Security.deregister_identity_fixture(identity.agent_id)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_ai, :file_guard_module, value)
        :error -> Application.delete_env(:arbor_ai, :file_guard_module)
      end
    end)

    assert {:error, _reason} =
             Handler.authorize_file(identity.agent_id, "/private/tmp/synthetic-input", :read)

    assert {:error, _reason} =
             Handler.authorize_file(identity.agent_id, "/private/tmp/synthetic-output", :write)
  end
end
