defmodule Arbor.Gateway.MCP.IdentityRegistryUnavailableSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-007"

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Gateway.MCP.Handler
  alias Arbor.Security

  @moduletag :fast

  defmodule UnavailableIdentitySecurity do
    def identity_active?(_agent_id), do: exit(:identity_registry_unavailable)
  end

  setup do
    previous_security = Application.fetch_env(:arbor_gateway, :security_module)
    previous_agent = Process.get(:arbor_authenticated_agent_id)

    {:ok, identity} = Identity.generate(name: "Gateway registry gap regression")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    on_exit(fn ->
      _ = Security.deregister_identity_fixture(identity.agent_id)
      restore_env(:security_module, previous_security)

      if is_nil(previous_agent) do
        Process.delete(:arbor_authenticated_agent_id)
      else
        Process.put(:arbor_authenticated_agent_id, previous_agent)
      end
    end)

    %{identity: identity}
  end

  @tag spec: "SSEC-007"
  test "security regression: arbor_run denies a verified principal during an identity registry gap",
       %{identity: identity} do
    Process.put(:arbor_authenticated_agent_id, identity.agent_id)
    Application.put_env(:arbor_gateway, :security_module, UnavailableIdentitySecurity)

    assert {:ok, %{content: [%{type: "text", text: text}]}, %{}} =
             Handler.handle_call_tool(
               "arbor_run",
               %{"action" => "nonexistent_action", "params" => %{}},
               %{}
             )

    assert text =~ "## Unauthorized"
    assert text =~ "identity verification failed"
    refute text =~ "not found"
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_gateway, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_gateway, key)
end
