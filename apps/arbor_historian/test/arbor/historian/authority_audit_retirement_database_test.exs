defmodule Arbor.Historian.AuthorityAuditRetirementDatabaseTest do
  @moduledoc """
  Real-SQL-sink lanes for Security audit terminal-identity retirement
  (Floor-and-Ledger v3, slice 4c/4d).

  Each test swaps a durable `:operational` AuditJournalOwner in as the
  registered Security journal, points Historian's durable EventLog target at
  a private, fully migrated SQLite database (never the shared
  `~/.arbor/arbor_test.db`: these lanes commit thousands of rows and must not
  hold that file's write lock), and runs the real AuthorityAuditPuller
  (content readback, then exact acknowledgement) through the public
  `Security.grant/revoke` and `Historian.flush_authority_audit/0` boundary.
  Every EventLog write is a real committed SQL transaction.

  The sustained lane is the exact-parent security regression: on 52a2cc3fa
  delivered identities stay retained, so grant 1537 (identity 3073) is refused
  `:audit_unavailable` by the retained-increase cap. The target-replacement
  lane pins retirement-era behavior (fails on the parent because nothing is
  retired and the puller reports nothing).
  """
  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :integration
  @moduletag timeout: 1_800_000

  import ExUnit.CaptureLog

  alias Arbor.Common.SafePath
  alias Arbor.Historian
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.Contracts.AuditJournal

  @target_name :historian_durable_event_log
  @conflict_event [:arbor, :historian, :authority_audit, :conflict]
  @retired_event [:arbor, :security, :audit_journal, :retired]

  defmodule TemplateRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :arbor_historian, adapter: Ecto.Adapters.SQLite3
  end

  defmodule SinkRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :arbor_historian, adapter: Ecto.Adapters.SQLite3
  end

  defmodule FreshSinkRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :arbor_historian, adapter: Ecto.Adapters.SQLite3
  end

  # One fully migrated template database per module run; each test copies it,
  # so the migrations are compiled and run once. The template is already in
  # WAL mode (persistent in the file header), so a copy's pooled connections
  # never race to switch journal modes at connect.
  setup_all do
    dir = unique_dir("historian-retire-sql")
    template = Path.join(dir, "template.sqlite3")

    {:ok, repo} =
      TemplateRepo.start_link(
        database: template,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        journal_mode: :wal,
        log: false
      )

    migrations = Application.app_dir(:arbor_persistence, "priv/repo/migrations")
    _ = Ecto.Migrator.run(TemplateRepo, migrations, :up, all: true, log: false)
    _ = TemplateRepo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
    :ok = Supervisor.stop(repo)
    on_exit(fn -> File.rm_rf(dir) end)
    %{template: template}
  end

  setup ctx do
    :ok = Security.TestBootstrap.start!()
    root = unique_dir("historian-retire-journal")
    original = Process.whereis(AuditJournalOwner)
    true = Process.unregister(AuditJournalOwner)

    {:ok, journal} =
      AuditJournalOwner.start_link(mode: :durable, root: root, capacity_profile: :operational)

    Process.unlink(journal)
    old_target = Application.fetch_env(:arbor_historian, :durable_event_log_target)
    start_sink!(SinkRepo, ctx.template)
    use_sink(SinkRepo)
    principal = "agent_retire_sql_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = Process.whereis(AuditJournalOwner), do: GenServer.stop(pid)
      true = Process.register(original, AuditJournalOwner)

      case old_target do
        {:ok, value} -> Application.put_env(:arbor_historian, :durable_event_log_target, value)
        :error -> Application.delete_env(:arbor_historian, :durable_event_log_target)
      end

      File.rm_rf(root)
    end)

    start_supervised!({Arbor.Historian.AuthorityAuditPuller, poll_interval_ms: 60_000})
    %{principal: principal, root: root, template: ctx.template}
  end

  @tag :slow
  test "security regression: 2300 public grant/revoke pairs drain through real SQL acknowledgement past 4096 identities",
       ctx do
    handler = "authority-audit-retire-sql-retired-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @retired_event,
        fn _event, measurements, metadata, pid ->
          send(pid, {:retired, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    started = System.monotonic_time(:millisecond)
    {:ok, before_audit} = Security.capability_mutation_audit_status()

    max_retained =
      1..2300
      |> Enum.chunk_every(50)
      |> Enum.reduce(0, fn pairs, max_retained ->
        Enum.each(pairs, &grant_and_revoke!(ctx.principal, &1))
        delivered = 2 * length(pairs)

        assert {:ok, %{delivered: ^delivered, pending: 0}} =
                 Historian.flush_authority_audit()

        {:ok, status} = Security.audit_journal_status()
        retained = status["capacity"]["retained_operation_count"]
        assert retained < 4096
        max(max_retained, retained)
      end)

    assert max_retained < 4096
    elapsed = System.monotonic_time(:millisecond) - started
    publications = retired_publications()
    durations = publications |> Enum.map(fn {m, _meta} -> m.duration_ms end) |> Enum.sort()

    IO.puts(
      "\n[audit retirement real SQL sink] identities=4600 elapsed_ms=#{elapsed} " <>
        "publications=#{length(publications)} publication_ms=#{inspect(durations)}"
    )

    assert length(publications) == 8

    assert Enum.all?(publications, fn {m, meta} ->
             m.count == 512 and meta.trigger == :acknowledge and m.duration_ms < 5_000
           end)

    {:ok, after_audit} = Security.capability_mutation_audit_status()
    assert after_audit[:degraded_reductions] == before_audit[:degraded_reductions]

    # Every identity landed exactly once as committed SQL content.
    assert row_count(SinkRepo) == 4600
    assert distinct_stream_count(SinkRepo) == 4600

    {:ok, status} = Security.audit_journal_status()
    assert status["pending_count"] == 0
    assert status["last_refusal"] == "none"
    assert status["capacity"]["retired_operation_total"] == 8 * 512
    assert status["capacity"]["retained_operation_count"] == 4600 - 8 * 512
    assert status["retirement"]["floor"] == 3
    assert status["retirement"]["ledger_state"] == "bound"
    assert status["retirement"]["ledger_frames"] == 8
    assert status["admission_open"] == true
    assert {:ok, %{delivered: 0, pending: 0}} = Historian.flush_authority_audit()
  end

  @tag capture_log: true
  test "retired identities survive stream deletion and target replacement; a conflicting row pins only its own operation",
       ctx do
    handler = attach_conflict_telemetry()
    on_exit(fn -> :telemetry.detach(handler) end)

    # G: an exact-facts grant that stays live, delivered, then retired with
    # the first T2 publication (512 delivered identities).
    g_opts = exact_grant_opts(ctx.principal, "retired-g")
    assert {:ok, :applied, g_id} = Security.acknowledged_grant(g_opts)

    assert {:ok, [%{"operation_id" => g_op, "status" => "effect_applied"}]} =
             Security.audit_journal_pending_operations()

    for n <- 1..255, do: grant_and_revoke!(ctx.principal, n)
    assert {:ok, _h} = grant(ctx.principal, "live-h")
    assert {:ok, %{delivered: 512, pending: 0}} = Historian.flush_authority_audit()

    {:ok, retired} = Security.audit_journal_status()
    assert retired["capacity"]["retired_operation_total"] == 512
    assert retired["capacity"]["retained_operation_count"] == 0
    assert retired["retirement"]["floor"] == 3

    g_stream = stream(g_op)
    assert {:ok, [g_event]} = read(SinkRepo, g_stream)
    assert g_event.data["intent"]["audit"]["data"]["capability_id"] == g_id
    v2_twin = legacy_twin(g_event.data["intent"])
    assert {:error, :retired_version} = AuditJournalOwner.append(prepared_record(v2_twin))

    # Historian forgets G's stream. The journal never consults Historian:
    # G's v2 twin is still below the floor, and re-presenting G's exact live
    # facts short-circuits at the store without reaching the journal.
    assert :ok = Historian.delete_stream_content(g_stream)
    assert {:ok, true} = Historian.stream_content_absent?(g_stream)
    assert {:error, :retired_version} = AuditJournalOwner.append(prepared_record(v2_twin))
    assert {:ok, :idempotent, ^g_id} = Security.acknowledged_grant(g_opts)
    assert {:ok, []} = Security.audit_journal_pending_operations()
    assert {:ok, %{delivered: 0, pending: 0}} = Historian.flush_authority_audit()
    assert {:ok, true} = Historian.stream_content_absent?(g_stream)
    {:ok, unchanged} = Security.audit_journal_status()

    assert Map.delete(unchanged, "oldest_pending_age_seconds") ==
             Map.delete(retired, "oldest_pending_age_seconds")

    # K: a new operation whose stream already holds different content stays
    # effect_applied, is never retired, and is reported once.
    assert {:ok, _k} = grant(ctx.principal, "conflict-k")
    assert {:ok, [%{"operation_id" => k_op}]} = Security.audit_journal_pending_operations()
    bad = Event.new(stream(k_op), "capability_granted", %{"wrong" => "body"}, id: k_op)

    assert {:ok, [_]} =
             Persistence.append(@target_name, EctoEventLog, stream(k_op), bad, repo: SinkRepo)

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 0, pending: 1}} = Historian.flush_authority_audit()
      end)

    assert log =~ "#{k_op} (audit_content_conflict, event_log)"
    assert conflicts() == [{k_op, :audit_content_conflict, :event_log}]

    log =
      capture_log(fn ->
        assert {:ok, %{delivered: 0, pending: 1}} = Historian.flush_authority_audit()
      end)

    refute log =~ "stuck"
    assert conflicts() == []

    assert {:ok, [%{"operation_id" => ^k_op, "status" => "effect_applied"}]} =
             Security.audit_journal_pending_operations()

    # A fresh durable target: new operations deliver there, retired ones are
    # never redelivered, and the stuck operation converges.
    start_sink!(FreshSinkRepo, ctx.template)
    use_sink(FreshSinkRepo)
    assert {:ok, %{delivered: 1, pending: 0}} = Historian.flush_authority_audit()
    assert {:ok, _l} = grant(ctx.principal, "fresh-l")
    assert {:ok, %{delivered: 1, pending: 0}} = Historian.flush_authority_audit()
    assert row_count(FreshSinkRepo) == 2
    assert {:ok, [k_event]} = read(FreshSinkRepo, stream(k_op))
    assert k_event.data["effect"] == "applied"
    assert {:ok, []} = read(FreshSinkRepo, g_stream)

    {:ok, final} = Security.audit_journal_status()
    assert final["pending_count"] == 0
    assert final["capacity"]["retired_operation_total"] == 512
    assert final["capacity"]["retained_operation_count"] == 2
    assert {:error, :retired_version} = AuditJournalOwner.append(prepared_record(v2_twin))
  end

  # ---------------------------------------------------------------------------

  defp grant_and_revoke!(principal, n) do
    case grant(principal, "pair-#{n}") do
      {:ok, cap} ->
        case Security.revoke(cap.id) do
          :ok ->
            {:ok, audit} = Security.capability_mutation_audit_status()

            unless audit.audit == :recorded,
              do: flunk("pair #{n} (identity #{2 * n}) revoke audit #{inspect(audit)}")

          other ->
            flunk("pair #{n} (identity #{2 * n}) revoke: #{inspect(other)}")
        end

      other ->
        flunk("pair #{n} (identity #{2 * n - 1}) grant: #{inspect(other)}")
    end
  end

  defp grant(principal, suffix),
    do: Security.grant(principal: principal, resource: "arbor://memory/read/retire-sql/#{suffix}")

  defp exact_grant_opts(principal, suffix) do
    [
      capability_id: "cap_" <> Base.encode16(:erlang.md5("#{principal}-#{suffix}"), case: :lower),
      granted_at: ~U[2026-09-28 12:00:00Z],
      principal: principal,
      resource: "arbor://memory/read/retire-sql/#{suffix}"
    ]
  end

  # The v2 intent of the same facts as a delivered v3 intent (the identity a
  # pre-cutover producer would have minted).
  defp legacy_twin(intent) do
    {:ok, v2} =
      intent
      |> Map.delete("operation_id")
      |> Map.merge(%{"version" => 2, "kind" => "arbor.security.authority_mutation_intent.v2"})
      |> AuditJournal.admit_intent()

    v2
  end

  defp prepared_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp start_sink!(repo, template) do
    dir = unique_dir("historian-retire-sink")
    database = Path.join(dir, "sink.sqlite3")
    File.cp!(template, database)

    start_supervised!(
      {repo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal,
       log: false}
    )
  end

  defp use_sink(repo) do
    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: @target_name,
      backend: EctoEventLog,
      opts: [repo: repo]
    })
  end

  defp read(repo, stream),
    do: Persistence.read_stream(@target_name, EctoEventLog, stream, repo: repo)

  defp row_count(repo) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT count(*) FROM events WHERE stream_id LIKE 'security:authority_mutation:%'"
      )

    count
  end

  defp distinct_stream_count(repo) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT count(DISTINCT stream_id) FROM events " <>
          "WHERE stream_id LIKE 'security:authority_mutation:%'"
      )

    count
  end

  defp stream(id), do: "security:authority_mutation:" <> id

  defp attach_conflict_telemetry do
    handler = "authority-audit-retire-sql-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @conflict_event,
        fn _event, _measurements, metadata, pid -> send(pid, {:conflict, metadata}) end,
        test_pid
      )

    handler
  end

  defp retired_publications(acc \\ []) do
    receive do
      {:retired, measurements, metadata} -> retired_publications([{measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp conflicts(acc \\ []) do
    receive do
      {:conflict, %{operation_id: id, reason: reason, source: source}} ->
        conflicts([{id, reason, source} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp unique_dir(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, real} = SafePath.resolve_real(dir)
    File.chmod!(real, 0o700)
    on_exit(fn -> File.rm_rf(real) end)
    real
  end
end
