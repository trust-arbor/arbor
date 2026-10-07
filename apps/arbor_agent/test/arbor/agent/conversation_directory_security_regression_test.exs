Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationDirectorySecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}
  alias Arbor.Contracts.Security.SignedRequest
  @moduletag :fast

  defmodule Aliases do
    def resolve(id), do: {:ok, Map.get(Process.get(:directory_aliases, %{}), id, id)}
  end

  defmodule DirectoryStorage do
    def normalize_conversation_directory_options(opts),
      do: Arbor.Persistence.normalize_conversation_directory_options(opts)

    def list_user_conversation_records(owner, opts) do
      send(self(), {:directory_read, owner, opts})
      if callback = Process.get(:after_directory_read), do: callback.()
      records = Enum.filter(Process.get(:directory_records, []), &(&1.owner_tenant == owner))
      {:ok, %{records: records, has_more: false, next_cursor: nil}}
    end

    def read_user_conversation_record(owner, id) do
      send(self(), {:reference_read, owner, id})

      case Enum.find(
             Process.get(:directory_records, []),
             &(&1.owner_tenant == owner and &1.engagement_id == id)
           ) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  defmodule WindowStorage do
    def normalize_conversation_window_options(opts),
      do: Arbor.Persistence.normalize_conversation_window_options(opts)

    def read_conversation_window(agent, engagement, _opts) do
      send(self(), {:preview_read, agent, engagement})
      if callback = Process.get(:after_preview_read), do: callback.()

      {:ok,
       %{
         entries: [
           %{
             id: "entry_preview",
             role: "user",
             content: String.duplicate("🌲", 200),
             timestamp: "2026-10-02T00:00:00Z",
             entry_ordinal: 1
           }
         ],
         head: 1,
         first: 1,
         last: 1,
         has_older: false,
         has_newer: false
       }}
    end
  end

  defmodule NoDurableEngagements do
    def available?, do: false
  end

  setup do
    settings = [
      {:arbor_security, :session_token_secret, :crypto.strong_rand_bytes(32)},
      {:arbor_security, :identity_alias_resolver, Aliases},
      {:arbor_security, :identity_verification, true},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :capability_signing_required, true},
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :policy_enforcer_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_comms, :conversation_directory_persistence_module, DirectoryStorage},
      {:arbor_comms, :conversation_persistence_module, WindowStorage},
      {:arbor_comms, :engagement_persistence_module, NoDurableEngagements}
    ]

    previous =
      for {app, key, value} <- settings do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    primary = human()
    linked = human()
    foreign = human()
    target = "agent_directory_#{System.unique_integer([:positive])}"
    denied = target <> "_denied"
    own = record(target, primary.id)
    ungranted = record(denied, primary.id)
    other = record(target, foreign.id)
    Process.put(:directory_records, [own, ungranted, other])
    cap = grant(primary.id, target)

    %{
      primary: primary,
      linked: linked,
      foreign: foreign,
      target: target,
      denied: denied,
      own: own,
      cap: cap
    }
  end

  test "public directory releases only gated names and bounded previews", c do
    assert {:ok, %{conversations: [item], next_cursor: nil, has_more: false}} = list(c.primary)
    assert item.engagement_id == c.own.engagement_id
    assert item.agent_id == c.target
    assert item.display_name == c.target
    assert String.length(item.preview) == 160

    assert Enum.sort(Map.keys(item)) ==
             Enum.sort([
               :engagement_id,
               :agent_id,
               :display_name,
               :status,
               :updated_at,
               :preview,
               :last_message_at
             ])

    assert_receive {:preview_read, target, engagement}
    assert target == c.target and engagement == c.own.engagement_id
    denied = c.denied
    refute_receive {:preview_read, ^denied, _}
  end

  test "security regression missing invalid wrong-subject and expired proof stop before index reads",
       c do
    {:ok, expired} = SessionToken.generate(c.primary.id, ttl: -1)

    for opts <- [
          [],
          [session_token: "invalid"],
          [signed_request: nil],
          [session_token: c.foreign.token],
          [session_token: expired]
        ] do
      assert {:error, :unauthorized} = Arbor.Agent.list_conversations(c.primary.id, opts)
      refute_receive {:directory_read, _, _}
    end
  end

  test "security regression linked ownership never inherits another proof subject's grants", c do
    Process.put(:directory_aliases, %{c.linked.id => c.primary.id})
    assert {:ok, %{conversations: []}} = list(c.linked)
    assert {:error, :not_found} = reference(c.linked, c.own.engagement_id)
    refute_receive {:preview_read, _, _}
    cap = grant(c.linked.id, c.target)
    assert {:ok, %{conversations: [%{engagement_id: id}]}} = list(c.linked)
    assert id == c.own.engagement_id
    assert :ok = Security.revoke_fixture(cap.id)
    assert {:ok, %{conversations: []}} = list(c.linked)
    assert {:ok, %{conversations: [_]}} = list(c.primary)
  end

  test "security regression foreign absent and revoked deep references disclose no row", c do
    assert {:error, :not_found} = reference(c.foreign, c.own.engagement_id)
    assert {:error, :not_found} = reference(c.primary, "eng_00000000000000000000000000000000")
    assert {:ok, %{engagement_id: id}} = reference(c.primary, c.own.engagement_id)
    assert id == c.own.engagement_id
    assert :ok = Security.revoke_fixture(c.cap.id)
    assert {:error, :not_found} = reference(c.primary, c.own.engagement_id)
  end

  test "security regression revocation during preview prevents publication", c do
    Process.put(:after_preview_read, fn -> Security.revoke_fixture(c.cap.id) end)
    assert {:ok, %{conversations: []}} = list(c.primary)
    assert_receive {:preview_read, _, _}
  end

  test "security regression owner alias changes and resolver outages reject the whole release",
       c do
    Process.put(:directory_aliases, %{c.linked.id => c.primary.id})
    grant(c.linked.id, c.target)

    Process.put(:after_directory_read, fn ->
      Process.put(:directory_aliases, %{c.linked.id => c.foreign.id})
    end)

    assert {:error, :unauthorized} = list(c.linked)
    Application.delete_env(:arbor_security, :identity_alias_resolver)
    assert {:error, :unauthorized} = list(c.primary)
  end

  test "security regression signed index consumes a nonce once and binds subject selectors and operation",
       c do
    proof = sign(c.primary, :list, nil, limit: 2)

    assert {:ok, %{conversations: [_]}} =
             Arbor.Agent.list_conversations(c.primary.id, signed_request: proof, limit: 2)

    assert {:error, :unauthorized} =
             Arbor.Agent.list_conversations(c.primary.id, signed_request: proof, limit: 2)

    proof = sign(c.primary, :list, nil, cursor: 0, limit: 2)

    for opts <- [[cursor: 1, limit: 2], [cursor: 0, limit: 1]] do
      assert {:error, :unauthorized} =
               Arbor.Agent.list_conversations(c.primary.id, [signed_request: proof] ++ opts)
    end

    assert {:error, :unauthorized} =
             Arbor.Agent.resolve_conversation_reference(c.primary.id, c.own.engagement_id,
               signed_request: proof
             )

    assert {:ok, principal} = Security.verify_request(proof)
    assert principal == c.primary.id
  end

  test "security regression reference signatures cannot substitute another ID or subject", c do
    proof = sign(c.primary, :reference, c.own.engagement_id, [])

    assert {:error, :unauthorized} =
             Arbor.Agent.resolve_conversation_reference(
               c.primary.id,
               "eng_00000000000000000000000000000000",
               signed_request: proof
             )

    assert {:error, :unauthorized} =
             Arbor.Agent.resolve_conversation_reference(c.foreign.id, c.own.engagement_id,
               signed_request: proof
             )

    assert {:ok, _} =
             Arbor.Agent.resolve_conversation_reference(c.primary.id, c.own.engagement_id,
               signed_request: proof
             )
  end

  test "security regression authority overrides malformed bounds and duplicate proof keys fail before storage",
       c do
    for opts <- [
          [owner_tenant: c.foreign.id],
          [principal_id: c.foreign.id],
          [agent_id: c.denied],
          [engagement_id: c.own.engagement_id],
          [persistence: DirectoryStorage],
          [limit: 0],
          [cursor: -1],
          [limit: 1, limit: 2],
          [session_token: "a", session_token: "b"],
          [signed_request: nil, session_token: c.primary.token]
        ] do
      assert {:error, :invalid_opts} = Arbor.Agent.list_conversations(c.primary.id, opts)
      refute_receive {:directory_read, _, _}
    end

    assert {:error, :invalid_opts} =
             Arbor.Agent.resolve_conversation_reference(c.primary.id, c.own.engagement_id,
               session_token: c.primary.token,
               limit: 1
             )
  end

  defp human do
    oidc = OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    {:ok, token} = SessionToken.generate(oidc.identity.agent_id)

    on_exit(fn ->
      Security.deregister_identity_fixture(oidc.identity.agent_id)
      oidc.cleanup.()
    end)

    %{id: oidc.identity.agent_id, key: oidc.identity.private_key, token: token}
  end

  defp record(agent, owner) do
    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(agent, owner)

    %{
      engagement_id: engagement.id,
      agent_id: agent,
      owner_tenant: owner,
      scope: "user",
      visibility: "private",
      status: "active",
      updated_at: ~U[2026-10-02 00:00:00Z]
    }
  end

  defp grant(principal, target) do
    assert {:ok, cap} =
             Security.grant_fixture(
               principal: principal,
               resource: "arbor://chat/agent/" <> target
             )

    on_exit(fn -> Security.revoke_fixture(cap.id) end)
    cap
  end

  defp list(human), do: Arbor.Agent.list_conversations(human.id, session_token: human.token)

  defp reference(human, id),
    do: Arbor.Agent.resolve_conversation_reference(human.id, id, session_token: human.token)

  defp sign(human, operation, input, opts) do
    {:ok, bytes} =
      Arbor.Agent.conversation_index_request_payload(operation, human.id, input, opts)

    {:ok, proof} = SignedRequest.sign(bytes, human.id, human.key)
    proof
  end
end
