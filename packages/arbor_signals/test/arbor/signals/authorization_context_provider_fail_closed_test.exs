defmodule Arbor.Signals.AuthorizationContextProviderFailClosedTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.AuthorizationContext
  alias Arbor.Signals.Channels
  alias Arbor.Signals.Config.Testing
  alias Arbor.Signals.Contracts.AuthContext
  alias __MODULE__.{Exits, Malformed, Missing, OpaqueAuthorization, OpaqueContext, Raises, Throws}

  setup do
    Testing.isolate_namespace()
    Testing.put(:auth_context_module, Arbor.Signals.Adapters.AuthContext)
    :ok
  end

  test "default context adapter accepts its exact type and never an asserted principal map" do
    context = AuthContext.new("principal", signed_request: :bound_proof)

    assert {:ok, "principal"} = AuthorizationContext.principal_id(context)
    assert {:ok, :bound_proof} = AuthorizationContext.signed_request(context)

    refute AuthorizationContext.valid?(%{principal_id: "principal", signed_request: :bound_proof})
    assert {:error, :authenticated_principal_required} = AuthorizationContext.principal_id(nil)
    assert {:error, :identity_proof_required} = AuthorizationContext.signed_request(nil)
  end

  test "missing proof remains a refusal even for a recognized context type" do
    context = AuthContext.new("principal")
    assert AuthorizationContext.valid?(context)
    assert {:error, :identity_proof_required} = AuthorizationContext.signed_request(context)
  end

  test "a configured opaque credential supports channel operations without admitting asserted identities" do
    Arbor.Signals.TestSupport.Case.ensure_processes()
    token = make_ref()
    context = {:opaque_context, token}
    before = Channels.stats()

    assert {:error, :authenticated_principal_required} = Channels.create("opaque-denied", context)

    assert {:error, :authenticated_principal_required} =
             Channels.create("map-denied", %{principal_id: "opaque-principal"})

    assert Channels.stats() == before

    Testing.put(:auth_context_module, OpaqueContext)
    Testing.put(:security_module, OpaqueAuthorization)
    Testing.put(:channel_principal_authorizer, Arbor.Signals.Adapters.CapabilityAuthorizer)
    Testing.put(:opaque_context_token, token)

    assert {:error, :authenticated_principal_required} =
             Channels.create("wrong-token-denied", {:opaque_context, make_ref()})

    assert {:ok, channel, :server_managed} = Channels.create("opaque-authorized", context)
    assert channel.creator_id == "opaque-principal"
    Testing.put(:opaque_channel_id, channel.id)

    on_exit(fn ->
      Testing.put(:auth_context_module, OpaqueContext)
      Testing.put(:security_module, OpaqueAuthorization)
      Testing.put(:channel_principal_authorizer, Arbor.Signals.Adapters.CapabilityAuthorizer)
      Testing.put(:opaque_context_token, token)
      Testing.put(:opaque_channel_id, channel.id)
      _ = Channels.leave(channel.id, context)
    end)

    assert :ok = Channels.send(channel.id, context, :opaque_message, %{value: 42})
    assert :ok = Channels.leave(channel.id, context)
    assert {:error, :not_found} = Channels.get(channel.id)
  end

  test "absent, malformed and failing context providers do not fall back to a local identity" do
    context = AuthContext.new("principal", signed_request: :bound_proof)

    for provider <- [nil, true, "not-a-module", Missing, Raises, Throws, Exits, Malformed] do
      Testing.put(:auth_context_module, provider)
      refute AuthorizationContext.valid?(context)

      assert {:error, :authenticated_principal_required} =
               AuthorizationContext.principal_id(context)

      assert {:error, :identity_proof_required} = AuthorizationContext.signed_request(context)
    end
  end

  defmodule Missing do
  end

  defmodule OpaqueContext do
    @moduledoc false
    @behaviour Arbor.Signals.Contracts.AuthorizationContext

    @impl true
    def principal_id({:opaque_context, token}) when is_reference(token) do
      if Testing.get(:opaque_context_token) == token,
        do: {:ok, "opaque-principal"},
        else: {:error, :invalid_context}
    end

    def principal_id(_context), do: {:error, :invalid_context}

    @impl true
    def signed_request({:opaque_context, token} = context) do
      with {:ok, _principal} <- principal_id(context), do: {:ok, {:opaque_proof, token}}
    end

    def signed_request(_context), do: {:error, :invalid_context}
  end

  defmodule OpaqueAuthorization do
    @moduledoc false
    @behaviour Arbor.Signals.Contracts.Authorization

    @impl true
    def authorize("opaque-principal", resource, operation,
          signed_request: {:opaque_proof, token},
          verify_identity: true
        )
        when operation in [:create, :send, :leave] do
      expected_resource =
        case operation do
          :create ->
            "arbor://signals/channel/create"

          _ ->
            digest =
              :crypto.hash(:sha256, Testing.get(:opaque_channel_id))
              |> Base.encode16(case: :lower)

            "arbor://signals/channel/#{operation}/#{digest}"
        end

      if token == Testing.get(:opaque_context_token) and resource == expected_resource,
        do: {:ok, :authorized},
        else: {:error, :unauthorized}
    end

    def authorize(_principal, _resource, _operation, _opts), do: {:error, :unauthorized}
  end

  defmodule Raises do
    def principal_id(_context), do: raise("unavailable context provider")
    def signed_request(_context), do: raise("unavailable context provider")
  end

  defmodule Throws do
    def principal_id(_context), do: throw(:unavailable)
    def signed_request(_context), do: throw(:unavailable)
  end

  defmodule Exits do
    def principal_id(_context), do: exit(:unavailable)
    def signed_request(_context), do: exit(:unavailable)
  end

  defmodule Malformed do
    def principal_id(_context), do: {:ok, ""}
    def signed_request(_context), do: {:ok, nil}
  end
end
