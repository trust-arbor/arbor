defmodule Arbor.Agent.MessageFacadeSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.MessageFacade
  alias Arbor.Agent.Registry
  alias Arbor.Agent.SessionManager
  alias Arbor.Contracts.Pipeline.Response, as: PipelineResponse
  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  defmodule CaptureHost do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call({:query, input, opts}, _from, state) do
      send(state.parent, {:query_seen, input, opts})
      reply = Map.get(state, :reply, "reply-fixed")
      {:reply, {:ok, %{text: reply}}, state}
    end
  end

  defmodule FakeAuthSession do
    @moduledoc false
    # Bare process speaking GenServer.call protocol for send_authenticated_message/4.
    def start_link(parent, reply_fun) do
      pid =
        spawn_link(fn ->
          receive do
            {:"$gen_call", {from_pid, ref} = from, request} ->
              send(parent, {:auth_session_call, from_pid, request})
              reply = reply_fun.(from_pid, request)
              GenServer.reply(from, reply)
              # Stay alive briefly so lookup still sees us if needed.
              Process.sleep(50)
          end
        end)

      {:ok, pid}
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)

    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    assert Process.whereis(Arbor.Security.CapabilityStore) != nil,
           "CapabilityStore must be running for real Security path tests"

    assert Process.whereis(Arbor.Security.DeliveryReceiptBroker) != nil,
           "DeliveryReceiptBroker must be running for authenticated receipt path tests"

    :ok
  end

  setup do
    original_identity = Application.get_env(:arbor_security, :identity_verification, true)
    original_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled, true)
    original_strict = Application.get_env(:arbor_security, :strict_identity_mode, false)
    original_signing = Application.get_env(:arbor_security, :capability_signing_required, true)
    original_session_mod = Application.get_env(:arbor_agent, :orchestrator_session_module)

    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)

    on_exit(fn ->
      Application.put_env(:arbor_security, :identity_verification, original_identity)
      Application.put_env(:arbor_security, :reflex_checking_enabled, original_reflex)
      Application.put_env(:arbor_security, :strict_identity_mode, original_strict)
      Application.put_env(:arbor_security, :capability_signing_required, original_signing)

      case original_session_mod do
        nil -> Application.delete_env(:arbor_agent, :orchestrator_session_module)
        mod -> Application.put_env(:arbor_agent, :orchestrator_session_module, mod)
      end
    end)

    uid = System.unique_integer([:positive])
    caller = "human_msgfacade_#{uid}"
    target = "agent_msgfacade_#{uid}"
    other = "agent_msgfacade_other_#{uid}"

    {:ok, caller: caller, target: target, other: other, uid: uid}
  end

  defp track_grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      assert :ok = Security.revoke(cap.id)
      assert {:ok, capabilities} = Security.list_capabilities(principal)
      refute Enum.any?(capabilities, &(&1.id == cap.id))
    end)

    cap
  end

  defp build_message(caller, opts \\ []) do
    sent_at = Keyword.get(opts, :sent_at, ~U[2026-08-01 12:00:00.123456Z])

    engagement_id =
      Keyword.get(
        opts,
        :engagement_id,
        "engagement_voice_#{System.unique_integer([:positive])}"
      )

    content = Keyword.get(opts, :content, "hello from voice")
    metadata = Keyword.get(opts, :transport_metadata, %{backend: "xai_realtime", input: :speech})

    %UserMessage{
      content: content,
      sent_at: sent_at,
      sender_id: Keyword.get(opts, :sender_id, caller),
      transport: :voice,
      transport_metadata: metadata,
      engagement_id: engagement_id
    }
  end

  defp build_route_free_message(caller, opts \\ []) do
    build_message(caller, Keyword.put(opts, :engagement_id, nil))
  end

  defp register_capture_host(target, parent \\ self(), reply \\ "reply-fixed") do
    {:ok, pid} = CaptureHost.start_link(parent: parent, reply: reply)

    :ok =
      Registry.register(target, pid, %{
        runtime: :arbor,
        model_config: %{runtime: :arbor},
        host_pid: pid,
        module: CaptureHost,
        agent_id: target
      })

    on_exit(fn ->
      assert :ok = Registry.unregister(target)
      assert {:error, :not_found} = Registry.lookup(target)

      if Process.alive?(pid) do
        assert :ok = GenServer.stop(pid)
      end

      refute Process.alive?(pid)
    end)

    pid
  end

  defp register_agent_only(target) do
    # Registered agent without a usable host — enough for Manager.find_agent.
    pid = spawn(fn -> Process.sleep(:infinity) end)

    :ok =
      Registry.register(target, pid, %{
        runtime: :arbor,
        model_config: %{runtime: :arbor},
        host_pid: pid,
        module: :none,
        agent_id: target
      })

    on_exit(fn ->
      _ = Registry.unregister(target)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  # Test-only: run ETS mutations inside the SessionManager owner process so
  # :protected table writes succeed without a production mutation seam.
  defp owner_ets(fun) when is_function(fun, 0) do
    owner = Process.whereis(SessionManager)
    assert is_pid(owner)
    parent = self()
    ref = make_ref()

    :sys.replace_state(owner, fn state ->
      send(parent, {ref, fun.()})
      state
    end)

    receive do
      {^ref, result} -> result
    after
      1_000 -> flunk("owner ETS op timed out")
    end
  end

  defp insert_fake_session!(agent_id, session_pid) do
    true = owner_ets(fn -> :ets.insert(SessionManager, {agent_id, session_pid}) end)

    on_exit(fn ->
      if Process.whereis(SessionManager) && :ets.whereis(SessionManager) != :undefined do
        _ = owner_ets(fn -> :ets.delete(SessionManager, agent_id) end)
      end
    end)

    :ok
  end

  defp flunk_chat_fun do
    fn _msg, _sender, _opts ->
      flunk("message effect must not be called")
    end
  end

  defp counting_funs do
    auth_counter = :counters.new(1, [])
    chat_counter = :counters.new(1, [])

    authorize = fn _caller, _resource, _action, _auth_opts ->
      :counters.add(auth_counter, 1, 1)
      {:ok, :authorized}
    end

    chat = fn msg, sender, opts ->
      :counters.add(chat_counter, 1, 1)
      {:ok, {"counted", msg, sender, opts}}
    end

    {auth_counter, chat_counter, authorize, chat}
  end

  defp auth_collaborators(opts) do
    parent = Keyword.get(opts, :parent, self())
    issue_counter = Keyword.get(opts, :issue_counter, :counters.new(1, []))
    discard_counter = Keyword.get(opts, :discard_counter, :counters.new(1, []))
    chat_auth_counter = Keyword.get(opts, :chat_auth_counter, :counters.new(1, []))

    reply = Keyword.get(opts, :reply, {:ok, %PipelineResponse{content: "auth-ok"}})
    on_chat = Keyword.get(opts, :on_chat)

    issue_receipt =
      Keyword.get(opts, :issue_receipt, fn _c, _r, _a, auth_opts ->
        :counters.add(issue_counter, 1, 1)
        send(parent, {:issue_seen, auth_opts})

        token = :crypto.strong_rand_bytes(32)
        assert {:ok, receipt} = DeliveryReceipt.new(token: token)
        {:ok, receipt}
      end)

    discard_receipt =
      Keyword.get(opts, :discard_receipt, fn receipt ->
        :counters.add(discard_counter, 1, 1)
        send(parent, {:discard_seen, receipt})
        :ok
      end)

    chat_authenticated =
      Keyword.get(opts, :chat_authenticated, fn msg, sender, receipt, chat_opts ->
        :counters.add(chat_auth_counter, 1, 1)
        send(parent, {:chat_auth_seen, msg, sender, receipt, chat_opts})

        if is_function(on_chat, 4) do
          on_chat.(msg, sender, receipt, chat_opts)
        else
          case reply do
            {:ok, %PipelineResponse{} = r} -> {:ok, PipelineResponse.content(r)}
            other -> other
          end
        end
      end)

    chat_response_authenticated =
      Keyword.get(opts, :chat_response_authenticated, fn msg, sender, receipt, chat_opts ->
        :counters.add(chat_auth_counter, 1, 1)
        send(parent, {:chat_auth_seen, msg, sender, receipt, chat_opts})

        if is_function(on_chat, 4) do
          on_chat.(msg, sender, receipt, chat_opts)
        else
          reply
        end
      end)

    %{
      authorize: fn _c, _r, _a, _o -> flunk("ordinary authorize must not be called on auth path") end,
      issue_receipt: issue_receipt,
      discard_receipt: discard_receipt,
      chat: fn _m, _s, _o -> flunk("ordinary chat must not be called on auth path") end,
      chat_response: fn _m, _s, _o ->
        flunk("ordinary chat_response must not be called on auth path")
      end,
      chat_authenticated: chat_authenticated,
      chat_response_authenticated: chat_response_authenticated
    }
  end

  # Humans require OIDC registration (Registry rejects bare human_ register).
  # Inline the minimal issuer path so arbor_agent tests do not depend on
  # arbor_security/test/support (not on the agent test load path).
  defp register_active_human! do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/msgfacade/#{unique}"
    subject = "subject-#{unique}"
    client_id = "arbor-test-client"
    kid = "test-key-#{unique}"

    private_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private_map} = JOSE.JWK.to_map(private_jwk)
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)
    public_map = Map.merge(public_map, %{"alg" => "ES256", "kid" => kid})
    signer = Joken.Signer.create("ES256", private_map, %{"kid" => kid})

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => client_id,
      "exp" => System.os_time(:second) + 3_600,
      "iat" => System.os_time(:second),
      "email" => "operator-#{unique}@example.test",
      "name" => "MessageFacade OIDC Human"
    }

    {:ok, id_token} = Joken.Signer.sign(claims, signer)

    table = :arbor_oidc_jwks_cache

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    true =
      :ets.insert(
        table,
        {issuer, %{"keys" => [public_map]}, System.monotonic_time(:millisecond) + 60_000}
      )

    {:ok, identity} = Arbor.Contracts.Security.Identity.generate(name: claims["name"])

    human_id =
      "human_" <>
        String.slice(
          Base.encode16(:crypto.hash(:sha256, "#{issuer}:#{subject}"), case: :lower),
          0,
          40
        )

    human_identity = %{
      identity
      | agent_id: human_id,
        metadata: %{
          "identity_type" => "human",
          "oidc_issuer" => issuer,
          "oidc_sub" => subject
        }
    }

    assert :ok =
             Security.register_oidc_identity(human_identity, id_token, %{
               issuer: issuer,
               client_id: client_id
             })

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table, issuer)
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  defp assert_no_secret_leak(term, secrets) do
    inspected = inspect(term, limit: :infinity, printable_limit: :infinity)

    for secret <- secrets, is_binary(secret), byte_size(secret) > 0 do
      refute String.contains?(inspected, secret)
      refute :binary.match(inspected, secret) != :nomatch
    end
  end

  # ---------------------------------------------------------------------------
  # A. Real Security + Manager authorized exact envelope (ordinary path)
  # ---------------------------------------------------------------------------

  describe "authorized exact envelope via real Security and Manager" do
    test "engagement-tagged UserMessage reaches Manager once and reply is unchanged", %{
      caller: caller,
      target: target
    } do
      track_grant!(caller, "arbor://chat/agent/#{target}")
      host_pid = register_capture_host(target, self(), "reply-fixed")

      sent_at = ~U[2026-08-01 15:30:00.654321Z]
      engagement_id = "engagement_exact_#{System.unique_integer([:positive])}"
      metadata = %{backend: "xai_realtime", device: "mac", turn: 7}

      message =
        build_message(caller,
          sent_at: sent_at,
          engagement_id: engagement_id,
          content: "exact envelope content",
          transport_metadata: metadata
        )

      assert {:ok, "reply-fixed"} =
               Arbor.Agent.send_message(caller, target, message, timeout: 5_000)

      assert_receive {:query_seen, %UserMessage{} = seen, opts}
      refute_receive {:query_seen, _, _}, 50

      # Exact envelope identity — not a field-by-field subset.
      assert seen == message
      assert opts[:timeout] == 5_000
      refute Keyword.has_key?(opts, :session_token)
      assert Process.alive?(host_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # A2. Authenticated path — real Security issue + Session bridge
  # ---------------------------------------------------------------------------

  describe "security regression: authenticated session_token delivery (VOICE-17)" do
    @describetag voice_id: "VOICE-17"
    @describetag spec: "VOICE-17"

    setup do
      prev_secret = Application.get_env(:arbor_security, :session_token_secret)

      Application.put_env(
        :arbor_security,
        :session_token_secret,
        "agent-msg-facade-secret-#{System.unique_integer([:positive])}"
      )

      Application.put_env(:arbor_security, :identity_verification, true)

      on_exit(fn ->
        case prev_secret do
          nil -> Application.delete_env(:arbor_security, :session_token_secret)
          v -> Application.put_env(:arbor_security, :session_token_secret, v)
        end
      end)

      :ok
    end

    test "security regression: non-owner cannot replace Session binding or steal authenticated delivery" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_hijack_#{n}"
      resource = "arbor://chat/agent/#{target}"

      track_grant!(caller, resource)
      register_agent_only(target)

      parent = self()
      facade_caller = self()

      clean = %PipelineResponse{
        content: "binding-safe-reply",
        tool_history: [],
        tool_rounds: 0
      }

      {:ok, legit_session_pid} =
        FakeAuthSession.start_link(parent, fn call_from_pid, request ->
          assert match?(
                   {:send_authenticated_message, %UserMessage{}, %DeliveryReceipt{}},
                   request
                 )

          {_tag, msg, receipt} = request
          send(parent, {:legit_got, call_from_pid, msg, receipt})
          assert {:ok, ^caller} = Security.consume_delivery_receipt(receipt, resource, :chat)
          {:ok, clean}
        end)

      insert_fake_session!(target, legit_session_pid)

      Application.put_env(
        :arbor_agent,
        :orchestrator_session_module,
        Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge
      )

      # Separate attacker process attempts to replace the agent→session binding.
      _attacker =
        spawn(fn ->
          hostile_session =
            spawn(fn ->
              receive do
                {:"$gen_call", {from_pid, _ref} = from, request} ->
                  send(parent, {:hostile_got, from_pid, request})
                  GenServer.reply(from, {:ok, %PipelineResponse{content: "stolen"}})
              end
            end)

          result =
            try do
              :ets.insert(SessionManager, {target, hostile_session})
            rescue
              e -> {:raised, e}
            catch
              class, reason -> {class, reason}
            end

          send(parent, {:attacker_write, result, hostile_session})
        end)

      assert_receive {:attacker_write, write_result, hostile_session}, 1_000
      assert is_pid(hostile_session)

      # Hostile session blocks in receive forever if not cleaned up.
      on_exit(fn ->
        if is_pid(hostile_session) and Process.alive?(hostile_session) do
          Process.exit(hostile_session, :kill)
        end
      end)

      # On :protected tables non-owner insert raises; must not succeed with true.
      # Base (:public) returns true here — that is the behavioral base-fail evidence.
      refute write_result == true

      case write_result do
        {:raised, %ArgumentError{}} ->
          :ok

        {:raised, %ErlangError{original: :badarg}} ->
          :ok

        {:error, :badarg} ->
          :ok

        {:exit, :badarg} ->
          :ok

        other ->
          flunk("expected ETS write refusal for non-owner, got: #{inspect(other)}")
      end

      # Legitimate binding must remain intact after the refused write.
      assert {:ok, ^legit_session_pid} = SessionManager.get_session(target)

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller, content: "binding integrity probe")

      assert {:ok, "binding-safe-reply"} =
               Arbor.Agent.send_message(caller, target, message,
                 timeout: 5_000,
                 session_token: token
               )

      assert_receive {:legit_got, from_pid, %UserMessage{} = seen, %DeliveryReceipt{} = receipt},
                     1_000

      assert from_pid == facade_caller
      refute from_pid == Process.whereis(SessionManager)
      assert seen == message
      assert seen.engagement_id == nil
      assert is_struct(receipt, DeliveryReceipt)

      # Attacker session must never observe the authenticated message or receipt.
      refute_receive {:hostile_got, _, _}, 200

      # Deterministic cleanup after no-delivery assertion (on_exit is backup).
      if Process.alive?(hostile_session), do: Process.exit(hostile_session, :kill)
    end

    test "security regression: valid human proof exchanges once and reaches exact Session" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_auth_#{n}"
      resource = "arbor://chat/agent/#{target}"

      track_grant!(caller, resource)
      register_agent_only(target)

      parent = self()
      facade_caller = self()

      clean = %PipelineResponse{
        content: "session-auth-reply",
        tool_history: [],
        tool_rounds: 0
      }

      {:ok, session_pid} =
        FakeAuthSession.start_link(parent, fn from_pid, request ->
          send(parent, {:from_pid, from_pid})
          assert from_pid == facade_caller

          assert match?(
                   {:send_authenticated_message, %UserMessage{}, %DeliveryReceipt{}},
                   request
                 )

          {_tag, _msg, receipt} = request
          # Real Session consumes on accept — destroy the one-use receipt.
          assert {:ok, ^caller} = Security.consume_delivery_receipt(receipt, resource, :chat)
          {:ok, clean}
        end)

      insert_fake_session!(target, session_pid)

      # Module export seam: a thin wrapper that delegates to GenServer.call protocol.
      Application.put_env(
        :arbor_agent,
        :orchestrator_session_module,
        Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge
      )

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller, content: "auth path content")

      assert {:ok, "session-auth-reply"} =
               Arbor.Agent.send_message(caller, target, message,
                 timeout: 5_000,
                 session_token: token
               )

      assert_receive {:auth_session_call, ^facade_caller,
                      {:send_authenticated_message, %UserMessage{} = seen, %DeliveryReceipt{} = receipt}}

      assert seen == message
      assert seen.engagement_id == nil
      assert {:ok, bearer} = DeliveryReceipt.bearer_token(receipt)

      # Receipt was consumed or discarded by Session/facade — must not remain live.
      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)

      assert_no_secret_leak({:ok, "session-auth-reply"}, [token, bearer])
      refute_receive {:query_seen, _, _}, 50
    end

    test "security regression: structured response returns real Pipeline.Response" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_struct_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_agent_only(target)

      parent = self()
      facade_caller = self()

      clean = %PipelineResponse{
        content: "structured-ok",
        tool_history: [%{"name" => "noop"}],
        tool_rounds: 1
      }

      resource = "arbor://chat/agent/#{target}"

      {:ok, session_pid} =
        FakeAuthSession.start_link(parent, fn from_pid, {_tag, _msg, receipt} ->
          assert from_pid == facade_caller
          _ = Security.consume_delivery_receipt(receipt, resource, :chat)
          {:ok, clean}
        end)

      insert_fake_session!(target, session_pid)

      Application.put_env(
        :arbor_agent,
        :orchestrator_session_module,
        Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge
      )

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller)

      assert {:ok, %PipelineResponse{} = response} =
               Arbor.Agent.send_message_response(caller, target, message,
                 timeout: 5_000,
                 session_token: token
               )

      assert PipelineResponse.content(response) == "structured-ok"
      assert response.content == "structured-ok"
      assert response.tool_rounds == 1
      refute Map.has_key?(Map.from_struct(response), :text)
    end

    test "security regression: non-nil engagement_id rejected before receipt issuance" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_eng_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target)

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_message(caller, engagement_id: "engagement_claimed_#{n}")

      issue_counter = :counters.new(1, [])

      collab =
        auth_collaborators(
          issue_counter: issue_counter,
          issue_receipt: fn _c, _r, _a, _o ->
            :counters.add(issue_counter, 1, 1)
            flunk("issue must not run when engagement_id is non-nil")
          end
        )

      assert {:error, :invalid_engagement_id} =
               MessageFacade.deliver_text(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 collab
               )

      assert :counters.get(issue_counter, 1) == 0
      refute_receive {:query_seen, _, _}, 50
    end

    test "security regression: valid token without exact capability denies before delivery" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_nocap_#{n}"

      register_capture_host(target)
      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller)

      assert {:error, :unauthorized} =
               Arbor.Agent.send_message(caller, target, message, session_token: token)

      refute_receive {:query_seen, _, _}, 50
      refute_receive {:auth_session_call, _, _}, 50
      refute inspect({:error, :unauthorized}) =~ token
    end

    test "security regression: missing proof with verification on denies before delivery" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_miss_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target)
      message = build_message(caller)

      assert {:error, :unauthorized} = Arbor.Agent.send_message(caller, target, message)
      refute_receive {:query_seen, _, _}, 50
    end

    test "security regression: wrong-principal token denies before Manager" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      other = register_active_human!()
      target = "agent_msgfacade_wrongtok_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target)
      message = build_route_free_message(caller)

      assert {:ok, wrong_token} = SessionToken.generate(other)

      assert {:error, :unauthorized} =
               Arbor.Agent.send_message(caller, target, message, session_token: wrong_token)

      refute_receive {:query_seen, _, _}, 50
      refute_receive {:auth_session_call, _, _}, 50
      refute inspect({:error, :unauthorized}) =~ wrong_token
    end

    test "security regression: tampered token denies before Manager" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_tamper_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target)
      message = build_route_free_message(caller)

      assert {:ok, good} = SessionToken.generate(caller)
      {:ok, raw} = Base.url_decode64(good, padding: false)
      <<sig::binary-size(32), first, rest::binary>> = raw

      tampered =
        Base.url_encode64(sig <> <<Bitwise.bxor(first, 0xFF)>> <> rest, padding: false)

      assert {:error, :unauthorized} =
               Arbor.Agent.send_message(caller, target, message, session_token: tampered)

      refute_receive {:query_seen, _, _}, 50
      refute inspect({:error, :unauthorized}) =~ good
      refute inspect({:error, :unauthorized}) =~ tampered
    end

    test "security regression: missing Session discards receipt and never calls APIAgent" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_nosess_#{n}"
      resource = "arbor://chat/agent/#{target}"

      track_grant!(caller, resource)
      register_capture_host(target)
      # No ETS session entry

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller)

      assert {:error, :delivery_failed} =
               Arbor.Agent.send_message(caller, target, message,
                 timeout: 2_000,
                 session_token: token
               )

      refute_receive {:query_seen, _, _}, 50
    end

    test "security regression: caller PID is original facade caller not Manager/SessionManager" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_pid_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_agent_only(target)

      parent = self()
      facade_caller = self()

      resource = "arbor://chat/agent/#{target}"

      {:ok, session_pid} =
        FakeAuthSession.start_link(parent, fn from_pid, {_tag, _msg, receipt} ->
          send(parent, {:observed_caller, from_pid})
          _ = Security.consume_delivery_receipt(receipt, resource, :chat)
          {:ok, %PipelineResponse{content: "pid-ok"}}
        end)

      insert_fake_session!(target, session_pid)

      Application.put_env(
        :arbor_agent,
        :orchestrator_session_module,
        Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge
      )

      assert {:ok, token} = SessionToken.generate(caller)

      assert {:ok, "pid-ok"} =
               Arbor.Agent.send_message(
                 caller,
                 target,
                 build_route_free_message(caller),
                 timeout: 3_000,
                 session_token: token
               )

      assert_receive {:observed_caller, observed}
      assert observed == facade_caller
      refute observed == Process.whereis(SessionManager)
    end

    test "security regression: text and structured success emit one user and one assistant signal" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_sig_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_agent_only(target)

      parent = self()
      _ = Application.ensure_all_started(:arbor_signals)

      {:ok, session_pid} =
        FakeAuthSession.start_link(parent, fn _from, {_tag, _msg, receipt} ->
          _ = Security.consume_delivery_receipt(receipt, "arbor://chat/agent/#{target}", :chat)
          {:ok, %PipelineResponse{content: "signal-ok", tool_history: [], tool_rounds: 0}}
        end)

      insert_fake_session!(target, session_pid)

      Application.put_env(
        :arbor_agent,
        :orchestrator_session_module,
        Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge
      )

      handler = fn signal ->
        send(parent, {:agent_signal, signal})
        :ok
      end

      assert {:ok, sub_ref} =
               Arbor.Signals.subscribe("agent.chat_message", handler, async: false)

      on_exit(fn ->
        if Process.whereis(Arbor.Signals.Bus) do
          _ = Arbor.Signals.unsubscribe(sub_ref)
        end
      end)

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller, content: "signal path")

      assert {:ok, "signal-ok"} =
               Arbor.Agent.send_message(caller, target, message,
                 timeout: 3_000,
                 session_token: token
               )

      assert_receive {:agent_signal,
                      %{data: %{role: :user, content: "signal path"}}},
                     1_000

      assert_receive {:agent_signal,
                      %{data: %{role: :assistant, content: "signal-ok"}}},
                     1_000

      refute_receive {:agent_signal, _}, 100

      # Structured path — new session process for second call
      {:ok, session_pid2} =
        FakeAuthSession.start_link(parent, fn _from, {_tag, _msg, receipt} ->
          _ = Security.consume_delivery_receipt(receipt, "arbor://chat/agent/#{target}", :chat)
          {:ok, %PipelineResponse{content: "signal-struct", tool_history: [], tool_rounds: 0}}
        end)

      insert_fake_session!(target, session_pid2)
      assert {:ok, token2} = SessionToken.generate(caller)

      assert {:ok, %PipelineResponse{content: "signal-struct"}} =
               Arbor.Agent.send_message_response(caller, target, message,
                 timeout: 3_000,
                 session_token: token2
               )

      assert_receive {:agent_signal,
                      %{data: %{role: :user, content: "signal path"}}},
                     1_000

      assert_receive {:agent_signal,
                      %{data: %{role: :assistant, content: "signal-struct"}}},
                     1_000

      refute_receive {:agent_signal, _}, 100
    end

    test "security regression: public-path bearer echo in content fails closed without signal leak" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_echo_#{n}"
      resource = "arbor://chat/agent/#{target}"

      track_grant!(caller, resource)
      register_agent_only(target)

      parent = self()
      _ = Application.ensure_all_started(:arbor_signals)

      # Malicious Session echoes the receipt bearer into assistant content.
      # Facade must reject after admission, emit no assistant signal, clean up receipt.
      {:ok, session_pid} =
        FakeAuthSession.start_link(parent, fn _from, {_tag, _msg, receipt} ->
          assert {:ok, bearer} = DeliveryReceipt.bearer_token(receipt)
          send(parent, {:echoed_bearer, bearer})

          {:ok,
           %PipelineResponse{
             content: "leak-pre-" <> bearer <> "-post",
             tool_history: [],
             tool_rounds: 0
           }}
        end)

      insert_fake_session!(target, session_pid)

      Application.put_env(
        :arbor_agent,
        :orchestrator_session_module,
        Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge
      )

      handler = fn signal ->
        send(parent, {:agent_signal, signal})
        :ok
      end

      assert {:ok, sub_ref} =
               Arbor.Signals.subscribe("agent.chat_message", handler, async: false)

      on_exit(fn ->
        if Process.whereis(Arbor.Signals.Bus) do
          _ = Arbor.Signals.unsubscribe(sub_ref)
        end
      end)

      assert {:ok, token} = SessionToken.generate(caller)
      message = build_route_free_message(caller, content: "echo probe")

      assert {:error, :delivery_failed} =
               Arbor.Agent.send_message(caller, target, message,
                 timeout: 3_000,
                 session_token: token
               )

      assert_receive {:echoed_bearer, bearer}, 1_000
      assert_receive {:agent_signal, %{data: %{role: :user, content: "echo probe"}}}, 1_000
      # No assistant signal — admission rejected before emit.
      refute_receive {:agent_signal, %{data: %{role: :assistant}}}, 200
      refute_receive {:agent_signal, _}, 50

      assert_no_secret_leak({:error, :delivery_failed}, [token, bearer])

      # Receipt must not remain live (Session did not consume; facade discarded).
      assert {:ok, forged} = DeliveryReceipt.new(token: bearer)

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(forged, resource, :chat)
    end
  end

  # ---------------------------------------------------------------------------
  # A3. Synthetic authenticated failure matrix + secret containment
  # ---------------------------------------------------------------------------

  describe "security regression: authenticated failure matrix and secret containment" do
    @describetag voice_id: "VOICE-17"
    @describetag spec: "VOICE-17"

    test "security regression: issue faults never deliver and create no receipt", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "proof-#{System.unique_integer([:positive])}"
      chat_auth_counter = :counters.new(1, [])

      faults = [
        fn _c, _r, _a, _o -> {:error, :unauthorized} end,
        fn _c, _r, _a, _o -> {:error, :broker_unavailable} end,
        fn _c, _r, _a, _o -> {:ok, :not_a_receipt} end,
        fn _c, _r, _a, _o -> :ok end,
        fn _c, _r, _a, _o -> raise "issue boom" end,
        fn _c, _r, _a, _o -> throw(:issue_throw) end,
        fn _c, _r, _a, _o -> exit(:issue_exit) end
      ]

      for issue <- faults do
        collab =
          auth_collaborators(
            chat_auth_counter: chat_auth_counter,
            issue_receipt: issue
          )

        :counters.put(chat_auth_counter, 1, 0)

        assert {:error, :unauthorized} =
                 MessageFacade.deliver_text(
                   caller,
                   target,
                   message,
                   [session_token: token],
                   collab
                 )

        assert :counters.get(chat_auth_counter, 1) == 0
      end
    end

    test "security regression: delivery faults discard receipt and return :delivery_failed", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "proof-#{System.unique_integer([:positive])}"
      discard_counter = :counters.new(1, [])

      faults = [
        fn _m, _s, _r, _o -> {:error, :agent_not_found} end,
        fn _m, _s, _r, _o -> {:error, :no_session} end,
        fn _m, _s, _r, _o -> {:error, :session_unavailable} end,
        fn _m, _s, _r, _o -> {:ok, %{text: "not-a-response"}} end,
        fn _m, _s, _r, _o -> :ok end,
        fn _m, _s, _r, _o -> raise "delivery boom" end,
        fn _m, _s, _r, _o -> throw(:delivery_throw) end,
        fn _m, _s, _r, _o -> exit(:delivery_exit) end
      ]

      for on_chat <- faults do
        :counters.put(discard_counter, 1, 0)

        collab =
          auth_collaborators(
            discard_counter: discard_counter,
            on_chat: on_chat
          )

        assert {:error, :delivery_failed} =
                 MessageFacade.deliver_text(
                   caller,
                   target,
                   message,
                   [session_token: token],
                   collab
                 )

        assert :counters.get(discard_counter, 1) == 1
        assert_receive {:discard_seen, %DeliveryReceipt{}}
      end
    end

    test "security regression: embedded proof in content discards and fails closed", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "proof-embed-#{System.unique_integer([:positive])}"
      discard_counter = :counters.new(1, [])
      bearer_holder = :ets.new(:bearer_holder, [:set, :public])

      issue = fn _c, _r, _a, _o ->
        raw = :crypto.strong_rand_bytes(32)
        assert {:ok, receipt} = DeliveryReceipt.new(token: raw)
        true = :ets.insert(bearer_holder, {:bearer, raw})
        {:ok, receipt}
      end

      on_chat = fn _m, _s, _receipt, _o ->
        # Prefixed/suffixed proof echo in content — containment must reject.
        {:ok, "pre-" <> token <> "-post"}
      end

      collab =
        auth_collaborators(
          discard_counter: discard_counter,
          issue_receipt: issue,
          on_chat: on_chat
        )

      assert {:error, :delivery_failed} =
               MessageFacade.deliver_text(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 collab
               )

      assert :counters.get(discard_counter, 1) == 1
      assert_receive {:discard_seen, _}
      assert_no_secret_leak({:error, :delivery_failed}, [token])
      :ets.delete(bearer_holder)
    end

    test "security regression: embedded bearer in nested list/map discards and fails closed", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "proof-nested-#{System.unique_integer([:positive])}"
      discard_counter = :counters.new(1, [])

      issue = fn _c, _r, _a, _o ->
        raw = :crypto.strong_rand_bytes(32)
        assert {:ok, receipt} = DeliveryReceipt.new(token: raw)
        send(self(), {:issued_bearer, raw})
        {:ok, receipt}
      end

      on_chat = fn _m, _s, receipt, _o ->
        assert {:ok, bearer} = DeliveryReceipt.bearer_token(receipt)

        {:ok,
         %PipelineResponse{
           content: "ok",
           tool_history: [%{"note" => "x" <> bearer <> "y"}],
           tool_rounds: 0
         }}
      end

      collab =
        auth_collaborators(
          discard_counter: discard_counter,
          issue_receipt: issue,
          chat_response_authenticated: on_chat
        )

      assert {:error, :delivery_failed} =
               MessageFacade.deliver_response(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 collab
               )

      assert :counters.get(discard_counter, 1) == 1
      assert_receive {:discard_seen, _}
      assert_receive {:issued_bearer, bearer}
      assert_no_secret_leak({:error, :delivery_failed}, [token, bearer])
    end

    test "security regression: nested DeliveryReceipt struct in response fails closed", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "proof-struct-#{System.unique_integer([:positive])}"
      discard_counter = :counters.new(1, [])

      on_chat = fn _m, _s, receipt, _o ->
        {:ok,
         %PipelineResponse{
           content: "ok",
           tool_history: [%{nested: receipt}],
           tool_rounds: 0
         }}
      end

      collab =
        auth_collaborators(
          discard_counter: discard_counter,
          chat_response_authenticated: on_chat
        )

      assert {:error, :delivery_failed} =
               MessageFacade.deliver_response(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 collab
               )

      assert :counters.get(discard_counter, 1) == 1
    end

    test "security regression: clean auth success projects Pipeline.Response without secrets", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller, content: "clean-auth")
      token = "proof-clean-#{System.unique_integer([:positive])}"
      discard_counter = :counters.new(1, [])

      clean = %PipelineResponse{
        content: "assistant-clean",
        tool_history: [],
        tool_rounds: 0,
        raw: %{should: "drop"},
        metadata: %{should: "drop"}
      }

      collab =
        auth_collaborators(
          discard_counter: discard_counter,
          reply: {:ok, clean}
        )

      assert {:ok, %PipelineResponse{} = response} =
               MessageFacade.deliver_response(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 collab
               )

      assert response.content == "assistant-clean"
      assert PipelineResponse.content(response) == "assistant-clean"
      assert response.raw == nil
      assert response.metadata == %{}
      assert :counters.get(discard_counter, 1) == 0
      assert_receive {:chat_auth_seen, ^message, ^caller, %DeliveryReceipt{}, opts}
      assert opts[:agent_id] == target
      refute Keyword.has_key?(opts, :session_token)
    end

    test "security regression: composite map keys cannot smuggle proof or bearer", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "proof-key-#{System.unique_integer([:positive])}"
      discard_counter = :counters.new(1, [])

      issue = fn _c, _r, _a, _o ->
        raw = :crypto.strong_rand_bytes(32)
        assert {:ok, receipt} = DeliveryReceipt.new(token: raw)
        send(self(), {:issued_bearer, raw})
        {:ok, receipt}
      end

      # Proof smuggled in a tuple key; bearer smuggled in a list key.
      on_chat = fn _m, _s, receipt, _o ->
        assert {:ok, bearer} = DeliveryReceipt.bearer_token(receipt)

        {:ok,
         %PipelineResponse{
           content: "ok",
           tool_history: [],
           tool_rounds: 0,
           usage: %{{:meta, token} => "x", [bearer] => "y"}
         }}
      end

      collab =
        auth_collaborators(
          discard_counter: discard_counter,
          issue_receipt: issue,
          chat_response_authenticated: on_chat
        )

      assert {:error, :delivery_failed} =
               MessageFacade.deliver_response(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 collab
               )

      assert :counters.get(discard_counter, 1) == 1
      assert_receive {:discard_seen, _}
      assert_receive {:issued_bearer, bearer}
      assert_no_secret_leak({:error, :delivery_failed}, [token, bearer])
    end
  end

  # ---------------------------------------------------------------------------
  # B. Security regression — real deny before delivery
  # ---------------------------------------------------------------------------

  describe "security regression: real capability deny before delivery" do
    test "security regression: missing capability denies and never delivers", %{
      caller: caller,
      target: target
    } do
      register_capture_host(target)
      message = build_message(caller)

      assert {:error, :unauthorized} = Arbor.Agent.send_message(caller, target, message)
      refute_receive {:query_seen, _, _}, 50
    end

    test "security regression: capability scoped to another agent denies before delivery", %{
      caller: caller,
      target: target,
      other: other
    } do
      track_grant!(caller, "arbor://chat/agent/#{other}")
      register_capture_host(target)
      message = build_message(caller)

      assert {:error, :unauthorized} = Arbor.Agent.send_message(caller, target, message)
      refute_receive {:query_seen, _, _}, 50
    end
  end

  # ---------------------------------------------------------------------------
  # C. Security regression — synthetic authorize fault classes
  # ---------------------------------------------------------------------------

  describe "security regression: authorize fault classes fail closed" do
    test "security regression: pending, malformed, raise, throw, exit, unavailable never deliver",
         %{
           caller: caller,
           target: target
         } do
      message = build_message(caller)
      chat = flunk_chat_fun()

      faults = [
        fn _c, _r, _a, _o -> {:ok, :pending_approval, "prop_1"} end,
        fn _c, _r, _a, _o -> :ok end,
        fn _c, _r, _a, _o -> {:ok, :weird} end,
        fn _c, _r, _a, _o -> :authorized end,
        fn _c, _r, _a, _o -> raise "auth boom" end,
        fn _c, _r, _a, _o -> throw(:auth_throw) end,
        fn _c, _r, _a, _o -> exit(:auth_exit) end,
        fn _c, _r, _a, _o -> exit({:noproc, {GenServer, :call, [:missing, :x]}}) end
      ]

      for authorize <- faults do
        assert {:error, :unauthorized} =
                 MessageFacade.deliver(caller, target, message, [], authorize, chat)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # D. Validation before effects
  # ---------------------------------------------------------------------------

  describe "input and option validation before effects" do
    test "rejects invalid ids, sender, engagement, content, and opts before authorize/delivery",
         %{
           caller: caller,
           target: target
         } do
      {auth_c, chat_c, authorize, chat} = counting_funs()
      good = build_message(caller)
      oversize_id = "agent_" <> String.duplicate("a", 252)

      cases = [
        {"not_a_principal", target, good, [], :invalid_caller_id},
        {caller, "not_a_principal", good, [], :invalid_agent_id},
        {"agent_", target, good, [], :invalid_caller_id},
        {caller, "agent_bad/segment", good, [], :invalid_agent_id},
        {caller, "agent_bad?x", good, [], :invalid_agent_id},
        {caller, "agent_bad#frag", good, [], :invalid_agent_id},
        {caller, "agent_bad@host", good, [], :invalid_agent_id},
        {"human_ has space", target, good, [], :invalid_caller_id},
        {caller, "agent_ctrl\n", good, [], :invalid_agent_id},
        {caller, "agent_foo%2Fbar", good, [], :invalid_agent_id},
        {caller, "agent_foo%3Fbar", good, [], :invalid_agent_id},
        {caller, "agent_föo", good, [], :invalid_agent_id},
        {caller, "agent_foo🚀", good, [], :invalid_agent_id},
        {caller, "agent_foo\\bar", good, [], :invalid_agent_id},
        {caller, "agent_foo bar", good, [], :invalid_agent_id},
        {caller, "agent_foo\tbar", good, [], :invalid_agent_id},
        {caller, oversize_id, good, [], :invalid_agent_id},
        {caller, target, build_message(caller, sender_id: "human_other"), [], :invalid_sender},
        {caller, target, %{good | engagement_id: nil}, [], :invalid_engagement_id},
        {caller, target, %{good | engagement_id: "   "}, [], :invalid_engagement_id},
        {caller, target, %{good | engagement_id: <<0, "x">>}, [], :invalid_engagement_id},
        {caller, target, %{good | content: ""}, [], :invalid_content},
        {caller, target, %{good | content: "   "}, [], :invalid_content},
        {caller, target, %{good | content: String.duplicate("a", 32_769)}, [], :invalid_content},
        {caller, target, "not a struct", [], :invalid_message},
        {caller, target, good, [timeout: 0], :invalid_timeout},
        {caller, target, good, [timeout: 30_001], :invalid_timeout},
        {caller, target, good, [timeout: -1], :invalid_timeout},
        {caller, target, good, [timeout: "fast"], :invalid_timeout},
        {caller, target, good, [unknown: true], :invalid_opts},
        {caller, target, good, [timeout: 1000, timeout: 2000], :invalid_opts},
        {caller, target, good, [session_token: nil], :invalid_opts},
        {caller, target, good, [session_token: ""], :invalid_opts},
        {caller, target, good, [session_token: :atom], :invalid_opts},
        {caller, target, good, [session_token: String.duplicate("x", 4097)], :invalid_opts},
        {caller, target, good, [session_token: "a", session_token: "b"], :invalid_opts},
        {caller, target, good, %{timeout: 1000}, :invalid_opts},
        {caller, target, good, :timeout, :invalid_opts},
        {caller, target, good, [{:timeout, 1000} | :not_a_list], :invalid_opts},
        {caller, target, good, [:timeout], :invalid_opts}
      ]

      for {c, t, msg, opts, expected} <- cases do
        :counters.put(auth_c, 1, 0)
        :counters.put(chat_c, 1, 0)

        assert {:error, ^expected} = MessageFacade.deliver(c, t, msg, opts, authorize, chat)
        assert :counters.get(auth_c, 1) == 0
        assert :counters.get(chat_c, 1) == 0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # E. Manager failure normalize
  # ---------------------------------------------------------------------------

  describe "Manager failure normalization" do
    test "errors, malformed success, raise, throw, exit become :delivery_failed without leakage",
         %{
           caller: caller,
           target: target
         } do
      message = build_message(caller, content: "secret-content-xyz", engagement_id: "eng_secret")
      authorize = fn _c, _r, _a, _o -> {:ok, :authorized} end

      chats = [
        fn _m, _s, _o -> {:error, :agent_not_found} end,
        fn _m, _s, _o -> {:ok, %{text: "x"}} end,
        fn _m, _s, _o -> :ok end,
        fn _m, _s, _o -> raise "manager boom secret-content-xyz" end,
        fn _m, _s, _o -> throw({:boom, "eng_secret"}) end,
        fn _m, _s, _o -> exit({:killed, "secret-content-xyz"}) end
      ]

      for chat <- chats do
        assert {:error, :delivery_failed} =
                 MessageFacade.deliver(caller, target, message, [], authorize, chat)
      end
    end

    test "valid binary reply including empty string is returned unchanged", %{
      caller: caller,
      target: target
    } do
      message = build_message(caller)
      authorize = fn _c, _r, _a, _o -> {:ok, :authorized} end

      assert {:ok, ""} =
               MessageFacade.deliver(caller, target, message, [], authorize, fn _m, _s, _o ->
                 {:ok, ""}
               end)

      chat = fn msg, sender, opts ->
        assert msg == message
        assert sender == caller
        assert opts[:agent_id] == target
        assert opts[:timeout] == 100
        refute Keyword.has_key?(opts, :session_token)
        {:ok, "ok"}
      end

      assert {:ok, "ok"} =
               MessageFacade.deliver(caller, target, message, [timeout: 100], authorize, chat)
    end
  end

  # ---------------------------------------------------------------------------
  # F. Absent-token compatibility (ordinary authorize path)
  # ---------------------------------------------------------------------------

  describe "security regression: absent-token ordinary path compatibility" do
    test "security regression: absent session_token forwards empty auth opts", %{
      caller: caller,
      target: target
    } do
      message = build_message(caller)

      authorize = fn _c, _r, _a, auth_opts ->
        assert auth_opts == []
        {:ok, :authorized}
      end

      chat = fn _m, _s, opts ->
        refute Keyword.has_key?(opts, :session_token)
        {:ok, "ok"}
      end

      assert {:ok, "ok"} = MessageFacade.deliver(caller, target, message, [], authorize, chat)
    end

    test "security regression: present token never calls ordinary authorize/chat", %{
      caller: caller,
      target: target
    } do
      message = build_route_free_message(caller)
      token = "tok-#{System.unique_integer([:positive])}"

      authorize = fn _c, _r, _a, _o -> flunk("authorize must not run on auth branch") end
      chat = fn _m, _s, _o -> flunk("chat must not run on auth branch") end

      # deliver/6 with token present routes to issue path; default issue fails closed
      assert {:error, :unauthorized} =
               MessageFacade.deliver(
                 caller,
                 target,
                 message,
                 [session_token: token],
                 authorize,
                 chat
               )
    end

    @tag voice_id: "VOICE-17"
    test "security regression: agent caller without token uses authorize+Manager, no auth Session" do
      n = System.unique_integer([:positive])
      # Agent principal id shape — ordinary path only (issue is human-only).
      caller = "agent_msgfacade_agentcaller_#{n}"
      target = "agent_msgfacade_agenttarget_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target, self(), "agent-reply")

      message =
        build_message(caller,
          content: "agent-to-agent",
          engagement_id: "engagement_agent_#{n}"
        )

      assert {:ok, "agent-reply"} =
               Arbor.Agent.send_message(caller, target, message, timeout: 3_000)

      assert_receive {:query_seen, %UserMessage{} = seen, opts}
      assert seen == message
      refute Keyword.has_key?(opts, :session_token)
      refute_receive {:auth_session_call, _, _}, 50
    end
  end

  # ---------------------------------------------------------------------------
  # G. Public fixed collaborators / exports
  # ---------------------------------------------------------------------------

  describe "public facade uses fixed collaborators" do
    test "send_message and send_message_response are exported" do
      exports = Arbor.Agent.__info__(:functions)
      assert {:send_message, 3} in exports
      assert {:send_message, 4} in exports
      assert {:send_message_response, 3} in exports
      assert {:send_message_response, 4} in exports
    end
  end
end

defmodule Arbor.Agent.MessageFacadeSecurityRegressionTest.SessionBridge do
  @moduledoc false
  # Runtime bridge stand-in: same arity as Orchestrator.Session.send_authenticated_message/4
  # but delegates to GenServer.call so FakeAuthSession (bare process) works.

  def send_authenticated_message(session, message, receipt, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      session,
      {:send_authenticated_message, message, receipt},
      timeout_ms
    )
  end

  def send_authenticated_message(_session, _message, _receipt, _timeout_ms),
    do: {:error, :invalid_authenticated_message_request}
end
