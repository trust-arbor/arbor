defmodule Arbor.Common.Extension.InvocationCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Extension.InvocationCore
  alias Arbor.Contracts.Extension.Envelope

  test "admits a matching handle, authorization, and request" do
    {handle, auth, request, bindings} = admitted()

    assert {:ok, [{:consume_nonce, nonce}]} =
             InvocationCore.admit(handle, auth, request, bindings)

    assert nonce == auth["nonce"]
  end

  test "unknown disposition blocks retry unless the protocol is idempotent" do
    {handle, auth, request, bindings} = admitted()

    assert {:error, "effect_disposition_unknown"} =
             InvocationCore.admit(handle, auth, request, %{
               bindings
               | pending_unknown?: true,
                 idempotent?: false
             })

    assert {:ok, _effects} =
             InvocationCore.admit(handle, auth, request, %{
               bindings
               | pending_unknown?: true,
                 idempotent?: true
             })
  end

  defp admitted do
    handle = Envelope.fixture(:provider_handle)
    auth = Envelope.fixture(:invocation_authorization)
    request = Envelope.fixture(:invocation_request)

    bindings = %{
      now: "2026-08-16T00:00:00Z",
      request_digest: request["request_sha256"],
      signature_status: :verified,
      consumed_nonces: MapSet.new(),
      revoked?: false,
      pending_unknown?: false,
      idempotent?: false
    }

    {handle, auth, request, bindings}
  end
end
