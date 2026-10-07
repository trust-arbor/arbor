defmodule Arbor.Security.TerminalLoginSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :terminal_login
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, TerminalLogin}

  @admission_source String.duplicate("s", 43)

  defmodule Aliases do
    def resolve(principal) do
      case Application.get_env(:arbor_security, :terminal_alias_block) do
        {:after_calls, observer, tag, count} ->
          seen = Process.get({:terminal_alias_calls, tag}, 0) + 1
          Process.put({:terminal_alias_calls, tag}, seen)

          if seen == count do
            send(observer, {:alias_blocked, self()})

            receive do
              :release_alias -> :ok
            end
          end

        {observer, tag} when is_pid(observer) ->
          if Process.get(:terminal_alias_blocked) != tag do
            Process.put(:terminal_alias_blocked, tag)
            send(observer, {:alias_blocked, self()})

            receive do
              :release_alias -> :ok
            end
          end

        _ ->
          :ok
      end

      {:ok,
       Map.get(
         Application.get_env(:arbor_security, :terminal_test_aliases, %{}),
         principal,
         principal
       )}
    end
  end

  defmodule DeviceFlow do
    def start(config) do
      send(config.observer, {:device_start, self()})

      if config[:block_start] do
        receive do
          :continue -> :ok
        end
      end

      {:ok,
       %{
         "verification_uri" => config[:verification_uri] || "https://login.example.test/device",
         "verification_uri_complete" => "https://login.example.test/device?secret=NEVER_EXPORT",
         "user_code" => "SAFE-CODE",
         "device_code" => "SECRET_DEVICE_CODE",
         "expires_in" => 300,
         "interval" => 1
       }}
    end

    def poll(config, _response) do
      send(config.observer, {:device_poll, self()})

      receive do
        {:token, token} ->
          {:ok, %{"id_token" => token, "refresh_token" => "SECRET_REFRESH_TOKEN"}}

        :crash ->
          raise "SECRET_PROVIDER_EXCEPTION"
      end
    end
  end

  setup do
    overrides = [
      identity_alias_resolver: Aliases,
      terminal_test_aliases: %{},
      terminal_alias_block: nil,
      identity_verification: true,
      strict_identity_mode: false,
      capability_signing_required: true,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false,
      constraint_enforcement_enabled: true,
      session_token_secret:
        "terminal-login-security-regression-secret-#{System.unique_integer([:positive])}",
      terminal_login: [device_flow_module: DeviceFlow, max_starts_per_source: 32],
      oidc: []
    ]

    before =
      Enum.map(overrides, fn {key, _} -> {key, Application.fetch_env(:arbor_security, key)} end)

    Enum.each(overrides, fn {key, value} -> Application.put_env(:arbor_security, key, value) end)

    on_exit(fn ->
      Enum.each(before, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)

      restart_broker()
    end)

    oidc = identity!()
    provider = Map.put(oidc.provider, :observer, self())
    Application.put_env(:arbor_security, :oidc, device_flow: provider)
    restart_broker()
    target = "agent_terminal_#{System.unique_integer([:positive])}"
    %{oidc: oidc, caller: oidc.identity.agent_id, target: target, provider: provider}
  end

  test "security regression: bare login admission cannot start anonymous IdP work", c do
    assert {:error, :terminal_login_source_required} = Security.begin_terminal_login(c.target)
    refute_receive {:device_start, _}
  end

  test "security regression: a stolen flow handle cannot poll or cancel another source", c do
    source_a = @admission_source
    source_b = String.duplicate("b", 43)

    Application.put_env(:arbor_security, :oidc,
      device_flow: Map.put(c.provider, :block_start, true)
    )

    restart_broker()
    grant!(c.caller, c.target)

    start = Task.async(fn -> Security.begin_terminal_login(c.target, source_a) end)
    assert_receive {:device_start, worker}

    [{_key, starting_flow}] = :sys.get_state(TerminalLogin).flows |> Map.to_list()
    refute Map.has_key?(starting_flow, :handle)

    send(worker, :continue)
    assert {:ok, pending} = Task.await(start)
    assert_receive {:device_poll, ^worker}

    refute inspect(:sys.get_state(TerminalLogin)) =~ pending.handle
    refute inspect(:sys.get_status(TerminalLogin)) =~ pending.handle

    assert {:error, :unauthorized} = Security.terminal_login_status(pending.handle)
    assert {:error, :unauthorized} = Security.cancel_terminal_login(pending.handle)

    assert {:error, :unauthorized} =
             Task.async(fn -> Security.terminal_login_status(pending.handle, source_b) end)
             |> Task.await()

    assert {:error, :unauthorized} =
             Task.async(fn -> Security.cancel_terminal_login(pending.handle, source_b) end)
             |> Task.await()

    assert {:ok, :pending} =
             Task.async(fn -> Security.terminal_login_status(pending.handle, source_a) end)
             |> Task.await()

    send(worker, {:token, c.oidc.id_token})

    assert {:ok, %{credential: credential}} =
             await_status(pending.handle, source_a)

    assert is_binary(credential)
  end

  test "security regression: source and global admission budgets bound IdP fanout", c do
    Application.put_env(:arbor_security, :terminal_login,
      device_flow_module: DeviceFlow,
      max_pending: 8,
      max_pending_per_source: 1,
      max_starts_per_source: 2,
      max_starts_per_window: 3,
      start_window_seconds: 60
    )

    restart_broker()
    source_a = @admission_source
    source_b = String.duplicate("b", 43)
    source_c = String.duplicate("c", 43)

    assert {:ok, first} = begin_login(c.target, source_a)
    assert_receive {:device_start, _first_worker}
    assert_receive {:device_poll, _first_worker}
    assert {:error, :login_unavailable} = begin_login(c.target, source_a)
    refute_receive {:device_start, _}

    assert {:ok, second} = begin_login(c.target, source_b)
    assert_receive {:device_start, _second_worker}
    assert_receive {:device_poll, _second_worker}
    assert :ok = Security.cancel_terminal_login(first.handle, source_a)
    assert :ok = Security.cancel_terminal_login(second.handle, source_b)

    assert {:ok, third} = begin_login(c.target, source_a)
    assert_receive {:device_start, _third_worker}
    assert_receive {:device_poll, _third_worker}
    assert :ok = Security.cancel_terminal_login(third.handle, source_a)

    assert {:error, :login_unavailable} = begin_login(c.target, source_a)
    assert {:error, :login_unavailable} = begin_login(c.target, source_c)
    refute_receive {:device_start, _}
  end

  test "security regression: existing linked human uses own grant and one-shot opaque credential",
       c do
    owner = identity!()

    Application.put_env(:arbor_security, :terminal_test_aliases, %{
      c.caller => owner.identity.agent_id
    })

    cap = grant!(c.caller, c.target)
    before = Security.list_capabilities(c.caller)
    {handle, session} = login!(c)
    assert Enum.sort(Map.keys(session)) == [:credential, :lifetime, :principal, :target]
    assert session.principal == c.caller
    assert session.target == c.target
    assert byte_size(session.credential) == 43
    assert session.lifetime == :connection
    claim!(session)

    assert {:error, :unauthorized} =
             Security.terminal_login_status(handle, @admission_source)

    assert {:ok, binding} = Security.verify_terminal_session(session.credential)
    assert binding.owner == owner.identity.agent_id
    assert binding.target == c.target
    assert binding.principal == c.caller

    assert {:ok, :authorized} =
             Security.recheck_conversation_session(
               c.caller,
               c.target,
               binding.owner,
               binding.session_token
             )

    assert {:error, :unauthorized} = Security.verify_terminal_session(binding.session_token)
    assert Security.list_capabilities(c.caller) == before
    assert {:ok, _} = Security.lookup(c.caller)
    refute inspect(:sys.get_status(TerminalLogin)) =~ session.credential
    refute inspect(:sys.get_status(TerminalLogin)) =~ binding.session_token
    assert :ok = Security.revoke_terminal_session(session.credential)
    assert {:error, :unauthorized} = Security.verify_terminal_session(session.credential)
    assert :ok = Security.revoke_terminal_session(session.credential)
    assert :ok = Security.revoke_fixture(cap.id)
  end

  test "security regression: login cannot provision unknown humans or inherit owner grants", c do
    unknown = identity!(register: false)

    Application.put_env(:arbor_security, :oidc,
      device_flow: Map.put(unknown.provider, :observer, self())
    )

    assert {:ok, pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    send(worker, {:token, unknown.id_token})
    assert {:error, :unauthorized} = await_status(pending.handle)
    assert {:error, :not_found} = Security.lookup(unknown.identity.agent_id)
    assert Security.list_capabilities(unknown.identity.agent_id) == {:ok, []}

    Application.put_env(:arbor_security, :oidc, device_flow: c.provider)
    owner = identity!()
    grant!(owner.identity.agent_id, c.target)

    Application.put_env(:arbor_security, :terminal_test_aliases, %{
      c.caller => owner.identity.agent_id
    })

    assert {:ok, pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    send(worker, {:token, c.oidc.id_token})
    assert {:error, :unauthorized} = await_status(pending.handle)
    assert Security.list_capabilities(c.caller) == {:ok, []}
  end

  test "security regression: revoked grants, changed owners and inactive subjects invalidate credentials",
       c do
    cap = grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    claim!(session)
    assert :ok = Security.revoke_fixture(cap.id)
    assert {:error, :unauthorized} = preflight(session.credential)
    assert {:error, :unauthorized} = Security.verify_terminal_session(session.credential)

    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    claim!(session)
    owner = identity!()

    Application.put_env(:arbor_security, :terminal_test_aliases, %{
      c.caller => owner.identity.agent_id
    })

    assert {:error, :unauthorized} = Security.verify_terminal_session(session.credential)
    Application.put_env(:arbor_security, :terminal_test_aliases, %{})
    {_handle, session} = login!(c)
    claim!(session)
    assert :ok = Security.suspend_identity_fixture(c.caller, "security regression fixture")
    assert {:error, :unauthorized} = Security.verify_terminal_session(session.credential)
  end

  test "security regression: real verifier rejects malformed or wrong signed OIDC claims", c do
    grant!(c.caller, c.target)
    signer = signer_for!(c.oidc)
    now = System.os_time(:second)

    invalid = [
      %{"exp" => "future"},
      %{"exp" => nil},
      %{"exp" => now - 1},
      %{"sub" => ""},
      %{"sub" => 42},
      %{"sub" => String.duplicate("x", 257)},
      %{"iss" => "https://foreign.example"},
      %{"aud" => "foreign-client"},
      %{"nbf" => now + 3_600},
      %{"nbf" => "past"},
      %{"nbf" => nil},
      %{"iat" => nil},
      %{"iat" => now + 3_600},
      %{"azp" => "foreign-client"},
      %{"azp" => nil},
      %{"aud" => [c.provider.client_id, 42]},
      %{"aud" => [c.provider.client_id, "second"]}
    ]

    for mutation <- invalid do
      {:ok, token} = Joken.Signer.sign(Map.merge(c.oidc.claims, mutation), signer)
      assert {:ok, pending} = begin_login(c.target)
      assert_receive {:device_poll, worker}
      send(worker, {:token, token})
      assert {:error, :unauthorized} = await_status(pending.handle)
    end

    claims =
      Map.merge(c.oidc.claims, %{
        "aud" => [c.provider.client_id, "second"],
        "azp" => c.provider.client_id
      })

    {:ok, token} = Joken.Signer.sign(claims, signer)
    {_handle, session} = login!(c, token)
    claim!(session)
    assert {:ok, _} = Security.verify_terminal_session(session.credential)
  end

  test "security regression: cancellation retires the exact worker before acknowledging", c do
    assert {:ok, pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    monitor = Process.monitor(worker)

    assert {:ok, :pending} =
             Security.terminal_login_status(pending.handle, @admission_source)

    assert :ok = Security.cancel_terminal_login(pending.handle, @admission_source)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}

    assert {:error, :unauthorized} =
             Security.terminal_login_status(pending.handle, @admission_source)

    assert :ok = Security.cancel_terminal_login(pending.handle, @admission_source)
    assert Process.alive?(Process.whereis(TerminalLogin))
  end

  test "security regression: caller loss during device start and broker shutdown retire owned workers",
       c do
    Application.put_env(:arbor_security, :oidc,
      device_flow: Map.put(c.provider, :block_start, true)
    )

    caller = spawn(fn -> begin_login(c.target) end)
    assert_receive {:device_start, worker}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000

    Application.put_env(:arbor_security, :oidc, device_flow: c.provider)
    assert {:ok, _pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    monitor = Process.monitor(worker)
    assert :ok = Supervisor.terminate_child(Security.Supervisor, TerminalLogin)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert {:ok, _} = Supervisor.restart_child(Security.Supervisor, TerminalLogin)
  end

  @tag :slow
  test "security regression: pending and unclaimed deadlines release capacity fail closed", c do
    Application.put_env(:arbor_security, :terminal_login,
      device_flow_module: DeviceFlow,
      pending_seconds: 1,
      attach_seconds: 1,
      max_pending: 1,
      max_active: 1
    )

    restart_broker()
    assert {:ok, pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    monitor = Process.monitor(worker)
    assert {:error, :login_unavailable} = begin_login(c.target)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000

    assert {:error, :unauthorized} =
             Security.terminal_login_status(pending.handle, @admission_source)

    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    assert {:error, :login_unavailable} = begin_login(c.target)
    Process.sleep(1_100)
    assert {:error, :unauthorized} = preflight(session.credential)
    assert {:ok, pending} = begin_login(c.target)
    assert :ok = Security.cancel_terminal_login(pending.handle, @admission_source)
  end

  @tag :slow
  test "security regression: an expired ready handle cannot overtake its queued timer", c do
    Application.put_env(:arbor_security, :terminal_login,
      device_flow_module: DeviceFlow,
      pending_seconds: 1,
      attach_seconds: 30
    )

    restart_broker()
    grant!(c.caller, c.target)
    assert {:ok, pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    send(worker, {:token, c.oidc.id_token})
    await_ready(pending.handle)
    :ok = :sys.suspend(TerminalLogin)

    task =
      Task.async(fn ->
        Security.terminal_login_status(pending.handle, @admission_source)
      end)

    try do
      await_call_wait(task.pid)
      Process.sleep(1_100)
    after
      :sys.resume(TerminalLogin)
    end

    assert {:error, :unauthorized} = Task.await(task)

    assert {:error, :unauthorized} =
             Security.terminal_login_status(pending.handle, @admission_source)
  end

  @tag :slow
  test "security regression: attach deadline is rechecked after a blocked authorization gate",
       c do
    Application.put_env(:arbor_security, :terminal_login,
      device_flow_module: DeviceFlow,
      attach_seconds: 1
    )

    restart_broker()
    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    Application.put_env(:arbor_security, :terminal_alias_block, {self(), make_ref()})
    task = Task.async(fn -> preflight(session.credential) end)
    assert_receive {:alias_blocked, broker}
    assert broker == Process.whereis(TerminalLogin)
    Process.sleep(1_100)
    send(broker, :release_alias)
    assert {:error, :unauthorized} = Task.await(task)
  end

  test "security regression: connection proofs stay scoped and worker failures expose no secrets",
       c do
    grant!(c.caller, c.target)
    signer = signer_for!(c.oidc)
    expiry = System.os_time(:second) + 30
    {:ok, token} = Joken.Signer.sign(Map.put(c.oidc.claims, "exp", expiry), signer)
    {_handle, session} = login!(c, token)
    assert session.lifetime == :connection
    refute Map.has_key?(session, :expires_at)
    claim!(session)
    assert {:ok, binding} = Security.verify_terminal_session(session.credential)

    {:ok, <<_mac::binary-size(32), encoded::binary>>} =
      Base.url_decode64(binding.session_token, padding: false)

    proof = :erlang.binary_to_term(encoded, [:safe])
    assert proof.v == 2
    assert proof.target == c.target
    assert proof.exp - proof.iat == 90
    assert proof.exp > expiry

    assert {:error, :unauthorized} =
             Security.verify_human_session(c.caller, binding.session_token)

    assert {:ok, next} = Security.verify_terminal_session(session.credential)
    refute next.session_token == binding.session_token
    assert {:ok, pending} = begin_login(c.target)

    assert Enum.sort(Map.keys(pending)) == [
             :expires_in,
             :handle,
             :interval,
             :user_code,
             :verification_uri
           ]

    refute inspect(pending) =~ "SECRET"
    assert pending.verification_uri == "https://login.example.test/device"
    assert_receive {:device_poll, worker}
    send(worker, :crash)
    assert {:error, :unauthorized} = await_status(pending.handle)
  end

  test "security regression: invalid target, handles, URI and caller-selected options fail closed",
       c do
    for target <- [nil, %{}, "", "agent_bad/path", String.duplicate("a", 257)] do
      assert {:error, :unauthorized} = begin_login(target)
    end

    refute_receive {:device_start, _}

    assert {:error, :unauthorized} =
             GenServer.call(
               TerminalLogin,
               {:unsupported_request, [credential: "PRIVATE_SENTINEL"]}
             )

    assert Process.alive?(Process.whereis(TerminalLogin))

    for opaque <- [nil, "", String.duplicate("x", 44), %{target: c.target}] do
      assert {:error, :unauthorized} =
               Security.terminal_login_status(opaque, @admission_source)

      assert {:error, :unauthorized} = Security.verify_terminal_session(opaque)
      assert :ok = Security.cancel_terminal_login(opaque, @admission_source)
      assert :ok = Security.revoke_terminal_session(opaque)
    end

    for uri <- [
          "http://remote.example/device",
          "https://user:secret@example.test/device",
          "https://example.test/#token"
        ] do
      Application.put_env(:arbor_security, :oidc,
        device_flow: Map.put(c.provider, :verification_uri, uri)
      )

      assert {:error, :unauthorized} = begin_login(c.target)
    end
  end

  @tag :localhost_verification_uri
  test "security regression: allowed localhost verification instructions reach the caller", c do
    uri = "http://localhost:8080/device?flow=chat"

    Application.put_env(:arbor_security, :oidc,
      device_flow: Map.merge(c.provider, %{allow_http: true, verification_uri: uri})
    )

    assert {:ok, pending} = begin_login(c.target)
    on_exit(fn -> Security.cancel_terminal_login(pending.handle, @admission_source) end)
    assert pending.verification_uri == uri
    refute Map.has_key?(pending, :device_code)
    refute Map.has_key?(pending, :verification_uri_complete)
    assert_receive {:device_poll, worker}
    monitor = Process.monitor(worker)
    assert :ok = Security.cancel_terminal_login(pending.handle, @admission_source)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    refute Process.alive?(worker)

    assert {:error, :unauthorized} =
             Security.terminal_login_status(pending.handle, @admission_source)
  end

  test "security regression: local verification instructions retain HTTP and URI safety gates",
       c do
    for {allow_http, uri} <- [
          {false, "http://localhost:8080/device"},
          {true, "http://localhost.example.test/device"},
          {true, "http://localhost./device"},
          {true, "http://sub.localhost/device"},
          {true, "http://remote.example/device"},
          {true, "http://user:secret@localhost:8080/device"},
          {true, "http://localhost:8080/device#token"},
          {true, "http://localhost:0/device"},
          {true, "http://localhost:65536/device"},
          {true, "http://localhost:8080/device with space"}
        ] do
      Application.put_env(:arbor_security, :oidc,
        device_flow: Map.merge(c.provider, %{allow_http: allow_http, verification_uri: uri})
      )

      assert {:error, :unauthorized} = begin_login(c.target)
      assert_receive {:device_start, _}
      refute_receive {:device_poll, _}
    end
  end

  test "trusted config overrides stay within hard limits" do
    Application.put_env(:arbor_security, :terminal_login,
      attach_seconds: 301,
      reconnect_seconds: 3_601,
      pending_seconds: 301,
      max_pending: 33,
      max_active: 129
    )

    assert %{
             attach_seconds: 60,
             reconnect_seconds: 120,
             pending_seconds: 300,
             max_pending: 32,
             max_pending_per_source: 2,
             max_starts_per_source: 4,
             max_starts_per_window: 64,
             start_window_seconds: 60,
             max_active: 128
           } =
             Security.Config.terminal_login_options()
  end

  @tag :terminal_claim_required
  test "security regression: a retrieved credential cannot issue proof before connection claim",
       c do
    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    assert {:error, :unauthorized} = Security.verify_terminal_session(session.credential)
    assert {:ok, metadata} = preflight(session.credential)
    assert metadata.lifetime == :connection
    refute Map.has_key?(metadata, :session_token)
    claim!(session)
    assert {:ok, _} = Security.verify_terminal_session(session.credential)
  end

  @tag :slow
  test "security regression: a live connection outlives initial OIDC and attach deadlines", c do
    Application.put_env(:arbor_security, :terminal_login,
      device_flow_module: DeviceFlow,
      attach_seconds: 1,
      reconnect_seconds: 1
    )

    restart_broker()
    grant!(c.caller, c.target)
    expiry = System.os_time(:second) + 3
    {:ok, token} = Joken.Signer.sign(Map.put(c.oidc.claims, "exp", expiry), signer_for!(c.oidc))
    {_handle, session} = login!(c, token)
    claim!(session)
    assert {:ok, first} = Security.verify_terminal_session(session.credential)
    Process.sleep(max((expiry - System.os_time(:second)) * 1_000 + 100, 1_100))
    assert System.os_time(:second) >= expiry
    assert {:ok, next} = Security.verify_terminal_session(session.credential)
    assert next.lifetime == :connection
    refute next.session_token == first.session_token

    assert {:ok, :authorized} =
             Security.recheck_conversation_session(
               c.caller,
               c.target,
               c.caller,
               next.session_token
             )
  end

  test "security regression: competing claims admit one exact owner and deny nonowner proof", c do
    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    left = owner!()
    right = owner!()

    tasks =
      for pid <- [left, right],
          do:
            Task.async(fn ->
              {pid, owner_call(pid, :claim_terminal_session, session.credential)}
            end)

    results = Enum.map(tasks, &Task.await/1)

    [{winner, {:ok, metadata}}] =
      Enum.filter(results, fn {_, result} -> match?({:ok, _}, result) end)

    [{loser, {:error, :unauthorized}}] =
      Enum.reject(results, fn {_, result} -> match?({:ok, _}, result) end)

    assert metadata.lifetime == :connection
    assert {:error, :unauthorized} = Security.verify_terminal_session(session.credential)
    assert {:error, :session_in_use} = preflight(session.credential)

    assert {:error, :unauthorized} =
             owner_call(loser, :verify_terminal_session, session.credential)

    assert {:error, :unauthorized} =
             owner_call(loser, :claim_terminal_session, session.credential)

    assert {:ok, ^metadata} = owner_call(winner, :claim_terminal_session, session.credential)
    assert {:ok, _} = owner_call(winner, :verify_terminal_session, session.credential)
    assert :ok = Security.revoke_terminal_session(session.credential)

    assert {:error, :unauthorized} =
             owner_call(winner, :verify_terminal_session, session.credential)

    assert Process.alive?(winner)
  end

  test "security regression: exact owner loss permits reconnect and stale generations cannot retire it",
       c do
    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    key = :crypto.hash(:sha256, session.credential)
    unclaimed = :sys.get_state(TerminalLogin).sessions[key]
    owner = owner!()
    assert {:ok, _} = owner_call(owner, :claim_terminal_session, session.credential)
    attached = :sys.get_state(TerminalLogin).sessions[key]
    monitor = Process.monitor(owner)
    Application.put_env(:arbor_security, :terminal_alias_block, {self(), make_ref()})
    preflight = Task.async(fn -> preflight(session.credential) end)
    assert_receive {:alias_blocked, broker}

    try do
      # The broker is still inside this preflight when the owner dies, so its
      # exact DOWN cannot be consumed before the post-authorization liveness check.
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    after
      send(broker, :release_alias)
    end

    assert {:ok, _} = Task.await(preflight)
    Application.put_env(:arbor_security, :terminal_alias_block, nil)
    detached = await_phase(session.credential, :detached)
    assert {:ok, _} = preflight(session.credential)
    claim!(session)
    send(TerminalLogin, {:session_expire, key, unclaimed.timer_tag})
    send(TerminalLogin, {:session_expire, key, detached.timer_tag})
    send(TerminalLogin, {:DOWN, attached.owner_ref, :process, owner, :killed})
    assert {:ok, _} = Security.verify_terminal_session(session.credential)
    assert :sys.get_state(TerminalLogin).sessions[key].owner_pid == self()
  end

  @tag :slow
  test "security regression: detached grace expires and cannot be refreshed by preflight", c do
    Application.put_env(:arbor_security, :terminal_login,
      device_flow_module: DeviceFlow,
      reconnect_seconds: 1
    )

    restart_broker()
    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    owner = owner!()
    assert {:ok, _} = owner_call(owner, :claim_terminal_session, session.credential)
    Process.exit(owner, :kill)
    detached = await_phase(session.credential, :detached)
    assert {:ok, _} = preflight(session.credential)
    assert await_phase(session.credential, :detached).deadline == detached.deadline
    Process.sleep(1_100)
    assert {:error, :unauthorized} = preflight(session.credential)

    assert {:error, :unauthorized} =
             apply(Security, :claim_terminal_session, [session.credential])
  end

  test "security regression: a dead queued claimant cannot consume the attachment", c do
    grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    :ok = :sys.suspend(TerminalLogin)
    claimant = spawn(fn -> apply(Security, :claim_terminal_session, [session.credential]) end)
    monitor = Process.monitor(claimant)

    try do
      await_call_wait(claimant)
      Process.exit(claimant, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^claimant, _}
    after
      :sys.resume(TerminalLogin)
    end

    assert {:ok, _} = preflight(session.credential)
    claim!(session)
    assert {:ok, _} = Security.verify_terminal_session(session.credential)
  end

  test "security regression: authorization lost after proof issuance withholds the proof", c do
    cap = grant!(c.caller, c.target)
    {_handle, session} = login!(c)
    owner = owner!()
    assert {:ok, _} = owner_call(owner, :claim_terminal_session, session.credential)

    # Each owner resolution calls the alias resolver for subject and canonical
    # owner. The third call holds the second gate, after fresh proof generation.
    Application.put_env(
      :arbor_security,
      :terminal_alias_block,
      {:after_calls, self(), make_ref(), 3}
    )

    verify = Task.async(fn -> owner_call(owner, :verify_terminal_session, session.credential) end)
    assert_receive {:alias_blocked, broker}

    try do
      assert :ok = Security.revoke_fixture(cap.id)
    after
      send(broker, :release_alias)
    end

    assert {:error, :unauthorized} = Task.await(verify)

    assert {:error, :unauthorized} =
             owner_call(owner, :verify_terminal_session, session.credential)
  end

  defp preflight(credential), do: apply(Security, :preflight_terminal_session, [credential])

  defp claim!(session) do
    assert {:ok, metadata} = apply(Security, :claim_terminal_session, [session.credential])
    metadata
  end

  defp owner! do
    pid = spawn(fn -> owner_loop() end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp owner_loop do
    receive do
      {:call, caller, ref, function, credential} ->
        send(caller, {ref, apply(Security, function, [credential])})
        owner_loop()
    end
  end

  defp owner_call(pid, function, credential) do
    ref = make_ref()
    send(pid, {:call, self(), ref, function, credential})

    receive do
      {^ref, result} -> result
    after
      3_000 -> flunk("connection owner did not reply")
    end
  end

  defp await_phase(credential, phase, attempts \\ 200)
  defp await_phase(_, _, 0), do: flunk("terminal session did not reach its lifecycle phase")

  defp await_phase(credential, phase, attempts) do
    key = :crypto.hash(:sha256, credential)

    case :sys.get_state(TerminalLogin).sessions[key] do
      %{phase: ^phase} = binding ->
        binding

      _ ->
        Process.sleep(5)
        await_phase(credential, phase, attempts - 1)
    end
  end

  defp identity!(opts \\ []) do
    fixture = OIDCTestHelper.issue_identity()

    if Keyword.get(opts, :register, true) do
      assert :ok =
               Security.register_oidc_identity(
                 fixture.identity,
                 fixture.id_token,
                 fixture.provider
               )

      on_exit(fn -> Security.deregister_identity_fixture(fixture.identity.agent_id) end)
    end

    on_exit(fixture.cleanup)
    fixture
  end

  defp grant!(principal, target) do
    assert {:ok, cap} =
             Security.grant_fixture(
               principal: principal,
               resource: "arbor://chat/agent/" <> target
             )

    on_exit(fn -> Security.revoke_fixture(cap.id) end)
    cap
  end

  defp login!(c, token \\ nil) do
    assert {:ok, pending} = begin_login(c.target)
    assert_receive {:device_poll, worker}
    send(worker, {:token, token || c.oidc.id_token})
    assert {:ok, session} = await_status(pending.handle)
    {pending.handle, session}
  end

  defp begin_login(target, source \\ @admission_source) do
    Security.begin_terminal_login(target, source)
  end

  defp await_status(handle), do: await_status(handle, @admission_source, 200)
  defp await_status(handle, source), do: await_status(handle, source, 200)
  defp await_status(_handle, _source, 0), do: flunk("terminal login did not settle")

  defp await_status(handle, source, attempts) do
    case Security.terminal_login_status(handle, source) do
      {:ok, :pending} ->
        Process.sleep(5)
        await_status(handle, source, attempts - 1)

      result ->
        result
    end
  end

  # Read-only scheduling barriers: the test never writes broker state or a
  # completion receipt. Public status must reject a call queued before expiry.
  defp await_ready(handle, attempts \\ 200)
  defp await_ready(_handle, 0), do: flunk("terminal login did not become ready")

  defp await_ready(handle, attempts) do
    key = :crypto.hash(:sha256, handle)

    case :sys.get_state(TerminalLogin).flows[key] do
      %{stage: :ready} ->
        :ok

      _ ->
        Process.sleep(2)
        await_ready(handle, attempts - 1)
    end
  end

  defp await_call_wait(pid, attempts \\ 200)
  defp await_call_wait(_pid, 0), do: flunk("status caller did not block on broker")

  defp await_call_wait(pid, attempts) do
    case Process.info(pid, :status) do
      {:status, :waiting} ->
        :ok

      {:status, _running_or_runnable} ->
        Process.sleep(2)
        await_call_wait(pid, attempts - 1)

      nil ->
        flunk("status caller exited before broker resumed")
    end
  end

  defp restart_broker do
    :ok = Supervisor.terminate_child(Security.Supervisor, TerminalLogin)
    {:ok, _} = Supervisor.restart_child(Security.Supervisor, TerminalLogin)
    :ok
  end

  defp signer_for!(fixture) do
    private = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private_map} = JOSE.JWK.to_map(private)
    {_, public_map} = JOSE.JWK.to_public_map(private)
    kid = "terminal-claims"
    jwks = %{"keys" => [Map.merge(public_map, %{"kid" => kid, "alg" => "ES256"})]}

    :ok = Arbor.Security.OIDC.JwksCache.put_fixture(fixture.provider, jwks)

    Joken.Signer.create("ES256", private_map, %{"kid" => kid})
  end
end
