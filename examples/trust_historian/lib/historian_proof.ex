defmodule PairedStandaloneConsumer.HistorianProof do
  @moduledoc """
  Actual public Core -> canonical Historian puller -> real SQL evidence.

  Receipts retain public operation IDs/digests only and are rechecked against
  real SQL on each VM. They never authorize an ACK or substitute for journal
  durability. No test-only Core APIs or invented node-restart backend are used.
  """
  alias Arbor.Historian
  alias Arbor.Persistence.Core, as: Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Security
  alias Arbor.Security.Contracts.AuditJournal

  @app :paired_standalone_consumer
  @puller Arbor.Historian.AuthorityAuditPuller
  @volatile PairedStandaloneConsumer.HistorianProof.VolatileLog
  @max_operations 10_000
  @max_receipt_bytes 4_000_000

  defmodule AuthoritySource do
    @moduledoc "Inline calls preserve the actual canonical puller as the Core consumer."
    @behaviour Arbor.Historian.Contracts.AuthoritySource
    def reconcile_authority_audit do
      observe(:reconcile)
      Arbor.Security.reconcile_authority_audit()
    end

    def authority_audit_delivery_batch do
      observe(:batch)
      result = Arbor.Security.authority_audit_delivery_batch()

      case result do
        {:ok, items} ->
          headers =
            Enum.map(items, fn item ->
              {item["operation_id"], item["intent_sha256"], get_in(item, ["event", "timestamp"])}
            end)

          observe({:batch_headers, headers})

        _ ->
          :ok
      end

      result
    end

    def acknowledge_authority_audit(id, digest) do
      observe({:acknowledge, id})
      Arbor.Security.acknowledge_authority_audit(id, digest)
    end

    defp observe(operation) do
      case Application.get_env(:paired_standalone_consumer, :historian_observer) do
        {pid, reference} when is_pid(pid) -> send(pid, {reference, operation, self()})
        _ -> :ok
      end
    end
  end

  defmodule LostAckBackend do
    @moduledoc "Real SQL performs the append; only its caller-visible ACK is lost."
    alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
    def durability_class(opts), do: EctoEventLog.durability_class(opts)
    def read_stream(stream, opts), do: EctoEventLog.read_stream(stream, opts)

    def append(stream, events, opts) do
      case EctoEventLog.append(stream, events, opts) do
        {:ok, _} ->
          case Application.get_env(:paired_standalone_consumer, :historian_observer) do
            {pid, reference} when is_pid(pid) -> send(pid, {reference, :sql_ack_lost, self()})
            _ -> :ok
          end

          {:error, :lost_ack}

        error ->
          error
      end
    end
  end

  @doc "Pause pull delivery before real public authority mutations; SQL invocation audit remains available."
  def pause! do
    Application.put_env(:arbor_historian, :authority_source, nil)
    # Drain any already-selected pass before returning. The nil source causes a
    # later pass to refuse, and the GenServer call serializes prior callbacks.
    {:error, :audit_source_unavailable} = Historian.flush_authority_audit()
    :ok
  end

  @doc "Deliver actual pending effects once, merge receipts, then recheck all prior SQL evidence."
  def write! do
    :ok = pause!()
    identity!()
    target = sql_target!()
    pending = pending!()
    prior = read_receipt(false)
    verify_receipt!(prior, target)
    current = deliver!(pending, target, false)
    rows = merge_rows!(prior["operations"], current)
    ordinary = ordinary_sql_history!(prior["ordinary_history"])

    receipt =
      Map.merge(prior, %{"version" => 1, "operations" => rows, "ordinary_history" => ordinary})

    write_receipt!(receipt)
    verify_receipt!(receipt, target)
    :ok = pause!()

    %{
      "checks" => [
        "real canonical puller PID delegates directly to public Core",
        "real SQL node_restart exact readback before ACK",
        "one immutable SQL event per actual journal operation",
        "public ordinary SQL history/query/timeline after projection loss"
      ],
      "operations" => map_size(rows),
      "new_operations" => length(pending),
      "storage_durability" => "node_restart",
      "retirement_qualified" => false,
      "remaining_required" => [
        "retirement workload >=4096 actually retired",
        "persistent content conflict",
        "compatible authority-state rollback with current journal/SQL retained"
      ]
    }
  end

  @doc "Fresh-VM check of every public receipt against SQL; no mint/replay of evidence."
  def recover! do
    :ok = pause!()
    identity!()
    receipt = read_receipt(true)
    verify_receipt!(receipt, sql_target!())

    %{
      "checks" => [
        "fresh VM exact SQL operation identity and canonical fingerprint",
        "fresh VM complete ordinary history from real SQL"
      ],
      "operations" => map_size(receipt["operations"]),
      "storage_durability" => "node_restart",
      "retirement_qualified" => false
    }
  end

  @doc "Real pending effects survive a real volatile target and a caller with the wrong PID."
  def refused! do
    :ok = pause!()
    identity!()
    target = sql_target!()
    pending = pending!()
    ensure(pending != [], "volatile proof requires real new pending operations")
    first = hd(pending)

    ensure(
      Security.reconcile_authority_audit() == {:error, :unauthorized_audit_consumer},
      "wrong PID reconciled the journal"
    )

    ensure(
      Security.authority_audit_delivery_batch() == {:error, :unauthorized_audit_consumer},
      "wrong PID acquired delivery batch"
    )

    ensure(
      Security.acknowledge_authority_audit(first["operation_id"], first["intent_sha256"]) ==
        {:error, :unauthorized_audit_consumer},
      "wrong PID acknowledged a genuine intent"
    )

    ensure(is_nil(Process.whereis(@volatile)), "volatile backend is borrowed")

    {:ok, backend} =
      ETS.start_link(name: @volatile, trim_interval_ms: :disabled, max_age_ms: :infinity)

    try do
      Application.put_env(:arbor_historian, :durable_event_log_target, %{
        name: @volatile,
        backend: ETS,
        opts: []
      })

      {:ok, :process_lifetime} = Persistence.durability_class(@volatile, ETS, [])
      Application.put_env(:arbor_historian, :authority_source, AuthoritySource)
      {:ok, %{delivered: 0, pending: count}} = Historian.flush_authority_audit()
      ensure(count == length(pending), "volatile backend retired a pending effect")
      ensure(pending!() == pending, "volatile backend changed public pending state")

      for item <- pending do
        {:ok, []} =
          Persistence.read_stream(@volatile, ETS, stream(item["operation_id"]), limit: 2)
      end

      :ok = pause!()
    after
      Application.put_env(:arbor_historian, :authority_source, nil)
      Application.put_env(:arbor_historian, :durable_event_log_target, target)
      if Process.alive?(backend), do: GenServer.stop(backend, :normal)
    end

    :ok
  end

  @doc "Commit to actual SQL while dropping only append ACK, then prove no duplicate on reread."
  def lost_ack! do
    :ok = pause!()
    target = sql_target!()
    pending = pending!()
    ensure(pending != [], "lost ACK proof requires real new pending operations")

    for item <- pending do
      {:ok, []} = read_operation(target, item["operation_id"])
    end

    prior = read_receipt(true)

    try do
      current = deliver!(pending, Map.put(target, :backend, LostAckBackend), true)
      receipt = Map.put(prior, "operations", merge_rows!(prior["operations"], current))
      write_receipt!(receipt)
      verify_receipt!(receipt, target)
    after
      :ok = pause!()
      Application.put_env(:arbor_historian, :durable_event_log_target, target)
    end

    :ok
  end

  @doc "Actual private Repo termination refuses delivery without losing pending intent; no outage stub."
  def outage! do
    :ok = pause!()
    target = sql_target!()
    pending = pending!()
    ensure(pending != [], "outage proof requires real new pending operations")
    repo = Keyword.fetch!(target.opts, :repo)
    owner = PairedStandaloneConsumer.Supervisor
    {^repo, old_pid, :supervisor, _} = List.keyfind(Supervisor.which_children(owner), repo, 0)
    ensure(is_pid(old_pid), "private Repo is not the declared direct child")
    :ok = Supervisor.terminate_child(owner, repo)

    try do
      ensure(is_nil(Process.whereis(repo)), "Repo outage did not stop the actual private Repo")
      Application.put_env(:arbor_historian, :authority_source, AuthoritySource)
      {:ok, %{delivered: 0, pending: count}} = Historian.flush_authority_audit()
      ensure(count == length(pending), "Repo outage retired a pending effect")
      ensure(pending!() == pending, "Repo outage changed public pending state")
      :ok = pause!()
    after
      Application.put_env(:arbor_historian, :authority_source, nil)
      {:ok, new_pid} = Supervisor.restart_child(owner, repo)
      ensure(is_pid(new_pid) and new_pid != old_pid, "actual private Repo was not restarted")
    end

    verify_receipt!(read_receipt(true), sql_target!())
    :ok
  end

  @doc "Run 2300 actual public grant/revoke pairs in the admitted caller, then gate real retirement."
  def retirement!(real_mutation_fun) when is_function(real_mutation_fun, 1) do
    :ok = pause!()
    identity!()
    target = sql_target!()
    ensure(pending!() == [], "retirement requires an initially drained journal")
    prior = read_receipt(true)
    verify_receipt!(prior, target)
    original_ids = MapSet.new(Map.keys(prior["operations"]))
    {:ok, before_audit} = Security.capability_mutation_audit_status()

    receipt =
      1..2_300
      |> Enum.chunk_every(32)
      |> Enum.reduce(prior, fn indices, receipt ->
        # The closure executes inline in C's actual Provisioner PID, which owns
        # and refreshes its real actor handle; it must do one public grant and
        # revoke per index. Journal observation below prevents no-op credit.
        Enum.each(indices, fn index -> :ok = real_mutation_fun.(index) end)
        pending = pending!()

        ensure(
          length(pending) == 2 * length(indices),
          "workload did not create two real identities per pair"
        )

        ensure(
          Enum.all?(pending, &(not Map.has_key?(receipt["operations"], &1["operation_id"]))),
          "workload reused a prior operation identity"
        )

        rows = deliver!(pending, target, false)
        updated = Map.put(receipt, "operations", merge_rows!(receipt["operations"], rows))
        write_receipt!(updated)
        {:ok, status} = Security.audit_journal_status()

        ensure(
          status["capacity"]["retained_operation_count"] < 4_096,
          "retirement exceeded original retained bound"
        )

        updated
      end)

    new_ids = MapSet.difference(MapSet.new(Map.keys(receipt["operations"])), original_ids)

    ensure(
      MapSet.size(new_ids) == 4_600,
      "workload did not create 4600 distinct committed SQL identities"
    )

    {:ok, after_audit} = Security.capability_mutation_audit_status()

    ensure(
      after_audit[:degraded_reductions] == before_audit[:degraded_reductions],
      "public workload degraded audit coverage"
    )

    status = retirement_status!()

    receipt =
      Map.put(receipt, "retirement", %{
        "public_pairs" => 2_300,
        "new_sql_identities" => 4_600,
        "retired_operation_total" => status["capacity"]["retired_operation_total"],
        "ledger_frames" => status["retirement"]["ledger_frames"]
      })

    write_receipt!(receipt)
    retirement!()
  end

  @doc "Fresh-VM gate only: no credit until the real journal has retired at least 4096 operations."
  def retirement! do
    _status = retirement_status!()
    receipt = read_receipt(true)

    ensure(
      receipt["retirement"]["public_pairs"] == 2_300 and
        receipt["retirement"]["new_sql_identities"] == 4_600 and
        map_size(receipt["operations"]) >= 4_600,
      "real 2300-pair workload receipt missing"
    )

    verify_receipt!(receipt, sql_target!())

    %{
      "checks" => [
        "2300 real public grant/revoke pairs and 4600 distinct SQL identities",
        "actual public journal retirement >=4096 with bound eight-frame ledger",
        "retired SQL events remain exact"
      ],
      "retirement_qualified" => true
    }
  end

  defp retirement_status! do
    {:ok, status} = Security.audit_journal_status()

    ensure(
      status["capacity"]["retired_operation_total"] >= 4_096,
      "retirement workload has not reached original threshold"
    )

    ensure(status["retirement"]["ledger_state"] == "bound", "retirement ledger is not bound")

    ensure(
      status["retirement"]["ledger_frames"] >= 8,
      "retirement ledger has fewer than eight committed frames"
    )

    ensure(
      status["retirement"]["floor"] == 3,
      "retirement did not preserve the existing version floor"
    )

    ensure(
      status["pending_count"] == 0 and status["last_refusal"] == "none" and
        status["admission_open"] == true,
      "retirement did not leave open, drained authority"
    )

    status
  end

  @doc "Seed one exact public grant before the runner's retirement workload and namespace-only attack."
  def namespace_attack_seed!(real_exact_grant_fun) when is_function(real_exact_grant_fun, 0) do
    :ok = pause!()
    ensure(pending!() == [], "namespace seed requires drained authority")
    ensure(not File.exists?(namespace_seed_path()), "namespace seed receipt already exists")
    {:ok, :applied, cap_id} = real_exact_grant_fun.()
    [item] = pending!()
    id = item["operation_id"]
    rows = deliver!([item], sql_target!(), false)
    {:ok, [event]} = read_operation(sql_target!(), id)

    ensure(
      event.data["intent"]["audit"]["data"]["capability_id"] == cap_id,
      "namespace seed capability binding changed"
    )

    prior = read_receipt(true)
    write_receipt!(Map.put(prior, "operations", merge_rows!(prior["operations"], rows)))

    write_json!(namespace_seed_path(), %{
      "operation_id" => id,
      "capability_id" => cap_id,
      "intent_sha256" => item["intent_sha256"],
      "operation_fingerprint" => event.operation_fingerprint,
      "prepared_at" => event.data["intent"]["prepared_at"]
    })

    %{
      "checks" => ["real exact-grant seed delivered before namespace-only attack"],
      "operation_id" => id
    }
  end

  # A dedicated conflict/rollback phase must supply exactly one *real* new public
  # mutation while delivery is paused. It deliberately remains non-quiescent.
  @doc "Persist wrong content in actual SQL and prove it cannot ACK the genuine pending intent."
  def conflict! do
    :ok = pause!()
    target = sql_target!()
    [item] = pending!()
    id = item["operation_id"]
    {:ok, []} = read_operation(target, id)

    wrong =
      Event.new(stream(id), "capability_granted", %{"wrong" => "deliberate-conflict"}, id: id)

    {:ok, [committed]} =
      Persistence.append(target.name, target.backend, stream(id), wrong, target.opts)

    fingerprint = committed.operation_fingerprint
    Application.put_env(:arbor_historian, :authority_source, AuthoritySource)

    try do
      {:ok, %{delivered: 0, pending: 1}} = Historian.flush_authority_audit()
      ensure(pending!() == [item], "conflicting content acknowledged the genuine intent")
      {:ok, [current]} = read_operation(target, id)
      ensure(current.operation_fingerprint == fingerprint, "conflict rewrote immutable SQL")

      write_conflict_receipt!(%{
        "operation_id" => id,
        "intent_sha256" => item["intent_sha256"],
        "operation_fingerprint" => fingerprint
      })
    after
      :ok = pause!()
    end

    %{
      "checks" => ["actual SQL conflicting event keeps real mutation effect_applied"],
      "pending_conflict" => 1
    }
  end

  @doc "Same-candidate namespace rollback attack only; never predecessor compatibility rollback credit."
  def namespace_rollback_attack!(real_represent_fun) when is_function(real_represent_fun, 0) do
    :ok = pause!()
    identity!()
    target = sql_target!()
    seed = read_json!(namespace_seed_path())
    id = seed["operation_id"]
    ensure(pending!() == [], "namespace attack requires initially drained retained journal")
    {:ok, before_status} = Security.audit_journal_status()

    ensure(
      before_status["capacity"]["retired_operation_total"] >= 4_096,
      "namespace seed was not subjected to retirement workload"
    )

    {:ok, :applied, cap_id} = real_represent_fun.()

    ensure(
      cap_id == seed["capability_id"],
      "namespace rollback changed exact capability identity"
    )

    [item] = pending!()

    ensure(
      item["operation_id"] == id and item["intent_sha256"] != seed["intent_sha256"],
      "namespace rollback did not re-present the same identity with new intent content"
    )

    reference = make_ref()
    Application.put_env(@app, :historian_observer, {self(), reference})
    Application.put_env(:arbor_historian, :authority_source, AuthoritySource)

    try do
      for _ <- 1..2 do
        {:ok, %{delivered: 0, pending: 1}} = Historian.flush_authority_audit()

        ensure(
          pending!() == [item],
          "namespace rollback acknowledged/retired conflicting evidence"
        )
      end

      puller = Process.whereis(@puller)
      expect_pid!(reference, :reconcile, puller)
      expect_pid!(reference, :batch, puller)
      prepared_at = expect_batch_header!(reference, puller, id, item["intent_sha256"])

      ensure(
        prepared_at != seed["prepared_at"],
        "namespace attack did not run in a different prepare second"
      )

      {:ok, [event]} = read_operation(target, id)

      ensure(
        event.operation_fingerprint == seed["operation_fingerprint"] and
          event.data["intent"]["prepared_at"] == seed["prepared_at"],
        "namespace rollback replaced original SQL evidence"
      )

      {:ok, after_status} = Security.audit_journal_status()

      ensure(
        after_status["capacity"]["retired_operation_total"] ==
          before_status["capacity"]["retired_operation_total"],
        "namespace conflict changed retired total"
      )

      verify_receipt!(read_receipt(true), target)
    after
      :ok = pause!()
      Application.delete_env(@app, :historian_observer)
    end

    %{
      "checks" => [
        "same-candidate capability-namespace-only rollback preserves old SQL and denies conflicting ACK"
      ],
      "pending_conflict" => 1,
      "predecessor_compatibility_rollback_qualified" => false
    }
  end

  defp deliver!(pending, target, require_lost_ack) do
    identity!()
    ensure(length(pending) <= @max_operations, "unbounded pending batch")
    reference = make_ref()
    Application.put_env(@app, :historian_observer, {self(), reference})
    puller = Process.whereis(@puller)
    start_trace!(puller)
    Application.put_env(:arbor_historian, :durable_event_log_target, target)
    Application.put_env(:arbor_historian, :authority_source, AuthoritySource)

    try do
      {:ok, %{pending: 0}} = Historian.flush_authority_audit()
      ensure(pending!() == [], "successful delivery left pending operations")
      ensure(Process.whereis(@puller) == puller, "canonical puller restarted during delivery")
      trace = finish_trace!(puller)
      verify_delivery_trace!(trace, pending, require_lost_ack)
      expect_pid!(reference, :reconcile, puller)
      expect_pid!(reference, :batch, puller)

      rows =
        Map.new(pending, fn item ->
          id = item["operation_id"]
          expect_pid!(reference, {:acknowledge, id}, puller)
          {id, verified_row!(sql_target!(), item)}
        end)

      if require_lost_ack, do: expect_lost_ack!(reference)
      {:ok, %{delivered: 0, pending: 0}} = Historian.flush_authority_audit()
      rows
    after
      stop_trace!(puller)
      :ok = pause!()
      Application.delete_env(@app, :historian_observer)
    end
  end

  defp trace_patterns do
    [
      {Persistence, :durability_class, 3},
      {Persistence, :read_stream, 4},
      {Persistence, :append, 5},
      {AuthoritySource, :acknowledge_authority_audit, 2}
    ]
  end

  defp start_trace!(puller) do
    ensure(
      :erlang.trace_info(puller, :flags) == {:flags, []},
      "canonical puller has a borrowed tracer"
    )

    for {module, _function, _arity} = mfa <- trace_patterns() do
      ensure(Code.ensure_loaded?(module), "public trace module unavailable")

      ensure(
        :erlang.trace_info(mfa, :traced) == {:traced, false},
        "public function has a borrowed trace pattern"
      )
    end

    Enum.each(trace_patterns(), &:erlang.trace_pattern(&1, true, [:global]))
    1 = :erlang.trace(puller, true, [:call, {:tracer, self()}])
    :ok
  end

  defp finish_trace!(puller) do
    reference = :erlang.trace_delivered(puller)

    receive do
      {:trace_delivered, ^puller, ^reference} -> :ok
    after
      2_000 -> raise("canonical puller trace not delivered")
    end

    :erlang.trace(puller, false, [:call])
    collect_trace(puller, [])
  end

  defp stop_trace!(puller) do
    if Process.alive?(puller), do: :erlang.trace(puller, false, [:call])
    Enum.each(trace_patterns(), &:erlang.trace_pattern(&1, false, [:global]))
    :ok
  end

  defp collect_trace(puller, acc) do
    receive do
      {:trace, ^puller, :call, {Persistence, :durability_class, [_name, _backend, _opts]}} ->
        collect_trace(puller, [{:durability, nil} | acc])

      {:trace, ^puller, :call, {Persistence, :read_stream, [_name, _backend, stream, _opts]}} ->
        collect_trace(puller, [{:read, stream} | acc])

      {:trace, ^puller, :call, {Persistence, :append, [_name, _backend, stream, _event, _opts]}} ->
        collect_trace(puller, [{:append, stream} | acc])

      {:trace, ^puller, :call, {AuthoritySource, :acknowledge_authority_audit, [id, _digest]}} ->
        collect_trace(puller, [{:acknowledge, stream(id)} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp verify_delivery_trace!(trace, pending, require_append) do
    segments = trace_segments(trace, [])
    expected_streams = pending |> Enum.map(&stream(&1["operation_id"])) |> Enum.sort()

    observed_streams =
      Enum.map(segments, fn segment ->
        case segment do
          [
            {:durability, nil},
            {:read, first},
            {:append, second},
            {:read, third},
            {:acknowledge, last}
          ]
          when first == second and second == third and third == last ->
            first

          [{:durability, nil}, {:read, first}, {:acknowledge, last}]
          when first == last and not require_append ->
            first

          _ ->
            raise("canonical puller did not read exact durable content before ACK")
        end
      end)
      |> Enum.sort()

    ensure(
      observed_streams == expected_streams,
      "canonical puller trace lost or duplicated an operation"
    )

    :ok
  end

  defp trace_segments([], acc), do: Enum.reverse(acc)

  defp trace_segments([{:durability, nil} | rest], acc) do
    {segment, remaining} = Enum.split_while(rest, &(elem(&1, 0) != :durability))
    trace_segments(remaining, [[{:durability, nil} | segment] | acc])
  end

  defp trace_segments(_, _),
    do: raise("canonical puller trace did not begin at durability admission")

  defp verified_row!(target, item) do
    id = item["operation_id"]
    {:ok, [event]} = read_operation(target, id)

    ensure(
      event.id == id and event.stream_id == stream(id) and event.event_number == 1,
      "SQL mutation identity/position changed"
    )

    ensure(event.data["effect"] == "applied", "SQL record is not an applied effect")
    intent = event.data["intent"]
    ensure(is_map(intent) and intent["operation_id"] == id, "SQL intent identity changed")
    {:ok, canonical} = AuditJournal.canonical_intent_bytes(intent)
    digest = Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)

    ensure(
      digest == item["intent_sha256"] and event.metadata["intent_sha256"] == digest,
      "SQL content does not bind exact original intent"
    )

    fingerprint = Persistence.canonical_event_fingerprint(event.stream_id, event)
    ensure(fingerprint == event.operation_fingerprint, "SQL content fingerprint changed")
    %{"intent_sha256" => digest, "operation_fingerprint" => fingerprint}
  end

  defp verify_receipt!(receipt, target) do
    operations = receipt["operations"]

    ensure(
      is_map(operations) and map_size(operations) <= @max_operations,
      "invalid public receipt"
    )

    for {id, expected} <- operations do
      ensure(
        verified_row!(target, Map.put(expected, "operation_id", id)) == expected,
        "prior SQL evidence changed"
      )
    end

    if receipt["ordinary_history"], do: ordinary_sql_history!(receipt["ordinary_history"])
    :ok
  end

  defp ordinary_sql_history!(nil) do
    for {id, value} <- [{"paired_history_one", 1}, {"paired_history_two", 2}] do
      :ok =
        Historian.persist_durable_event("global", "activity:paired_proof", %{value: value},
          metadata: %{signal_id: id, source: "arbor://paired-proof"}
        )
    end

    {:ok, entries} =
      Historian.query(
        source: "arbor://paired-proof",
        category: :activity,
        limit: 3,
        max_scan: 100
      )

    ensure(
      Enum.map(entries, & &1.signal_id) == ["paired_history_one", "paired_history_two"],
      "ordinary SQL query mismatch"
    )

    result = %{
      "signal_ids" => Enum.map(entries, & &1.signal_id),
      "first" => DateTime.to_iso8601(hd(entries).timestamp),
      "last" => DateTime.to_iso8601(List.last(entries).timestamp)
    }

    ordinary_sql_history!(result)
  end

  defp ordinary_sql_history!(expected) when is_map(expected) do
    {:ok, entries} =
      Historian.query(
        source: "arbor://paired-proof",
        category: :activity,
        limit: 3,
        max_scan: 100
      )

    ensure(
      Enum.map(entries, & &1.signal_id) == expected["signal_ids"],
      "complete SQL history missing after restart"
    )

    {:ok, from, 0} = DateTime.from_iso8601(expected["first"])
    {:ok, to, 0} = DateTime.from_iso8601(expected["last"])

    span =
      Historian.span(
        from: DateTime.add(from, -1, :second),
        to: DateTime.add(to, 1, :second),
        streams: ["global"]
      )

    {:ok, timeline} = Historian.reconstruct(span)

    ensure(
      Enum.map(Enum.filter(timeline, &(&1.source == "arbor://paired-proof")), & &1.signal_id) ==
        expected["signal_ids"],
      "SQL timeline missing after restart"
    )

    expected
  end

  defp identity! do
    ensure(
      Application.spec(:arbor_historian, :mod) == {Arbor.Historian.Application, []},
      "canonical Historian callback changed"
    )

    root = Process.whereis(Arbor.Historian.Supervisor)
    ensure(is_pid(root), "canonical Historian root absent")
    {@puller, pid, :worker, _} = List.keyfind(Supervisor.which_children(root), @puller, 0)
    ensure(pid == Process.whereis(@puller), "puller is not a direct canonical child")

    ensure(
      :application.get_application(pid) == {:ok, :arbor_historian},
      "wrong puller application owner"
    )

    ensure(
      Application.get_env(:arbor_capabilities, :authority_audit_consumer_name) == @puller and
        Application.get_env(:arbor_capabilities, :authority_audit_consumer_application) ==
          :arbor_historian,
      "Core consumer descriptor is not the actual canonical puller"
    )

    for module <- [Historian, Arbor.Historian.Application, @puller] do
      ensure(
        :application.get_application(module) == {:ok, :arbor_historian},
        "wrong Historian module owner"
      )
    end

    ensure(
      :application.get_application(EctoEventLog) == {:ok, :arbor_persistence_sql},
      "SQL backend is not the public package"
    )

    :ok
  end

  defp sql_target! do
    target = Application.fetch_env!(@app, :historian_sql_target)

    ensure(
      target == %{
        name: :historian_durable_event_log,
        backend: EctoEventLog,
        opts: [repo: Arbor.Persistence.SQL.Repo]
      },
      "unexpected SQL target"
    )

    {:ok, :node_restart} = Persistence.durability_class(target.name, target.backend, target.opts)
    target
  end

  defp pending! do
    {:ok, pending} = Security.audit_journal_pending_operations()

    ensure(
      is_list(pending) and length(pending) <= @max_operations,
      "invalid public pending batch"
    )

    ensure(
      Enum.all?(
        pending,
        &(&1["status"] == "effect_applied" and is_binary(&1["operation_id"]) and
            is_binary(&1["intent_sha256"]))
      ),
      "pending effect is not stable"
    )

    Enum.sort_by(pending, & &1["operation_id"])
  end

  defp read_operation(target, id),
    do:
      Persistence.read_stream(
        target.name,
        target.backend,
        stream(id),
        Keyword.put(target.opts, :limit, 2)
      )

  defp stream(id), do: "security:authority_mutation:" <> id

  defp merge_rows!(old, new) do
    Map.merge(old, new, fn _id, existing, current ->
      ensure(existing == current, "operation receipt identity changed")
      current
    end)
  end

  defp expect_pid!(reference, operation, pid) do
    receive do
      {^reference, ^operation, ^pid} -> :ok
      {^reference, ^operation, _other} -> raise("Historian callback escaped the canonical puller")
    after
      2_000 -> raise("Historian callback was not observed")
    end
  end

  defp expect_batch_header!(reference, puller, id, digest) do
    receive do
      {^reference, {:batch_headers, headers}, ^puller} ->
        {^id, ^digest, timestamp} = List.keyfind(headers, id, 0)
        timestamp

      {^reference, {:batch_headers, _headers}, _wrong_pid} ->
        raise("batch metadata escaped canonical puller")
    after
      2_000 -> raise("real batch metadata not observed")
    end
  end

  defp expect_lost_ack!(reference) do
    receive do
      {^reference, :sql_ack_lost, pid} when is_pid(pid) -> :ok
    after
      2_000 -> raise("real SQL append ACK was not lost")
    end
  end

  defp receipt_path do
    root = System.fetch_env!("PAIRED_STATE_ROOT") |> Path.expand()

    path =
      System.get_env(
        "PAIRED_HISTORIAN_STATE_PATH",
        Path.join(root, "historian-public-receipt.json")
      )
      |> Path.expand()

    ensure(Path.dirname(path) == root, "receipt is outside the private state root")
    path
  end

  defp namespace_seed_path, do: receipt_path() <> ".namespace-seed"
  defp conflict_path, do: receipt_path() <> ".conflict"

  defp read_receipt(required) do
    if File.exists?(receipt_path()),
      do: read_json!(receipt_path()),
      else:
        if(required,
          do: raise("public Historian receipt missing"),
          else: %{"version" => 1, "operations" => %{}, "ordinary_history" => nil}
        )
  end

  defp read_json!(path) do
    %{type: :regular, size: size} = File.lstat!(path)
    ensure(size <= @max_receipt_bytes, "public receipt too large")
    path |> File.read!() |> Jason.decode!()
  end

  defp write_receipt!(receipt), do: write_json!(receipt_path(), receipt)
  defp write_conflict_receipt!(receipt), do: write_json!(conflict_path(), receipt)

  defp write_json!(path, receipt) do
    bytes = Jason.encode!(receipt)
    ensure(byte_size(bytes) <= @max_receipt_bytes, "public receipt too large")

    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular, links: 1}} -> :ok
      _ -> raise("public receipt is not an owned regular file")
    end

    temporary = path <> ".next-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, file} = :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive])

    try do
      File.chmod!(temporary, 0o600)
      :ok = :file.write(file, bytes)
      :ok = :file.sync(file)
    after
      :ok = :file.close(file)
    end

    File.rename!(temporary, path)
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("Historian composed qualification failed: " <> label)
end
