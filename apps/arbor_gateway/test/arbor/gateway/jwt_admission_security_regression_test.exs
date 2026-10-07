defmodule Arbor.Gateway.JwtAdmissionSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "SSEC-007,SSEC-009"

  import Plug.Conn
  import Plug.Test

  alias Arbor.Gateway.JwtAuth

  @moduletag :fast
  @moduletag :security_regression

  defmodule SecurityFacadeStub do
    def authenticate_oidc_token("header.inactive.signature" = token) do
      send(self(), {:oidc_token_authenticated, token})
      {:ok, "human_inactive", {:temporary_authority, :inactive}}
    end

    def authenticate_oidc_token("header.active.signature" = token) do
      send(self(), {:oidc_token_authenticated, token})
      {:ok, "human_active", {:temporary_authority, :active}}
    end

    def authenticate_oidc_token("header.close-failure.signature" = token) do
      send(self(), {:oidc_token_authenticated, token})
      {:ok, "human_active", {:temporary_authority, :close_failure}}
    end

    def identity_active?(agent_id) do
      send(self(), {:identity_status_checked, agent_id})
      agent_id == "human_active"
    end

    def close_signing_authority(authority) do
      send(self(), {:temporary_authority_closed, authority})

      case authority do
        {:temporary_authority, :close_failure} -> {:error, :forced_close_failure}
        _ -> :ok
      end
    end
  end

  @opts JwtAuth.init(security_facade: SecurityFacadeStub)

  @tag spec: "SSEC-007,SSEC-009"
  test "security regression: a verified token cannot bypass registered active identity admission" do
    conn = authenticate("header.inactive.signature")

    assert_received {:oidc_token_authenticated, "header.inactive.signature"}
    assert_received {:identity_status_checked, "human_inactive"}
    assert_received {:temporary_authority_closed, {:temporary_authority, :inactive}}
    refute Map.has_key?(conn.assigns, :agent_id)
    refute Map.has_key?(conn.assigns, :jwt_authenticated)
  end

  test "an admitted active identity is assigned after its temporary authority is closed" do
    conn = authenticate("header.active.signature")

    assert_received {:identity_status_checked, "human_active"}
    assert_received {:temporary_authority_closed, {:temporary_authority, :active}}
    assert conn.assigns.agent_id == "human_active"
    assert conn.assigns.jwt_authenticated
  end

  test "security regression: authority cleanup failure denies JWT admission" do
    conn = authenticate("header.close-failure.signature")

    assert_received {:temporary_authority_closed, {:temporary_authority, :close_failure}}
    refute Map.has_key?(conn.assigns, :agent_id)
    refute Map.has_key?(conn.assigns, :jwt_authenticated)
  end

  defp authenticate(token) do
    conn(:get, "/api/test")
    |> put_req_header("authorization", "Bearer #{token}")
    |> JwtAuth.call(@opts)
  end
end
