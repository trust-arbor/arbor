defmodule Arbor.Historian.AuthorityAuditRetirementPeerRestartTest do
  @moduledoc """
  Whole-BEAM restart over a real SQL sink for Security audit terminal-identity
  retirement (Floor-and-Ledger v3, slice 4b, required).

  Each phase is a fresh OS BEAM (`:peer`) that boots the umbrella's test
  configuration with production-shaped durable state under private temporary
  paths: a JSONFile authority store and a durable `:operational` audit journal
  under one realpath authority root (Application/TestBootstrap-selected, the
  same way a node selects them), a persistent system-authority key,
  `Arbor.Persistence.Repo` on a private SQLite file (never the shared test
  database), migrated in the peer, and the real `AuthorityAuditPuller` whose
  durable target is that Repo.

  - Peer A drives more than 600 public `Security.grant/revoke` lifecycles
    (flushing between batches) so the first T2 retiring publication retires
    512 delivered identities, then halts.
  - Peer B reopens the same root and SQLite file: identical journal status
    except wall-clock fields, floor 3, the bound ledger; a flush redelivers
    nothing; a raw v2 prepared of a retired identity's facts is refused
    `:retired_version`; a new grant admits and delivers.
  - Peer C runs after a same-UID rollback of the capability namespace
    directory to a copy taken before one exact grant G (F14): re-issuing G's
    identical facts is admitted as a new operation with G's retired identity
    (accepted residual H4), stays `effect_applied` because the committed
    event carries G's original prepare time, is reported by the puller, and
    leaves every retired identity untouched.

  New behavior: on 52a2cc3fa nothing is retired (and the puller is silent), so
  the retirement assertions fail there.
  """
  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 900_000

  alias Arbor.Common.SafePath
  alias Arbor.Security.Contracts.AuditJournal

  driver =
    defmodule PeerDriver do
      @moduledoc false
      # Shipped to the peers as object code; runs only lib modules there.
      alias Arbor.Historian
      alias Arbor.Historian.Config, as: HistorianConfig
      alias Arbor.Persistence
      alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
      alias Arbor.Persistence.Repo
      alias Arbor.Security
      alias Arbor.Security.AuditJournalOwner

      @target_name :historian_durable_event_log
      @conflict_event [:arbor, :historian, :authority_audit, :conflict]

      def boot(%{umbrella: umbrella, db: db, root: root, keys: keys, collector: collector}) do
        # Nothing may reach the control channel before the forwarder is up.
        :ok = :logger.set_primary_config(:level, :none)

        umbrella
        |> Path.join("config/config.exs")
        |> Config.Reader.read!(env: :test, target: :host)
        |> Application.put_all_env(persistent: true)

        put_all(:arbor_security,
          authority_state_root: root,
          storage_backend: Arbor.Security.Store.JSONFile,
          audit_journal_mode: :durable,
          system_authority_mode: :persistent,
          master_key_path: Path.join(keys, "master.key")
        )

        put_all(:arbor_persistence, [
          {Repo,
           database: db,
           pool: DBConnection.ConnectionPool,
           pool_size: 4,
           busy_timeout: 5_000,
           journal_mode: :wal,
           log: false}
        ])

        put_all(:arbor_historian,
          durable_event_log_target: %{
            name: @target_name,
            backend: EctoEventLog,
            opts: [repo: Repo]
          }
        )

        {:ok, _} = Application.ensure_all_started(:arbor_historian)
        install_log_forwarder(collector)
        true = Repo.__adapter__() == Ecto.Adapters.SQLite3
        {:ok, _} = Supervisor.start_child(Arbor.Persistence.Supervisor, Repo)
        migrations = Path.join(umbrella, "apps/arbor_persistence/priv/repo/migrations")
        _ = Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
        :ok = Security.TestBootstrap.start!()

        for child <- [
              {Arbor.Persistence.EventLog.ETS,
               name: Arbor.Historian.EventLog.ETS, mode: :projection},
              {Arbor.Historian.AuthorityAuditPuller, poll_interval_ms: 60_000}
            ] do
          {:ok, _} = Supervisor.start_child(Arbor.Historian.Supervisor, child)
        end

        :ok =
          :telemetry.attach(
            "peer-authority-audit-conflict",
            @conflict_event,
            &__MODULE__.forward_telemetry/4,
            collector
          )

        {:ok, status} = Security.audit_journal_status()
        {status["mode"], status["durability"]}
      end

      defp put_all(app, pairs),
        do: Enum.each(pairs, fn {k, v} -> Application.put_env(app, k, v, persistent: true) end)

      defp install_log_forwarder(collector) do
        Enum.each(:logger.get_handler_ids(), &:logger.remove_handler/1)

        :ok =
          :logger.add_handler(:peer_forward, __MODULE__, %{
            level: :warning,
            config: %{collector: collector}
          })

        :ok = :logger.set_primary_config(:level, :warning)
      end

      # :logger handler: forward the puller's reports and every error.
      def log(%{level: level, msg: msg, meta: meta}, %{config: %{collector: collector}}) do
        puller? = match?({Arbor.Historian.AuthorityAuditPuller, _, _}, Map.get(meta, :mfa))

        if puller? or level in [:error, :critical, :alert, :emergency],
          do: send(collector, {:peer_log, level, puller?, render(msg)})

        :ok
      end

      def forward_telemetry(_event, measurements, metadata, collector),
        do: send(collector, {:peer_conflict, measurements, metadata})

      defp render({:string, chardata}), do: IO.chardata_to_string(chardata)

      defp render({format, args}) when is_list(args),
        do: format |> :io_lib.format(args) |> IO.chardata_to_string()

      defp render(other), do: inspect(other)

      # Public grant/revoke pairs through the Security facade, flushing the
      # real puller every `flush_every` pairs. Returns every unexpected reply.
      def drive_pairs(principal, range, flush_every) do
        range
        |> Enum.chunk_every(flush_every)
        |> Enum.flat_map(fn pairs ->
          errors = Enum.flat_map(pairs, &pair(principal, &1))
          expected = 2 * length(pairs)

          case Historian.flush_authority_audit() do
            {:ok, %{delivered: ^expected, pending: 0}} -> errors
            other -> errors ++ [{:flush, List.first(pairs), other}]
          end
        end)
      end

      defp pair(principal, n) do
        with {:ok, cap} <- grant(principal, "pair-#{n}"),
             :ok <- Security.revoke(cap.id),
             {:ok, %{audit: :recorded}} <- Security.capability_mutation_audit_status() do
          []
        else
          other -> [{n, other}]
        end
      end

      def grant(principal, suffix),
        do:
          Security.grant(principal: principal, resource: "arbor://memory/read/peer-sql/#{suffix}")

      def acknowledged_grant(opts), do: Security.acknowledged_grant(opts)
      def flush, do: Historian.flush_authority_audit()
      def status, do: Security.audit_journal_status()
      def pending, do: Security.audit_journal_pending_operations()
      def raw_append(record), do: AuditJournalOwner.append(record)

      def read(stream),
        do: Persistence.read_stream(@target_name, EctoEventLog, stream, repo: Repo)

      # The acknowledgement boundary is the puller's exact readback: every
      # delivered row is committed content whose stored operation fingerprint
      # is the canonical fingerprint of that content.
      def committed_audit_rows do
        %{rows: rows} =
          Repo.query!(
            "SELECT stream_id FROM events WHERE stream_id LIKE 'security:authority_mutation:%'"
          )

        streams = Enum.map(rows, fn [stream] -> stream end)

        exact =
          Enum.count(streams, fn stream ->
            case read(stream) do
              {:ok, [event]} ->
                is_binary(event.operation_fingerprint) and
                  Persistence.canonical_event_fingerprint(stream, event) ==
                    event.operation_fingerprint

              _ ->
                false
            end
          end)

        %{rows: length(streams), distinct: length(Enum.uniq(streams)), exact: exact}
      end

      def target_durability do
        {:ok, target} = HistorianConfig.durable_event_log_target()
        Persistence.durability_class(target.name, target.backend, target.opts)
      end
    end

  @driver elem(driver, 1)
  @driver_binary elem(driver, 2)
  @umbrella Path.expand("../../../../..", __DIR__)
  @wall_clock [["oldest_pending_age_seconds"], ["retirement", "oldest_prepared_age_seconds"]]

  test "a whole-BEAM restart over a real SQL sink keeps retirement, redelivers nothing, and a rolled-back grant is pinned and reported" do
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)

    root = unique_dir("peer-sql-authority")
    keys = unique_dir("peer-sql-keys")
    db = Path.join(unique_dir("peer-sql-db"), "historian.sqlite3")
    backup = unique_dir("peer-sql-rollback")
    opts = %{umbrella: @umbrella, db: db, root: root, keys: keys, collector: self()}
    principal = "agent_peer_sql_#{System.unique_integer([:positive])}"
    g_opts = exact_grant_opts(principal)

    # -- Peer A -------------------------------------------------------------
    {peer_a, a} = start_driver_peer!("audit_sql_a", opts)
    assert {:ok, :node_restart} = call(a, :target_durability, [])
    assert [] = call(a, :drive_pairs, [principal, 1..10, 10])

    # The rollback copy of the authority store, taken before exact grant G.
    before_g = namespace_listing(root)
    copy_namespaces!(root, backup)
    assert {:ok, :applied, g_id} = call(a, :acknowledged_grant, [g_opts])

    assert {:ok, [%{"operation_id" => g_op, "status" => "effect_applied"}]} =
             call(a, :pending, [])

    capability_ns = changed_namespace!(before_g, namespace_listing(root))
    assert {:ok, %{delivered: 1, pending: 0}} = call(a, :flush, [])

    # 620 more public lifecycles: the first T2 publication retires 512.
    assert [] = call(a, :drive_pairs, [principal, 11..320, 50])
    assert {:ok, %{delivered: 0, pending: 0}} = call(a, :flush, [])
    assert {:ok, status_a} = call(a, :status, [])
    identities = 2 * 320 + 1
    assert status_a["pending_count"] == 0
    assert status_a["capacity"]["retired_operation_total"] == 512
    assert status_a["capacity"]["retained_operation_count"] == identities - 512
    assert status_a["retirement"]["floor"] == 3
    assert status_a["retirement"]["ledger_state"] == "bound"
    assert status_a["retirement"]["ledger_frames"] == 1
    assert status_a["last_refusal"] == "none"

    # The puller acknowledged only after durability_class and the exact SQL
    # readback: every identity is one committed, fingerprint-exact row.
    assert %{rows: ^identities, distinct: ^identities, exact: ^identities} =
             call(a, :committed_audit_rows, [])

    assert {:ok, [g_event]} = call(a, :read, [stream(g_op)])
    assert g_event.data["intent"]["audit"]["data"]["capability_id"] == g_id
    original_prepared_at = g_event.data["intent"]["prepared_at"]

    :ok = :peer.stop(peer_a)
    refute a in Node.list(:connected)

    # -- Peer B: restart --------------------------------------------------
    {peer_b, b} = start_driver_peer!("audit_sql_b", opts)
    assert {:ok, status_b} = call(b, :status, [])
    assert drop_wall_clock(status_b) == drop_wall_clock(status_a)

    # No redelivery of retired (or delivered) operations.
    assert {:ok, %{delivered: 0, pending: 0}} = call(b, :flush, [])

    # A retired identity's v2 twin is below the floor.
    v2_twin = legacy_twin(g_event.data["intent"])
    assert {:error, :retired_version} = call(b, :raw_append, [prepared_record(v2_twin)])

    # A new grant admits and delivers.
    assert {:ok, _cap} = call(b, :grant, [principal, "after-restart"])
    assert {:ok, %{delivered: 1, pending: 0}} = call(b, :flush, [])
    assert {:ok, status_b2} = call(b, :status, [])
    assert status_b2["capacity"]["retired_operation_total"] == 512
    assert %{rows: rows_b} = call(b, :committed_audit_rows, [])
    assert rows_b == identities + 1
    :ok = :peer.stop(peer_b)

    # -- Peer C: same-UID rollback of the capability namespace (F14) -------
    restore_namespace!(backup, root, capability_ns)
    drain_peer_messages()
    {_peer_c, c} = start_driver_peer!("audit_sql_c", opts)
    assert {:ok, status_c} = call(c, :status, [])
    assert status_c["pending_count"] == 0
    assert status_c["capacity"]["retired_operation_total"] == 512

    # The rolled-back store no longer holds G, so its identical facts apply
    # again: same v3 identity (retired, so admitted as new: residual H4),
    # a different prepare second.
    assert {:ok, :applied, ^g_id} = call(c, :acknowledged_grant, [g_opts])

    assert {:ok, [%{"operation_id" => ^g_op, "status" => "effect_applied"}]} =
             call(c, :pending, [])

    assert {:ok, %{delivered: 0, pending: 1}} = call(c, :flush, [])

    assert_receive {:peer_log, :warning, true, warning}, 5_000
    assert warning =~ "#{g_op} (audit_content_conflict, event_log)"

    assert_receive {:peer_conflict, %{count: 1},
                    %{operation_id: ^g_op, reason: :audit_content_conflict, source: :event_log}},
                   5_000

    # Retried, never acknowledged, never retired; reported once.
    assert {:ok, %{delivered: 0, pending: 1}} = call(c, :flush, [])
    refute_receive {:peer_log, :warning, true, _}, 500
    refute_receive {:peer_conflict, _, _}, 100

    assert {:ok, [%{"operation_id" => ^g_op, "status" => "effect_applied"}]} =
             call(c, :pending, [])

    # Retired identities and the committed history are untouched.
    assert {:ok, status_c2} = call(c, :status, [])
    assert status_c2["capacity"]["retired_operation_total"] == 512
    assert %{rows: ^rows_b} = call(c, :committed_audit_rows, [])
    assert {:ok, [still]} = call(c, :read, [stream(g_op)])
    assert still.data["intent"]["prepared_at"] == original_prepared_at
    assert {:error, :retired_version} = call(c, :raw_append, [prepared_record(v2_twin)])
  end

  # ---------------------------------------------------------------------------

  defp call(node, fun, args), do: :erpc.call(node, @driver, fun, args, 600_000)

  defp exact_grant_opts(principal) do
    [
      capability_id: "cap_" <> Base.encode16(:erlang.md5("#{principal}-g"), case: :lower),
      granted_at: ~U[2026-09-28 12:00:00Z],
      principal: principal,
      resource: "arbor://memory/read/peer-sql/rollback-g"
    ]
  end

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
      "kind" => "arbor.security.authority_mutation_record.v1",
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp stream(id), do: "security:authority_mutation:" <> id

  defp drop_wall_clock(status) do
    Enum.reduce(@wall_clock, status, fn path, acc -> put_in(acc, path, :wall_clock) end)
  end

  # JSONFile keeps each authority-store namespace in its own `ns_*` directory
  # under the authority root; the journal and its ledger are root files.
  defp namespace_listing(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "ns_"))
    |> Map.new(fn ns ->
      files = root |> Path.join(ns) |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "."))
      {ns, Enum.sort(files)}
    end)
  end

  defp changed_namespace!(before, after_g) do
    changed = for {ns, files} <- after_g, Map.get(before, ns) != files, do: ns
    assert [ns] = changed, "exactly one namespace changes on a grant: #{inspect(changed)}"
    ns
  end

  defp copy_namespaces!(root, backup) do
    for ns <- root |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "ns_")) do
      {_, 0} = System.cmd("cp", ["-Rp", Path.join(root, ns), Path.join(backup, ns)])
    end

    :ok
  end

  defp restore_namespace!(backup, root, ns) do
    target = Path.join(root, ns)
    File.rm_rf!(target)
    {_, 0} = System.cmd("cp", ["-Rp", Path.join(backup, ns), target])
    :ok
  end

  defp drain_peer_messages do
    receive do
      {:peer_log, _, _, _} -> drain_peer_messages()
      {:peer_conflict, _, _} -> drain_peer_messages()
    after
      0 -> :ok
    end
  end

  defp start_driver_peer!(prefix, opts) do
    name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
    {:ok, peer, node} = start_peer(name)
    on_exit(fn -> safely_stop_peer(peer) end)
    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])

    {:module, @driver} =
      :erpc.call(node, :code, :load_binary, [
        @driver,
        ~c"authority_audit_retirement_peer_driver",
        @driver_binary
      ])

    assert {"durable", "durable"} = :erpc.call(node, @driver, :boot, [opts], 300_000)
    {peer, node}
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      false
    else
      epmd = System.find_executable("epmd") || flunk("epmd executable is unavailable")
      {_output, 0} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)

      name =
        String.to_atom(
          "authority_audit_sql_test_#{System.unique_integer([:positive, :monotonic])}@localhost"
        )

      {:ok, _} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  # As distributed_peer_integration_test.exs: lifecycle control on stdio,
  # then an explicit distribution connection.
  defp start_peer(name) do
    options = %{name: name, host: ~c"localhost", connection: :standard_io, args: []}

    with {:ok, peer, peer_node} <- :peer.start_link(options) do
      case Node.connect(peer_node) do
        true ->
          {:ok, peer, peer_node}

        other ->
          safely_stop_peer(peer)
          {:error, {:distribution_connection_failed, peer_node, other}}
      end
    end
  end

  defp safely_stop_peer(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
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
