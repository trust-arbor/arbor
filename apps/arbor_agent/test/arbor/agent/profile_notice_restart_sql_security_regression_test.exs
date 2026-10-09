defmodule Arbor.Agent.ProfileNoticeRestartSQLSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :security_regression
  alias Arbor.Agent.{Character, Profile, ProfileStore}
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security

  defmodule Repo do
    use Ecto.Repo, otp_app: :arbor_agent, adapter: Ecto.Adapters.SQLite3
  end

  # Trusted protocol source fixture reads the real backend-confirmed Profile;
  # no claim of actual BranchSupervisor, notice SQL or UI acceptance. The same
  # test bytes select the prior authoritative read on a predecessor without the
  # new serialized notice snapshot API; both enforce the same expected denial.
  defmodule Source do
    @behaviour Arbor.Security.Contracts.NativeNoticeSourceAuthorizer
    def acquire(principal, owner) do
      function =
        if function_exported?(ProfileStore, :notice_authority_snapshot, 1),
          do: :notice_authority_snapshot,
          else: :authority_mutation_snapshot

      with {:ok, record} <- apply(ProfileStore, function, [principal]),
           [mailbox] <- record.data["notice_mailboxes"] do
        {:ok,
         %{
           principal_id: principal,
           owner_pid: owner,
           branch_pid: owner,
           role: :session,
           mailboxes: [mailbox]
         }}
      else
        _ -> {:error, :native_notice_source_required}
      end
    end

    def recheck(source, mailbox, _),
      do: if(mailbox in source.mailboxes, do: :ok, else: {:error, :unauthorized})
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "profile_notice_sql_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    start_supervised!(
      {Repo,
       database: Path.join(dir, "profile.sqlite3"),
       pool_size: 1,
       journal_mode: :wal,
       busy_timeout: 5_000,
       log: false}
    )

    path = Path.expand("../../../../arbor_persistence/priv/repo/migrations", __DIR__)

    for {file, version, module} <- [
          {"20260130000001_create_records.exs", 20_260_130_000_001,
           Arbor.Persistence.Repo.Migrations.CreateRecords},
          {"20260625000001_records_single_unique_identity.exs", 20_260_625_000_001,
           Arbor.Persistence.Repo.Migrations.RecordsSingleUniqueIdentity},
          {"20260713000001_add_records_revision.exs", 20_260_713_000_001,
           Arbor.Persistence.Repo.Migrations.AddRecordsRevision},
          {"20260713000002_records_generation_and_namespace_key_identity.exs", 20_260_713_000_002,
           Arbor.Persistence.Repo.Migrations.RecordsGenerationAndNamespaceKeyIdentity}
        ] do
      Code.require_file(Path.join(path, file))
      assert :ok = Ecto.Migrator.up(Repo, version, module, log: false)
    end

    start_supervised!(
      {BufferedStore,
       name: :arbor_agent_profiles,
       collection: :agent_profiles,
       backend: Arbor.Persistence.QueryableStore.Postgres,
       backend_opts: [repo: Repo],
       write_mode: :sync,
       ack_mode: :backend}
    )

    old = Application.fetch_env(:arbor_security, :native_notice_source_authorizer)
    Application.put_env(:arbor_security, :native_notice_source_authorizer, Source)
    old_legacy = Application.fetch_env(:arbor_agent, :legacy_agents_dir)
    Application.put_env(:arbor_agent, :legacy_agents_dir, dir)

    on_exit(fn ->
      case old do
        {:ok, value} ->
          Application.put_env(:arbor_security, :native_notice_source_authorizer, value)

        :error ->
          Application.delete_env(:arbor_security, :native_notice_source_authorizer)
      end

      case old_legacy do
        {:ok, value} -> Application.put_env(:arbor_agent, :legacy_agents_dir, value)
        :error -> Application.delete_env(:arbor_agent, :legacy_agents_dir)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "security regression: broker restart cannot borrow prewrite SQL mailbox authority" do
    {:ok, identity} = Identity.generate(name: "profile-notice-sql")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))
    :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    mailbox = %{
      "mailbox_id" => "owner",
      "recipient_subject_id" => "human_notice_sql",
      "owner_id" => "human_notice_sql",
      "engagement_id" => "eng_" <> String.duplicate("a", 32)
    }

    profile = %Profile{
      agent_id: identity.agent_id,
      display_name: "SQL witness",
      character: Character.new(name: "SQL witness"),
      notice_mailboxes: [mailbox],
      created_at: DateTime.utc_now(),
      version: 1
    }

    assert :ok = Arbor.Agent.store_profile(profile)
    assert {:ok, old_record} = ProfileStore.authority_mutation_snapshot(identity.agent_id)
    assert {:ok, _old_source} = source(identity)
    broker = Process.whereis(Arbor.Security.NativeNoticeBroker)
    :ok = :sys.suspend(broker)

    # A failed observation must not leave the broker suspended for the next test.
    on_exit(fn ->
      if is_pid(broker) and Process.alive?(broker), do: :sys.resume(broker)
    end)

    writer = Task.async(fn -> Arbor.Agent.store_profile(%{profile | notice_mailboxes: []}) end)

    mutation_owner =
      if function_exported?(ProfileStore, :notice_authority_snapshot, 1),
        do: Process.whereis(Arbor.Agent.ProfileAuthorityOwner),
        else: writer.pid

    wait_for_call(mutation_owner)
    true = :erlang.suspend_process(writer.pid)

    try do
      :ok = :sys.resume(broker)
      # FIFO public barrier behind begin retirement; no private state mutation.
      assert {:error, :native_notice_source_required} =
               Security.native_notice_action_resource(%{})

      assert :ok =
               Supervisor.terminate_child(
                 Arbor.Security.Supervisor,
                 Arbor.Security.NativeNoticeBroker
               )

      assert {:ok, successor_broker} =
               Supervisor.restart_child(
                 Arbor.Security.Supervisor,
                 Arbor.Security.NativeNoticeBroker
               )

      assert successor_broker != broker
      # Caller continuation is still held. The fixed owner has completed or
      # owns the pending write; a new source cannot pin the old SQL Record.
      probe = Task.async(fn -> source(identity) end)
      probe_result = Task.await(probe, 2_000)
      true = :erlang.resume_process(writer.pid)
      assert :ok = Task.await(writer, 2_000)
      assert {:ok, revoked} = ProfileStore.authority_mutation_snapshot(identity.agent_id)
      assert revoked.data["notice_mailboxes"] == []
      assert revoked.revision > old_record.revision
      assert {:error, :native_notice_source_required} = probe_result
    after
      if Process.alive?(broker), do: :sys.resume(broker)

      if Process.alive?(writer.pid) do
        try do
          :erlang.resume_process(writer.pid)
        rescue
          ArgumentError -> :ok
        end
      end

      Security.delete_signing_key_fixture(identity.agent_id)
      Security.deregister_identity_fixture(identity.agent_id)
    end
  end

  test "security regression: lazy legacy migration cannot replace newer SQL mailbox revocation",
       c do
    raced_migration(:lazy, c.dir)
  end

  test "security regression: bulk legacy migration cannot replace newer SQL mailbox revocation",
       c do
    raced_migration(:bulk, c.dir)
  end

  defp raced_migration(mode, dir) do
    principal = "agent_notice_legacy_#{mode}"

    legacy = %Profile{
      agent_id: principal,
      display_name: "Stale legacy",
      character: Character.new(name: "Legacy"),
      created_at: DateTime.utc_now(),
      version: 1,
      notice_mailboxes: [
        %{
          "mailbox_id" => "owner",
          "recipient_subject_id" => "human_notice_sql",
          "owner_id" => "human_notice_sql",
          "engagement_id" => "eng_" <> String.duplicate("a", 32)
        }
      ]
    }

    current = %{legacy | display_name: "Current durable", notice_mailboxes: []}
    path = Path.join(dir, principal <> ".agent.json")
    File.write!(path, Profile.to_json(legacy) |> elem(1))
    # The cache still proves absence while a newer public write is queued.
    # Candidate serializes on its lane; predecessor queues at BufferedStore.
    owner =
      if function_exported?(ProfileStore, :notice_authority_snapshot, 1),
        do: Process.whereis(Arbor.Agent.ProfileAuthorityOwner),
        else: Process.whereis(:arbor_agent_profiles)

    :ok = :sys.suspend(owner)
    writer = Task.async(fn -> Arbor.Agent.store_profile(current) end)
    wait_for_call(writer.pid)

    migrator =
      Task.async(fn ->
        case mode do
          :lazy -> Arbor.Agent.load_profile(principal)
          :bulk -> ProfileStore.migrate_json_profiles()
        end
      end)

    try do
      wait_for_call(migrator.pid)
      :ok = :sys.resume(owner)
      assert :ok = Task.await(writer, 2_000)
      result = Task.await(migrator, 2_000)
      assert {:ok, stored} = ProfileStore.authority_mutation_snapshot(principal)
      assert stored.data["notice_mailboxes"] == []
      assert stored.data["display_name"] == "Current durable"

      case mode do
        :lazy ->
          assert {:ok, loaded} = result
          assert loaded.display_name == "Current durable"
          assert loaded.notice_mailboxes == []

        :bulk ->
          assert {:ok, 0} = result
      end

      # Existing durable state is preserved, never replaced by legacy facts.
      assert File.exists?(path)
    after
      :sys.resume(owner)
    end
  end

  defp source(identity) do
    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    Security.open_native_notice_source(authority)
  end

  defp wait_for_call(pid, count \\ 100)
  defp wait_for_call(_, 0), do: flunk("owned mutation did not reach the suspended broker")

  defp wait_for_call(pid, count) do
    # Profile writes reach NativeNoticeBroker through AuthenticatedCall, which
    # waits in its own receive. GenServer.call still shows :gen.do_call.
    case Process.info(pid, :current_function) do
      {:current_function, {:gen, :do_call, _}} ->
        :ok

      {:current_function, {Arbor.Common.AuthenticatedCall, fun, arity}}
      when fun in [:call, :await_challenge, :await_reply] and arity in [3, 4] ->
        :ok

      _ ->
        Process.sleep(2)
        wait_for_call(pid, count - 1)
    end
  end
end
