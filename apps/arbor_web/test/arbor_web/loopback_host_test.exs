defmodule Arbor.Web.LoopbackHostTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Arbor.Web.LoopbackHost

  @moduletag :fast

  setup do
    previous_any = Application.get_env(:arbor_web, :dev_allow_any_host)
    previous_hosts = Application.get_env(:arbor_web, :dev_allowed_hosts)

    on_exit(fn ->
      restore(:dev_allow_any_host, previous_any)
      restore(:dev_allowed_hosts, previous_hosts)
    end)

    Application.delete_env(:arbor_web, :dev_allow_any_host)
    Application.delete_env(:arbor_web, :dev_allowed_hosts)
    :ok
  end

  test "allows loopback Host values and rejects a rebinding name" do
    assert LoopbackHost.allowed_host?("localhost")
    assert LoopbackHost.allowed_host?("127.0.0.1")
    assert LoopbackHost.allowed_host?("[::1]")
    assert LoopbackHost.allowed_host?("localhost:4001")
    refute LoopbackHost.allowed_host?("evil.example")
    refute LoopbackHost.allowed_host?("localhost.evil.example")
  end

  test "allowed_origins lists http loopback origins on the configured port" do
    assert LoopbackHost.allowed_origins(4001) == [
             "http://localhost:4001",
             "http://127.0.0.1:4001",
             "http://[::1]:4001"
           ]
  end

  test "enforced? is on for the dashboard unless auth is required or opted out" do
    assert LoopbackHost.enforced?(otp_app: :arbor_dashboard, require_auth: false)
    refute LoopbackHost.enforced?(otp_app: :arbor_dashboard, require_auth: true)
    refute LoopbackHost.enforced?(otp_app: :arbor_dashboard, allow_any_host: true)
    refute LoopbackHost.enforced?(otp_app: :arbor_web)
  end

  test "plug returns 403 for a rebinding Host when dashboard no-auth is enforced" do
    conn =
      conn(:get, "http://evil.example/")
      |> LoopbackHost.call(otp_app: :arbor_dashboard, require_auth: false)

    assert conn.halted
    assert conn.status == 403
  end

  test "plug passes loopback Host through" do
    conn =
      conn(:get, "http://localhost/")
      |> LoopbackHost.call(otp_app: :arbor_dashboard, require_auth: false)

    refute conn.halted
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_web, key)
  defp restore(key, value), do: Application.put_env(:arbor_web, key, value)
end
