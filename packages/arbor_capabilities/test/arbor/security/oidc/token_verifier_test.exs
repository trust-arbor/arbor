defmodule Arbor.Security.OIDC.TokenVerifierTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.OAuth.HttpClient.{Request, Response}
  alias Arbor.Security.OIDC.JwksCache
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.OIDCTestHelper

  @moduletag :fast

  defmodule RotatedJwksClient do
    def request(%Request{}) do
      %{jwks: jwks, counter: counter} =
        Application.fetch_env!(:arbor_capabilities, :rotated_jwks_test_fixture)

      Agent.update(counter, &(&1 + 1))
      {:ok, %Response{status: 200, body: Jason.encode!(jwks)}}
    end
  end

  describe "host cache ownership and rotation" do
    test "security regression: a cached kid miss refetches rotated JWKS once" do
      fixture = OIDCTestHelper.issue_identity()

      provider =
        Map.merge(fixture.provider, %{
          endpoints: %{jwks_uri: fixture.provider.issuer <> "/jwks"},
          http_client: RotatedJwksClient
        })

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Application.put_env(:arbor_capabilities, :rotated_jwks_test_fixture, %{
        jwks: fixture.jwks,
        counter: counter
      })

      on_exit(fn ->
        Application.delete_env(:arbor_capabilities, :rotated_jwks_test_fixture)
        JwksCache.delete_fixture(provider)
        fixture.cleanup.()
        if Process.alive?(counter), do: Agent.stop(counter)
      end)

      :ok =
        JwksCache.put_fixture(
          provider,
          %{"keys" => [%{"kid" => "retired-key", "kty" => "RSA"}]}
        )

      assert {:ok, claims} = TokenVerifier.verify(fixture.id_token, provider)
      assert claims["sub"] == fixture.claims["sub"]
      assert Agent.get(counter, & &1) == 1
      assert {:ok, ^claims} = TokenVerifier.verify(fixture.id_token, provider)
      assert Agent.get(counter, & &1) == 1
    end

    test "security regression: the supervised JWKS table rejects direct key planting" do
      table = :arbor_oidc_jwks_cache
      assert :ets.info(table, :owner) == Process.whereis(JwksCache)
      assert :ets.info(table, :protection) == :protected

      assert_raise ArgumentError, fn ->
        :ets.insert(
          table,
          {"https://attacker.example", %{"keys" => [%{"kid" => "planted"}]}, :infinity}
        )
      end
    end

    test "security regression: arbitrary cache mutation cannot poison a configured verifier" do
      fixture = OIDCTestHelper.issue_identity()
      on_exit(fixture.cleanup)

      refute function_exported?(JwksCache, :put, 3)
      refute function_exported?(JwksCache, :delete, 1)

      poisoned_provider = Map.put(fixture.provider, :http_client, RotatedJwksClient)

      :ok =
        JwksCache.put_fixture(poisoned_provider, %{
          "keys" => [%{"kid" => "poisoned", "alg" => "not-an-algorithm"}]
        })

      on_exit(fn -> JwksCache.delete_fixture(poisoned_provider) end)

      assert {:ok, claims} = TokenVerifier.verify(fixture.id_token, fixture.provider)
      assert claims["sub"] == fixture.claims["sub"]
    end
  end
end
