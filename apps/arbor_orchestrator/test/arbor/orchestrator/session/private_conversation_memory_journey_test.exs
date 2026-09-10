Code.require_file(
  Path.expand("../../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

Code.require_file(
  Path.expand("../../../../../arbor_memory/test/support/private_snapshot_fixture.ex", __DIR__)
)

defmodule Arbor.Orchestrator.Session.PrivateConversationMemoryJourneyTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Memory.Test.PrivateSnapshotFixture, as: SnapshotFixture

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @real_turn_dot Path.expand("../../../../specs/pipelines/session/turn.dot", __DIR__)
  @migrations Path.expand("../../../../../arbor_persistence/priv/repo/migrations", __DIR__)
  @sentinel "the observatory passphrase is VIOLET-QUARTZ-731"

  defmodule CaptureProvider do
    def provider, do: "lm_studio"
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

    def complete(request, opts) do
      observer = Application.fetch_env!(:arbor_orchestrator, :_private_memory_journey_observer)
      send(observer, {:model_request, request.messages, opts})

      {:ok,
       %Arbor.LLM.Response{
         text: "Understood.",
         finish_reason: :stop,
         content_parts: [Arbor.LLM.ContentPart.text("Understood.")],
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
         raw: %{}
       }}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  setup_all do
    assert Process.whereis(Repo) == nil,
           "Run this isolated SQLite journey standalone; it must not reuse another Repo."

    root =
      Path.join(System.tmp_dir!(), "arbor_private_journey_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    database = Path.join(root, "journey.sqlite3")

    repo_opts = [
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5_000,
      journal_mode: :wal
    ]

    repo_supervisor =
      start_supervised!(%{
        id: :private_journey_repo_supervisor,
        start: {Supervisor, :start_link, [[{Repo, repo_opts}], [strategy: :one_for_one]]}
      })

    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

    if Process.whereis(Arbor.Orchestrator.EventRegistry) == nil,
      do: start_supervised!({Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry})

    if Process.whereis(Arbor.Comms.EngagementStore) == nil,
      do: start_supervised!(Arbor.Comms.EngagementStore)

    on_exit(fn ->
      if Process.alive?(repo_supervisor), do: Supervisor.stop(repo_supervisor)
      if Path.dirname(root) != System.tmp_dir!(), do: raise("invalid fixture root")
      File.rm_rf!(root)
    end)

    {:ok, fixture_root: root, repo_supervisor: repo_supervisor}
  end

  setup do
    set_env(:arbor_security, :identity_verification, true)
    set_env(:arbor_security, :policy_enforcer_enabled, false)
    set_env(:arbor_security, :approval_guard_enabled, false)
    set_env(:arbor_security, :reflex_checking_enabled, false)
    set_env(:arbor_security, :uri_registry_enforcement, false)
    set_env(:arbor_trust, :policy_enforcer_enabled, false)
    set_env(:arbor_trust, :approval_guard_enabled, false)
    set_env(:arbor_memory, :private_memory_security, Security)
    set_env(:arbor_memory, :strict_vector_seam, Arbor.Memory.StrictVectorSeam.Default)
    set_env(:arbor_persistence, :vector_store_backend, Arbor.Persistence.VectorStore.Ecto)
    set_env(:arbor_persistence, :vector_store_repo, Repo)
    set_env(:arbor_orchestrator, :_private_memory_journey_observer, self())
    set_env(:arbor_orchestrator, :preprocessor_enabled, false)
    snapshot_fixture = SnapshotFixture.start!()

    endpoint = embedding_endpoint!()
    # ReqLLM endpoint ownership uses the canonical ProviderRegistry config.
    set_env(:arbor_orchestrator, :lm_studio, base_url: endpoint.url)
    set_env(:arbor_llm, :lm_studio_base_url, endpoint.url)

    config = [
      enabled: true,
      provider: :lm_studio,
      model: "private-journey-embedding",
      base_url: endpoint.url,
      timeout_ms: 5_000
    ]

    set_env(:arbor_orchestrator, :private_conversation_memory, config)
    assert Keyword.fetch!(Arbor.Orchestrator.Config.private_conversation_memory(), :enabled)

    previous_client = Arbor.LLM.Client.default_client()

    client =
      Arbor.LLM.Client.new(default_provider: "lm_studio")
      |> Arbor.LLM.Client.register_adapter(CaptureProvider)

    Arbor.LLM.Client.set_default_client(client)
    on_exit(fn -> Arbor.LLM.Client.set_default_client(previous_client) end)

    owner = owner!()
    session_id = "private-journey-#{System.unique_integer([:positive])}"

    {:ok,
     owner: owner, session_id: session_id, endpoint: endpoint, snapshot_fixture: snapshot_fixture}
  end

  test "authenticated real turn.dot commits a signed pair, indexes it, and recalls after cold SQLite and a new engagement",
       ctx do
    first = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, response} = turn(first, ctx.owner, @sentinel)
    assert response.metadata.conversation_memory.status == "indexed"
    assert response.metadata.conversation_memory.transcript == "committed"
    assert_receive {:model_request, first_messages, opts}
    assert inspect(first_messages) =~ @sentinel
    refute Keyword.has_key?(opts, :memory_write_policy)

    [user, assistant] =
      Arbor.Persistence.load_recent_session_messages(ctx.session_id, limit: 1_000)

    assert user.metadata["private_memory_source"] == assistant.metadata["private_memory_source"]
    original = user.metadata["private_memory_source"]["descriptor"]
    assert original["human_id"] == ctx.owner.human.agent_id
    assert original["agent_id"] == ctx.owner.agent.agent_id

    assert {:ok, [record]} =
             Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)

    original_id = record.id
    assert record.source_namespace == original["source_namespace"]
    assert :ok = GenServer.stop(first)

    # Real persisted rows are reconstructed after the SQLite owner restarts.
    assert :ok = Supervisor.terminate_child(ctx.repo_supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(ctx.repo_supervisor, Repo)
    new_engagement = replace_engagement!(ctx.owner)
    second = start_session!(ctx, ctx.owner, ctx.session_id)
    assert Session.get_state(second).messages == []
    drain_embeddings()

    assert {:ok, second_response} =
             turn(second, ctx.owner, "What was the observatory passphrase?")

    assert second_response.metadata.conversation_memory.status == "indexed"
    assert_receive {:model_request, recalled_messages, _opts}
    assert inspect(recalled_messages) =~ @sentinel
    assert original["engagement_id"] != new_engagement.id

    assert {:ok, stored} =
             Arbor.Persistence.fetch_vector_record(
               ctx.owner.agent.agent_id,
               original["source_namespace"],
               original["source_key"]
             )

    assert stored.id == original_id

    assert stored.payload["body"]["conversation_scope"]["engagement_id"] ==
             original["engagement_id"]

    refute drain_embeddings()
           |> Enum.any?(&Enum.any?(&1, fn text -> String.contains?(text, @sentinel) end))
  end

  test "same-agent other-human and same-human other-agent prompts never receive the owner's indexed conversation",
       ctx do
    first = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, _} = turn(first, ctx.owner, @sentinel)
    assert_receive {:model_request, _, _}
    :ok = GenServer.stop(first)

    for other <- [owner!(ctx.owner.agent, nil), owner!(nil, ctx.owner.human)] do
      session = start_session!(ctx, other, "foreign-#{System.unique_integer([:positive])}")
      assert {:ok, _} = turn(session, other, "What was the observatory passphrase?")
      assert_receive {:model_request, messages, _}
      refute inspect(messages) =~ @sentinel
      :ok = GenServer.stop(session)
    end
  end

  test "acknowledged indexing failure remains committed and recovers exactly once on the next admitted turn",
       ctx do
    Agent.update(ctx.endpoint.state, &Map.put(&1, :fail_content, @sentinel))
    first = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, response} = turn(first, ctx.owner, @sentinel)
    assert response.metadata.conversation_memory == %{status: "pending", transcript: "committed"}
    assert_receive {:model_request, _, _}
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 2
    assert {:ok, []} = Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)
    :ok = GenServer.stop(first)

    Agent.update(ctx.endpoint.state, &Map.put(&1, :fail_content, nil))
    second = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, _} = turn(second, ctx.owner, "Recall the prior passphrase")
    assert_receive {:model_request, messages, _}
    assert inspect(messages) =~ @sentinel
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 4

    assert {:ok, rows} =
             Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)

    assert length(rows) == 2
    assert length(Enum.uniq_by(rows, & &1.source_key)) == 2
  end

  test "unknown append outcome recovers only an observed complete committed pair and never retries the append",
       ctx do
    observer = self()

    append = fn uuid, entries ->
      assert {:ok, 2} = Arbor.Persistence.append_session_entries(uuid, entries)
      send(observer, :committed_but_ack_lost)
      {:error, :outcome_unknown}
    end

    first = start_session!(ctx, ctx.owner, ctx.session_id, append_session_entries: append)
    assert {:error, :turn_commit_failed} = turn(first, ctx.owner, @sentinel)
    assert_received :committed_but_ack_lost
    assert_receive {:model_request, _, _}
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 2
    assert {:ok, []} = Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)
    :ok = GenServer.stop(first)

    second = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, _} = turn(second, ctx.owner, "Recover the earlier conversation")
    assert_receive {:model_request, messages, _}
    assert inspect(messages) =~ @sentinel
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 4
    refute_received :committed_but_ack_lost
  end

  test "recovery rejects another human's pending source in the same Session before embedding or prompting",
       ctx do
    Agent.update(ctx.endpoint.state, &Map.put(&1, :fail_content, @sentinel))
    first = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, response} = turn(first, ctx.owner, @sentinel)
    assert response.metadata.conversation_memory.status == "pending"
    assert_receive {:model_request, _, _}
    :ok = GenServer.stop(first)
    Agent.update(ctx.endpoint.state, &Map.put(&1, :fail_content, nil))
    drain_embeddings()

    foreign = owner!(ctx.owner.agent, nil)
    session = start_session!(ctx, foreign, ctx.session_id)
    assert {:ok, _} = turn(session, foreign, "A separate human's new conversation")
    assert_receive {:model_request, messages, _}
    refute inspect(messages) =~ @sentinel

    refute drain_embeddings()
           |> Enum.any?(&Enum.any?(&1, fn text -> String.contains?(text, @sentinel) end))

    assert {:ok, [row]} =
             Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)

    assert row.payload["body"]["conversation_scope"]["human_id"] == foreign.human.agent_id
  end

  test "recovery never indexes an incomplete observed source pair after an unknown append outcome",
       ctx do
    append = fn uuid, [user, _assistant] ->
      assert {:ok, 1} = Arbor.Persistence.append_session_entries(uuid, [user])
      {:error, :outcome_unknown}
    end

    first = start_session!(ctx, ctx.owner, ctx.session_id, append_session_entries: append)
    assert {:error, :turn_commit_failed} = turn(first, ctx.owner, @sentinel)
    assert_receive {:model_request, _, _}
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 1
    :ok = GenServer.stop(first)
    drain_embeddings()

    second = start_session!(ctx, ctx.owner, ctx.session_id)
    assert {:ok, _} = turn(second, ctx.owner, "Start a fresh complete conversation")
    assert_receive {:model_request, messages, _}
    refute inspect(messages) =~ @sentinel

    refute drain_embeddings()
           |> Enum.any?(&Enum.any?(&1, fn text -> String.contains?(text, @sentinel) end))

    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 3

    assert {:ok, [_]} =
             Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)
  end

  test "enabled source attestation failure refuses append; explicit disabled mode performs no automatic embedding",
       ctx do
    set_env(:arbor_security, :system_authority_mode, :ephemeral)
    restart_root!()
    session = start_session!(ctx, ctx.owner, ctx.session_id)

    assert {:error, :private_memory_source_unavailable} =
             turn(session, ctx.owner, "No recoverable source")

    assert Arbor.Persistence.load_recent_session_messages(ctx.session_id) == []
    :ok = GenServer.stop(session)

    set_env(:arbor_orchestrator, :private_conversation_memory, false)
    drain_embeddings()
    disabled = start_session!(ctx, ctx.owner, "disabled-#{System.unique_integer([:positive])}")
    assert {:ok, response} = turn(disabled, ctx.owner, "Explicit disabled memory")
    assert response.metadata.conversation_memory.status == "disabled"
    assert drain_embeddings() == []
  end

  for interruption <- [:cancel, :session_death, :caller_death] do
    @tag interruption: interruption
    test "post-ACK #{interruption} leaves one recoverable pair and cannot apply a late embedding",
         ctx do
      Agent.update(ctx.endpoint.state, &Map.put(&1, :hold_sources, true))
      session = start_session!(ctx, ctx.owner, ctx.session_id)
      observer = self()

      {caller, monitor} =
        spawn_monitor(fn ->
          result =
            try do
              turn(session, ctx.owner, @sentinel)
            catch
              :exit, reason -> {:call_exit, reason}
            end

          send(observer, {:held_turn_result, result})
        end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

      assert_receive {:embedding_held, server}, 5_000
      assert_receive {:model_request, _, _}
      # The real HTTP request is blocked, yet the Session mailbox remains live.
      assert Session.get_state(session).turn_in_flight
      assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 2

      assert {:ok, []} =
               Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)

      case ctx.interruption do
        :cancel ->
          assert :ok = Session.cancel_turn(session)
          assert_receive {:held_turn_result, {:ok, response}}, 5_000

          assert response.metadata.conversation_memory == %{
                   status: "pending",
                   transcript: "committed"
                 }

          assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
          refute Session.get_state(session).turn_in_flight

        :session_death ->
          Process.unlink(session)
          session_monitor = Process.monitor(session)
          Process.exit(session, :kill)
          assert_receive {:DOWN, ^session_monitor, :process, ^session, :killed}
          assert_receive {:held_turn_result, {:call_exit, _}}, 5_000
          assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}

        :caller_death ->
          Process.exit(caller, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
          await_idle(session)
      end

      Agent.update(ctx.endpoint.state, &Map.put(&1, :hold_sources, false))
      send(server, {:release_embedding, self()})
      assert_receive :embedding_released, 5_000
      if Process.alive?(session), do: GenServer.stop(session)
      assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 2

      assert {:ok, []} =
               Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)

      recovered = start_session!(ctx, ctx.owner, ctx.session_id)
      assert {:ok, _} = turn(recovered, ctx.owner, "Recall the committed passphrase")
      assert_receive {:model_request, messages, _}
      assert inspect(messages) =~ @sentinel
      assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 4

      assert {:ok, rows} =
               Arbor.Persistence.list_vector_records(ctx.owner.agent.agent_id, limit: 100)

      assert length(rows) == 2
    end
  end

  test "invalid private embedding routes and oversized queries fail before any provider request",
       ctx do
    good = Arbor.Orchestrator.Config.private_conversation_memory()

    configurations = [
      Keyword.put(good, :base_url, "https://api.openai.com/v1"),
      Keyword.put(good, :base_url, "http://localhost:1234/v1"),
      Keyword.put(good, :provider, :openai),
      Keyword.delete(good, :model),
      Keyword.put(good, :timeout_ms, 30_001),
      good ++ [model: "duplicate"],
      good ++ [owner: ctx.owner.human.agent_id],
      [{:enabled, true} | :invalid]
    ]

    for config <- configurations do
      Application.put_env(:arbor_orchestrator, :private_conversation_memory, config)
      session = start_session!(ctx, ctx.owner, "invalid-#{System.unique_integer([:positive])}")

      assert {:error, :private_memory_configuration_unavailable} =
               turn(session, ctx.owner, "Private route sentinel")

      :ok = GenServer.stop(session)
    end

    Application.put_env(:arbor_orchestrator, :private_conversation_memory, good)
    session = start_session!(ctx, ctx.owner, ctx.session_id)

    assert {:error, :private_memory_admission_unavailable} =
             turn(session, ctx.owner, String.duplicate("x", 65_537))

    refute_received {:model_request, _, _}
    assert drain_embeddings() == []
    assert Arbor.Persistence.load_recent_session_messages(ctx.session_id) == []
  end

  test "two authenticated focus interactions produce a corrected private prompt after cold reconstruction",
       ctx do
    session = start_session!(ctx, ctx.owner, ctx.session_id)
    declaration = "Remember my current focus: observatory calibration"
    correction = "Correction: my current focus is: telescope alignment"
    assert {:ok, first} = turn(session, ctx.owner, declaration)
    assert first.metadata.relationship_memory == %{status: "saved", transcript: "committed"}
    assert_receive {:model_request, _, _}
    assert {:ok, second} = turn(session, ctx.owner, correction)
    assert second.metadata.relationship_memory == %{status: "saved", transcript: "committed"}
    assert_receive {:model_request, _, _}
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 4
    assert :ok = GenServer.stop(session)
    assert :ok = SnapshotFixture.restart_store!(ctx.snapshot_fixture)
    assert :ok = SnapshotFixture.restart_root!(ctx.snapshot_fixture)
    replace_engagement!(ctx.owner)

    # Disable semantic recall for this request so the observed focus can only
    # come from the verified relationship snapshot, with no retained transcript.
    query = "What should we focus on now?"
    Agent.update(ctx.endpoint.state, &Map.put(&1, :fail_content, query))
    later = start_session!(ctx, ctx.owner, ctx.session_id <> "-later")
    assert Session.get_state(later).messages == []
    assert {:ok, third} = turn(later, ctx.owner, query)
    assert third.metadata.relationship_memory.status == "not_requested"
    assert_receive {:model_request, messages, _}
    user = Enum.find(Enum.reverse(messages), &(&1.role == :user))
    assert Arbor.LLM.Message.text(user) =~ "## Private relationship context"
    assert Arbor.LLM.Message.text(user) =~ "User-stated current focus: telescope alignment"
    refute inspect(messages) =~ "observatory calibration"
    refute_received {:model_request, _, _}
    assert :ok = GenServer.stop(later)

    for other <- [owner!(ctx.owner.agent, nil), owner!(nil, ctx.owner.human)] do
      foreign = start_session!(ctx, other, "focus-foreign-#{System.unique_integer([:positive])}")
      assert {:ok, _} = turn(foreign, other, query)
      assert_receive {:model_request, messages, _}
      refute inspect(messages) =~ "telescope alignment"
      refute inspect(messages) =~ "Private relationship context"
      assert :ok = GenServer.stop(foreign)
    end

    assert {:ok, false} = Arbor.Memory.relationships_absent?(ctx.owner.agent.agent_id)
    assert :ok = Arbor.Memory.delete_all_relationships(ctx.owner.agent.agent_id)
    assert {:ok, true} = Arbor.Memory.relationships_absent?(ctx.owner.agent.agent_id)
    admission = SnapshotFixture.admission!(ctx.owner)

    assert {:ok, %{relationship: %{}, fence: :not_found}} =
             Arbor.Memory.get_private_relationship(admission)
  end

  test "post-ACK relationship status is independent of vector failure and a rejected correction never retries transcript",
       ctx do
    session = start_session!(ctx, ctx.owner, ctx.session_id)
    directive = "Remember my current focus: mirror polishing"
    Agent.update(ctx.endpoint.state, &Map.put(&1, :fail_content, directive))
    assert {:ok, response} = turn(session, ctx.owner, directive)
    assert response.metadata.conversation_memory.status == "pending"
    assert response.metadata.relationship_memory == %{status: "saved", transcript: "committed"}
    assert_receive {:model_request, _, _}
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 2

    assert {:ok, conflict} =
             turn(session, ctx.owner, "Remember my current focus: silent replacement")

    assert conflict.metadata.relationship_memory == %{status: "conflict", transcript: "committed"}
    assert_receive {:model_request, _, _}
    assert length(Arbor.Persistence.load_recent_session_messages(ctx.session_id)) == 4
    admission = SnapshotFixture.admission!(ctx.owner)

    assert {:ok, %{relationship: %{"current_focus" => "mirror polishing"}}} =
             Arbor.Memory.get_private_relationship(admission)
  end

  defp await_idle(session, attempts \\ 100)
  defp await_idle(_session, 0), do: flunk("Session did not finish its cancelled index stage")

  defp await_idle(session, attempts) do
    if Session.get_state(session).turn_in_flight do
      receive do
      after
        10 -> :ok
      end

      await_idle(session, attempts - 1)
    else
      :ok
    end
  end

  defp start_session!(_ctx, owner, session_id, adapters \\ []) do
    assert {:ok, pid} =
             Session.start_link(
               session_id: session_id,
               agent_id: owner.agent.agent_id,
               turn_dot: @real_turn_dot,
               start_heartbeat: false,
               adapters: Map.new(adapters),
               signer: fn resource ->
                 SignedRequest.sign(resource, owner.agent.agent_id, owner.agent.private_key)
               end,
               config: %{
                 "llm_provider" => "lm_studio",
                 "llm_model" => "journey-response",
                 "stream" => false,
                 "recover_session" => false
               }
             )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp turn(session, owner, text) do
    resource = "arbor://chat/agent/" <> owner.agent.agent_id

    assert {:ok, signed} =
             SignedRequest.sign(resource, owner.human.agent_id, owner.human.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(owner.human.agent_id, resource, :chat,
               signed_request: signed,
               expected_resource: resource
             )

    message = UserMessage.from_voice(text, sender_id: owner.human.agent_id)
    Session.send_authenticated_message(session, message, receipt, 15_000)
  end

  defp owner!(agent \\ nil, human \\ nil) do
    agent = agent || new_agent!()
    human = human || new_human!()

    for {principal, resource} <- [
          {human.agent_id, "arbor://chat/agent/" <> agent.agent_id},
          {agent.agent_id, "arbor://memory/read/" <> agent.agent_id},
          {agent.agent_id, "arbor://memory/write/" <> agent.agent_id},
          {agent.agent_id, "arbor://orchestrator/execute"},
          {agent.agent_id, "arbor://orchestrator/execute/llm_query"},
          {agent.agent_id, "arbor://orchestrator/execute/transform"},
          {agent.agent_id, "arbor://orchestrator/execute/unknown"}
        ] do
      assert {:ok, cap} = Security.grant(principal: principal, resource: resource)
      on_exit(fn -> Security.revoke(cap.id) end)
    end

    %{agent: agent, human: human}
  end

  defp new_agent! do
    assert {:ok, agent} = Identity.generate()
    assert :ok = Security.register_identity(Identity.public_only(agent))
    on_exit(fn -> Security.deregister_identity(agent.agent_id) end)
    agent
  end

  defp new_human! do
    fixture = Arbor.Security.OIDCTestHelper.issue_identity()

    assert :ok =
             Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)

    on_exit(fn ->
      fixture.cleanup.()
      Security.deregister_identity(fixture.identity.agent_id)
    end)

    fixture.identity
  end

  defp replace_engagement!(owner) do
    {:ok, previous} =
      Arbor.Comms.resolve_user_engagement(owner.agent.agent_id, owner.human.agent_id)

    :ok = Arbor.Comms.EngagementStore.delete(previous.id)
    id = "eng_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    assert {:ok, engagement} =
             Arbor.Comms.EngagementStore.resolve_or_create(
               owner.agent.agent_id,
               owner.human.agent_id,
               id: id,
               scope: :user,
               visibility: :private,
               owner_tenant: owner.human.agent_id
             )

    assert {:ok, ^engagement} =
             Arbor.Comms.resolve_user_engagement(owner.agent.agent_id, owner.human.agent_id)

    engagement
  end

  defp restart_root! do
    assert :ok =
             Supervisor.terminate_child(Arbor.Security.Supervisor, Arbor.Security.SystemAuthority)

    assert {:ok, _} =
             Supervisor.restart_child(Arbor.Security.Supervisor, Arbor.Security.SystemAuthority)
  end

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

  defp embedding_endpoint! do
    observer = self()
    {:ok, state} = Agent.start_link(fn -> %{fail_content: nil, hold_sources: false} end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    server = spawn_link(fn -> accept_embedding(listener, state, observer) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    %{url: "http://127.0.0.1:#{port}/v1", state: state}
  end

  defp accept_embedding(listener, state, observer) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve_embedding(socket, state, observer)
        :gen_tcp.close(socket)
        accept_embedding(listener, state, observer)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve_embedding(socket, state, observer) do
    body = read_http(socket, "")
    request = Jason.decode!(body)
    texts = List.wrap(request["input"])
    send(observer, {:embedding_request, texts})

    if Agent.get(state, & &1.hold_sources) and
         Enum.any?(texts, &String.starts_with?(&1, "User: ")) do
      send(observer, {:embedding_held, self()})

      receive do
        {:release_embedding, releasing_test} -> send(releasing_test, :embedding_released)
      after
        10_000 -> raise "held embedding fixture was not released"
      end
    end

    failure = Agent.get(state, & &1.fail_content)

    if failure && Enum.any?(texts, &String.contains?(&1, failure)) do
      send_json(socket, 400, %{"error" => %{"message" => "fixture embedding unavailable"}})
    else
      data =
        Enum.with_index(texts, fn _text, index ->
          %{"index" => index, "embedding" => [1.0 | List.duplicate(0.0, 767)]}
        end)

      send_json(socket, 200, %{
        "model" => "private-journey-embedding",
        "data" => data,
        "usage" => %{"prompt_tokens" => length(texts), "total_tokens" => length(texts)}
      })
    end
  end

  defp read_http(socket, buffer) when byte_size(buffer) < 1_000_000 do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        remaining = String.to_integer(length) - byte_size(body)

        if remaining > 0 do
          {:ok, rest} = :gen_tcp.recv(socket, remaining, 5_000)
          body <> rest
        else
          body
        end

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        read_http(socket, buffer <> chunk)
    end
  end

  defp send_json(socket, status, value) do
    body = Jason.encode!(value)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Fixture\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end

  defp drain_embeddings(acc \\ []) do
    receive do
      {:embedding_request, texts} -> drain_embeddings([texts | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
