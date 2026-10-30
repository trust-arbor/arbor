defmodule Arbor.Security.OIDCOptionalAdapterSecurityRegressionTest do
  use ExUnit.Case, async: false

  @unavailable {:error, :oidc_adapter_unavailable}

  defmodule CrashedAdapter do
    @moduledoc false
    def prepare_verification(_token, _provider), do: raise("private-adapter-error-canary")

    def build_authorize_url(_provider, _redirect, _state, _opts),
      do: exit({:private_adapter_exit, "private-adapter-error-canary"})
  end

  @tag :fast
  test "security regression: host verification never accepts prepared claims or caller-provided keys" do
    provider = %{issuer: "https://unavailable.idp.invalid", client_id: "arbor"}

    for supplied <- [
          %{"iss" => provider.issuer, "sub" => "caller-claims", "aud" => provider.client_id},
          %{token: "original.signed.token", provider: provider, jwks: %{"keys" => []}}
        ] do
      assert {:error, :invalid_provider_config} =
               Arbor.Security.verify_oidc_token(supplied, provider)
    end
  end

  @tag :fast
  test "security regression: crashed configured adapters are unavailable without exception reflection" do
    original = Application.fetch_env(:arbor_capabilities, :oidc_adapter)

    try do
      Application.put_env(:arbor_capabilities, :oidc_adapter, CrashedAdapter)
      provider = %{issuer: "https://unavailable.idp.invalid", client_id: "arbor"}

      assert @unavailable == Arbor.Security.verify_oidc_token("original.signed.token", provider)

      assert @unavailable ==
               Arbor.Security.build_oidc_authorize_url(
                 provider,
                 "https://owned.invalid/cb",
                 "state"
               )
    after
      case original do
        {:ok, value} -> Application.put_env(:arbor_capabilities, :oidc_adapter, value)
        :error -> Application.delete_env(:arbor_capabilities, :oidc_adapter)
      end
    end
  end
end
