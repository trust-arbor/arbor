defmodule Arbor.Common.ExtensionEnvelopesTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.ExtensionEnvelopes
  alias Arbor.Contracts.Extension.Envelope

  test "runtime consumes handle, transaction, receipt, and invocation envelopes" do
    for kind <- [
          :provider_handle,
          :activation_transaction,
          :activation_receipt,
          :invocation_request,
          :invocation_result
        ] do
      fixture = Envelope.fixture(kind)
      assert {:ok, ^fixture} = ExtensionEnvelopes.validate(kind, fixture)
      assert {:ok, _} = ExtensionEnvelopes.validate_signed(Envelope.signed_fixture(kind))
    end
  end

  test "runtime refuses authorization envelopes and executable handle identity" do
    assert {:error, :unsupported_kind} =
             ExtensionEnvelopes.validate(
               :activation_authorization,
               Envelope.fixture(:activation_authorization)
             )

    handle = Envelope.fixture(:provider_handle)

    assert {:error, :invalid_envelope_shape} =
             ExtensionEnvelopes.validate(
               :provider_handle,
               Map.put(handle, "module", "Elixir.Foo")
             )
  end
end
