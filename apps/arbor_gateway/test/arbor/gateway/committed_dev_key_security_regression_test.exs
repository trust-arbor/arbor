defmodule Arbor.Gateway.CommittedDevKeySecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check group X, 2026-10-23): config/dev.exs
  ships the well-known literal `arbor-dev-key`, and nothing refused that key
  outside `:dev` or when the gateway bound a non-loopback address.

  Symantec Skynet (https://www.security.com/threat-intelligence/ai-llmjacking-skynet)
  sprays known keys at exposed AI gateways. A prod-like Mix env, or
  `MIX_ENV=dev` bound to `0.0.0.0`, must not authenticate that literal.

  Pre-fix: Application.start succeeds and `Auth` accepts `arbor-dev-key`
  under `MIX_ENV=test` (not `:dev`) and with `bind_ip: {0, 0, 0, 0}`.
  Post-fix: boot fails or Auth rejects with a clear development-key error.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Arbor.Gateway.Application, as: GatewayApplication
  alias Arbor.Gateway.Auth
  alias Arbor.Gateway.CommittedDevKey

  @moduletag :fast

  @dev_key "arbor-dev-key"
  @opts Auth.init([])

  setup do
    prev_app = Application.get_env(:arbor_gateway, :api_key)
    prev_bind = Application.get_env(:arbor_gateway, :bind_ip)
    prev_env = System.get_env("ARBOR_GATEWAY_API_KEY")

    on_exit(fn ->
      restore_app(:api_key, prev_app)
      restore_app(:bind_ip, prev_bind)

      case prev_env do
        nil -> System.delete_env("ARBOR_GATEWAY_API_KEY")
        value -> System.put_env("ARBOR_GATEWAY_API_KEY", value)
      end
    end)

    System.delete_env("ARBOR_GATEWAY_API_KEY")
    :ok
  end

  test "security regression: prod-like MIX_ENV with arbor-dev-key must not authenticate" do
    # MIX_ENV=test is not :dev. The committed literal must not be a working
    # credential here — Skynet-class scanners try exactly this key.
    assert Mix.env() != :dev
    assert {:ok, _} = Application.ensure_all_started(:arbor_gateway)

    Application.put_env(:arbor_gateway, :api_key, @dev_key)
    Application.put_env(:arbor_gateway, :bind_ip, {127, 0, 0, 1})

    conn = authenticate(@dev_key)

    assert conn.halted,
           "arbor-dev-key must be refused outside :dev (got through to status=#{inspect(conn.status)})"

    assert conn.status in [401, 503]
    body = Jason.decode!(conn.resp_body)
    assert_clear_dev_key_error(body)
  end

  test "security regression: non-loopback bind with arbor-dev-key must not authenticate" do
    assert Mix.env() != :dev
    assert {:ok, _} = Application.ensure_all_started(:arbor_gateway)

    Application.put_env(:arbor_gateway, :api_key, @dev_key)
    Application.put_env(:arbor_gateway, :bind_ip, {0, 0, 0, 0})

    conn = authenticate(@dev_key)

    assert conn.halted,
           "arbor-dev-key must be refused on a non-loopback bind (got through to status=#{inspect(conn.status)})"

    assert conn.status in [401, 503]
    body = Jason.decode!(conn.resp_body)
    assert_clear_dev_key_error(body)
  end

  test "security regression: ARBOR_GATEWAY_API_KEY=arbor-dev-key is also refused outside :dev" do
    assert Mix.env() != :dev
    Application.put_env(:arbor_gateway, :api_key, "unique-operator-key")
    Application.put_env(:arbor_gateway, :bind_ip, {127, 0, 0, 1})
    System.put_env("ARBOR_GATEWAY_API_KEY", @dev_key)

    conn = authenticate(@dev_key)

    assert conn.halted
    assert conn.status in [401, 503]
    assert_clear_dev_key_error(Jason.decode!(conn.resp_body))
  end

  test "a unique production-like key still authenticates outside :dev" do
    Application.put_env(:arbor_gateway, :api_key, "unique-prod-like-key")
    Application.put_env(:arbor_gateway, :bind_ip, {127, 0, 0, 1})

    conn = authenticate("unique-prod-like-key")
    refute conn.halted
  end

  test "security regression: :dev plus loopback is the only admission for arbor-dev-key" do
    assert :ok =
             CommittedDevKey.admit(
               api_key: @dev_key,
               env: :dev,
               bind_ip: {127, 0, 0, 1}
             )

    assert {:error, not_prod} =
             CommittedDevKey.admit(
               api_key: @dev_key,
               env: :prod,
               bind_ip: {127, 0, 0, 1}
             )

    assert not_prod =~ "arbor-dev-key"
    assert not_prod =~ ":prod"

    assert {:error, not_test} =
             CommittedDevKey.admit(
               api_key: @dev_key,
               env: :test,
               bind_ip: {127, 0, 0, 1}
             )

    assert not_test =~ ":test"

    assert {:error, any_iface} =
             CommittedDevKey.admit(
               api_key: @dev_key,
               env: :dev,
               bind_ip: {0, 0, 0, 0}
             )

    assert any_iface =~ "non-loopback"
    assert any_iface =~ "arbor-dev-key"

    assert {:error, lan} =
             CommittedDevKey.admit(
               api_key: @dev_key,
               env: :dev,
               bind_ip: {10, 0, 0, 5}
             )

    assert lan =~ "non-loopback"

    assert :ok =
             CommittedDevKey.admit(
               api_key: "unique-prod-like-key",
               env: :prod,
               bind_ip: {0, 0, 0, 0}
             )
  end

  test "security regression: boot_check fails prod-like config with arbor-dev-key" do
    assert {:error, {:committed_dev_key_refused, message}} =
             CommittedDevKey.boot_check(
               api_key: @dev_key,
               env: :prod,
               bind_ip: {127, 0, 0, 1}
             )

    assert message =~ "arbor-dev-key"
    assert message =~ "ARBOR_GATEWAY_API_KEY"

    assert :ok =
             CommittedDevKey.boot_check(
               api_key: "unique-prod-like-key",
               env: :prod,
               bind_ip: {0, 0, 0, 0}
             )

    assert :ok =
             CommittedDevKey.boot_check(
               api_key: @dev_key,
               env: :dev,
               bind_ip: {127, 0, 0, 1}
             )
  end

  test "security regression: localhost is a documented loopback bind" do
    # :inet.parse_address("localhost") returns {:error, :einval}, not :error.
    # A :error-only clause raises CaseClauseError and breaks :dev + localhost.
    assert CommittedDevKey.loopback_bind?("localhost")
    assert CommittedDevKey.loopback_bind?("LocalHost")
    assert CommittedDevKey.loopback_bind?("127.0.0.1")
    assert CommittedDevKey.loopback_bind?("[::1]")

    assert :ok =
             CommittedDevKey.admit(
               api_key: @dev_key,
               env: :dev,
               bind_ip: "localhost"
             )
  end

  test "security regression: Auth 503 does not leak Mix env or bind address" do
    assert Mix.env() != :dev
    Application.put_env(:arbor_gateway, :api_key, @dev_key)
    Application.put_env(:arbor_gateway, :bind_ip, {203, 0, 113, 10})

    {conn, log} =
      with_log(fn ->
        authenticate(@dev_key)
      end)

    assert conn.halted
    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    combined = "#{body["error"]} #{body["detail"]}"

    refute combined =~ "MIX_ENV"
    refute combined =~ ":test"
    refute combined =~ ":prod"
    refute combined =~ "203, 0, 113, 10"
    refute combined =~ "203.0.113.10"
    assert combined =~ "Committed development API key refused"

    assert log =~ "arbor-dev-key" or log =~ "203, 0, 113, 10" or log =~ "MIX_ENV",
           "server logs must keep the refusal detail, got #{inspect(log)}"
  end

  test "security regression: Application.start/2 refuses arbor-dev-key outside :dev" do
    assert Mix.env() != :dev
    Application.put_env(:arbor_gateway, :api_key, @dev_key)
    Application.put_env(:arbor_gateway, :bind_ip, {127, 0, 0, 1})

    assert {:error, {:committed_dev_key_refused, message}} =
             GatewayApplication.start(:normal, [])

    assert message =~ "arbor-dev-key"
    assert {:ok, _} = Application.ensure_all_started(:arbor_gateway)

    Application.put_env(:arbor_gateway, :api_key, "unique-prod-like-key")

    result = GatewayApplication.start(:normal, [])
    refute match?({:error, {:committed_dev_key_refused, _}}, result)
  end

  defp authenticate(key) do
    conn(:get, "/")
    |> put_req_header("x-api-key", key)
    |> Auth.call(@opts)
  end

  defp assert_clear_dev_key_error(body) when is_map(body) do
    combined = "#{body["error"]} #{body["detail"]}"

    named? =
      String.contains?(combined, "arbor-dev-key") or
        String.contains?(combined, "development API key") or
        String.contains?(combined, "committed development")

    assert named?, "refusal must name the development key, got #{inspect(body)}"

    refute String.contains?(combined, "Invalid API key"),
           "refusal must not hide behind a generic invalid-key message: #{inspect(body)}"

    refute String.contains?(combined, "MIX_ENV"),
           "HTTP body must not reveal Mix env: #{inspect(body)}"

    refute String.contains?(combined, ":test"),
           "HTTP body must not reveal Mix env: #{inspect(body)}"

    refute String.contains?(combined, "{0, 0, 0, 0}"),
           "HTTP body must not reveal bind address: #{inspect(body)}"
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbor_gateway, key)
  defp restore_app(key, value), do: Application.put_env(:arbor_gateway, key, value)
end
