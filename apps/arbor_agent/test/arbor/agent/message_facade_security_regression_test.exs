defmodule Arbor.Agent.MessageFacadeSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.MessageFacade
  alias Arbor.Agent.Registry
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
          {Arbor.Security.Reflex.Registry, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    assert Process.whereis(Arbor.Security.CapabilityStore) != nil,
           "CapabilityStore must be running for real Security path tests"

    :ok
  end

  setup do
    original_identity = Application.get_env(:arbor_security, :identity_verification, true)
    original_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled, true)
    original_strict = Application.get_env(:arbor_security, :strict_identity_mode, false)
    original_signing = Application.get_env(:arbor_security, :capability_signing_required, true)

    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)

    on_exit(fn ->
      Application.put_env(:arbor_security, :identity_verification, original_identity)
      Application.put_env(:arbor_security, :reflex_checking_enabled, original_reflex)
      Application.put_env(:arbor_security, :strict_identity_mode, original_strict)
      Application.put_env(:arbor_security, :capability_signing_required, original_signing)
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

  # ---------------------------------------------------------------------------
  # A. Real Security + Manager authorized exact envelope
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
  # A2. Enabled identity verification + human session token (public path)
  # ---------------------------------------------------------------------------

  describe "security regression: enabled identity verification with session_token" do
    setup do
      prev_secret = Application.get_env(:arbor_security, :session_token_secret)

      Application.put_env(
        :arbor_security,
        :session_token_secret,
        "agent-msg-facade-secret-#{System.unique_integer([:positive])}"
      )

      # Force the production identity-verification path ON for this describe.
      Application.put_env(:arbor_security, :identity_verification, true)

      on_exit(fn ->
        case prev_secret do
          nil -> Application.delete_env(:arbor_security, :session_token_secret)
          v -> Application.put_env(:arbor_security, :session_token_secret, v)
        end
      end)

      :ok
    end

    test "security regression: valid human token + exact chat cap delivers exact envelope once" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_tok_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      host_pid = register_capture_host(target, self(), "reply-token")

      assert {:ok, token} = SessionToken.generate(caller)

      message =
        build_message(caller,
          content: "enabled-identity token path",
          engagement_id: "engagement_token_#{n}"
        )

      assert {:ok, "reply-token"} =
               Arbor.Agent.send_message(caller, target, message,
                 timeout: 5_000,
                 session_token: token
               )

      assert_receive {:query_seen, %UserMessage{} = seen, opts}
      refute_receive {:query_seen, _, _}, 50

      assert seen == message
      assert opts[:timeout] == 5_000
      refute Keyword.has_key?(opts, :session_token)
      refute inspect(opts) =~ token
      refute inspect({:ok, "reply-token"}) =~ token
      assert Process.alive?(host_pid)
    end

    test "security regression: valid token without exact capability denies before delivery" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_nocap_#{n}"

      register_capture_host(target)
      assert {:ok, token} = SessionToken.generate(caller)
      message = build_message(caller)

      assert {:error, :unauthorized} =
               Arbor.Agent.send_message(caller, target, message, session_token: token)

      refute_receive {:query_seen, _, _}, 50
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

    test "security regression: exact capability but wrong-principal token denies before Manager" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      other = register_active_human!()
      target = "agent_msgfacade_wrongtok_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target)
      message = build_message(caller)

      assert {:ok, wrong_token} = SessionToken.generate(other)

      assert {:error, :unauthorized} =
               Arbor.Agent.send_message(caller, target, message, session_token: wrong_token)

      refute_receive {:query_seen, _, _}, 50
      refute inspect({:error, :unauthorized}) =~ wrong_token
    end

    test "security regression: exact capability but tampered token denies before Manager" do
      n = System.unique_integer([:positive])
      caller = register_active_human!()
      target = "agent_msgfacade_tamper_#{n}"

      track_grant!(caller, "arbor://chat/agent/#{target}")
      register_capture_host(target)
      message = build_message(caller)

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
        # Percent-encoded separators must not pass the positive allowlist
        {caller, "agent_foo%2Fbar", good, [], :invalid_agent_id},
        {caller, "agent_foo%3Fbar", good, [], :invalid_agent_id},
        # Unicode outside [A-Za-z0-9_-]
        {caller, "agent_föo", good, [], :invalid_agent_id},
        {caller, "agent_foo🚀", good, [], :invalid_agent_id},
        # Reserved / control bytes
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
        # Non-keyword / improper / non-list option shapes
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
  # F. Session token option forwarding (synthetic)
  # ---------------------------------------------------------------------------

  describe "security regression: session_token option forwarding" do
    test "security regression: authorizer receives exact token once; Manager never sees it", %{
      caller: caller,
      target: target
    } do
      message = build_message(caller)
      token = "session-token-sentinel-#{System.unique_integer([:positive])}"
      auth_counter = :counters.new(1, [])

      authorize = fn c, resource, action, auth_opts ->
        :counters.add(auth_counter, 1, 1)
        assert c == caller
        assert resource == "arbor://chat/agent/#{target}"
        assert action == :chat
        assert auth_opts == [session_token: token]
        {:ok, :authorized}
      end

      chat = fn msg, sender, opts ->
        assert msg == message
        assert sender == caller
        assert opts[:agent_id] == target
        assert opts[:timeout] == 5_000
        refute Keyword.has_key?(opts, :session_token)
        refute inspect(opts) =~ token
        {:ok, "reply-ok"}
      end

      assert {:ok, "reply-ok"} =
               MessageFacade.deliver(
                 caller,
                 target,
                 message,
                 [timeout: 5_000, session_token: token],
                 authorize,
                 chat
               )

      assert :counters.get(auth_counter, 1) == 1
    end

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
  end

  # ---------------------------------------------------------------------------
  # G. Public fixed collaborators / exports
  # ---------------------------------------------------------------------------

  describe "public facade uses fixed collaborators" do
    test "send_message/3 and send_message/4 are both exported" do
      exports = Arbor.Agent.__info__(:functions)
      assert {:send_message, 3} in exports
      assert {:send_message, 4} in exports
    end
  end
end
