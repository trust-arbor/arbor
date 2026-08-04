defmodule Arbor.Security.ExactCapabilityExerciseTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry

  @session_id "session_0123456789abcdef0123456789abcdef"
  @resource "arbor://voice/realtime/xai/#{@session_id}"
  @scope "human_exact_capability_test"
  @destination "api.x.ai"

  setup do
    previous = %{
      identity_verification: Application.fetch_env(:arbor_security, :identity_verification),
      strict_identity_mode: Application.fetch_env(:arbor_security, :strict_identity_mode)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, true)

    {:ok, identity} = Identity.generate(name: "exact-capability-exercise")
    :ok = Registry.register(identity)

    on_exit(fn ->
      restore_env(:identity_verification, previous.identity_verification)
      restore_env(:strict_identity_mode, previous.strict_identity_mode)
    end)

    {:ok, agent_id: identity.agent_id}
  end

  test "source-owned exact capability path keeps active identity checks but omits request proof",
       %{
         agent_id: agent_id
       } do
    capability_id = grant_route_capability(agent_id, @resource)

    assert {:error, :missing_signed_request} =
             Security.authorize(agent_id, @resource, :connect,
               exact_capability_id: capability_id,
               session_id: @session_id,
               task_id: nil,
               principal_scope: @scope
             )

    assert {:ok, :authorized} = exercise(agent_id, capability_id)
  end

  test "suspended identity cannot exercise an otherwise valid exact capability", %{
    agent_id: agent_id
  } do
    capability_id = grant_route_capability(agent_id, @resource)
    assert :ok = Security.suspend_identity(agent_id, reason: "test")
    on_exit(fn -> Security.resume_identity(agent_id) end)

    assert {:error, :unauthorized} = exercise(agent_id, capability_id)
  end

  test "revoked identity cannot exercise a capability", %{agent_id: agent_id} do
    capability_id = grant_route_capability(agent_id, @resource)
    assert :ok = Security.revoke_identity(agent_id, reason: "test")

    assert {:error, :unauthorized} = exercise(agent_id, capability_id)
  end

  test "unknown identity is denied even when strict identity mode is disabled" do
    unknown_id = "agent_ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    capability_id = grant_route_capability(unknown_id, @resource)
    Application.put_env(:arbor_security, :strict_identity_mode, false)

    assert {:error, :unauthorized} = exercise(unknown_id, capability_id)
  end

  test "a broad or forged capability id cannot substitute for the intended exact capability", %{
    agent_id: agent_id
  } do
    exact_id = grant_route_capability(agent_id, @resource)
    broad_id = grant_route_capability(agent_id, "arbor://voice/realtime/xai/**")

    assert {:error, :unauthorized} = exercise(agent_id, broad_id)
    assert {:error, :unauthorized} = exercise(agent_id, "cap_ffffffffffffffffffffffffffffffff")
    assert {:ok, :authorized} = exercise(agent_id, exact_id)
  end

  test "the signed capability must carry the exact expected egress tier and destination", %{
    agent_id: agent_id
  } do
    wrong_destination_id =
      grant_route_capability(agent_id, @resource, destination: "attacker.invalid")

    assert {:error, :unauthorized} = exercise(agent_id, wrong_destination_id)
  end

  test "max-use accounting remains on the normal authorization side-effect path", %{
    agent_id: agent_id
  } do
    capability_id = grant_route_capability(agent_id, @resource, max_uses: 1)

    assert {:ok, :authorized} = exercise(agent_id, capability_id)
    assert {:error, :unauthorized} = exercise(agent_id, capability_id)
  end

  test "expectation maps are closed and atom-keyed", %{agent_id: agent_id} do
    capability_id = grant_route_capability(agent_id, @resource)

    assert {:error, :invalid_request} =
             Security.authorize_source_owned_exact_ordinary_capability(
               agent_id,
               @resource,
               :connect,
               capability_id,
               Map.put(expectations(), :provider, "xai")
             )

    assert {:error, :invalid_request} =
             Security.authorize_source_owned_exact_ordinary_capability(
               agent_id,
               @resource,
               :connect,
               capability_id,
               %{"session_id" => @session_id}
             )
  end

  defp exercise(agent_id, capability_id) do
    Security.authorize_source_owned_exact_ordinary_capability(
      agent_id,
      @resource,
      :connect,
      capability_id,
      expectations()
    )
  end

  defp expectations do
    %{
      session_id: @session_id,
      task_id: nil,
      principal_scope: @scope,
      expected_egress: %{max_tier: :external_provider, destination: @destination}
    }
  end

  defp grant_route_capability(agent_id, resource, opts \\ []) do
    destination = Keyword.get(opts, :destination, @destination)

    grant_opts = [
      principal: agent_id,
      resource: resource,
      delegation_depth: 0,
      session_id: @session_id,
      task_id: nil,
      principal_scope: @scope,
      constraints: %{
        egress: %{max_tier: :external_provider, destinations: [destination]}
      }
    ]

    grant_opts =
      case Keyword.fetch(opts, :max_uses) do
        {:ok, max_uses} -> Keyword.put(grant_opts, :max_uses, max_uses)
        :error -> grant_opts
      end

    assert {:ok, capability_id} = Security.grant_capability_id(grant_opts)
    on_exit(fn -> Security.revoke(capability_id) end)
    capability_id
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_security, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_security, key)
end
