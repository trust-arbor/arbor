defmodule Arbor.Gateway.JwtAuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Arbor.Gateway.JwtAuth

  @moduletag :fast

  @opts JwtAuth.init([])

  describe "when no bearer token" do
    test "passes through without modification" do
      conn =
        conn(:get, "/api/test")
        |> JwtAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :agent_id)
      refute Map.has_key?(conn.assigns, :jwt_authenticated)
    end
  end

  describe "when bearer token is not a JWT" do
    test "passes through for API key (no dots)" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Bearer arbor-dev-key")
        |> JwtAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :jwt_authenticated)
    end
  end

  describe "when bearer token looks like JWT" do
    test "passes through when no OIDC providers configured" do
      # Create a fake JWT-shaped token (3 dot-separated parts)
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{
            "iss" => "https://test.example.com",
            "sub" => "user123",
            "exp" => System.os_time(:second) + 3600
          }),
          padding: false
        )

      sig = Base.url_encode64("fake-sig", padding: false)
      token = "#{header}.#{payload}.#{sig}"

      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Bearer #{token}")
        |> JwtAuth.call(@opts)

      # No OIDC providers configured in test → falls through
      refute conn.halted
      refute Map.has_key?(conn.assigns, :jwt_authenticated)
    end
  end

  describe "when no authorization header" do
    test "passes through to API key auth" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("x-api-key", "some-key")
        |> JwtAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :jwt_authenticated)
    end
  end
end
