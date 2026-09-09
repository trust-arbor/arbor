Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Memory.PrivateConversationSQLiteTest do
  @moduledoc """
  Standalone private Memory assembly proof with genuine human receipts, the
  persisted Security root and the production strict SQLite vector backend.
  Closes/reopens the Repo and root store from private files; this is a process
  and storage reopen proof, not whole-BEAM, node or host recovery.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Memory
  alias Arbor.Persistence.Repo
  alias Arbor.Security

  @moduletag :isolated_repo
  @moduletag :database
  @moduletag :sqlite
  @moduletag :integration
  @migrations_path Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  if Repo.__adapter__() != Ecto.Adapters.SQLite3 do
    @moduletag skip: "requires the compiled SQLite Repo adapter"
  end

  defmodule NoEmbeddingProvider do
    def embed(_text), do: {:error, :unexpected_embedding_provider_call}
  end

  setup do
    assert GenServer.whereis(Repo) == nil,
           "run the private Memory SQLite proof standalone, with no existing Repo"

    root =
      Path.join(
        System.tmp_dir!(),
        "arbor_private_memory_sqlite_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    settings = [
      {:arbor_memory, :strict_vector_seam, Arbor.Memory.StrictVectorSeam.Default},
      {:arbor_memory, :private_memory_security, Security},
      {:arbor_persistence, :vector_store_backend, Arbor.Persistence.VectorStore.Ecto},
      {:arbor_persistence, :vector_store_repo, Repo},
      {:arbor_security, :identity_verification, true},
      {:arbor_security, :system_authority_mode, :persistent},
      {:arbor_security, :master_key_path, Path.join(root, "master.key")}
    ]

    previous =
      Enum.map(settings, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      stop_root!()
      stop_root_store!()
      Enum.each(previous, &restore_env/1)
      :ok = Arbor.Security.TestBootstrap.restore_supervised_tree!()
      File.rm_rf!(root)
    end)

    # Fixture lifecycle only: replace the test bootstrap's ephemeral signing
    # store with an owned JSONFile store, then start the real persisted root.
    stop_root!()
    stop_root_store!()
    start_root_store!(root)
    start_root!()

    repo_opts = [
      database: Path.join(root, "vectors.sqlite3"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 5_000,
      journal_mode: :wal
    ]

    start_supervised!({Repo, repo_opts})
    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, log: false)

    %{root: root, repo_opts: repo_opts}
  end

  test "private records survive SQLite and root reopen only for a fresh admission to the same owner pair",
       ctx do
    owner = pair()
    other_human = pair(owner.agent_id)
    other_agent = pair(nil, owner.human)
    admission = admit!(owner, "engagement-before-reopen")
    content = "The private conversation marker is OPAL-73"

    assert {:ok, private_id} =
             Memory.index_private_conversation(admission, content, embedding(),
               source_id: "committed-source-one"
             )

    assert {:ok, [%{id: ^private_id, content: ^content, provenance_status: :verified}]} =
             Memory.recall_private_conversations(admission, embedding(), threshold: 0.9)

    assert {:ok, ordinary_id} =
             Memory.store_embedding(owner.agent_id, "ordinary public control", vector(), %{
               type: :fact
             })

    start_general_index!(owner.agent_id)
    assert_general_control(owner.agent_id, ordinary_id, private_id)
    assert :ok = Memory.cleanup_for_agent(owner.agent_id)
    refute Memory.index_running?(owner.agent_id)

    # A live, previously successful admission cannot turn an unavailable real
    # store into empty success. Close it before replacing the root and Repo.
    assert :ok = stop_supervised(Repo)

    assert {:error, :backend_failure} =
             Memory.recall_private_conversations(admission, embedding(), [])

    assert :ok = Security.close_private_memory_admission(admission)

    assert {:error, :invalid_memory_admission} =
             Memory.recall_private_conversations(admission, embedding(), [])

    stop_root!()
    stop_root_store!()
    start_supervised!({Repo, ctx.repo_opts})
    start_root_store!(ctx.root)
    start_root!()

    fresh = admit!(owner, "engagement-after-reopen")

    assert {:ok, [%{id: ^private_id, content: ^content, provenance_status: :verified} = recalled]} =
             Memory.recall_private_conversations(fresh, embedding(), threshold: 0.9)

    assert_in_delta recalled.similarity, 1.0, 0.000001

    # The stable source remains idempotent after both stores reopen and a new
    # turn supplies the admission; the original private row is not duplicated.
    assert {:ok, ^private_id} =
             Memory.index_private_conversation(fresh, content, embedding(),
               source_id: "committed-source-one"
             )

    assert {:ok, [_one_record]} = Memory.recall_private_conversations(fresh, embedding(), [])

    for foreign_pair <- [other_human, other_agent] do
      foreign_admission = admit!(foreign_pair, "engagement-foreign")
      assert {:ok, []} = Memory.recall_private_conversations(foreign_admission, embedding(), [])
      assert :ok = Security.close_private_memory_admission(foreign_admission)
    end

    start_general_index!(owner.agent_id)
    assert_general_control(owner.agent_id, ordinary_id, private_id)
    assert :ok = Security.close_private_memory_admission(fresh)
    assert :ok = Memory.cleanup_for_agent(owner.agent_id)
  end

  defp start_general_index!(agent_id) do
    assert {:ok, pid} =
             Memory.init_for_agent(agent_id,
               backend: :dual,
               graph_enabled: false,
               embedding_provider: NoEmbeddingProvider
             )

    assert is_pid(pid)
    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)
  end

  defp assert_general_control(agent_id, ordinary_id, private_id) do
    assert {:ok, %{entry_count: 1}} = Memory.index_stats(agent_id)

    assert {:ok, results} =
             Memory.recall(agent_id, "ordinary public control",
               embedding: vector(),
               threshold: 0.9
             )

    assert Enum.any?(results, &(&1.id == ordinary_id and &1.content == "ordinary public control"))
    refute Enum.any?(results, &(&1.id == private_id or &1.content =~ "OPAL-73"))
  end

  defp pair(agent_id \\ nil, human \\ nil) do
    agent_id = agent_id || new_agent!()
    human = human || new_human!()
    grant!(agent_id, "arbor://memory/read/" <> agent_id)
    grant!(agent_id, "arbor://memory/write/" <> agent_id)
    grant!(human.agent_id, "arbor://chat/agent/" <> agent_id)
    %{agent_id: agent_id, human: human}
  end

  defp new_agent! do
    assert {:ok, identity} = Identity.generate()
    assert :ok = Security.register_identity(Identity.public_only(identity))
    on_exit(fn -> Security.deregister_identity(identity.agent_id) end)
    identity.agent_id
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

  defp grant!(principal, resource) do
    assert {:ok, capability} = Security.grant(principal: principal, resource: resource)
    on_exit(fn -> Security.revoke(capability.id) end)
  end

  defp admit!(owner, engagement) do
    resource = "arbor://chat/agent/" <> owner.agent_id

    assert {:ok, signed} =
             SignedRequest.sign(resource, owner.human.agent_id, owner.human.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(owner.human.agent_id, resource, :chat,
               signed_request: signed,
               expected_resource: resource
             )

    assert {:ok, admission} =
             Security.exchange_private_memory_receipt(
               receipt,
               owner.agent_id,
               owner.human.agent_id,
               %{
                 session_id: "session-#{engagement}",
                 turn_id: "turn-#{System.unique_integer([:positive])}"
               }
             )

    assert :ok = Security.activate_private_memory_admission(admission, engagement)
    admission
  end

  defp embedding do
    %{embedding: vector(), provider: "local", model: "private-sqlite-test", dimensions: 768}
  end

  defp vector, do: [1.0 | List.duplicate(0.0, 767)]

  defp stop_root! do
    assert :ok =
             Supervisor.terminate_child(Arbor.Security.Supervisor, Arbor.Security.SystemAuthority)
  end

  defp start_root! do
    assert {:ok, _pid} =
             Supervisor.restart_child(Arbor.Security.Supervisor, Arbor.Security.SystemAuthority)
  end

  defp start_root_store!(root) do
    assert {:ok, pid} =
             Arbor.Security.AuthorityStore.start_link(
               name: :arbor_security_signing_keys,
               backend: Arbor.Security.Store.JSONFile,
               backend_opts: [base_dir: Path.join(root, "signing-store")],
               namespace: "signing_keys",
               hydration_limit: 100
             )

    Process.unlink(pid)
  end

  defp stop_root_store! do
    for operation <- [:terminate_child, :delete_child] do
      case apply(Supervisor, operation, [Arbor.Security.Supervisor, :arbor_security_signing_keys]) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    if pid = Process.whereis(:arbor_security_signing_keys), do: GenServer.stop(pid)
  end

  defp restore_env({app, key, {:ok, value}}), do: Application.put_env(app, key, value)
  defp restore_env({app, key, :error}), do: Application.delete_env(app, key)
end
