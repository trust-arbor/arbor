Code.require_file(
  Path.expand("../../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Agent.ConversationActivityAdapterOrderingRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans
  alias ConversationKit.Arbor, as: Adapter
  @compile {:no_warn_undefined, ConversationKit.Arbor}
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  # Optional package consumer: run with its normally compiled private BEAMs on
  # ERL_LIBS and --include external. No new Agent runtime dependency is added.
  @moduletag :external
  @migrations Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  setup_all do
    assert Code.ensure_loaded?(Adapter),
           "Normally compile the local adapter package before this joined lane."

    assert Process.whereis(Repo) == nil, "This joined lane owns the canonical private Repo."
    root = Path.join(System.tmp_dir!(), "activity-ordering-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      {Repo,
       database: Path.join(root, "journal.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    # Own the production authority-audit consumer and its real private SQL
    # target, as well as the journal/index. Never bypass backlog admission.
    set_env(:arbor_historian, :durable_event_log_target, %{
      name: :ordering_authority_audit,
      backend: Arbor.Persistence.EventLog.Ecto,
      opts: [repo: Repo]
    })

    assert Process.whereis(Arbor.Historian.AuthorityAuditPuller) == nil
    start_supervised!({Arbor.Historian.AuthorityAuditPuller, poll_interval_ms: 25})

    for {name, child} <- [
          {Arbor.Comms.EngagementStore, Arbor.Comms.EngagementStore},
          {Arbor.Comms.ConversationActivity, Arbor.Comms.ConversationActivity},
          {:arbor_user_config,
           {Arbor.Persistence.BufferedStore,
            name: :arbor_user_config,
            backend: Arbor.Security.Store.JSONFile,
            write_mode: :sync,
            ack_mode: :backend,
            backend_opts: [base_dir: Path.join(root, "aliases")],
            collection: "ordering_aliases"}}
        ] do
      if Process.whereis(name) == nil,
        do: start_supervised!(Supervisor.child_spec(child, id: name))
    end

    :ok
  end

  setup do
    c = Humans.setup!()
    set_env(:arbor_security, :identity_alias_resolver, Arbor.Agent.IdentityAliasResolver)

    set_env(:arbor_comms, :conversation_journal,
      backend: Arbor.Persistence.EventLog.Ecto,
      name: :conversation_journal,
      opts: [repo: Repo]
    )

    {:ok, target} = Security.generate_identity()
    assert :ok = Security.register_identity_fixture(target)
    on_exit(fn -> Security.deregister_identity_fixture(target.agent_id) end)
    cap = Humans.grant!(c.human_id, "arbor://chat/agent/" <> target.agent_id)
    {:ok, %{operation_id: audit_id}} = Security.capability_mutation_audit_status()
    {:ok, engagement} = Arbor.Comms.resolve_user_engagement(target.agent_id, c.human_id)
    scope = %{principal_id: c.human_id, agent_id: target.agent_id, engagement_id: engagement.id}
    observer = self()

    proof = fn request ->
      send(observer, {:fresh_proof, request})
      {:ok, [session_token: c.token]}
    end

    {:ok, client} =
      Adapter.new(c.human_id, target.agent_id, proof, expected_engagement_id: engagement.id)

    {:ok,
     Map.merge(c, %{
       target: target.agent_id,
       cap: cap,
       audit_id: audit_id,
       scope: scope,
       client: client
     })}
  end

  test "security regression real indexed active and queued producer page is accepted by the public adapter",
       c do
    assert {:ok, _} =
             Arbor.Comms.admit_conversation_command(c.scope, %{
               id: "active",
               text: "private active input"
             })

    assert {:ok, _} = Arbor.Comms.claim_conversation_command(c.scope, "active")

    assert {:ok, _} =
             Arbor.Comms.admit_conversation_command(c.scope, %{
               id: "queued",
               text: "private queued input"
             })

    page = complete_page!(c, 3)
    assert length(page.commands) == 2
    assert Enum.sort(Enum.map(page.commands, & &1.command_id)) == ["active", "queued"]
    assert page.index_watermark == 3 and page.source_watermark == 3 and not page.incomplete
    # A bounded positive producer witness, with no proof or private task fields.
    IO.puts(
      "ACTIVITY_ORDERING_PRODUCER " <>
        Jason.encode!(%{
          commands:
            Enum.map(
              page.commands,
              &Map.take(&1, [:command_id, :admitted_cursor, :delivery_status, :execution])
            ),
          source_watermark: page.source_watermark,
          index_watermark: page.index_watermark
        })
    )

    assert {:ok, _, records, discovery} = Adapter.activity(c.client)
    assert ids(records) == ["queued", "active"]
    refute discovery.has_more
    assert discovery.next_cursor == nil
    assert Enum.all?(records, &(not Map.has_key?(&1, "task_id")))
    refute inspect(records) =~ "private active input"
    assert_receive {:fresh_proof, %{operation: :activity, target: target, options: options}}
    assert target == c.target and options[:expected_engagement_id] == c.scope.engagement_id
    assert {:ok, %{pending: 0}} = Arbor.Historian.flush_authority_audit()

    assert {:ok, [audit]} =
             Arbor.Persistence.read_stream(
               :ordering_authority_audit,
               Arbor.Persistence.EventLog.Ecto,
               "security:authority_mutation:" <> c.audit_id,
               repo: Repo
             )

    assert audit.data["effect"] == "applied"
    assert audit.data["intent"]["audit"]["data"]["capability_id"] == c.cap.id
  end

  test "security regression bounded older pages remain discoverable after newer admissions and fresh revocation",
       c do
    for n <- 1..60 do
      assert {:ok, _} =
               Arbor.Comms.admit_conversation_command(c.scope, %{
                 id: "work_#{n}",
                 text: "private work #{n}"
               })
    end

    for n <- 1..10 do
      id = "terminal_#{n}"

      assert {:ok, _} =
               Arbor.Comms.admit_conversation_command(c.scope, %{
                 id: id,
                 text: "private terminal input"
               })

      assert {:ok, claim} = Arbor.Comms.claim_conversation_command(c.scope, id)

      assert {:ok, _} =
               Arbor.Comms.settle_conversation_command(c.scope, id, claim, %{
                 status: :completed,
                 text: "private terminal output"
               })
    end

    assert %{commands: page, has_more: true} = complete_page!(c, 90)
    assert length(page) == 20
    assert Enum.map(page, & &1.command_id) == Enum.map(60..41//-1, &"work_#{&1}")
    assert {:ok, _, first, discovery} = Adapter.activity(c.client, limit: 20)
    assert ids(first) == Enum.map(60..41//-1, &"work_#{&1}")
    assert {:ok, _} = Arbor.Comms.claim_conversation_command(c.scope, "work_20")

    assert {:ok, _} =
             Arbor.Comms.admit_conversation_command(c.scope, %{
               id: "newest",
               text: "private new work"
             })

    complete_page!(c, 92)

    assert {:ok, _, middle, next} =
             Adapter.activity(c.client, limit: 20, cursor: discovery.next_cursor)

    assert ids(middle) == Enum.map(40..21//-1, &"work_#{&1}")
    assert {:ok, _, last, final} = Adapter.activity(c.client, limit: 20, cursor: next.next_cursor)
    assert ids(last) == Enum.map(20..1//-1, &"work_#{&1}")
    assert final.next_cursor == nil and not final.has_more
    assert length(Enum.uniq(ids(first ++ middle ++ last))) == 60
    assert {:ok, _, latest, _} = Adapter.activity(c.client, limit: 1)
    assert ids(latest) == ["newest"]
    assert {:ok, observed} = Adapter.controls(c.client)
    controls = Adapter.controls_projection(observed)
    assert length(controls["activities"]) == 8
    assert List.first(controls["activities"])["command_id"] == "newest"
    assert inspect(controls) =~ "not_observed"

    for field <- [
          "task_id",
          "principal_id",
          "agent_id",
          "engagement_id",
          "session_token",
          "claim_token"
        ] do
      refute inspect(controls) =~ field
    end

    refute inspect(controls) =~ "private terminal"
    assert :ok = Security.revoke_fixture(c.cap.id)
    assert {:error, :unauthorized} = Adapter.activity(c.client)
  end

  defp ids(records), do: Enum.map(records, & &1["command_id"])

  defp complete_page!(c, source),
    do: await_page!(c, source, System.monotonic_time(:millisecond) + 10_000)

  defp await_page!(c, source, deadline) do
    case Arbor.Agent.conversation_activity(c.human_id, c.target,
           session_token: c.token,
           expected_engagement_id: c.scope.engagement_id
         ) do
      {:ok, %{source_watermark: ^source, index_watermark: ^source} = page} ->
        page

      {:ok, _} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "actual journal index did not catch up"

        Process.sleep(50)
        await_page!(c, source, deadline)

      other ->
        flunk("public activity failed: #{inspect(other)}")
    end
  end

  defp set_env(app, key, value) do
    prior = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case prior do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
