defmodule Arbor.Security.AuditJournalOwnerTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.Contracts.AuditJournal


  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @t1 "2026-08-20T12:00:01Z"
  @t2 "2026-08-20T12:00:02Z"
  @status_keys MapSet.new([
                 "version",
                 "mode",
                 "durability",
                 "availability",
                 "reason",
                 "serving",
                 "poisoned",
                 "torn_tail",
                 "last_error",
                 "entry_count",
                 "byte_count",
                 "pending_count",
                 "oldest_pending_age_seconds",
                 "committed_frames",
                 "capacity"
               ])
  @forbidden ~w(pid fd handle root path token core records intent capability private_key signing_key digest identity callback module backend)

  setup do
    name = unique_name()
    on_exit(fn -> stop_named(name) end)
    %{name: name}
  end

  test "disabled never creates a log and append is an error", %{name: name} do
    root = unique_root()
    assert {:ok, pid} = Owner.start_link(mode: :disabled, name: name)
    assert {:error, :journal_disabled} = Owner.append(pid, prepared(1))
    refute match?({:ok, _}, Owner.append(pid, prepared(1)))
    assert {:ok, status} = Owner.status(pid)
    assert status["mode"] == "disabled"
    assert status["durability"] == "dormant"
    assert status["availability"] == "dormant"
    assert status["reason"] == "disabled"
    assert status["last_error"] == "disabled"
    assert status["serving"] == false
    assert status["committed_frames"] == 0
    refute File.exists?(Path.join(root, "audit_journal.v1.log"))
    assert Jason.encode!(status)
  end

  test "ephemeral never creates a log and restart loses memory", %{name: name} do
    root = unique_root()
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared(1))
    assert {:ok, status} = Owner.status(pid)
    assert status["mode"] == "ephemeral"
    assert status["durability"] == "ephemeral"
    assert status["availability"] == "serving"
    assert status["reason"] == "none"
    assert status["entry_count"] == 1
    refute File.exists?(Path.join(root, "audit_journal.v1.log"))

    :ok = GenServer.stop(pid)
    assert {:ok, _pid} = Owner.start_link(mode: :ephemeral, name: name)
    assert {:ok, restarted} = Owner.status(name)
    assert restarted["entry_count"] == 0
    assert restarted["pending_count"] == 0
  end

  test "durable restart replay matches Core.fold", %{name: name} do
    root = unique_root()
    {prepared, applied, _delivered} = grant_lifecycle()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert {:ok, :committed} = Owner.append(pid, applied)
    assert {:ok, before} = Owner.status(pid)
    assert {:ok, pending} = Owner.pending_operations(pid)
    :ok = GenServer.stop(pid)

    assert {:ok, _pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, after_status} = Owner.status(name)
    assert {:ok, after_pending} = Owner.pending_operations(name)
    assert {:ok, folded} = AuditJournalCore.fold([prepared, applied])
    shown = AuditJournalCore.show(folded)
    assert after_status["entry_count"] == shown["entry_count"]
    assert after_status["byte_count"] == shown["byte_count"]
    assert after_status["pending_count"] == 1
    assert after_status["committed_frames"] == 2
    assert after_pending == pending
    assert after_status["entry_count"] == before["entry_count"]
    assert File.exists?(Path.join(root, "audit_journal.v1.log"))
  end

  test "concurrent appends are serialized", %{name: name} do
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)

    results =
      1..8
      |> Enum.map(fn n ->
        Task.async(fn -> Owner.append(pid, prepared(n)) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &(&1 == {:ok, :committed}))
    assert {:ok, status} = Owner.status(pid)
    assert status["entry_count"] == 8
    assert {:ok, pending} = Owner.pending_operations(pid)
    assert length(pending) == 8
  end

  test "duplicate is idempotent and conflict is preserved", %{name: name} do
    {prepared, applied, _delivered} = grant_lifecycle()
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert {:ok, :idempotent} = Owner.append(pid, prepared)
    assert {:ok, :committed} = Owner.append(pid, applied)

    other = Map.put(applied, "occurred_at", "2026-08-20T12:00:09Z")
    assert {:error, :operation_conflict} = Owner.append(pid, other)
    assert {:ok, status} = Owner.status(pid)
    assert status["entry_count"] == 2
    assert status["last_error"] == "none"
  end

  test "soft and hard capacity match Core", %{name: name} do
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)

    for n <- 1..32 do
      assert {:ok, :committed} = Owner.append(pid, prepared(n))
    end

    assert {:error, :soft_capacity_exhausted} = Owner.append(pid, prepared(33))

    {:ok, revoke_intent} = AuditJournal.admit_intent(revoke_facts(40))
    assert {:ok, :committed} = Owner.append(pid, prepared_record(revoke_intent))
    assert {:ok, :committed} = Owner.append(pid, rejected_record(revoke_intent, @t1))

    {:ok, first} = AuditJournal.admit_intent(grant_facts(1))
    assert {:ok, :committed} = Owner.append(pid, applied_record(first, @t1))
    assert {:ok, :committed} = Owner.append(pid, delivered_record(first, @t2))

    for n <- 41..52 do
      {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
      assert {:ok, :committed} = Owner.append(pid, prepared_record(intent))
    end

    {:ok, overflow} = AuditJournal.admit_intent(revoke_facts(99))
    assert {:error, :capacity_exhausted} = Owner.append(pid, prepared_record(overflow))
    assert {:ok, status} = Owner.status(pid)
    assert status["entry_count"] == 48
    assert status["last_error"] == "none"
  end

  test "start_supervised kill restarts durable owner from disk", %{name: name} do
    root = unique_root()
    opts = [mode: :durable, root: root, name: name]
    spec = Supervisor.child_spec({Owner, opts}, id: name)
    {:ok, pid} = start_supervised(spec)
    assert {:ok, :committed} = Owner.append(pid, prepared(1))
    Process.exit(pid, :kill)

    new_pid =
      Enum.find_value(1..50, fn _ ->
        case Process.whereis(name) do
          restarted when is_pid(restarted) and restarted != pid ->
            restarted

          _other ->
            Process.sleep(10)
            nil
        end
      end)

    assert is_pid(new_pid)
    assert {:ok, status} = Owner.status(name)
    assert status["entry_count"] == 1
    assert status["committed_frames"] == 1
  end

  test "bounded queries are JSON-clean", %{name: name} do
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared(1))
    assert {:ok, status} = Owner.status(pid)
    assert {:ok, pending} = Owner.pending_operations(pid)

    assert MapSet.new(Map.keys(status)) == @status_keys
    assert status["oldest_pending_age_seconds"] in 0..31_536_000
    assert length(pending) <= 48
    assert Jason.encode!(status)
    assert Jason.encode!(pending)

    for key <- @forbidden do
      refute Map.has_key?(status, key)
    end

    assert hd(pending)["status"] == "prepared"
    refute Map.has_key?(hd(pending), "intent")
  end

  test "security regression: malformed Core makes pending query fail closed", %{name: name} do
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)
    :sys.replace_state(pid, &Map.put(&1, :core, %{}))
    assert {:error, :journal_unavailable} = Owner.pending_operations(pid)
  end

  test "commit-uncertain poisons and never acknowledges success", %{name: name} do
    root = unique_root()
    {prepared, applied, _delivered} = grant_lifecycle()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert :ok = Owner.__test_inject__(pid, :sync_error, :eio)
    result = Owner.append(pid, applied)
    assert :ok = Owner.__test_inject__(pid, :clear)

    refute match?({:ok, _}, result)
    assert {:error, {:commit_uncertain, :sync_failed}} = result
    assert {:error, :journal_poisoned} = Owner.append(pid, applied)
    assert {:ok, status} = Owner.status(pid)
    assert status["poisoned"] == true
    assert status["availability"] == "degraded"
    assert status["reason"] == "poisoned"
    assert status["last_error"] == "commit_uncertain"
    assert status["serving"] == false
    assert status["pending_count"] == 1
    refute is_binary(status["last_error"]) and String.contains?(status["last_error"], "eio")
  end

  test "torn tail reopens degraded and refuses appends", %{name: name} do
    root = unique_root()
    {prepared, applied, _delivered} = grant_lifecycle()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    :ok = GenServer.stop(pid)

    path = Path.join(root, "audit_journal.v1.log")
    File.write!(path, File.read!(path) <> <<"AJL">>)
    File.chmod!(path, 0o600)

    assert {:ok, _pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, status} = Owner.status(name)
    assert status["torn_tail"] == true
    assert status["availability"] == "degraded"
    assert status["reason"] == "torn_tail"
    assert status["last_error"] == "torn_tail"
    assert status["serving"] == false
    assert {:error, {:not_committed, :torn_tail}} = Owner.append(name, applied)
    assert {:ok, pending} = Owner.pending_operations(name)
    assert length(pending) == 1
  end

  test "not_committed write failure poisons and keeps the outer error", %{name: name} do
    root = unique_root()
    {prepared, applied, _delivered} = grant_lifecycle()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert :ok = Owner.__test_inject__(pid, :write_error, :injected_write)
    result = Owner.append(pid, applied)
    assert :ok = Owner.__test_inject__(pid, :clear)

    refute match?({:ok, _}, result)
    assert {:error, {:not_committed, :injected_write}} = result
    assert {:error, :journal_poisoned} = Owner.append(pid, applied)
    assert {:ok, status} = Owner.status(pid)
    assert status["poisoned"] == true
    assert status["last_error"] == "not_committed"
    assert status["reason"] == "poisoned"
    assert status["serving"] == false
  end

  test "start_link rejects caller-selectable path module callback backend", %{name: name} do
    root = unique_root()

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :durable, root: root, path: "/tmp/x.log", name: name)

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :ephemeral, file_module: AuditJournalFile, name: name)

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :ephemeral, callback: fn -> :ok end, name: name)

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :ephemeral, backend: :memory, name: name)
  end

  test "corrupt open fails start and does not serve invented state", %{name: name} do
    root = unique_root()
    {prepared, _applied, _delivered} = grant_lifecycle()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    :ok = GenServer.stop(pid)

    path = Path.join(root, "audit_journal.v1.log")
    File.write!(path, flip_byte(File.read!(path), 40))
    File.chmod!(path, 0o600)

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:journal_open_failed, :digest_mismatch}} =
               Owner.start_link(mode: :durable, root: root, name: name)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end

    refute Process.whereis(name)
  end

  test "durable soft-capacity reclaimable terminals publish once and retry", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert {:ok, before} = Owner.status(pid)
    assert before["entry_count"] == 32
    assert {:ok, :committed} = Owner.append(pid, extra)
    assert {:ok, :idempotent} = Owner.append(pid, extra)
    assert {:ok, status} = Owner.status(pid)
    assert {:ok, pending} = Owner.pending_operations(pid)
    assert status["entry_count"] == 10
    assert status["committed_frames"] == 10
    assert status["capacity"]["used_entries"] == 10
    assert status["pending_count"] == 9
    assert status["last_error"] == "none"
    assert extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
    assert Jason.encode!(status)
  end

  test "durable hard-capacity reserve reclaimable terminals publish once", %{name: name} do
    root = unique_root()
    extra = revoke_prepared(33)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_hard_reclaimable(pid)
    assert {:ok, :committed} = Owner.append(pid, extra)
    assert {:ok, status} = Owner.status(pid)
    assert {:ok, pending} = Owner.pending_operations(pid)
    assert status["entry_count"] == 18
    assert status["committed_frames"] == 18
    assert status["pending_count"] == 17
    assert extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
    revoke_ids = Enum.map(17..32, fn n -> revoke_prepared(n)["operation_id"] end)
    pending_ids = Enum.map(pending, & &1["operation_id"])
    assert Enum.all?(revoke_ids, &(&1 in pending_ids))
  end

  test "unreclaimable soft and hard capacity do not publish", %{name: name} do
    root = unique_root()
    extra_grant = prepared(33)
    extra_revoke = revoke_prepared(99)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_unreclaimable_soft(pid)
    assert {:ok, before} = Owner.status(pid)
    assert {:error, :soft_capacity_exhausted} = Owner.append(pid, extra_grant)
    assert {:ok, after_soft} = Owner.status(pid)
    assert after_soft["committed_frames"] == before["committed_frames"]
    assert after_soft["last_error"] == "none"
    refute File.exists?(candidate_path(root))
    :ok = GenServer.stop(pid)

    hard_name = :"#{name}_hard"
    on_exit(fn -> stop_named(hard_name) end)
    assert {:ok, hard} = Owner.start_link(mode: :durable, root: unique_root(), name: hard_name)
    fill_unreclaimable_hard(hard)
    assert {:ok, hard_before} = Owner.status(hard)
    assert {:error, :capacity_exhausted} = Owner.append(hard, extra_revoke)
    assert {:ok, hard_after} = Owner.status(hard)
    assert hard_after["committed_frames"] == hard_before["committed_frames"]
    assert hard_after["last_error"] == "none"
  end

  test "not_published keeps the old log and permits later retry", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    before = File.read!(log_path(root))
    assert {:ok, before_status} = Owner.status(pid)
    assert :ok = Owner.__test_inject__(pid, :compact_sync_error, :eio)
    result = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    assert {:error, :soft_capacity_exhausted} = result
    refute match?({:ok, _}, result)
    assert {:ok, status} = Owner.status(pid)
    assert status["serving"] == true
    assert status["poisoned"] == false
    assert status["committed_frames"] == before_status["committed_frames"]
    assert status["last_error"] == "none"
    assert File.read!(log_path(root)) == before
    refute File.exists?(candidate_path(root))
    assert {:ok, :committed} = Owner.append(pid, extra)
  end

  test "source_invalid poisons immediately and restart does not invent extra", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert :ok = Owner.__test_inject__(pid, :compact_rewrite_source_same_size)
    result = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    refute match?({:ok, _}, result)
    assert {:error, {:not_committed, :source_invalid}} = result
    assert {:error, :journal_poisoned} = Owner.append(pid, extra)
    assert {:ok, status} = Owner.status(pid)
    assert status["poisoned"] == true
    assert status["serving"] == false
    assert status["last_error"] == "not_committed"
    refute status["last_error"] == "source_invalid"
    refute inspect(status) =~ "digest_mismatch"
    refute inspect(status) =~ "eio"
    :ok = GenServer.stop(pid)

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      started = Owner.start_link(mode: :durable, root: root, name: name)

      case started do
        {:ok, restarted} ->
          assert {:ok, pending} = Owner.pending_operations(restarted)
          refute extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
          assert {:ok, after_status} = Owner.status(restarted)
          assert after_status["serving"] == true
          assert after_status["poisoned"] == false

        {:error, {:journal_open_failed, _reason}} ->
          refute Process.whereis(name)
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "publish_uncertain poisons as commit_uncertain", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert :ok = Owner.__test_inject__(pid, :compact_dir_sync, :eio)
    result = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    refute match?({:ok, _}, result)
    assert {:error, {:commit_uncertain, :dir_sync_failed}} = result
    assert {:error, :journal_poisoned} = Owner.append(pid, extra)
    assert {:ok, status} = Owner.status(pid)
    assert status["poisoned"] == true
    assert status["last_error"] == "commit_uncertain"
    refute inspect(status) =~ "eio"
  end

  test "retry write_error after compact poisons and keeps compacted occupancy", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert :ok = Owner.__test_inject__(pid, :write_error, :injected_write)
    result = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    refute match?({:ok, _}, result)
    assert {:error, {:not_committed, :injected_write}} = result
    assert {:error, :journal_poisoned} = Owner.append(pid, extra)
    assert {:ok, status} = Owner.status(pid)
    assert status["poisoned"] == true
    assert status["serving"] == false
    assert status["last_error"] == "not_committed"
    assert status["entry_count"] == 9
    assert status["committed_frames"] == 9
    assert status["capacity"]["used_entries"] == 9
    assert {:ok, pending} = Owner.pending_operations(pid)
    refute extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
  end

  test "retry partial_write after compact poisons; restart is torn without extra", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert :ok = Owner.__test_inject__(pid, :partial_write, 3)
    result = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    refute match?({:ok, _}, result)
    assert {:error, {:not_committed, :write_failed}} = result
    assert {:ok, status} = Owner.status(pid)
    assert status["poisoned"] == true
    assert status["entry_count"] == 9
    assert status["committed_frames"] == 9
    :ok = GenServer.stop(pid)

    assert {:ok, _pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, restarted} = Owner.status(name)
    assert restarted["torn_tail"] == true
    assert restarted["serving"] == false
    assert {:ok, pending} = Owner.pending_operations(name)
    refute extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
  end

  test "conflict and malformed at unreclaimable cap never compact", %{name: name} do
    root = unique_root()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_unreclaimable_soft(pid)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    applied = applied_record(intent, @t1)
    assert {:ok, :committed} = Owner.append(pid, applied)
    assert {:ok, before} = Owner.status(pid)
    other = Map.put(applied, "occurred_at", "2026-08-20T12:00:09Z")
    assert {:ok, _} = AuditJournal.admit_record(other)
    assert {:error, :operation_conflict} = Owner.append(pid, other)
    assert {:error, :malformed} = Owner.append(pid, %{"nope" => true})
    assert {:ok, after_status} = Owner.status(pid)
    assert after_status["committed_frames"] == before["committed_frames"]
    refute File.exists?(candidate_path(root))
  end

  test "ephemeral capacity never creates a compact candidate", %{name: name} do
    root = unique_root()
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)

    for n <- 1..32 do
      assert {:ok, :committed} = Owner.append(pid, prepared(n))
    end

    assert {:error, :soft_capacity_exhausted} = Owner.append(pid, prepared(33))
    refute File.exists?(log_path(root))
    refute File.exists?(candidate_path(root))
  end

  test "restart after clean compact plus retry replays the extra record", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert {:ok, :committed} = Owner.append(pid, extra)
    assert {:ok, before} = Owner.status(pid)
    assert {:ok, pending} = Owner.pending_operations(pid)
    :ok = GenServer.stop(pid)

    assert {:ok, _pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, after_status} = Owner.status(name)
    assert {:ok, after_pending} = Owner.pending_operations(name)
    assert after_status["serving"] == true
    assert after_status["poisoned"] == false
    assert after_status["entry_count"] == before["entry_count"]
    assert after_status["committed_frames"] == before["committed_frames"]
    assert after_pending == pending
    assert extra["operation_id"] in Enum.map(after_pending, & &1["operation_id"])
  end

  test "restart after interior corruption of compacted log fails closed", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert {:ok, :committed} = Owner.append(pid, extra)
    :ok = GenServer.stop(pid)

    path = log_path(root)
    File.write!(path, flip_byte(File.read!(path), 40))
    File.chmod!(path, 0o600)

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:journal_open_failed, _reason}} =
               Owner.start_link(mode: :durable, root: root, name: name)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end

    refute Process.whereis(name)
  end

  test "restart after pre-publication miss does not invent extra", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert {:ok, before} = Owner.status(pid)
    assert :ok = Owner.__test_inject__(pid, :compact_sync_error, :eio)
    assert {:error, :soft_capacity_exhausted} = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    :ok = GenServer.stop(pid)

    assert {:ok, _pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, after_status} = Owner.status(name)
    assert {:ok, pending} = Owner.pending_operations(name)
    assert after_status["committed_frames"] == before["committed_frames"]
    refute extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
  end

  test "restart after post-publication uncertainty does not invent extra", %{name: name} do
    root = unique_root()
    extra = prepared(17)
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    fill_soft_reclaimable(pid)
    assert :ok = Owner.__test_inject__(pid, :compact_dir_sync, :eio)
    result = Owner.append(pid, extra)
    assert :ok = Owner.__test_inject__(pid, :clear)
    assert {:error, {:commit_uncertain, :dir_sync_failed}} = result
    :ok = GenServer.stop(pid)

    assert {:ok, _pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, after_status} = Owner.status(name)
    assert {:ok, pending} = Owner.pending_operations(name)
    assert after_status["poisoned"] == false
    assert after_status["entry_count"] == 9
    assert after_status["committed_frames"] == 9
    refute extra["operation_id"] in Enum.map(pending, & &1["operation_id"])
  end

  defp unique_name, do: :"aj_owner_#{System.unique_integer([:positive])}"

  defp stop_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp unique_root do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ajo-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp)
    File.chmod!(tmp, 0o700)
    {:ok, root} = SafePath.resolve_real(tmp)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp flip_byte(binary, index) do
    <<prefix::binary-size(index), byte, rest::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>
  end

  defp grant_lifecycle do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    {prepared_record(intent), applied_record(intent, @t1), delivered_record(intent, @t2)}
  end

  defp prepared(n) do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
    prepared_record(intent)
  end

  defp revoke_prepared(n) do
    {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
    prepared_record(intent)
  end

  defp fill_soft_reclaimable(pid) do
    for n <- 1..8 do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
      assert {:ok, :committed} = Owner.append(pid, prepared_record(intent))
      assert {:ok, :committed} = Owner.append(pid, applied_record(intent, @t1))
      assert {:ok, :committed} = Owner.append(pid, delivered_record(intent, @t2))
    end

    for n <- 9..16 do
      assert {:ok, :committed} = Owner.append(pid, prepared(n))
    end
  end

  defp fill_hard_reclaimable(pid) do
    for n <- 1..16 do
      {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
      assert {:ok, :committed} = Owner.append(pid, prepared_record(intent))
      assert {:ok, :committed} = Owner.append(pid, rejected_record(intent, @t1))
    end

    for n <- 17..32 do
      assert {:ok, :committed} = Owner.append(pid, revoke_prepared(n))
    end
  end

  defp fill_unreclaimable_soft(pid) do
    for n <- 1..32 do
      assert {:ok, :committed} = Owner.append(pid, prepared(n))
    end
  end

  defp fill_unreclaimable_hard(pid) do
    fill_unreclaimable_soft(pid)

    for n <- 1..16 do
      assert {:ok, :committed} = Owner.append(pid, revoke_prepared(n))
    end
  end

  defp log_path(root), do: Path.join(root, "audit_journal.v1.log")

  defp candidate_path(root), do: Path.join(root, ".audit_journal.v1.log.compact")

  defp grant_facts(n) do
    cap_id = cap_id(n)

    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => cap_id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => live_fp(1),
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp revoke_facts(n) do
    cap_id = cap_id(n)

    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_revoke",
      "effect_class" => "authority_reduce",
      "authority_namespace" => "capability",
      "authority_key" => cap_id,
      "before_fence" => live_fp(3),
      "after_fingerprint" => %{"kind" => "tombstone", "generation" => 3},
      "audit" => %{
        "event_type" => "capability_revoked",
        "data" => %{
          "capability_id" => cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp live_fp(generation) do
    %{
      "kind" => "live",
      "record_id" => "rec_1",
      "generation" => generation,
      "revision" => 1,
      "capability_digest" => @digest
    }
  end

  defp cap_id(n) do
    hex =
      n
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")

    "cap_" <> hex
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

  defp applied_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => %{
        "kind" => "applied",
        "after_fingerprint" => intent["after_fingerprint"]
      }
    }
  end

  defp rejected_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_rejected",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => %{"kind" => "rejected", "reason" => "before_mismatch"}
    }
  end

  defp delivered_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "delivered",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at
    }
  end
end
