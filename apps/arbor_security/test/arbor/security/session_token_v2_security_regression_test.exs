defmodule Arbor.Security.SessionTokenV2SecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-003"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security.SessionToken

  setup do
    previous = Application.get_env(:arbor_security, :session_token_secret)
    secret = "session-v2-regression-secret-at-least-32-bytes"
    Application.put_env(:arbor_security, :session_token_secret, secret)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_security, :session_token_secret),
        else: Application.put_env(:arbor_security, :session_token_secret, previous)
    end)

    {:ok, secret: secret}
  end

  @tag spec: "SSEC-003"
  test "security regression: default tokens are v2 and cannot authenticate filesystem authority" do
    assert {:ok, token} = SessionToken.generate("human_scoped_session")
    assert %{v: 2, purpose: :human_session, scopes: scopes} = payload(token)
    assert "arbor://fs" not in scopes

    assert {:error, :invalid_token_scope} =
             SessionToken.verify_for(token, "arbor://fs/write/secret", :write)

    assert {:ok, "human_scoped_session"} =
             SessionToken.verify_for(token, "arbor://chat/agent/agent_target", :chat)
  end

  test "security regression: revoking a session id invalidates its bearer immediately" do
    assert {:ok, token} = SessionToken.generate("human_revoked_session")
    assert {:ok, "human_revoked_session"} = SessionToken.verify(token)

    assert :ok = SessionToken.revoke(token)
    assert {:error, :session_revoked} = SessionToken.verify(token)
  end

  test "security regression: ambient conversation minting is denied" do
    assert {:error, :session_token_issuance_unauthorized} =
             SessionToken.generate_conversation("human_ambient", "agent_target")
  end

  test "security regression: direct registry mutation cannot resurrect a revoked bearer" do
    assert {:ok, token} = SessionToken.generate("human_registry_resurrection")
    claims = payload(token)
    assert :ok = SessionToken.revoke(token)

    assert {:error, :session_mutation_unauthorized} =
             Arbor.Security.SessionRegistry.issue(claims.sid, claims.pid, claims.exp)

    assert {:error, :session_revoked} = SessionToken.verify(token)
  end

  test "security regression: forged privileged from PID cannot issue or revoke sessions" do
    registry = Process.whereis(Arbor.Security.SessionRegistry)
    terminal = Process.whereis(Arbor.Security.TerminalLogin)
    assert is_pid(registry)
    assert is_pid(terminal)

    assert {:ok, token} = SessionToken.generate("human_raw_registry")
    claims = payload(token)
    forged_sid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    assert {:error, :session_mutation_unauthorized} =
             forged_call(
               registry,
               terminal,
               {:issue_terminal_conversation, forged_sid, claims.pid, "agent_target", claims.exp}
             )

    refute Arbor.Security.SessionRegistry.active?(forged_sid, claims.pid)

    assert {:error, :session_mutation_unauthorized} =
             forged_call(registry, terminal, {:revoke_token, token})

    assert {:ok, principal} = SessionToken.verify(token)
    assert principal == claims.pid
  end

  test "security regression: registry name takeover cannot resurrect a revoked session" do
    assert {:ok, token} = SessionToken.generate("human_name_takeover_session")
    assert :ok = SessionToken.revoke(token)

    registry = Arbor.Security.SessionRegistry
    real_registry = Process.whereis(registry)
    assert is_pid(real_registry)
    assert Process.unregister(registry)

    test_pid = self()

    squatter =
      spawn(fn ->
        true = Process.register(self(), registry)
        send(test_pid, :session_registry_squatter_ready)
        fake_session_registry_loop()
      end)

    assert_receive :session_registry_squatter_ready

    try do
      assert {:error, :session_revoked} = SessionToken.verify(token)
    after
      Process.exit(squatter, :kill)
      if Process.whereis(registry), do: Process.unregister(registry)
      if Process.alive?(real_registry), do: Process.register(real_registry, registry)
    end
  end

  test "security regression: approval authority expires before the browser session", %{
    secret: secret
  } do
    now = System.system_time(:second)
    sid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    old_payload = %{
      v: 2,
      pid: "human_old_approval",
      sid: sid,
      iat: now - 301,
      exp: now + 1_000,
      purpose: :human_session,
      scopes: payload_scopes()
    }

    :ok = Arbor.Security.SessionRegistry.issue_fixture(sid, old_payload.pid, old_payload.exp)
    token = encode(old_payload, secret)

    assert {:ok, "human_old_approval"} = SessionToken.verify(token)

    assert {:error, :approval_token_too_old} =
             SessionToken.verify_for(token, "arbor://approval/answer/task/task_1", :execute)
  end

  defp payload(token) do
    {:ok, <<_mac::binary-size(32), bytes::binary>>} = Base.url_decode64(token, padding: false)
    :erlang.binary_to_term(bytes, [:safe])
  end

  defp payload_scopes do
    {:ok, token} = SessionToken.generate("human_scope_fixture")
    payload(token).scopes
  end

  defp encode(payload, secret) do
    bytes = :erlang.term_to_binary(payload)
    mac = :crypto.mac(:hmac, :sha256, secret, bytes)
    Base.url_encode64(mac <> bytes, padding: false)
  end

  defp fake_session_registry_loop do
    receive do
      {:"$gen_call", {from, tag}, _request} ->
        send(from, {tag, true})
        fake_session_registry_loop()

      _other ->
        fake_session_registry_loop()
    end
  end

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged SessionRegistry call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end
end
