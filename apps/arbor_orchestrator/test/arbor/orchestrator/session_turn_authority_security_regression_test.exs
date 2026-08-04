defmodule Arbor.Orchestrator.SessionTurnAuthoritySecurityRegressionTest do
  @moduledoc """
  Security regression: receipt-authenticated Session ingress (VP-05D2A1P2).

  Security prerequisite for VOICE-17 (planned); does not un-plan the normative
  VOICE-17 statement. Self-contained — no shared new helper modules.
  """

  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"
  @moduletag spec: "VOICE-17"

  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Identifiers
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Security
  alias Arbor.Security.SessionToken

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

    :ok
  end

  setup do
    prev = %{
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      secret: Application.get_env(:arbor_security, :session_token_secret)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "vp05d2a1p2-test-secret-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      restore(:identity_verification, prev.identity_verification)
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
      restore(:session_token_secret, prev.secret)
    end)

    agent = register_active_agent!()
    agent_id = agent.agent_id
    human_id = register_active_human!()
    resource = "arbor://chat/agent/#{agent_id}"
    grant!(human_id, resource)

    %{
      agent_id: agent_id,
      agent_signer: agent.signer,
      human_id: human_id,
      resource: resource
    }
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)

  defp register_active_agent! do
    assert {:ok, identity} = Identity.generate(name: "VP05D2A1P2 session agent")
    assert :ok = Security.register_identity(Identity.public_only(identity))

    on_exit(fn ->
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{
      agent_id: identity.agent_id,
      signer: fn resource ->
        SignedRequest.sign(resource, identity.agent_id, identity.private_key)
      end
    }
  end

  defp register_active_human! do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/vp05d2a1p2/#{unique}"
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
      "name" => "VP05D2A1P2 OIDC Human"
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

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp put_orchestrator_cap!(agent_id) do
    assert {:ok, cap} =
             Arbor.Contracts.Security.Capability.new(
               resource_uri: "arbor://orchestrator/execute/**",
               principal_id: agent_id,
               delegation_depth: 0,
               constraints: %{},
               metadata: %{test: true}
             )

    Arbor.Security.CapabilityStore.put(cap)

    on_exit(fn ->
      _ = Arbor.Security.CapabilityStore.revoke(cap.id)
    end)

    cap
  end

  defp issue_receipt!(human_id, resource, action \\ :chat) do
    assert {:ok, token} = SessionToken.generate(human_id)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(human_id, resource, action,
               session_token: token
             )

    receipt
  end

  defp user_message!(human_id, content \\ "hello authenticated") do
    UserMessage.from_voice(content, sender_id: human_id)
  end

  defp session_state(agent_id, overrides \\ []) do
    base = %Session{
      session_id: "session_vp05d2a1p2_#{System.unique_integer([:positive])}",
      agent_id: agent_id,
      phase: :idle,
      turn_count: 0,
      messages: [],
      turn_in_flight: false,
      turn_from: nil,
      turn_caller_ref: nil,
      turn_task_ref: nil,
      turn_task_pid: nil,
      turn_user_message: nil,
      streaming_buffer: nil,
      turn_queue: [],
      cancelled_task_ids: %{},
      cancelled_task_id_order: [],
      config: %{},
      session_state: nil,
      behavior: nil,
      steer_froms: [],
      execution_mode: :session
    }

    Enum.reduce(overrides, Map.put(base, :turn_authority, nil), fn {key, value}, state ->
      Map.put(state, key, value)
    end)
  end

  defp authority!(human_id) do
    assert {:ok, auth} =
             TurnAuthority.new(
               turn_id: Identifiers.generate_id("turn_"),
               authenticated_principal_id: human_id,
               disclosure_capability_id: nil
             )

    auth
  end

  # Detect receipts or raw authority/receipt material in a term tree.
  # `allow_turn_authority?: true` permits process-local TurnAuthority structs
  # (Session state/queue) while still rejecting raw id/token bytes when listed.
  defp term_contains_forbidden?(term, forbidden_binaries, opts) do
    allow_ta? = Keyword.get(opts, :allow_turn_authority?, false)
    inspected = inspect(term, limit: :infinity, printable_limit: :infinity)

    Enum.any?(forbidden_binaries, fn bin ->
      is_binary(bin) and bin != "" and String.contains?(inspected, bin)
    end) or walk_forbidden?(term, forbidden_binaries, allow_ta?)
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_struct(term) do
    cond do
      is_struct(term, DeliveryReceipt) ->
        true

      is_struct(term, TurnAuthority) and not allow_ta? ->
        true

      is_struct(term, TurnAuthority) and allow_ta? ->
        # Process-local authority is allowed; still scan for raw forbidden bytes
        # only via inspect redaction — field access for leak of raw tokens.
        false

      true ->
        walk_forbidden?(Map.from_struct(term), forbidden, allow_ta?)
    end
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_map(term) do
    Enum.any?(term, fn {k, v} ->
      walk_forbidden?(k, forbidden, allow_ta?) or walk_forbidden?(v, forbidden, allow_ta?)
    end)
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_list(term) do
    Enum.any?(term, &walk_forbidden?(&1, forbidden, allow_ta?))
  end

  defp walk_forbidden?(term, forbidden, allow_ta?) when is_tuple(term) do
    term |> Tuple.to_list() |> walk_forbidden?(forbidden, allow_ta?)
  end

  defp walk_forbidden?(term, forbidden, _allow_ta?) when is_binary(term) do
    Enum.any?(forbidden, fn bin ->
      is_binary(bin) and bin != "" and String.contains?(term, bin)
    end)
  end

  defp walk_forbidden?(_term, _forbidden, _allow_ta?), do: false

  defp receipt_token_hex(receipt) do
    case DeliveryReceipt.bearer_token(receipt) do
      {:ok, token} -> Base.encode16(token, case: :lower)
      _ -> nil
    end
  end

  describe "security regression: exact authenticated ingress" do
    test "queues authority without receipt after exact consume and principal bind", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      msg = user_message!(human_id)
      token_hex = receipt_token_hex(receipt)
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active")
        )

      assert {:noreply, new_state} =
               Session.handle_call({:send_authenticated_message, msg, receipt}, from, state)

      assert length(new_state.turn_queue) == 1
      assert [{queued_msg, %TurnAuthority{} = auth, ^from}] = new_state.turn_queue
      assert queued_msg.sender_id == human_id
      assert queued_msg.content == msg.content
      assert auth.authenticated_principal_id == human_id
      assert auth.disclosure_capability_id == nil
      assert auth.turn_id =~ ~r/^turn_[0-9a-f]{32}$/

      refute term_contains_forbidden?(new_state.turn_queue, [token_hex],
               allow_turn_authority?: true
             )

      refute match?(%DeliveryReceipt{}, elem(hd(new_state.turn_queue), 1))

      # Replay must fail closed — receipt already consumed.
      assert {:reply, {:error, :unauthenticated}, returned_replay} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned_replay.turn_queue == state.turn_queue
      assert returned_replay.turn_authority == nil
    end

    test "sender mismatch consumes receipt and refuses without starting a turn", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      wrong = user_message!("human_other_claim")
      from = {self(), make_ref()}
      state = session_state(agent_id)

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call({:send_authenticated_message, wrong, receipt}, from, state)

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil
      assert returned.turn_user_message == nil

      # Destructive — replay with corrected sender also fails.
      corrected = user_message!(human_id)

      assert {:reply, {:error, :unauthenticated}, _} =
               Session.handle_call(
                 {:send_authenticated_message, corrected, receipt},
                 from,
                 state
               )
    end

    test "wrong target agent refuses and does not run a turn", %{
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      other_agent = "agent_other_#{System.unique_integer([:positive])}"
      msg = user_message!(human_id)
      state = session_state(other_agent)

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil
    end

    test "wrong action binding (same resource, non-chat action) refuses and cannot replay", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      # Same resource as Session will target, but issued for a non-:chat action.
      # Session always consumes with :chat — action mismatch must refuse.
      receipt = issue_receipt!(human_id, resource, :write)
      msg = user_message!(human_id)
      state = session_state(agent_id)

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []
      assert returned.turn_authority == nil

      # Bound to the issued action (or already discarded/failed) — cannot be
      # replayed as a successful :chat ingress either.
      assert {:reply, {:error, :unauthenticated}, _} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )
    end

    test "forged and malformed receipts refuse with bounded error", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      msg = user_message!(human_id)
      state = session_state(agent_id)
      from = {self(), make_ref()}

      assert {:ok, forged} = DeliveryReceipt.new(token: :crypto.strong_rand_bytes(32))

      assert {:reply, {:error, :unauthenticated}, returned} =
               Session.handle_call({:send_authenticated_message, msg, forged}, from, state)

      assert returned.turn_in_flight == false
      assert returned.turn_queue == []

      # Embellished forged UserMessage map (extra keys) fails closed.
      embellished = Map.put(msg, :extra_field, "smuggle")
      receipt2 = issue_receipt!(human_id, "arbor://chat/agent/#{agent_id}")

      assert {:reply, {:error, :unauthenticated}, returned2} =
               Session.handle_call(
                 {:send_authenticated_message, embellished, receipt2},
                 from,
                 state
               )

      assert returned2.turn_in_flight == false
      assert returned2.turn_queue == []
    end

    test "legacy mode discards receipt and never authenticates", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      msg = user_message!(human_id)
      state = session_state(agent_id, execution_mode: :legacy)

      assert {:reply, {:error, :legacy_mode}, returned} =
               Session.handle_call(
                 {:send_authenticated_message, msg, receipt},
                 {self(), make_ref()},
                 state
               )

      assert returned.turn_authority == nil
      assert returned.turn_queue == []

      # Receipt was discarded — cannot be consumed later.
      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)
    end

    test "public API rejects non-exact shapes without leaking", %{
      agent_id: agent_id
    } do
      assert {:error, :unauthenticated} =
               Session.send_authenticated_message(self(), "bare", :not_receipt)

      state = session_state(agent_id)
      assert state.turn_authority == nil
    end
  end

  describe "security regression: queue steering and reset" do
    test "authenticated queue head is never folded; nil-nil still steers", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      auth_from = {self(), make_ref()}
      nil_from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: nil,
          turn_user_message: UserMessage.from_string("active nil"),
          turn_queue: [
            {user_message!(human_id, "auth queued"), auth, auth_from},
            {UserMessage.from_string("nil queued"), nil, nil_from}
          ]
        )

      assert {:reply, :none, still} =
               Session.handle_call(:take_steering, {self(), make_ref()}, state)

      # Head retained, order preserved.
      assert still.turn_queue == state.turn_queue
      assert still.steer_froms == []

      # Active authority-bearing blocks fold of nil head too.
      active_auth =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: auth,
          turn_user_message: user_message!(human_id, "active auth"),
          turn_queue: [{UserMessage.from_string("nil head"), nil, nil_from}]
        )

      assert {:reply, :none, still_active} =
               Session.handle_call(:take_steering, {self(), make_ref()}, active_auth)

      assert still_active.turn_queue == active_auth.turn_queue

      # Both nil: fold.
      both_nil =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: nil,
          turn_user_message: UserMessage.from_string("active"),
          turn_queue: [{UserMessage.from_string("steer me"), nil, nil_from}]
        )

      assert {:reply, "steer me", folded} =
               Session.handle_call(:take_steering, {self(), make_ref()}, both_nil)

      assert folded.turn_queue == []
      assert nil_from in folded.steer_froms
    end

    test "authority retained in queue through drain head; reset clears active authority", %{
      agent_id: agent_id,
      agent_signer: agent_signer,
      human_id: human_id
    } do
      auth = authority!(human_id)
      from = {self(), make_ref()}
      msg = user_message!(human_id, "drained auth turn")
      next_from = {self(), make_ref()}

      in_flight =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: auth,
          turn_user_message: msg,
          turn_from: from,
          turn_queue: [
            {user_message!(human_id, "auth next"), auth, next_from},
            {UserMessage.from_string("nil after"), nil, {self(), make_ref()}}
          ]
        )

      # Common reset path clears active authority; queue retains FIFO authority.
      {:reply, :ok, after_cancel} =
        Session.handle_call(:cancel_turn, {self(), make_ref()}, in_flight)

      assert after_cancel.turn_authority == nil
      assert after_cancel.turn_in_flight == false
      assert length(after_cancel.turn_queue) == 2

      assert [{%UserMessage{content: "auth next"}, %TurnAuthority{}, ^next_from} | _] =
               after_cancel.turn_queue

      # Drain tombstone path: skip cancelled task without reordering survivors.
      from_b = {self(), make_ref()}
      from_c = {self(), make_ref()}
      msg_b = %{UserMessage.from_string("b") | transport_metadata: %{task_id: "task_b"}}

      drain_state =
        session_state(agent_id,
          cancelled_task_ids: %{"task_b" => true},
          cancelled_task_id_order: ["task_b"],
          turn_queue: [
            {msg_b, auth, from_b},
            {UserMessage.from_string("c work"), nil, from_c}
          ]
        )

      assert {:noreply, after_b} = Session.handle_info(:drain_queue, drain_state)
      assert length(after_b.turn_queue) == 1
      assert match?({%UserMessage{content: "c work"}, nil, _}, hd(after_b.turn_queue))
      refute after_b.turn_in_flight

      # Idle authenticated start sets turn_authority before the Task runs.
      put_orchestrator_cap!(agent_id)
      receipt = issue_receipt!(human_id, "arbor://chat/agent/#{agent_id}")
      idle = session_state(agent_id, turn_graph: nil, signer: agent_signer)
      start_from = {self(), make_ref()}

      assert {:noreply, started} =
               Session.handle_call(
                 {:send_authenticated_message, user_message!(human_id, "start auth"), receipt},
                 start_from,
                 idle
               )

      assert %TurnAuthority{} = started.turn_authority
      assert started.turn_authority.authenticated_principal_id == human_id
      assert started.turn_authority.disclosure_capability_id == nil
      assert started.turn_in_flight == true
      # Receipt never retained on state (authority itself is process-local OK).
      refute term_contains_forbidden?(started, [receipt_token_hex(receipt)],
               allow_turn_authority?: true
             )
    end

    test "direct send_message always carries nil authority in the queue", %{
      agent_id: agent_id
    } do
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active"),
          turn_authority: nil
        )

      assert {:noreply, new_state} =
               Session.handle_call({:send_message, "compat direct"}, from, state)

      assert [{%UserMessage{}, nil, ^from}] = new_state.turn_queue
    end

    test "cancel_task purge retains triple ordering semantics", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      from_b = {self(), make_ref()}
      from_c = {self(), make_ref()}

      msg_b = %{UserMessage.from_string("b") | transport_metadata: %{task_id: "task_b"}}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_user_message: UserMessage.from_string("active"),
          turn_from: {self(), make_ref()},
          turn_queue: [
            {msg_b, auth, from_b},
            {UserMessage.from_string("c"), nil, from_c}
          ]
        )

      assert {:reply, :ok, new_state} =
               Session.handle_call({:cancel_task, "task_b"}, {self(), make_ref()}, state)

      assert length(new_state.turn_queue) == 1
      assert [{%UserMessage{content: "c"}, nil, ^from_c}] = new_state.turn_queue
    end
  end

  describe "security regression: leak checks" do
    test "builders and engine values never carry authority or receipt material", %{
      agent_id: agent_id,
      human_id: human_id,
      resource: resource
    } do
      receipt = issue_receipt!(human_id, resource)
      token_hex = receipt_token_hex(receipt)
      msg = user_message!(human_id)
      auth = authority!(human_id)
      from = {self(), make_ref()}

      state =
        session_state(agent_id,
          turn_in_flight: true,
          turn_from: {self(), make_ref()},
          turn_user_message: UserMessage.from_string("active")
        )

      assert {:noreply, queued} =
               Session.handle_call({:send_authenticated_message, msg, receipt}, from, state)

      [{_qmsg, %TurnAuthority{} = qauth, _}] = queued.turn_queue
      forbidden = [token_hex, qauth.turn_id, qauth.authenticated_principal_id]

      values = Builders.build_turn_values(queued, msg.content)
      opts = Builders.build_engine_opts(queued, values)

      # Engine/builder artifacts must not carry TurnAuthority structs or raw ids.
      refute term_contains_forbidden?(values, forbidden, allow_turn_authority?: false)

      serializable_opts =
        opts
        |> Enum.reject(fn {_k, v} -> is_function(v) end)
        |> Map.new()

      refute term_contains_forbidden?(serializable_opts, forbidden, allow_turn_authority?: false)
      refute term_contains_forbidden?(values, [token_hex], allow_turn_authority?: false)

      # Public error shape is bounded.
      err = {:error, :unauthenticated}
      refute term_contains_forbidden?(err, forbidden, allow_turn_authority?: false)

      # Inspected Session projection redacts authority fields when present.
      with_auth = %{queued | turn_authority: auth}

      assert {:reply, projected, ^with_auth} =
               Session.handle_call(:get_state, {self(), make_ref()}, with_auth)

      inspected = inspect(projected, limit: :infinity, printable_limit: :infinity)
      refute inspected =~ auth.turn_id
      refute inspected =~ auth.authenticated_principal_id
      refute term_contains_forbidden?(projected, forbidden, allow_turn_authority?: false)
    end

    test "public get_state strips active and queued TurnAuthority; internal state unchanged", %{
      agent_id: agent_id,
      human_id: human_id
    } do
      auth = authority!(human_id)
      queue_from = {self(), make_ref()}
      compat_from = {self(), make_ref()}

      active_msg =
        human_id
        |> user_message!("active with auth")
        |> Map.merge(%{sender: human_id, transport_metadata: %{principal: human_id}})

      msg =
        human_id
        |> user_message!("queued with auth")
        |> Map.merge(%{sender: human_id, transport_metadata: %{principal: human_id}})

      compat_msg = user_message!("human_compat_projection", "nil authority compatibility")

      internal =
        session_state(agent_id,
          turn_in_flight: true,
          turn_authority: auth,
          turn_user_message: active_msg,
          turn_from: {self(), make_ref()},
          turn_queue: [{msg, auth, queue_from}, {compat_msg, nil, compat_from}]
        )

      assert {:reply, projected, still_internal} =
               Session.handle_call(:get_state, {self(), make_ref()}, internal)

      # Public projection: no TurnAuthority structs or authority ids escape.
      assert projected.turn_authority == nil

      assert %UserMessage{
               content: "active with auth",
               sender: nil,
               sender_id: nil,
               transport_metadata: %{}
             } = projected.turn_user_message

      assert [
               {%UserMessage{
                  content: "queued with auth",
                  sender: nil,
                  sender_id: nil,
                  transport_metadata: %{}
                }, nil, ^queue_from},
               {^compat_msg, nil, ^compat_from}
             ] = projected.turn_queue

      projected_inspected = inspect(projected, limit: :infinity, printable_limit: :infinity)
      refute projected_inspected =~ auth.turn_id
      refute projected_inspected =~ auth.authenticated_principal_id

      refute term_contains_forbidden?(projected, [auth.turn_id, auth.authenticated_principal_id],
               allow_turn_authority?: false
             )

      # Internal GenServer state is unchanged (authority retained process-locally).
      assert still_internal.turn_authority == auth
      assert still_internal.turn_user_message == active_msg

      assert [{^msg, ^auth, ^queue_from}, {^compat_msg, nil, ^compat_from}] =
               still_internal.turn_queue

      assert still_internal.turn_authority.turn_id == auth.turn_id
      assert still_internal.turn_authority.authenticated_principal_id == human_id
    end
  end
end
