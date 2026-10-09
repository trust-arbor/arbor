Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationNoticeNativeJourneySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{BranchSupervisor, Character, IdentityAliases, Profile, ProfileStore}
  alias Arbor.Agent.{IdentityAliasProofCore, SessionManager}
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :security_regression
  @migrations Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)
  @notice_action Arbor.Actions.Comms.PublishConversationNotice
  @stored_reply "Native notice persisted"
  @ordinary_reply "The ordinary deterministic turn still works"

  defmodule AuditRepo do
    use Ecto.Repo, otp_app: :arbor_agent, adapter: Ecto.Adapters.SQLite3
  end

  # Trusted producer fault fixture on the existing Comms persistence seam.
  # It reads the real SQL baseline and changes only one finite response fact.
  # Authentication, directory resolution, release checks and notice append all
  # keep their real facades. No caller callback, receipt or authority is injected.
  defmodule NoticeReadProducer do
    defdelegate append_native_conversation_notice(scope, value), to: Arbor.Persistence
    defdelegate normalize_conversation_window_options(opts), to: Arbor.Persistence
    defdelegate read_conversation_window(agent, engagement, opts), to: Arbor.Persistence

    def read_conversation_notice_page(scope, opts) do
      with {:ok, page} <- Arbor.Persistence.read_conversation_notice_page(scope, opts) do
        case Application.get_env(:arbor_agent, :native_notice_reader_fault, :valid_sql) do
          :valid_sql ->
            {:ok, page}

          :invalid_text ->
            [first | rest] = page.notices
            {:ok, %{page | notices: [%{first | text: first.text <> " altered"} | rest]}}

          :invalid_provenance ->
            [first | rest] = page.notices
            <<leading, digest_tail::binary>> = first.provenance["taint"]["payload_sha256"]
            different = if leading == ?0, do: "1", else: "0"

            changed =
              put_in(first.provenance["taint"]["payload_sha256"], different <> digest_tail)

            {:ok, %{page | notices: [changed | rest]}}

          :foreign_scope ->
            {:ok, %{page | owner_id: "human_foreign_notice_reader"}}

          :all_sql_rows ->
            full_sql_page(scope, opts, page)

          :retire_human_after_sql_read ->
            :ok = Arbor.Security.deregister_identity_fixture(page.owner_id)
            {:ok, page}

          _ ->
            {:error, :unsupported_native_notice_fixture_fault}
        end
      end
    end

    # Four real notices fit in at most two normal SQL pages in this fixture.
    # Reassemble that exact snapshot without truncation or duplicate ordinals;
    # an overfull producer response must still meet the Agent's wire budget.
    defp full_sql_page(_scope, _opts, %{has_older: false} = page), do: {:ok, page}

    defp full_sql_page(scope, opts, %{has_older: true} = page) do
      older_opts =
        opts
        |> Keyword.put(:before, page.next_before)
        |> Keyword.put(:through, page.through)
        |> Keyword.put(:limit, 50)

      with {:ok, %{has_older: false} = older} <-
             Arbor.Persistence.read_conversation_notice_page(scope, older_opts),
           true <- older.head == page.head and older.through == page.through,
           true <- length(page.notices) + length(older.notices) <= 50 do
        {:ok,
         %{page | notices: page.notices ++ older.notices, has_older: false, next_before: nil}}
      else
        _ -> {:error, :unsupported_native_notice_fixture_page}
      end
    end
  end

  # This fixture owns the canonical SQL name and every optional collaborator.
  # Run this file alone with --include isolated_repo. There is no injected
  # source/policy/Engine/action executor and no compute, provider or egress node.
  # The named child startup below is a runtime fixture, not an alternate policy.
  setup_all do
    # Umbrella Mix enters the selected app directory while running its tests.
    # The real Heartbeat graph loader uses the ordinary umbrella specs path.
    # This single isolated, async:false fixture restores the runtime cwd.
    previous_cwd = File.cwd!()
    File.cd!(Path.expand("../../../../..", __DIR__))
    on_exit(fn -> File.cd!(previous_cwd) end)

    assert Process.whereis(Repo) == nil,
           "Run the native notice journey alone in its private image."

    assert Process.whereis(:arbor_agent_profiles) == nil
    assert Process.whereis(:arbor_user_config) == nil
    assert is_pid(Process.whereis(Arbor.Agent.ProfileAuthorityOwner))

    root =
      Path.join(
        System.tmp_dir!(),
        "conversation-native-notice-" <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(root)

    start_supervised!(
      {Repo,
       database: Path.join(root, "conversation.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

    # Durable Security audit must not borrow the notice transaction's only SQL
    # connection. Both repositories are real, fixture-owned SQLite databases.
    start_supervised!(
      {AuditRepo,
       database: Path.join(root, "security-audit.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    Ecto.Migrator.run(AuditRepo, @migrations, :up, all: true, log: false)

    for {name, collection} <- [
          {:arbor_agent_profiles, "agent_profiles"},
          {:arbor_user_config, "user_config"}
        ] do
      start_supervised!(
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name,
           backend: Arbor.Persistence.QueryableStore.Postgres,
           backend_opts: [repo: Repo],
           write_mode: :sync,
           ack_mode: :backend,
           collection: collection},
          id: name
        )
      )
    end

    if Process.whereis(Arbor.Trust.Store) == nil do
      start_supervised!(
        {Arbor.Trust.Store,
         persistence: :durable,
         durable_backend: Arbor.Persistence.QueryableStore.Postgres,
         durable_backend_opts: [repo: AuditRepo],
         durable_collection: "native_notice_trust_profiles"}
      )
    end

    # The default test namespace permits OpenAuthorizer and starts no Bus. Use
    # the real capability subscription authorizer for the unprivileged witness.
    signals = Application.get_env(:arbor_kernel, :signals, [])

    set_env(
      :arbor_kernel,
      :signals,
      Keyword.merge(signals,
        authorizer: Arbor.Signals.Adapters.CapabilityAuthorizer,
        allow_open_authorizer: false,
        security_module: Security,
        crypto_module: Security,
        relay_enabled: false
      )
    )

    # Publication and subscribe accept only the application-supervised bus.
    # A bus started under this fixture's supervisor is registered and healthy,
    # then every subscribe returns :unauthorized. action.* and agent.* stay
    # unrestricted; security.* still requires a principal.
    assert :ok = Arbor.Signals.ensure_supervised_local_runtime!()
    assert Arbor.Signals.healthy?()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  setup %{root: root} = tags do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :capability_signing_required, true},
          {:arbor_security, :constraint_enforcement_enabled, true},
          {:arbor_security, :policy_enforcer_enabled, true},
          {:arbor_security, :approval_guard_enabled, true},
          {:arbor_security, :reflex_checking_enabled, true},
          {:arbor_security, :uri_registry_enforcement, true},
          {:arbor_security, :identity_alias_resolver, Arbor.Agent.IdentityAliasResolver},
          {:arbor_security, :native_notice_source_authorizer, Arbor.Agent.NoticeSourceAuthority},
          {:arbor_trust, :policy_module, Arbor.Trust.Policy},
          {:arbor_trust, :policy_enforcer_enabled, true},
          {:arbor_trust, :approval_guard_enabled, true},
          {:arbor_actions, :default_taint_policy, :strict},
          {:arbor_orchestrator, :private_conversation_memory, false},
          {:arbor_orchestrator, :preprocessor_enabled, false},
          {:arbor_persistence, :sql_repository, Repo},
          {:arbor_actions, :comms_module, Arbor.Comms},
          {:arbor_comms, :conversation_persistence_module, Arbor.Persistence},
          {:arbor_comms, :conversation_directory_persistence_module, Arbor.Persistence},
          {:arbor_comms, :conversation_journal,
           [
             backend: Arbor.Persistence.EventLog.Ecto,
             name: :native_notice_journey,
             opts: [repo: Repo]
           ]},
          {:arbor_historian, :durable_event_log_target,
           %{
             name: :native_notice_journey_audit,
             backend: Arbor.Persistence.EventLog.Ecto,
             opts: [repo: AuditRepo]
           }}
        ],
        do: set_env(app, key, value)

    # Use actual public OIDC registration with owned idempotent cleanup; the
    # deliberate retirement case must not fail later on a second deregistration.
    set_env(:arbor_security, :strict_identity_mode, true)
    set_env(:arbor_security, :session_token_module, Arbor.Security.SessionToken)

    set_env(
      :arbor_security,
      :session_token_secret,
      "native-notice-test-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    )

    oidc = Arbor.Security.OIDCTestHelper.issue_identity()
    assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
    {:ok, human_token} = Arbor.Security.SessionToken.generate(oidc.identity.agent_id)
    human = %{human_id: oidc.identity.agent_id, token: human_token}

    on_exit(fn ->
      assert Security.deregister_identity_fixture(human.human_id) in [:ok, {:error, :not_found}]
      oidc.cleanup.()
    end)

    {:ok, identity} = Identity.generate(name: "Native notice Branch owner")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))
    :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)
    chat_cap = Humans.grant!(human.human_id, "arbor://chat/agent/" <> identity.agent_id)

    assert {:ok, _} =
             Arbor.Trust.ensure_trust_profile(human.human_id,
               baseline: :block,
               rules: %{("arbor://chat/agent/" <> identity.agent_id) => :allow}
             )

    for uri <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/transform",
          "arbor://orchestrator/execute/action",
          "arbor://orchestrator/execute/unknown",
          "arbor://action/pipeline/run",
          "arbor://memory/read/" <> identity.agent_id,
          "arbor://memory/write/" <> identity.agent_id
        ],
        do: Humans.grant!(identity.agent_id, uri)

    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(identity.agent_id, human.human_id)

    mailbox = %{
      "mailbox_id" => "owner",
      "recipient_subject_id" => human.human_id,
      "owner_id" => human.human_id,
      "engagement_id" => engagement.id
    }

    profile = %Profile{
      agent_id: identity.agent_id,
      display_name: "Native notice journey",
      character: Character.new(name: "Native notice journey"),
      notice_mailboxes: [mailbox],
      created_at: DateTime.utc_now(),
      version: 1
    }

    assert :ok = Arbor.Agent.store_profile(profile)
    assert {:ok, stored_profile} = Arbor.Agent.load_profile(identity.agent_id)
    assert stored_profile.notice_mailboxes == [mailbox]
    assert @notice_action in Arbor.Actions.all_actions()

    resource =
      "arbor://comms/notice/publish/#{identity.agent_id}/#{human.human_id}/#{human.human_id}/#{engagement.id}"

    assert {:ok, _} =
             Arbor.Trust.ensure_trust_profile(identity.agent_id,
               baseline: :allow,
               rules: %{resource => :allow}
             )

    cap_options = if tags[:rate_allowance], do: [constraints: %{rate_limit: 2}], else: []
    notice_cap = Humans.grant!(identity.agent_id, resource, cap_options)
    params = notice_params("Native private notice " <> identity.agent_id)
    turn_path = Path.join(root, identity.agent_id <> "-turn.dot")
    heartbeat_path = Path.join(root, identity.agent_id <> "-heartbeat.dot")
    File.write!(turn_path, notice_dot(params))
    File.write!(heartbeat_path, ordinary_dot("Initial finite heartbeat"))

    # The loader accepts an already-resolved path. Joining this absolute fixture
    # onto a relative prefix drops the filesystem root, so the startup beat
    # looks under specs/pipelines/session and never completes.
    heartbeat_graph_name = heartbeat_path

    # Same public acquisition route as Lifecycle. These restart slots are
    # separate and purpose-bound; neither child receives a legacy signer/key.
    bootstraps = %{
      session: bootstrap!(identity, :session),
      heartbeat: bootstrap!(identity, :heartbeat)
    }

    config = %{"recover_session" => false, "tools" => [], "stream" => false}

    branch =
      start_supervised!(
        {BranchSupervisor,
         agent_id: identity.agent_id,
         host_opts: [memory_enabled: false, agent_type: :test],
         executor_opts: [sandbox_level: :strict],
         authority_bootstraps: bootstraps,
         session_opts: [
           session_id: "agent-session-" <> identity.agent_id,
           agent_id: identity.agent_id,
           turn_dot: turn_path,
           heartbeat_dot: heartbeat_path,
           signing_authority_bootstrap: bootstraps.session,
           start_heartbeat: false,
           config: config
         ],
         heartbeat_opts: [
           agent_id: identity.agent_id,
           signing_authority_bootstrap: bootstraps.heartbeat,
           heartbeat_dot: heartbeat_path,
           heartbeat_config: %{enabled: true, interval: 86_400_000, graph: heartbeat_graph_name},
           config: config
         ]}
      )

    children = BranchSupervisor.child_pids(identity.agent_id)
    assert children.session != children.heartbeat_service
    assert is_pid(children.session) and is_pid(children.heartbeat_service)
    assert BranchSupervisor.whereis(identity.agent_id) == branch

    # Test-owned discovery seam only: native source authorization independently
    # reads the actual BranchSupervisor topology and durable Profile above.
    :ok =
      Arbor.Agent.Registry.register(identity.agent_id, branch, %{
        runtime: :arbor,
        model_config: %{runtime: :arbor},
        host_pid: children.host,
        session_pid: children.session,
        supervisor_pid: branch,
        agent_id: identity.agent_id
      })

    :sys.replace_state(SessionManager, fn state ->
      :ets.insert(SessionManager, {identity.agent_id, children.session})
      state
    end)

    on_exit(fn ->
      Arbor.Agent.Registry.unregister(identity.agent_id)

      :sys.replace_state(SessionManager, fn state ->
        :ets.delete(SessionManager, identity.agent_id)
        state
      end)

      Security.delete_signing_key_fixture(identity.agent_id)
      Security.deregister_identity_fixture(identity.agent_id)
      Arbor.Trust.delete_trust_profile(identity.agent_id)
    end)

    c = %{
      human: human,
      identity: identity,
      target: identity.agent_id,
      engagement: engagement.id,
      branch: branch,
      session: children.session,
      heartbeat: children.heartbeat_service,
      profile: profile,
      params: params,
      resource: resource,
      notice_cap: notice_cap,
      chat_cap: chat_cap,
      turn_path: turn_path,
      heartbeat_path: heartbeat_path
    }

    # Let the real startup timer finish its harmless graph before any explicit
    # beat. Later beats run only by our mechanical trigger, once per test call.
    await!(fn ->
      state = GenServer.call(c.heartbeat, :get_state)
      if state.heartbeat_last_completed_at, do: {:ok, :ready}, else: :retry
    end)

    c
  end

  test "actual Session role executes fixed Jido notice action and authenticated SQL read", c do
    assert send_turn!(c).outcome.text == @stored_reply
    assert {:ok, page} = notices(c)
    assert page.owner_id == c.human.human_id
    assert page.target_agent_id == c.target
    assert page.engagement_id == c.engagement
    assert page.head == 1
    assert page.through == 1
    assert page.complete
    assert [notice] = page.notices
    assert notice.notice_id == c.params.notice_id
    assert notice.text == c.params.text
    assert notice.recipient_subject_id == c.human.human_id
    assert notice.ordinal == 1
    assert notice.provenance["origin"] == "native_action"
    label = notice.provenance["taint"]["taint"]
    assert label["level"] in ["untrusted", "hostile"]
    assert label["sensitivity"] in ["internal", "confidential", "restricted"]
    assert label["sanitizations"] == 0
    assert label["confidence"] == "unverified"
    assert row_count(c) == 1
  end

  test "actual HeartbeatService owns a separate source and persists via real Engine", c do
    state = run_heartbeat!(c, c.params)
    assert state.heartbeat_last_error == nil
    assert state.heartbeat_last_result.final_outcome.status in [:success, :partial_success]
    assert {:ok, %{head: 1, notices: [notice]}} = notices(c)
    assert notice.text == c.params.text
    assert row_count(c) == 1
    refute contains_authority?(state.heartbeat_last_result.context)

    replace_turn!(c, ordinary_dot(@ordinary_reply))
    assert send_turn!(c).outcome.text == @ordinary_reply
    assert row_count(c) == 1
  end

  @tag :rate_allowance
  test "identical notice across fresh native turns reconciles without another rate charge", c do
    assert send_turn!(c).outcome.text == @stored_reply
    assert send_turn!(c).outcome.text == @stored_reply
    assert {:ok, %{head: 1, notices: [_]}} = notices(c)
    assert row_count(c) == 1

    # Two tokens were granted. One append used one; the identical SQL row used
    # none. Fresh public authorization can therefore consume the one remainder.
    assert {:ok, :authorized} = authorize_notice(c)
    assert {:error, {:constraint_violated, :rate_limit, _}} = authorize_notice(c)
  end

  test "security regression: nominal action and caller labels cannot borrow Branch custody", c do
    assert {:error, :notice_publication_refused} = @notice_action.run(c.params, %{})

    assert {:error, _} =
             Arbor.Actions.authorize_and_execute(c.target, @notice_action, c.params, %{
               agent_id: c.target,
               principal_id: c.target,
               conversation_source: %{owner_pid: c.session, branch_pid: c.branch},
               mailbox_id: "owner"
             })

    assert {:error, :native_notice_source_required} =
             Security.native_notice_action_resource(c.params)

    assert {:ok, %{head: 0, notices: []}} = notices(c)
    assert row_count(c) == 0
    assert send_turn!(c).outcome.text == @stored_reply
  end

  test "security regression: revoked exact publish grant prevents new native SQL effect", c do
    assert send_turn!(c).outcome.text == @stored_reply
    assert :ok = Security.revoke_fixture(c.notice_cap.id)
    denied = notice_params("Revoked grant private text")
    replace_turn!(c, notice_dot(denied))

    assert %{status: :uncertain, outcome: %{status: :uncertain, reason: :delivery_unknown}} =
             send_turn!(c, allow_uncertain: true)

    assert_heartbeat_notice_denied!(
      run_heartbeat!(c, denied),
      :capability_preflight,
      :native_action_preflight_refused
    )

    assert {:ok, %{head: 1, notices: [notice]}} = notices(c)
    assert notice.notice_id == c.params.notice_id
    assert row_count(c) == 1
  end

  test "security regression: acknowledged mailbox removal denies writer and leaves ordinary turn usable",
       c do
    assert send_turn!(c).outcome.text == @stored_reply
    assert :ok = Arbor.Agent.store_profile(%{c.profile | notice_mailboxes: []})
    assert {:ok, snapshot} = ProfileStore.notice_authority_snapshot(c.target)
    assert snapshot.data["notice_mailboxes"] == []
    denied = notice_params("Removed mailbox private text")
    replace_turn!(c, notice_dot(denied))

    assert %{status: :uncertain, outcome: %{status: :uncertain, reason: :delivery_unknown}} =
             send_turn!(c, allow_uncertain: true)

    assert_heartbeat_notice_denied!(
      run_heartbeat!(c, denied),
      :resource_resolution,
      :invalid_action_authorization_resource
    )

    assert row_count(c) == 1
    assert {:ok, %{head: 1}} = notices(c)
    replace_turn!(c, ordinary_dot(@ordinary_reply))
    assert send_turn!(c).outcome.text == @ordinary_reply
  end

  test "security regression: original recipient chat revocation closes publication and reader",
       c do
    assert send_turn!(c).outcome.text == @stored_reply
    assert :ok = Security.revoke_fixture(c.chat_cap.id)
    state = run_heartbeat!(c, notice_params("Revoked recipient private text"))
    assert state.heartbeat_last_error != nil
    assert row_count(c) == 1
    assert {:error, :unauthorized} = notices(c)
  end

  test "security regression: actual alias redirection cannot reuse old recipient-owner mailbox",
       c do
    assert send_turn!(c).outcome.text == @stored_reply
    other_owner = Humans.human!()
    Humans.grant!(c.target, "arbor://identity/alias/manage")

    {:ok, payload} =
      IdentityAliasProofCore.canonical_payload({:link, c.human.human_id, other_owner})

    {:ok, proof} = SignedRequest.sign(payload, c.target, c.identity.private_key)

    assert :ok =
             IdentityAliases.link(c.target, c.human.human_id, other_owner, signed_request: proof)

    assert {:ok, ^other_owner} = Security.resolve_identity_alias(c.human.human_id)
    state = run_heartbeat!(c, notice_params("Changed owner private text"))
    assert state.heartbeat_last_error != nil
    assert row_count(c) == 1
    assert {:error, reason} = notices(c)

    assert reason in [
             :not_found,
             :conversation_unavailable,
             :conversation_scope_changed,
             :unauthorized
           ]
  end

  test "security regression: native notice Action and Heartbeat signals disclose no body, recipient or proof",
       c do
    observer = self()
    tag = make_ref()
    barrier = "native-notice-barrier-#{System.unique_integer([:positive])}"

    handler = fn signal ->
      send(observer, {tag, signal})
      :ok
    end

    assert {:ok, action_subscription} = Arbor.Signals.subscribe("action.*", handler, async: false)
    assert {:ok, agent_subscription} = Arbor.Signals.subscribe("agent.*", handler, async: false)
    assert {:error, :unauthorized} = Arbor.Signals.subscribe("security.*", handler, async: false)

    on_exit(fn ->
      Arbor.Signals.unsubscribe(action_subscription)
      Arbor.Signals.unsubscribe(agent_subscription)
    end)

    assert send_turn!(c).outcome.text == @stored_reply
    heartbeat_params = notice_params("Heartbeat private body " <> c.target)
    assert run_heartbeat!(c, heartbeat_params).heartbeat_last_error == nil
    assert row_count(c) == 2
    :ok = Arbor.Signals.emit(:action, :notice_fixture_barrier, %{fixture_barrier: barrier})
    signals = collect_signals!(tag, barrier, [])
    assert Enum.any?(signals, &(&1.type == :started))
    assert Enum.any?(signals, &(&1.type == :completed))

    # Actual authenticated private chat signals are metadata-only, including
    # both user admission and assistant completion. Observe every agent event.
    assert Enum.any?(signals, fn signal ->
             signal.category == :agent and signal.type == :chat_message and
               signal.data == %{role: :user, channel: :private_conversation}
           end)

    refute Enum.any?(signals, &(&1.category == :agent and &1.type == :notification))

    for signal <- signals do
      rendered = inspect(signal, limit: :infinity, printable_limit: :infinity)

      for private <- [
            c.params.text,
            heartbeat_params.text,
            c.params.notice_id,
            heartbeat_params.notice_id,
            c.human.token,
            c.human.human_id,
            "Run the finite native notice fixture",
            @stored_reply
          ],
          do: refute(String.contains?(rendered, private))

      refute contains_authority?(signal)
    end
  end

  test "same-scope malformed notice text or provenance is unavailable while fresh transcript window remains usable",
       c do
    assert send_turn!(c).outcome.text == @stored_reply
    install_reader_producer!()
    assert {:ok, %{head: 1, notices: [_]}} = notices(c)

    for fault <- [:invalid_text, :invalid_provenance] do
      Application.put_env(:arbor_agent, :native_notice_reader_fault, fault)
      assert {:error, :conversation_unavailable} = notices(c)
      assert_fresh_window_usable!(c)
      assert row_count(c) == 1
    end

    Application.put_env(:arbor_agent, :native_notice_reader_fault, :valid_sql)
    assert {:ok, %{head: 1, notices: [notice]}} = notices(c)
    assert notice.text == c.params.text
  end

  test "foreign producer page scope closes notice continuation while separately fresh window keeps actual scope",
       c do
    assert send_turn!(c).outcome.text == @stored_reply
    install_reader_producer!()
    assert {:ok, %{head: 1}} = notices(c)
    Application.put_env(:arbor_agent, :native_notice_reader_fault, :foreign_scope)
    assert {:error, :conversation_scope_changed} = notices(c)
    assert_fresh_window_usable!(c)
    assert row_count(c) == 1
  end

  test "exact 129024-byte valid native notice page is admitted through fresh Agent reader", c do
    install_reader_producer!()
    page = fill_notice_page!(c, 129_024)
    assert byte_size(Jason.encode!(page)) == 129_024
    assert {:ok, ^page} = notices(c)
    assert_fresh_window_usable!(c)
  end

  test "exact 129025-byte producer page of distinct valid SQL notices is refused at Agent wire bound",
       c do
    install_reader_producer!()
    page = fill_notice_page!(c, 129_025)
    assert byte_size(Jason.encode!(page)) == 129_025
    assert {:error, :page_too_large} = notices(c)
    assert_fresh_window_usable!(c)

    # The normal SQL producer paginates that same immutable data rather than
    # truncating or losing a record. Restoring it permits a bounded continuation.
    Application.put_env(:arbor_agent, :native_notice_reader_fault, :valid_sql)
    assert {:ok, bounded} = notices(c)
    assert byte_size(Jason.encode!(bounded)) <= 129_024
    assert bounded.has_older
    assert length(bounded.notices) == 3
    assert row_count(c) == 4
  end

  test "security regression: actual human retirement after SQL read denies release and future native publication",
       c do
    assert send_turn!(c).outcome.text == @stored_reply
    install_reader_producer!()
    assert {:ok, %{head: 1}} = notices(c)
    Application.put_env(:arbor_agent, :native_notice_reader_fault, :retire_human_after_sql_read)
    assert {:error, :unauthorized} = notices(c)

    assert {:error, :unauthorized} =
             Arbor.Agent.conversation_window(c.human.human_id, c.target,
               session_token: c.human.token,
               expected_engagement_id: c.engagement
             )

    denied = run_heartbeat!(c, notice_params("Retired human private body"))

    assert_heartbeat_notice_denied!(
      denied,
      :resource_resolution,
      :invalid_action_authorization_resource
    )

    assert row_count(c) == 1
  end

  defp bootstrap!(identity, purpose) do
    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: purpose,
        owner: self()
      )

    {:ok, bootstrap} = Security.issue_signing_authority_bootstrap(proof)
    bootstrap
  end

  defp notice_params(text) do
    %{
      mailbox_id: "owner",
      notice_id: "notice_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      kind: "notification",
      text: text
    }
  end

  defp notice_dot(params) do
    """
    digraph FiniteNativeNotice {
      start [shape=Mdiamond]
      notice [type=exec, target=action, action="comms_publish_conversation_notice", max_retries=0,
        param.mailbox_id=#{Jason.encode!(params.mailbox_id)}, param.notice_id=#{Jason.encode!(params.notice_id)},
        param.kind=#{Jason.encode!(params.kind)}, param.text=#{Jason.encode!(params.text)}, output_prefix=native_notice]
      response [type=transform, transform=constant, expression=#{Jason.encode!(@stored_reply)}, output_key="session.response"]
      exit [shape=Msquare]
      start -> notice -> response -> exit
    }
    """
  end

  defp ordinary_dot(reply) do
    """
    digraph FiniteOrdinaryTurn {
      start [shape=Mdiamond]
      response [type=transform, transform=constant, expression=#{Jason.encode!(reply)}, output_key="session.response"]
      exit [shape=Msquare]
      start -> response -> exit
    }
    """
  end

  defp replace_turn!(c, dot) do
    File.write!(c.turn_path, dot)
    assert :ok = GenServer.call(c.session, :reload_dot)
  end

  defp send_turn!(c, opts \\ []) do
    # Only the two explicit refusal witnesses request the existing honest
    # public uncertain delivery envelope. Positive native turns remain strict.
    assert opts in [[], [allow_uncertain: true]]
    command = "native-notice-command-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               c.human.human_id,
               c.target,
               %{id: command, text: "Run the finite native notice fixture"},
               session_token: c.human.token,
               expected_engagement_id: c.engagement,
               timeout: 10_000
             )

    await!(fn ->
      case Arbor.Agent.conversation_command(c.human.human_id, c.target, command,
             session_token: c.human.token,
             expected_engagement_id: c.engagement
           ) do
        {:ok, %{status: :completed} = result} ->
          {:ok, result}

        {:ok, %{status: :uncertain} = result} when opts == [allow_uncertain: true] ->
          {:ok, result}

        {:ok, %{status: :uncertain} = result} ->
          flunk("native fixture delivery uncertain: #{inspect(result)}")

        _ ->
          :retry
      end
    end)
  end

  defp run_heartbeat!(c, params) do
    before = GenServer.call(c.heartbeat, :get_state).heartbeat_beat_count
    File.write!(c.heartbeat_path, notice_dot(params))
    GenServer.cast(c.heartbeat, :reload_dot)
    _ = GenServer.call(c.heartbeat, :get_state)
    send(c.heartbeat, :heartbeat)

    await!(fn ->
      state = GenServer.call(c.heartbeat, :get_state)

      if state.heartbeat_beat_count > before and not state.heartbeat_in_flight,
        do: {:ok, state},
        else: :retry
    end)
  end

  defp notices(c) do
    Arbor.Agent.conversation_notices(c.human.human_id, c.target,
      session_token: c.human.token,
      expected_engagement_id: c.engagement
    )
  end

  defp install_reader_producer! do
    set_env(:arbor_comms, :conversation_persistence_module, NoticeReadProducer)
    set_env(:arbor_agent, :native_notice_reader_fault, :valid_sql)

    assert Application.get_env(:arbor_comms, :conversation_directory_persistence_module) ==
             Arbor.Persistence
  end

  defp assert_fresh_window_usable!(c) do
    assert {:ok, window} =
             Arbor.Agent.conversation_window(c.human.human_id, c.target,
               session_token: c.human.token,
               expected_engagement_id: c.engagement
             )

    assert window.engagement_id == c.engagement
    assert Enum.any?(window.entries, &(&1.role == "assistant" and &1.content == @stored_reply))
  end

  defp fill_notice_page!(c, target_bytes) when target_bytes in [129_024, 129_025] do
    for _ <- 1..3 do
      replace_turn!(c, notice_dot(notice_params(String.duplicate("a", 32_768))))
      assert send_turn!(c).outcome.text == @stored_reply
    end

    scope = %{
      owner_id: c.human.human_id,
      target_agent_id: c.target,
      engagement_id: c.engagement
    }

    assert {:ok, %{head: 3, notices: [first | _]} = baseline} =
             Arbor.Persistence.read_conversation_notice_page(scope)

    last_params = notice_params("b")

    # This encoding model is only a length calculation, never a producer value
    # or authority. IDs and digests have fixed lengths; UTC SQL timestamps keep
    # their six-digit precision. The fourth real native append creates its own
    # current timestamp and authentic envelope, then we assert exact final bytes.
    model_record = %{first | notice_id: last_params.notice_id, text: "b", ordinal: 4}

    model_page = %{
      baseline
      | head: 4,
        through: 4,
        notices: [model_record | baseline.notices],
        has_older: false,
        next_before: nil
    }

    final_text_bytes = target_bytes - byte_size(Jason.encode!(model_page)) + 1
    assert final_text_bytes in 1..32_768
    last_params = %{last_params | text: String.duplicate("b", final_text_bytes)}
    replace_turn!(c, notice_dot(last_params))
    assert send_turn!(c).outcome.text == @stored_reply
    Application.put_env(:arbor_agent, :native_notice_reader_fault, :all_sql_rows)
    assert {:ok, page} = NoticeReadProducer.read_conversation_notice_page(scope, [])
    assert byte_size(Jason.encode!(page)) == target_bytes
    assert page.head == 4 and page.through == 4
    assert page.complete and not page.has_older and page.next_before == nil
    assert Enum.map(page.notices, & &1.ordinal) == [4, 3, 2, 1]
    assert length(Enum.uniq_by(page.notices, & &1.notice_id)) == 4

    for record <- page.notices do
      value = Map.take(record, [:notice_id, :recipient_subject_id, :kind, :text, :provenance])
      assert {:ok, ^value} = Security.validate_notice_publication_value(scope, value)
      assert byte_size(record.text) in 1..32_768
      assert byte_size(Jason.encode!(value)) <= 120_000
    end

    assert row_count(c) == 4
    page
  end

  defp assert_heartbeat_notice_denied!(state, stage, reason) do
    assert {:unadmitted_heartbeat_outcome, %{status: :fail, failure_reason: failure}} =
             state.heartbeat_last_error

    assert is_binary(failure)

    case stage do
      :capability_preflight -> assert failure =~ "Capability check failed"
      :resource_resolution -> assert failure =~ "Capability check failed"
    end

    assert String.contains?(failure, Atom.to_string(reason))
  end

  defp authorize_notice(c) do
    {:ok, proof} = SignedRequest.sign(c.resource, c.target, c.identity.private_key)

    Security.authorize(c.target, c.resource, :execute,
      signed_request: proof,
      verify_identity: true
    )
  end

  defp row_count(c) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM conversation_notices WHERE engagement_id = ?",
        [c.engagement]
      )

    count
  end

  defp await!(fun, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("Finite native notice fixture did not settle before its deadline")

        Process.sleep(25)
        await!(fun, deadline)
    end
  end

  defp collect_signals!(tag, barrier, signals) do
    receive do
      {^tag, %{data: %{fixture_barrier: ^barrier}}} -> Enum.reverse(signals)
      {^tag, signal} -> collect_signals!(tag, barrier, [signal | signals])
    after
      5_000 -> flunk("Actual public signal bus did not deliver its fixture barrier")
    end
  end

  defp contains_authority?(%{__struct__: module} = value) do
    module in [
      Arbor.Contracts.Security.SignedRequest,
      Arbor.Contracts.Security.SigningAuthority,
      Arbor.Contracts.Security.SigningAuthorityBootstrap,
      Arbor.Contracts.Security.DeliveryReceipt
    ] or contains_authority?(Map.from_struct(value))
  end

  defp contains_authority?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      (not is_nil(item) and
         key in [
           :conversation_source,
           :native_notice_source,
           :worker_custody,
           :signed_request,
           :signing_authority,
           :signature,
           :nonce,
           "conversation_source",
           "native_notice_source",
           "worker_custody",
           "signed_request",
           "signing_authority",
           "signature",
           "nonce"
         ]) or
        contains_authority?(item)
    end)
  end

  defp contains_authority?(value) when is_list(value),
    do: Enum.any?(value, &contains_authority?/1)

  defp contains_authority?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_authority?()

  defp contains_authority?(_), do: false

  defp set_env(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
