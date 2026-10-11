defmodule Arbor.Comms.Channels.EmailTlsSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Comms.Channels.Email

  # 2026-10-11 cross-library review F-013: SMTP delivery used
  # `tls_options: [verify: :verify_none]`, so a LAN attacker could present any
  # certificate (or strip STARTTLS) and read SMTP_PASS plus every outbound mail.
  setup do
    prev = Application.get_env(:arbor_comms, :email)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbor_comms, :email, prev),
        else: Application.delete_env(:arbor_comms, :email)
    end)

    :ok
  end

  test "security regression (F-013): relay certificates are verified by default" do
    Application.put_env(:arbor_comms, :email, [])
    opts = Email.tls_options("smtp.example.com")

    assert opts[:verify] == :verify_peer
    assert opts[:server_name_indication] == ~c"smtp.example.com"
    assert is_list(opts[:cacerts]) and opts[:cacerts] != []
  end

  test "verify_none is only reachable through an explicit opt-out" do
    Application.put_env(:arbor_comms, :email, tls_verify: :none)
    assert Email.tls_options("smtp.example.com")[:verify] == :verify_none
  end
end
