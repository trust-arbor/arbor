defmodule Arbor.Dashboard.AuthTest do
  # async: false — toggles :arbor_dashboard app env (auth credentials).
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Arbor.Dashboard.Auth

  @moduletag :fast
  @opts Auth.init([])

  setup do
    prev_user = Application.get_env(:arbor_dashboard, :auth_user)
    prev_pass = Application.get_env(:arbor_dashboard, :auth_pass)

    on_exit(fn ->
      restore(:auth_user, prev_user)
      restore(:auth_pass, prev_pass)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_dashboard, key)
  defp restore(key, val), do: Application.put_env(:arbor_dashboard, key, val)

  defp basic(user, pass), do: "Basic " <> Base.encode64("#{user}:#{pass}")

  # H6 (2026-02-16 review): the dashboard BasicAuth plug must ENFORCE configured
  # credentials and compare them in constant time (Plug.Crypto.secure_compare).
  #
  # Scope note: the constant-time property itself can't be asserted behaviorally
  # — a regression from secure_compare back to `==` is invisible to a functional
  # test (both reject wrong creds). These tests guard the *enforcement* behavior
  # (configured creds → wrong/missing credentials are rejected; correct pass),
  # which catches the larger regression class of the auth check being weakened or
  # removed. The constant-time comparison remains a code-review invariant.
  describe "H6: dashboard basic-auth enforcement (regression)" do
    setup do
      Application.put_env(:arbor_dashboard, :auth_user, "arbor")
      Application.put_env(:arbor_dashboard, :auth_pass, "s3cret")
      :ok
    end

    test "security regression (H6): correct credentials are allowed through" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", basic("arbor", "s3cret"))
        |> Auth.call(@opts)

      refute conn.halted, "correct credentials must pass the auth plug"
    end

    test "security regression (H6): a wrong password is rejected (401)" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", basic("arbor", "wrong"))
        |> Auth.call(@opts)

      assert conn.halted and conn.status == 401,
             "wrong password must be rejected — H6 regression. Got halted=#{conn.halted}, status=#{conn.status}"
    end

    test "security regression (H6): a wrong username is rejected (401)" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", basic("intruder", "s3cret"))
        |> Auth.call(@opts)

      assert conn.halted and conn.status == 401
    end

    test "security regression (H6): a request with no credentials is rejected (401)" do
      conn = conn(:get, "/") |> Auth.call(@opts)

      assert conn.halted and conn.status == 401,
             "missing credentials must be rejected when auth is configured — H6 regression"
    end
  end
end
