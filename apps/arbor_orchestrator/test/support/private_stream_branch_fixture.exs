defmodule Arbor.Orchestrator.TestSupport.PrivateStreamBranchFixture do
  @moduledoc """
  Real Branch fixture for the isolated ordinary-turn signal regression.

  Run its one owning-library test through the named no-start launcher in a fresh
  private umbrella VM. It configures the genuine applications before startup,
  owns fresh SQL/profile/Trust collaborators, and never stops a foreign owner.
  It never installs a provider dispatcher, synthetic Session state, or receipt.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.Agent.{BranchSupervisor, Character, Profile}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Persistence.Repo
  alias Arbor.Security

  @deadline_ms 15_000
  @state_key {__MODULE__, :cleanup_state}
  @model "private-stream-signal-fixture"

  defmodule AuditRepo do
    use Ecto.Repo, otp_app: :arbor_orchestrator, adapter: Ecto.Adapters.SQLite3
  end

  def open!(provider_adapter) do
    assert Code.ensure_loaded?(Arbor.Agent), "Run from the umbrella root in an isolated image"
    assert Process.whereis(Repo) == nil, "This fixture requires an unowned canonical Repo"

    for name <- [
          :arbor_agent_profiles,
          :arbor_user_config,
          Arbor.Trust.Store,
          Arbor.Trust.Manager
        ],
        do:
          assert(
            Process.whereis(name) == nil,
            "This fixture requires an unowned #{inspect(name)}"
          )

    previous_cwd = File.cwd!()
    source_root = Path.expand("../../../..", __DIR__)
    File.cd!(source_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "private-stream-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(root)
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    state = %{
      supervisor: supervisor,
      root: root,
      previous_cwd: previous_cwd,
      previous_env: [],
      capabilities: [],
      identity: nil,
      oidc: nil,
      branch_id: nil,
      subscription: nil,
      started_applications: [],
      started_database_applications: []
    }

    Process.put(@state_key, state)

    try do
      configure!(root)
      start_database_application!(:ecto_sql)
      start_database_application!(:ecto_sqlite3)
      assert is_pid(Process.whereis(Ecto.Repo.Registry))
      assert Enum.any?(Application.started_applications(), &(elem(&1, 0) == :db_connection))
      start!(Repo, {Repo, database_options(Path.join(root, "conversation.sqlite3"))})
      start!(AuditRepo, {AuditRepo, database_options(Path.join(root, "audit.sqlite3"))})
      migrations = Path.expand("../../../arbor_persistence/priv/repo/migrations", __DIR__)
      Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
      Ecto.Migrator.run(AuditRepo, migrations, :up, all: true, log: false)

      for {name, collection} <- [
            {:arbor_agent_profiles, "agent_profiles"},
            {:arbor_user_config, "user_config"}
          ] do
        start!(
          name,
          {Arbor.Persistence.BufferedStore,
           name: name,
           backend: Arbor.Persistence.QueryableStore.Postgres,
           backend_opts: [repo: Repo],
           write_mode: :sync,
           ack_mode: :backend,
           collection: collection}
        )
      end

      # The same production startup order as the accepted actual Branch helper:
      # SQL/audit targets and acknowledged profile stores exist before Security
      # freezes its startup configuration. No umbrella application task runs.
      start_runtime_application!(:arbor_agent)
      start_runtime_application!(:arbor_orchestrator)
      assert :ok = Arbor.Memory.TestBootstrap.start!()

      start!(
        Arbor.Trust.Store,
        {Arbor.Trust.Store,
         persistence: :durable,
         durable_backend: Arbor.Persistence.QueryableStore.Postgres,
         durable_backend_opts: [repo: AuditRepo],
         durable_collection: "private_stream_trust_profiles"}
      )

      start!(Arbor.Trust.Manager, {Arbor.Trust.Manager, []})
      assert Arbor.Trust.healthy?()
      assert is_pid(Process.whereis(Arbor.Trust.PolicyHost))
      assert is_pid(Process.whereis(Arbor.Orchestrator.RunJournal))

      for {name, spec} <- [
            {Arbor.Security.UriRegistry, Arbor.Security.UriRegistry},
            {Arbor.Agent.ExecutorRegistry,
             {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry}},
            {Arbor.Agent.ReasoningLoopRegistry,
             {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry}},
            {Arbor.Agent.ProfileAuthorityOwner, Arbor.Agent.ProfileAuthorityOwner},
            {Arbor.Agent.Registry, Arbor.Agent.Registry},
            {Arbor.Agent.SessionManager, Arbor.Agent.SessionManager},
            {Arbor.Agent.Orchestration.TaskSupervisor,
             {Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor}},
            {Arbor.Historian.AuthorityAuditPuller, Arbor.Historian.AuthorityAuditPuller},
            {Arbor.Signals.Store, Arbor.Signals.Store},
            {Arbor.Signals.TopicKeys, Arbor.Signals.TopicKeys},
            {Arbor.Signals.Bus, Arbor.Signals.Bus}
          ] do
        if Process.whereis(name) == nil, do: start!(name, spec)
      end

      assert Arbor.Signals.healthy?()

      assert :ok =
               Arbor.LLM.configure_provider_client(
                 adapters: %{"lm_studio" => provider_adapter},
                 default_provider: "lm_studio"
               )

      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      update!(%{oidc: oidc})
      assert :ok = Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)
      subject = oidc.identity.agent_id
      assert {:ok, token} = Security.SessionToken.generate(subject)
      assert {:ok, owner} = Security.resolve_conversation_owner(subject)
      assert {:ok, identity} = Identity.generate(name: "Private stream Branch")
      update!(%{identity: identity})
      target = identity.agent_id
      assert :ok = Security.register_identity(Identity.public_only(identity))
      assert :ok = Security.store_signing_key(target, identity.private_key)
      resource = "arbor://chat/agent/" <> target
      grant!(subject, resource)

      assert {:ok, _} =
               Arbor.Trust.ensure_trust_profile(subject,
                 baseline: :block,
                 rules: %{resource => :allow}
               )

      assert subject == owner

      resources = [
        "arbor://orchestrator/execute",
        "arbor://orchestrator/execute/compute",
        "arbor://orchestrator/execute/llm_query",
        "arbor://orchestrator/execute/transform",
        "arbor://orchestrator/execute/unknown",
        "arbor://action/pipeline/run",
        "arbor://memory/read/" <> target,
        "arbor://memory/write/" <> target
      ]

      for uri <- resources, do: grant!(target, uri)

      assert {:ok, _} =
               Arbor.Trust.ensure_trust_profile(target,
                 baseline: :block,
                 rules: Map.new(resources, &{&1, :allow})
               )

      assert {:ok, engagement} = Arbor.Comms.resolve_user_engagement(target, owner)

      mailbox = %{
        "mailbox_id" => "owner",
        "recipient_subject_id" => subject,
        "owner_id" => owner,
        "engagement_id" => engagement.id
      }

      profile = %Profile{
        agent_id: target,
        display_name: "Private stream Branch",
        character: Character.new(name: "Private stream Branch"),
        notice_mailboxes: [mailbox],
        created_at: DateTime.utc_now(),
        version: 1
      }

      assert :ok = Arbor.Agent.store_profile(profile)
      assert {:ok, stored_profile} = Arbor.Agent.load_profile(target)
      assert stored_profile.agent_id == target
      assert stored_profile.notice_mailboxes == [mailbox]
      turn_path = Path.join(root, "turn.dot")
      heartbeat_path = Path.join(root, "heartbeat.dot")
      File.write!(turn_path, turn_dot())
      File.write!(heartbeat_path, heartbeat_dot())
      source_root = Path.expand("../../../..", __DIR__)

      heartbeat_name =
        relative_fixture_path(
          heartbeat_path,
          Path.join(source_root, "apps/arbor_orchestrator/specs/pipelines/session")
        )

      bootstraps = %{
        session: bootstrap!(identity, :session),
        heartbeat: bootstrap!(identity, :heartbeat)
      }

      config = %{
        "recover_session" => false,
        "tools" => [],
        "stream" => true,
        "llm_provider" => "lmstudio",
        "llm_model" => @model
      }

      branch_id = {:private_stream_branch, target}
      update!(%{branch_id: branch_id})

      branch =
        start!(
          branch_id,
          {BranchSupervisor,
           agent_id: target,
           host_opts: [memory_enabled: false, agent_type: :test],
           executor_opts: [sandbox_level: :strict],
           authority_bootstraps: bootstraps,
           session_opts: [
             session_id: "agent-session-" <> target,
             agent_id: target,
             turn_dot: turn_path,
             heartbeat_dot: heartbeat_path,
             signing_authority_bootstrap: bootstraps.session,
             start_heartbeat: false,
             config: config
           ],
           heartbeat_opts: [
             agent_id: target,
             signing_authority_bootstrap: bootstraps.heartbeat,
             heartbeat_dot: heartbeat_path,
             heartbeat_config: %{enabled: true, interval: 86_400_000, graph: heartbeat_name},
             config: config
           ]}
        )

      children = BranchSupervisor.child_pids(target)
      assert BranchSupervisor.whereis(target) == branch
      assert is_pid(children.session) and is_pid(children.heartbeat_service)
      assert {:ok, discovered_session} = Arbor.Agent.SessionManager.get_session(target)
      assert discovered_session == children.session

      assert :ok =
               Arbor.Agent.Registry.register(target, branch, %{
                 runtime: :arbor,
                 model_config: %{runtime: :arbor},
                 host_pid: children.host,
                 session_pid: children.session,
                 supervisor_pid: branch,
                 agent_id: target
               })

      state =
        update!(%{
          subject: subject,
          token: token,
          target: target,
          engagement: engagement.id,
          session: children.session,
          branch: branch,
          heartbeat: children.heartbeat_service
        })

      on_exit(fn -> close!(state) end)
      assert {:ok, %{head: 0, entries: []}} = window!(state)
      state
    rescue
      error ->
        fallback_close()
        reraise error, __STACKTRACE__
    end
  end

  def submit!(state, text) do
    id = "private-stream-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    assert {:ok, _} =
             Arbor.Agent.submit_conversation_command(
               state.subject,
               state.target,
               %{id: id, text: text},
               options(state) ++ [timeout: 10_000]
             )

    id
  end

  def preview!(state, id, expected) do
    await!(fn ->
      assert {:ok, page} =
               Arbor.Agent.conversation_activity(
                 state.subject,
                 state.target,
                 options(state) ++ [limit: 50]
               )

      case Enum.find(page.commands, &(&1.command_id == id)) do
        %{execution: :running, preview: ^expected, preview_truncated: false} = command ->
          {:ok, command}

        _ ->
          :retry
      end
    end)
  end

  def completed!(state, id) do
    await!(fn ->
      assert {:ok, command} =
               Arbor.Agent.conversation_command(state.subject, state.target, id, options(state))

      case command.status do
        :completed -> {:ok, command}
        :uncertain -> flunk("Real stream turn must complete, not return an uncertain outcome")
        _ -> :retry
      end
    end)
  end

  def window!(state),
    do:
      Arbor.Agent.conversation_window(state.subject, state.target, options(state) ++ [limit: 40])

  def sql_pair!(state) do
    assert {:ok, %{rows: rows}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT e.role, e.content FROM session_entries e JOIN sessions s ON e.session_id = s.id
               WHERE s.session_id = ? AND s.agent_id = ? AND e.entry_type IN ('user', 'assistant')
                 AND json_extract(e.metadata, '$.engagement_id') = ? ORDER BY e.entry_ordinal
               """,
               ["agent-session-" <> state.target, state.target, state.engagement]
             )

    rows
  end

  def close!(%{supervisor: supervisor} = state) do
    try do
      try do
        if Process.alive?(supervisor) do
          if state[:branch_id],
            do: assert(:ok = Supervisor.terminate_child(supervisor, state.branch_id))

          if state[:target] do
            refute is_pid(BranchSupervisor.whereis(state.target))
            assert :ok = Arbor.Agent.Registry.unregister(state.target)
          end

          for cap <- state.capabilities, do: assert(:ok = Security.revoke(cap))

          if state[:identity] do
            assert :ok = Security.delete_signing_key(state.identity.agent_id)
            assert :ok = Security.deregister_identity(state.identity.agent_id)
            assert :ok = Arbor.Trust.delete_trust_profile(state.identity.agent_id)
          end

          if state[:oidc] do
            assert Security.deregister_identity(state.oidc.identity.agent_id) in [
                     :ok,
                     {:error, :not_found}
                   ]

            assert {:error, :not_found} = Security.identity_status(state.oidc.identity.agent_id)
            assert :ok = state.oidc.cleanup.()
            if state[:subject], do: assert(:ok = Arbor.Trust.delete_trust_profile(state.subject))
          end
        end
      after
        # Also reap exact acquired application IDs in ExUnit's on_exit actor,
        # where the linked private supervisor may already be down. Its death
        # alone never attests application cleanup or public identity retirement.
        try do
          assert :ok = Arbor.LLM.clear_provider_client()
        after
          try do
            stop_started_applications!(state.started_applications)
          after
            try do
              if Process.alive?(supervisor),
                do: assert(:ok = Supervisor.stop(supervisor, :normal, 10_000))

              refute Process.alive?(supervisor)
            after
              # Only after the exact Repo children are down may their acquired
              # database applications be stopped and SQL files removed.
              stop_started_applications!(state.started_database_applications)
            end
          end
        end
      end
    after
      restore!(state.previous_env)
      File.cd!(state.previous_cwd)
      File.rm_rf!(state.root)
    end

    :ok
  end

  defp options(state), do: [session_token: state.token, expected_engagement_id: state.engagement]

  defp database_options(path),
    do: [
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 1,
      busy_timeout: 5_000,
      journal_mode: :wal
    ]

  defp start!(id, spec) do
    state = Process.get(@state_key)

    assert {:ok, pid} =
             Supervisor.start_child(state.supervisor, Supervisor.child_spec(spec, id: id))

    pid
  end

  defp start_runtime_application!(app), do: start_application!(app, :started_applications)

  defp start_database_application!(app),
    do: start_application!(app, :started_database_applications)

  defp start_application!(app, state_key) do
    assert {:ok, started} = Application.ensure_all_started(app)
    state = Process.get(@state_key)
    update!(%{state_key => Enum.uniq(Map.fetch!(state, state_key) ++ started)})
    :ok
  end

  defp stop_started_applications!(started) do
    for app <- Enum.reverse(started) do
      # Idempotent on_exit after an acknowledged earlier normal close. Accept
      # only the exact local not-started result, never a generic stop failure.
      case Application.stop(app) do
        :ok -> :ok
        {:error, {:not_started, ^app}} -> :ok
        other -> flunk("Owned application stop failed for #{inspect(app)}: #{inspect(other)}")
      end

      refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == app))
    end

    :ok
  end

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)
    update!(%{capabilities: [cap.id | Process.get(@state_key).capabilities]})
    cap
  end

  defp bootstrap!(identity, purpose) do
    assert {:ok, proof} =
             Security.build_signing_authority_acquisition_proof(
               identity.agent_id,
               identity.private_key,
               purpose: purpose,
               owner: self()
             )

    assert {:ok, bootstrap} = Security.issue_signing_authority_bootstrap(proof)
    bootstrap
  end

  defp update!(updates) do
    state = Map.merge(Process.get(@state_key), updates)
    Process.put(@state_key, state)
    state
  end

  defp configure!(root) do
    signals = Application.get_env(:arbor_kernel, :signals, [])

    settings = [
      # These child options select fixture-owned genuine collaborators; the
      # full profile, mandatory PolicyHost and all security gates remain on.
      {:arbor_persistence, :start_children, false},
      {:arbor_persistence, :start_repo, false},
      {:arbor_persistence, :sql_repository, Repo},
      {:arbor_agent, :start_children, false},
      {:arbor_memory, :start_children, false},
      {:arbor_trust, :start_children, false},
      {:arbor_security, :start_children, true},
      {:arbor_security, :authority_state_root, Path.join(root, "security-authority")},
      {:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile},
      {:arbor_security, :audit_journal_mode, :durable},
      {:arbor_security, :master_key_path, Path.join(root, "security-master.key")},
      {:arbor_security, :distributed_signals, false},
      {:arbor_security, :event_log_adapter, Arbor.Historian.Adapters.SecurityEventLog},
      {:arbor_security, Arbor.Security.Store.JSONFile,
       [base_dir: Path.join(root, "security-authority")]},
      {:arbor_security, :identity_verification, true},
      {:arbor_security, :strict_identity_mode, true},
      {:arbor_security, :capability_signing_required, true},
      {:arbor_security, :constraint_enforcement_enabled, true},
      {:arbor_security, :policy_enforcer_enabled, true},
      {:arbor_security, :approval_guard_enabled, true},
      {:arbor_security, :reflex_checking_enabled, true},
      {:arbor_security, :uri_registry_enforcement, true},
      {:arbor_security, :egress_gate_enforcing, true},
      {:arbor_security, :identity_alias_resolver, Arbor.Agent.IdentityAliasResolver},
      {:arbor_security, :native_notice_source_authorizer, Arbor.Agent.NoticeSourceAuthority},
      {:arbor_security, :session_token_module, Security.SessionToken},
      {:arbor_security, :session_token_secret,
       Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)},
      {:arbor_trust, :policy_module, Arbor.Trust.Policy},
      {:arbor_trust, :policy_enforcer_enabled, true},
      {:arbor_trust, :approval_guard_enabled, true},
      {:arbor_actions, :default_taint_policy, :strict},
      {:arbor_actions, :comms_module, Arbor.Comms},
      {:arbor_orchestrator, :private_conversation_memory, false},
      {:arbor_orchestrator, :preprocessor_enabled, false},
      {:arbor_comms, :conversation_persistence_module, Arbor.Persistence},
      {:arbor_comms, :conversation_directory_persistence_module, Arbor.Persistence},
      {:arbor_comms, :conversation_journal,
       [
         backend: Arbor.Persistence.EventLog.Ecto,
         name: :private_stream_signal,
         opts: [repo: Repo]
       ]},
      {:arbor_historian, :start_children, true},
      {:arbor_historian, :durable_event_log_target,
       %{
         name: :private_stream_signal_audit,
         backend: Arbor.Persistence.EventLog.Ecto,
         opts: [repo: AuditRepo]
       }},
      {:arbor_orchestrator, :private_stream_signal_recipient, self()},
      {:arbor_kernel, :signals,
       Keyword.merge(signals,
         start_children: false,
         authorizer: Arbor.Signals.Adapters.CapabilityAuthorizer,
         allow_open_authorizer: false,
         security_module: Security,
         crypto_module: Security,
         relay_enabled: false
       )}
    ]

    previous =
      Enum.map(settings, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    update!(%{previous_env: previous})
    for {app, key, value} <- settings, do: Application.put_env(app, key, value)
    assert File.dir?(root)
  end

  defp restore!(previous) do
    for {app, key, value} <- previous do
      case value do
        {:ok, prior} -> Application.put_env(app, key, prior)
        :error -> Application.delete_env(app, key)
      end
    end
  end

  defp fallback_close do
    try do
      case Process.get(@state_key) do
        nil -> :ok
        state -> close!(state)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp await!(read, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @deadline_ms

    case read.() do
      {:ok, value} ->
        value

      :retry ->
        assert System.monotonic_time(:millisecond) < deadline,
               "Real stream observation did not reach its bounded phase"

        Process.sleep(25)
        await!(read, deadline)
    end
  end

  defp relative_fixture_path(target, base) do
    {target_parts, base_parts} = strip_shared_path(Path.split(target), Path.split(base))
    Path.join(List.duplicate("..", length(base_parts)) ++ target_parts)
  end

  defp strip_shared_path([same | target], [same | base]), do: strip_shared_path(target, base)
  defp strip_shared_path(target, base), do: {target, base}

  defp turn_dot do
    """
    digraph PrivateStreamSignal {
      start [shape=Mdiamond]
      call [type=compute, simulate="false", prompt="Reply to this private user", use_tools="false"]
      copy [type=transform, transform=identity, source_key="last_response", output_key="session.response"]
      done [shape=Msquare]
      start -> call -> copy -> done
    }
    """
  end

  defp heartbeat_dot do
    """
    digraph PrivateStreamHeartbeat {
      start [shape=Mdiamond]
      reply [type=transform, transform=constant, expression="Initial harmless heartbeat", output_key="session.response"]
      done [shape=Msquare]
      start -> reply -> done
    }
    """
  end
end
