defmodule Arbor.Security.DeliveryReceiptSecurityRegressionTest.FaultyVerifierError do
  @moduledoc false
  def verify(_token), do: {:error, :boom}
end

defmodule Arbor.Security.DeliveryReceiptSecurityRegressionTest.FaultyVerifierRaise do
  @moduledoc false
  def verify(_token), do: raise("verifier boom")
end

defmodule Arbor.Security.DeliveryReceiptSecurityRegressionTest.FaultyVerifierThrow do
  @moduledoc false
  def verify(_token), do: throw(:verifier_throw)
end

defmodule Arbor.Security.DeliveryReceiptSecurityRegressionTest.FaultyVerifierExit do
  @moduledoc false
  def verify(_token), do: exit(:verifier_exit)
end

defmodule Arbor.Security.DeliveryReceiptSecurityRegressionTest.MockConsensus do
  @moduledoc false
  def submit(%{proposer: _} = _proposal, _opts \\ []) do
    {:ok, "proposal_#{:erlang.unique_integer([:positive])}"}
  end

  def healthy?, do: true
end

defmodule Arbor.Security.DeliveryReceiptSecurityRegressionTest do
  @moduledoc """
  Security regression: public delivery-receipt facades (VP-05D2A1R).

  Security prerequisite for VOICE-17 (planned); does not un-plan the normative
  VOICE-17 statement.
  """

  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"

  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.SessionToken

  @sentinel_prefix "SESSION_TOKEN_SENTINEL_"

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
      secret: Application.get_env(:arbor_security, :session_token_secret),
      token_mod: Application.get_env(:arbor_security, :session_token_module),
      consensus_enabled: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      consensus_module: Application.get_env(:arbor_security, :consensus_module)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)

    Application.put_env(
      :arbor_security,
      :consensus_module,
      __MODULE__.MockConsensus
    )

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "vp05d2a1r-test-secret-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      restore(:identity_verification, prev.identity_verification)
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
      restore(:session_token_secret, prev.secret)
      restore(:session_token_module, prev.token_mod)
      restore(:consensus_escalation_enabled, prev.consensus_enabled)
      restore(:consensus_module, prev.consensus_module)
    end)

    active_before = broker_active()
    {:ok, active_before: active_before}
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)

  defp broker_active do
    case DeliveryReceiptBroker.stats() do
      %{active: n} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp assert_no_new_broker_entry(active_before) do
    assert broker_active() == active_before
  end

  defp register_human! do
    n = System.unique_integer([:positive])
    oidc = Arbor.Security.OIDCTestHelper.issue_identity(subject: "vp05d2a1r-#{n}")
    human_id = oidc.identity.agent_id

    assert :ok =
             Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  defp grant!(principal, resource, opts \\ []) do
    grant_opts =
      [principal: principal, resource: resource]
      |> Keyword.merge(opts)

    assert {:ok, cap} = Security.grant(grant_opts)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp resource! do
    "arbor://chat/agent/agent_vp05d2a1r_#{System.unique_integer([:positive])}"
  end

  defp attach_auth_events!(parent) do
    id = "vp05d2a1r-auth-events-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:arbor, :security, :authorization_granted],
          [:arbor, :security, :authorization_denied]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:auth_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  defp refute_sentinel_in_term(term, sentinel) do
    refute inspect(term) =~ sentinel
  end

  describe "security regression: authorized human issue and consume" do
    test "security regression: issue then exact consume returns Security-owned principal" do
      human_id = register_human!()
      resource = resource!()
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      assert {:ok, receipt} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token
               )

      assert {:ok, ^human_id} = Security.consume_delivery_receipt(receipt, resource, :chat)
    end

    test "security regression: replay forged resource/action mismatch reject" do
      human_id = register_human!()
      resource = resource!()
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      assert {:ok, receipt} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token
               )

      assert {:ok, ^human_id} = Security.consume_delivery_receipt(receipt, resource, :chat)

      # Replay
      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)

      # Forged
      assert {:ok, forged} = DeliveryReceipt.new(token: :crypto.strong_rand_bytes(32))

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(forged, resource, :chat)

      # Fresh receipt for mismatch cases
      assert {:ok, token2} = SessionToken.generate(human_id)

      assert {:ok, receipt2} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token2
               )

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt2, resource <> "/other", :chat)

      assert {:ok, token3} = SessionToken.generate(human_id)

      assert {:ok, receipt3} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token3
               )

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt3, resource, :write)
    end

    test "security regression: discard is idempotent and reveals no existence" do
      human_id = register_human!()
      resource = resource!()
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      assert {:ok, receipt} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token
               )

      assert :ok = Security.discard_delivery_receipt(receipt)
      assert :ok = Security.discard_delivery_receipt(receipt)

      assert {:error, :invalid_receipt} =
               Security.consume_delivery_receipt(receipt, resource, :chat)

      assert :ok = Security.discard_delivery_receipt(receipt)

      assert {:ok, token2} = SessionToken.generate(human_id)

      assert {:ok, receipt2} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token2
               )

      assert {:ok, ^human_id} = Security.consume_delivery_receipt(receipt2, resource, :chat)
      assert :ok = Security.discard_delivery_receipt(receipt2)
    end
  end

  describe "security regression: failed authorization creates no broker entry" do
    test "security regression: agent principal invalid before authorize", %{
      active_before: active_before
    } do
      {:ok, agent_identity} = Identity.generate(name: "vp05d2a1r-agent")
      agent_id = agent_identity.agent_id
      assert :ok = Security.register_identity(agent_identity)

      on_exit(fn ->
        _ = Security.deregister_identity(agent_id)
      end)

      resource = resource!()
      grant!(agent_id, resource)

      assert {:error, :invalid_principal} =
               Security.authorize_and_issue_delivery_receipt(agent_id, resource, :chat)

      assert_no_new_broker_entry(active_before)
    end

    test "security regression: denial pending verifier faults create no entry", %{
      active_before: active_before
    } do
      human_id = register_human!()
      resource = resource!()
      assert {:ok, token} = SessionToken.generate(human_id)

      # Denial — no capability
      assert {:error, :unauthorized} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token
               )

      assert_no_new_broker_entry(active_before)

      # Pending approval constraint
      grant!(human_id, resource, constraints: %{requires_approval: true})
      assert {:ok, token2} = SessionToken.generate(human_id)

      assert {:error, :pending_approval} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token2
               )

      assert_no_new_broker_entry(active_before)

      # Verifier error/raise/throw/exit → authorize normalizes; issue maps to unauthorized
      grant!(human_id, resource <> "_fault")

      for mod <- [
            __MODULE__.FaultyVerifierError,
            __MODULE__.FaultyVerifierRaise,
            __MODULE__.FaultyVerifierThrow,
            __MODULE__.FaultyVerifierExit
          ] do
        Application.put_env(:arbor_security, :session_token_module, mod)

        assert {:error, :unauthorized} =
                 Security.authorize_and_issue_delivery_receipt(
                   human_id,
                   resource <> "_fault",
                   :chat,
                   session_token: "any-token-value"
                 )

        assert_no_new_broker_entry(active_before)
      end

      Application.delete_env(:arbor_security, :session_token_module)
    end

    test "security regression: control opts and duplicate session_token rejected", %{
      active_before: active_before
    } do
      human_id = register_human!()
      resource = resource!()
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      for bad_opts <- [
            [ttl_ms: 1],
            [broker: :x],
            [clock: fn -> 0 end],
            [max_entries: 1],
            [session_token: token, session_token: token],
            [unknown_key: true],
            [task_id: "t1"],
            [principal_scope: "s1"],
            [verify_identity: true],
            [verify_identity: false],
            [session_token: token, signed_request: %{agent_id: human_id}],
            [],
            :not_a_keyword
          ] do
        assert {:error, :invalid_opts} =
                 Security.authorize_and_issue_delivery_receipt(
                   human_id,
                   resource,
                   :chat,
                   bad_opts
                 )
      end

      assert_no_new_broker_entry(active_before)
    end

    test "security regression: identity_verified false cannot disable verification", %{
      active_before: active_before
    } do
      human_id = register_human!()
      resource = resource!()
      grant!(human_id, resource)
      assert {:ok, token} = SessionToken.generate(human_id)

      # Bare false — rejected before authorize
      assert {:error, :invalid_opts} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 identity_verified: false
               )

      # False paired with a real session token — still rejected (cannot disable)
      assert {:error, :invalid_opts} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token,
                 identity_verified: false
               )

      # Non-true values also rejected (true is the atom :true in Elixir)
      for bad <- [nil, 0, 1, "true", false] do
        assert {:error, :invalid_opts} =
                 Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                   identity_verified: bad
                 )
      end

      assert_no_new_broker_entry(active_before)

      # Exactly true with session_token remains admitted (token still verified by authorize)
      assert {:ok, receipt} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: token,
                 identity_verified: true
               )

      assert {:ok, ^human_id} = Security.consume_delivery_receipt(receipt, resource, :chat)
    end

    test "security regression: non-canonical human principal rejected before authorize", %{
      active_before: active_before
    } do
      resource = resource!()

      for bad_principal <- [
            "",
            "human_" <> <<0>>,
            "human_" <> <<0xFF>>,
            "agent_not_allowed",
            "service_x",
            :not_binary,
            nil
          ] do
        assert {:error, :invalid_principal} =
                 Security.authorize_and_issue_delivery_receipt(bad_principal, resource, :chat,
                   session_token: "x"
                 )
      end

      assert_no_new_broker_entry(active_before)
    end
  end

  describe "security regression: raw session-token hygiene" do
    test "security regression: sentinel absent from receipt errors stats events" do
      human_id = register_human!()
      resource = resource!()
      grant!(human_id, resource)

      sentinel = @sentinel_prefix <> Integer.to_string(System.unique_integer([:positive]))
      assert byte_size(sentinel) > 20

      # Real token for success path; also probe deny with sentinel
      assert {:ok, good_token} = SessionToken.generate(human_id)
      attach_auth_events!(self())

      assert {:ok, receipt} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: good_token
               )

      assert_receive {:auth_event, [:arbor, :security, :authorization_granted], _m, grant_meta},
                     500

      refute_sentinel_in_term(receipt, good_token)
      refute_sentinel_in_term(receipt, sentinel)
      refute_sentinel_in_term(grant_meta, good_token)
      refute_sentinel_in_term(grant_meta, sentinel)

      stats = DeliveryReceiptBroker.stats()
      refute_sentinel_in_term(stats, good_token)
      refute_sentinel_in_term(stats, sentinel)

      assert {:ok, principal} = Security.consume_delivery_receipt(receipt, resource, :chat)
      refute_sentinel_in_term(principal, good_token)

      # Deny path with distinctive sentinel as the session token value
      assert {:error, deny_err} =
               Security.authorize_and_issue_delivery_receipt(human_id, resource, :chat,
                 session_token: sentinel
               )

      refute_sentinel_in_term(deny_err, sentinel)

      assert_receive {:auth_event, [:arbor, :security, :authorization_denied], _m, deny_meta},
                     500

      refute_sentinel_in_term(deny_meta, sentinel)

      assert {:error, invalid} =
               Security.consume_delivery_receipt(
                 %{token: :crypto.strong_rand_bytes(8)},
                 resource,
                 :chat
               )

      refute_sentinel_in_term(invalid, sentinel)

      # Broker format_status redaction
      pid = Process.whereis(DeliveryReceiptBroker)

      if is_pid(pid) do
        status = :sys.get_status(pid)
        refute_sentinel_in_term(status, good_token)
        refute_sentinel_in_term(status, sentinel)
      end
    end
  end
end
