defmodule Arbor.Shell.AppleContainerUnitJournalTest do
  @moduledoc """
  Isolated tests for the durable Apple Container unit-intent journal shell.

  Behavioral fail-closed cases are named as security regressions.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias Arbor.Shell.AppleContainerUnitJournal, as: Journal
  alias Arbor.Shell.AppleContainerUnitJournalCore, as: Core
  alias Arbor.Shell.Config
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.Executor

  @app :arbor_shell
  @config_key :apple_container_unit_journal_path
  @test_only_temp_cleanup_replace_key :__test_only_apple_container_unit_journal_temp_cleanup_replace
  @shlock_path "/usr/bin/shlock"
  @shlock_skip if(File.regular?(@shlock_path),
                 do: false,
                 else: "requires /usr/bin/shlock for active journal startup"
               )
  @moduletag :fast

  @hex32_a String.duplicate("a", 32)
  @hex32_b String.duplicate("b", 32)
  @unit_a "arbor-v1-#{@hex32_a}"
  @unit_b "arbor-v1-#{@hex32_b}"
  @exec_a "exec-alpha-1"
  @exec_b "exec-beta-2"
  @token_b String.duplicate("2", 64)

  setup do
    previous = Application.get_env(@app, @config_key)
    previous_cleanup_hook = Application.get_env(@app, @test_only_temp_cleanup_replace_key)
    root = unique_private_root!()

    on_exit(fn ->
      restore_env(previous)
      restore_test_only_cleanup_hook(previous_cleanup_hook)
      _ = File.rm_rf(root)
    end)

    Application.delete_env(@app, @config_key)
    Application.delete_env(@app, @test_only_temp_cleanup_replace_key)

    {:ok, root: root, path: Path.join(root, "unit-journal.json")}
  end

  # ---------------------------------------------------------------------------
  # Absent config → disabled fail-closed
  # ---------------------------------------------------------------------------

  describe "absent config" do
    test "starts disabled fail-closed so Shell still runs without journal path" do
      name = unique_name()

      assert {:ok, pid} = Journal.start_link(name: name)
      assert Process.alive?(pid)

      status = Journal.status(name)
      assert status["status"] == "disabled"
      assert status["reason"] == "apple_container_unit_journal_path_absent"
      assert status["active_count"] == nil

      assert {:error, :apple_container_unit_journal_disabled} =
               Journal.reserve(@unit_a, @exec_a, name)

      assert {:error, :apple_container_unit_journal_disabled} =
               Journal.complete(@unit_a, @token_b, name)

      assert {:error, :apple_container_unit_journal_disabled} =
               Journal.recovery_entries(name)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Path validation (config + start seams)
  # ---------------------------------------------------------------------------

  describe "path validation" do
    test "invalid configured Application path fails startup" do
      Application.put_env(@app, @config_key, "relative/journal.json")
      name = unique_name()

      assert {:error, {:invalid_apple_container_unit_journal_path, :relative_path}} =
               start_link_result(name: name)
    end

    test "malformed configured Application path fails startup" do
      Application.put_env(@app, @config_key, %{not: "a path"})
      name = unique_name()

      assert {:error, :apple_container_unit_journal_path_malformed} =
               start_link_result(name: name)
    end

    test "explicit test-path seam rejects non-canonical paths" do
      name = unique_name()

      assert {:error, {:invalid_apple_container_unit_journal_path, :trailing_slash}} =
               start_link_result(name: name, path: "/tmp/journal/")
    end

    test "rejects unknown start keys" do
      name = unique_name()

      assert {:error, {:unsupported_apple_container_unit_journal_start_keys, [:callback]}} =
               start_link_result(name: name, callback: fn -> :ok end)
    end
  end

  # ---------------------------------------------------------------------------
  # Reserve / complete / restart round-trip
  # ---------------------------------------------------------------------------

  describe "reserve complete and restart" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    test "persists exact snapshot on disk before replying the token", %{path: path} do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)

      parent = self()

      # Interpose by reading disk immediately after reserve returns: token reply
      # must only happen after the durable snapshot exists.
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, token)

      assert {:ok, bytes} = File.read(path)
      assert String.ends_with?(bytes, "\n")
      assert {:ok, snapshot} = Jason.decode(String.trim_trailing(bytes, "\n"))
      assert snapshot["schema_version"] == 1
      assert snapshot["generation"] == 1
      assert length(snapshot["active"]) == 1
      assert hd(snapshot["active"])["unit_name"] == @unit_a
      assert hd(snapshot["active"])["execution_id"] == @exec_a
      assert hd(snapshot["active"])["token"] == token
      assert is_integer(hd(snapshot["active"])["reserved_at_ms"])

      # Snapshot is Core.show shape and round-trips.
      assert {:ok, restored} = Core.new(snapshot)
      assert Core.show(restored) == snapshot

      send(parent, :done)
      assert_receive :done
      GenServer.stop(pid)
    end

    test "restart round-trips reserved intents from disk", %{path: path} do
      name1 = unique_name()
      assert {:ok, pid1} = start_journal!(name1, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name1)

      assert {:ok, [entry]} = Journal.recovery_entries(name1)
      assert entry.unit_name == @unit_a
      assert entry.token == token
      GenServer.stop(pid1)

      name2 = unique_name()
      assert {:ok, pid2} = start_journal!(name2, path)
      assert {:ok, [entry2]} = Journal.recovery_entries(name2)
      assert entry2.unit_name == @unit_a
      assert entry2.execution_id == @exec_a
      assert entry2.token == token

      status = Journal.status(name2)
      assert status["status"] == "ready"
      assert status["active_count"] == 1
      assert status["generation"] == 1

      GenServer.stop(pid2)
    end

    test "exact completion removes intent on disk; replay and wrong token fail closed", %{
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)

      assert {:error, :token_mismatch} = Journal.complete(@unit_a, @token_b, name)
      assert File.read!(path) == before

      assert {:error, :unknown_unit_name} = Journal.complete(@unit_b, token, name)
      assert File.read!(path) == before

      assert :ok = Journal.complete(@unit_a, token, name)
      after_complete = File.read!(path)
      assert {:ok, snap} = Jason.decode(String.trim_trailing(after_complete, "\n"))
      assert snap["active"] == []
      assert snap["generation"] == 2

      assert {:error, :unknown_unit_name} = Journal.complete(@unit_a, token, name)
      assert File.read!(path) == after_complete

      assert {:ok, []} = Journal.recovery_entries(name)
      GenServer.stop(pid)
    end

    test "malformed API inputs fail closed without mutating disk", %{path: path} do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)

      assert {:error, :invalid_unit_name} = Journal.reserve("not-a-unit", @exec_b, name)
      assert {:error, :invalid_execution_id} = Journal.reserve(@unit_b, "bad id", name)
      assert {:error, :invalid_unit_name} = Journal.complete("nope", token, name)
      assert {:error, :invalid_token} = Journal.complete(@unit_a, "short", name)
      assert File.read!(path) == before

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # reserve_record/3 — same transaction, full normalized Core.record reply
  # ---------------------------------------------------------------------------

  describe "reserve_record" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    test "returned record exactly matches recovery_entries and persisted restart state", %{
      path: path
    } do
      name1 = unique_name()
      assert {:ok, pid1} = start_journal!(name1, path)

      assert {:ok, record} = Journal.reserve_record(@unit_a, @exec_a, name1)
      assert is_map(record)
      assert record.unit_name == @unit_a
      assert record.execution_id == @exec_a
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, record.token)
      assert is_integer(record.reserved_at_ms) and record.reserved_at_ms >= 0
      assert map_size(record) == 4

      assert {:ok, [entry]} = Journal.recovery_entries(name1)
      assert entry == record

      # Disk snapshot must carry the exact committed fields before any reread path.
      assert {:ok, bytes} = File.read(path)
      assert {:ok, snapshot} = Jason.decode(String.trim_trailing(bytes, "\n"))
      assert length(snapshot["active"]) == 1
      disk = hd(snapshot["active"])
      assert disk["unit_name"] == record.unit_name
      assert disk["execution_id"] == record.execution_id
      assert disk["token"] == record.token
      assert disk["reserved_at_ms"] == record.reserved_at_ms

      GenServer.stop(pid1)

      name2 = unique_name()
      assert {:ok, pid2} = start_journal!(name2, path)
      assert {:ok, [restored]} = Journal.recovery_entries(name2)
      assert restored == record
      assert Journal.status(name2)["status"] == "ready"
      assert Journal.status(name2)["active_count"] == 1
      refute String.contains?(inspect(Journal.status(name2)), record.token)
      refute String.contains?(inspect(Journal.status(name2)), path)

      GenServer.stop(pid2)
    end

    test "reserve/3 remains token-only while sharing the same reservation path", %{path: path} do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)

      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      assert is_binary(token)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, token)
      refute is_map(token)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token
      assert entry.unit_name == @unit_a
      assert entry.execution_id == @exec_a

      # reserve_record still works for a second intent on the same owner.
      assert {:ok, record} = Journal.reserve_record(@unit_b, @exec_b, name)
      assert record.unit_name == @unit_b
      assert record.execution_id == @exec_b
      assert record.token != token

      assert {:ok, entries} = Journal.recovery_entries(name)
      assert length(entries) == 2
      assert Enum.any?(entries, &(&1 == record))
      assert Enum.any?(entries, &(&1.token == token))

      GenServer.stop(pid)
    end

    test "persistence failure never returns a record", %{root: root, path: path} do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, first} = Journal.reserve_record(@unit_a, @exec_a, name)
      before = File.read!(path)

      # Widen parent permissions so the next atomic publish fails closed.
      assert :ok = File.chmod(root, 0o750)

      assert {:error, {:apple_container_unit_journal_persist_failed, :journal_parent_not_private}} =
               Journal.reserve_record(@unit_b, @exec_b, name)

      assert File.read!(path) == before
      status = Journal.status(name)
      assert status["status"] == "poisoned"
      assert status["active_count"] == 1
      refute String.contains?(inspect(status), path)
      refute String.contains?(inspect(status), first.token)

      assert {:error, :apple_container_unit_journal_poisoned} =
               Journal.reserve_record(@unit_b, @exec_b, name)

      assert {:error, :apple_container_unit_journal_poisoned} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry == first

      GenServer.stop(pid)
    end

    test "disabled and core rejection paths match reserve/3", %{path: path} do
      # Disabled owner (no config path).
      disabled = unique_name()
      assert {:ok, disabled_pid} = Journal.start_link(name: disabled)

      assert {:error, :apple_container_unit_journal_disabled} =
               Journal.reserve(@unit_a, @exec_a, disabled)

      assert {:error, :apple_container_unit_journal_disabled} =
               Journal.reserve_record(@unit_a, @exec_a, disabled)

      GenServer.stop(disabled_pid)

      # Active owner: core rejections leave disk unchanged for both modes.
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)

      assert {:error, :invalid_unit_name} = Journal.reserve("not-a-unit", @exec_b, name)
      assert {:error, :invalid_unit_name} = Journal.reserve_record("not-a-unit", @exec_b, name)
      assert {:error, :invalid_execution_id} = Journal.reserve(@unit_b, "bad id", name)
      assert {:error, :invalid_execution_id} = Journal.reserve_record(@unit_b, "bad id", name)
      assert File.read!(path) == before

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token
      GenServer.stop(pid)
      _ = path
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed filesystem / corruption security regressions
  # ---------------------------------------------------------------------------

  describe "security regression fail-closed filesystem layout" do
    test "security regression: non-private parent fails startup without creating journal", %{
      root: root,
      path: path
    } do
      # Parent starts private from helper; widen group bits.
      assert :ok = File.chmod(root, 0o750)
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_parent_not_private}} =
               start_link_result(name: name, path: path)

      refute File.exists?(path)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    test "security regression: non-private existing target fails startup without replacement", %{
      path: path
    } do
      write_public_file!(path, empty_snapshot_json())
      before = File.read!(path)
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_file_not_private}} =
               start_link_result(name: name, path: path)

      assert File.read!(path) == before
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    @tag :security_regression
    test "security regression: hardlinked existing target fails startup without replacement", %{
      root: root,
      path: path
    } do
      sibling = Path.join(root, "journal-sibling.json")
      write_private_file!(sibling, empty_snapshot_json())
      assert :ok = File.ln(sibling, path)
      before = File.read!(path)
      before_stat = File.lstat!(path)
      assert before_stat.links == 2
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_hardlink_rejected}} =
               start_link_result(name: name, path: path)

      assert File.read!(path) == before
      after_stat = File.lstat!(path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.links == 2
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    test "security regression: symlink journal target fails startup without following or replacing",
         %{
           root: root,
           path: path
         } do
      real = Path.join(root, "real-journal.json")
      write_private_file!(real, empty_snapshot_json())
      assert :ok = File.ln_s(real, path)
      before_real = File.read!(real)
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_symlink_rejected}} =
               start_link_result(name: name, path: path)

      assert File.read!(real) == before_real
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    test "security regression: corrupt journal fails startup without replacement or delete", %{
      path: path
    } do
      corrupt = "{\"not\":\"valid-journal\"}\n"
      write_private_file!(path, corrupt)
      before = File.read!(path)
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, reason}} =
               start_link_result(name: name, path: path)

      assert reason in [
               :missing_schema_version,
               :missing_generation,
               :missing_active,
               :journal_invalid_schema,
               :invalid_journal
             ] or match?({:unsupported_keys, _}, reason)

      assert File.read!(path) == before

      assert {:error, {:apple_container_unit_journal_start_failed, _}} =
               start_link_result(name: unique_name(), path: path)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    test "security regression: oversize journal fails startup without truncation", %{path: path} do
      # Just over 1 MiB of valid UTF-8 JSON-ish content.
      oversize = String.duplicate("x", 1_048_577)
      write_private_file!(path, oversize)
      before_size = byte_size(File.read!(path))
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_snapshot_too_large}} =
               start_link_result(name: name, path: path)

      assert byte_size(File.read!(path)) == before_size
    end

    test "security regression: missing parent directory fails startup", %{root: root} do
      path = Path.join([root, "missing-parent", "journal.json"])
      name = unique_name()

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_parent_missing}} =
               start_link_result(name: name, path: path)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    test "security regression: deterministic persist failure preserves prior snapshot and poisons",
         %{
           root: root,
           path: path
         } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)

      # Widen parent permissions so the next atomic publish fails closed.
      assert :ok = File.chmod(root, 0o750)

      assert {:error, {:apple_container_unit_journal_persist_failed, :journal_parent_not_private}} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert File.read!(path) == before

      status = Journal.status(name)
      assert status["status"] == "poisoned"
      assert status["active_count"] == 1

      assert {:error, :apple_container_unit_journal_poisoned} =
               Journal.reserve(@unit_b, @exec_b, name)

      # Recovery still lists retained evidence.
      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token
      assert File.read!(path) == before

      # No temp residue left behind.
      temps =
        root
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, ".arbor-unit-journal-tmp-"))

      assert temps == []

      GenServer.stop(pid)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    @tag :security_regression
    test "security regression: parent replacement after start fails persist and poisons", %{
      root: root,
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)

      # Replace the private parent directory at the same path with a new inode,
      # then restore the journal file so only the parent identity has drifted.
      moved = root <> ".moved-" <> Integer.to_string(System.unique_integer([:positive]))
      assert :ok = File.rename(root, moved)
      File.mkdir!(root)
      assert :ok = File.chmod(root, 0o700)
      assert :ok = File.rename(Path.join(moved, Path.basename(path)), path)

      lock_src = Path.join(moved, Path.basename(path) <> ".lock")

      if File.exists?(lock_src) do
        _ = File.rename(lock_src, path <> ".lock")
      end

      assert {:error, {:apple_container_unit_journal_persist_failed, :journal_parent_replaced}} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert File.read!(path) == before
      status = Journal.status(name)
      assert status["status"] == "poisoned"
      refute String.contains?(inspect(status), path)
      refute String.contains?(inspect(status), root)

      assert {:error, :apple_container_unit_journal_poisoned} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token

      GenServer.stop(pid)
      _ = File.rm_rf(moved)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    @tag :security_regression
    test "security regression: target replacement after start fails persist and poisons", %{
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)
      before_stat = File.lstat!(path)

      # Deterministic inode replacement at the same path (unlink + rewrite).
      assert :ok = File.rm(path)
      write_private_file!(path, before)
      after_stat = File.lstat!(path)
      assert after_stat.inode != before_stat.inode

      assert {:error, {:apple_container_unit_journal_persist_failed, :journal_target_replaced}} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert File.read!(path) == before
      status = Journal.status(name)
      assert status["status"] == "poisoned"
      refute String.contains?(inspect(status), path)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token

      GenServer.stop(pid)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    @tag :security_regression
    test "security regression: expected-present target disappearance fails persist and poisons",
         %{
           path: path
         } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      assert File.exists?(path)

      assert :ok = File.rm(path)
      refute File.exists?(path)

      assert {:error, {:apple_container_unit_journal_persist_failed, :journal_target_missing}} =
               Journal.reserve(@unit_b, @exec_b, name)

      refute File.exists?(path)
      status = Journal.status(name)
      assert status["status"] == "poisoned"
      refute String.contains?(inspect(status), path)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token

      GenServer.stop(pid)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    @tag :security_regression
    test "security regression: reserve/complete/restart refreshes bound target identity", %{
      path: path
    } do
      name1 = unique_name()
      assert {:ok, pid1} = start_journal!(name1, path)

      # First publish binds a concrete target identity + content digest.
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name1)
      state1 = :sys.get_state(pid1)
      assert is_map(state1.binding)
      assert is_map(state1.binding.target)
      target_after_reserve = state1.binding.target
      disk_after_reserve = bound_target_from_path!(path)
      assert target_after_reserve == disk_after_reserve
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, target_after_reserve.digest)

      assert :ok = Journal.complete(@unit_a, token, name1)
      state2 = :sys.get_state(pid1)
      target_after_complete = state2.binding.target
      disk_after_complete = bound_target_from_path!(path)
      assert target_after_complete == disk_after_complete
      # Atomic rename publishes a new inode; binding must track it.
      assert target_after_complete.inode != target_after_reserve.inode
      # Content changed, so digest must refresh too.
      assert target_after_complete.digest != target_after_reserve.digest

      GenServer.stop(pid1)

      name2 = unique_name()
      assert {:ok, pid2} = start_journal!(name2, path)
      state3 = :sys.get_state(pid2)
      assert state3.binding.target == bound_target_from_path!(path)
      assert state3.binding.target.inode == target_after_complete.inode
      assert state3.binding.target.digest == target_after_complete.digest
      assert {:ok, []} = Journal.recovery_entries(name2)
      GenServer.stop(pid2)
    end

    @tag :requires_shlock
    @tag skip: @shlock_skip
    @tag :security_regression
    test "security regression: loaded descriptor and path identity are stable", %{path: path} do
      write_private_file!(path, empty_snapshot_json())
      expected = bound_target_from_path!(path)

      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      state = :sys.get_state(pid)

      # The admitted binding must equal the path lstat identity that survived
      # the descriptor-bound open/fstat/read/fstat/lstat sequence (no races),
      # plus the SHA-256 of those exact descriptor-read bytes.
      assert state.binding.target == expected
      assert state.binding.target == bound_target_from_path!(path)
      assert state.binding.target.links == 1
      assert state.binding.target.type == :regular
      assert state.binding.parent.type == :directory
      assert state.binding.parent.uid == state.binding.target.uid
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, state.binding.target.digest)

      # Parent identity excludes mutable times.
      refute Map.has_key?(state.binding.parent, :mtime)
      refute Map.has_key?(state.binding.parent, :ctime)
      refute Map.has_key?(state.binding.target, :mtime)
      refute Map.has_key?(state.binding.target, :ctime)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Slice B: process/BEAM-crash-consistent atomic publication
  # ---------------------------------------------------------------------------

  describe "security regression atomic publication slice B" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip
    @describetag :security_regression

    test "security regression: same-size in-place target mutation is detected before persist", %{
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)
      before_stat = File.lstat!(path)
      before_digest = sha256_hex(before)

      # Same inode, same size, different content — digest must catch this.
      mutated = mutate_same_size!(before)
      assert byte_size(mutated) == byte_size(before)
      assert mutated != before
      assert sha256_hex(mutated) != before_digest

      {:ok, io} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])

      try do
        assert :ok = :file.pwrite(io, 0, mutated)
        assert :ok = :file.sync(io)
      after
        _ = :file.close(io)
      end

      after_stat = File.lstat!(path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.size == before_stat.size
      assert File.read!(path) == mutated

      assert {:error,
              {:apple_container_unit_journal_persist_failed, :journal_target_digest_mismatch}} =
               Journal.reserve(@unit_b, @exec_b, name)

      # Prior snapshot content remains the mutated bytes we wrote; journal did
      # not publish a new generation over the undetected mutation.
      assert File.read!(path) == mutated
      status = Journal.status(name)
      assert status["status"] == "poisoned"
      assert status["active_count"] == 1
      refute String.contains?(inspect(status), path)
      refute String.contains?(inspect(status), before_digest)
      refute String.contains?(inspect(status), token)

      assert {:error, :apple_container_unit_journal_poisoned} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token

      GenServer.stop(pid)
    end

    test "security regression: successful persist refreshes bound digest from published proof", %{
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)

      assert {:ok, token1} = Journal.reserve(@unit_a, @exec_a, name)
      state1 = :sys.get_state(pid)
      disk1 = bound_target_from_path!(path)
      assert state1.binding.target == disk1
      assert state1.binding.target.digest == sha256_hex(File.read!(path))

      assert {:ok, _token2} = Journal.reserve(@unit_b, @exec_b, name)
      state2 = :sys.get_state(pid)
      disk2 = bound_target_from_path!(path)
      assert state2.binding.target == disk2
      assert state2.binding.target.digest != state1.binding.target.digest
      assert state2.binding.target.inode != state1.binding.target.inode
      assert state2.binding.target.digest == sha256_hex(File.read!(path))

      assert :ok = Journal.complete(@unit_a, token1, name)
      state3 = :sys.get_state(pid)
      assert state3.binding.target == bound_target_from_path!(path)
      assert state3.binding.target.digest != state2.binding.target.digest

      GenServer.stop(pid)
    end

    test "security regression: exact temp publication leaves no residue and private mode", %{
      root: root,
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)

      # Successful publish must leave only the journal (+ lock), never a temp.
      entries = File.ls!(root)
      temps = Enum.filter(entries, &String.starts_with?(&1, ".arbor-unit-journal-tmp-"))
      assert temps == []

      assert File.exists?(path)
      stat = File.lstat!(path)
      assert stat.type == :regular
      assert stat.links == 1
      assert (stat.mode &&& 0o777) == 0o600

      bytes = File.read!(path)
      assert String.ends_with?(bytes, "\n")
      assert {:ok, snap} = Jason.decode(String.trim_trailing(bytes, "\n"))
      assert hd(snap["active"])["token"] == token

      state = :sys.get_state(pid)
      assert state.binding.target == bound_target_from_path!(path)
      # Temp name form is fixed; residual temps would use that exact grammar.
      refute Enum.any?(
               entries,
               &Regex.match?(~r/\A\.arbor-unit-journal-tmp-[0-9a-f]{32}\.json\z/, &1)
             )

      GenServer.stop(pid)
    end

    test "security regression: cleanup removes only owned temp inode, never a replacement", %{
      root: root,
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)

      # Pre-seed an unrelated temp-shaped private file the journal never owned.
      hostile_name =
        ".arbor-unit-journal-tmp-" <> String.duplicate("c", 32) <> ".json"

      hostile_path = Path.join(root, hostile_name)
      hostile_content = "hostile-unrelated-temp\n"
      write_private_file!(hostile_path, hostile_content)
      hostile_inode = File.lstat!(hostile_path).inode

      # Make rename of a successfully written temp fail so cleanup_owned_temp
      # runs after the exclusive temp inode was established. On macOS, uchg on
      # the destination yields EPERM from rename(2).
      {_, 0} = System.cmd("/usr/bin/chflags", ["uchg", path])

      on_exit(fn ->
        _ = System.cmd("/usr/bin/chflags", ["nouchg", path])
      end)

      assert {:error, {:apple_container_unit_journal_persist_failed, reason}} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert match?({:journal_persist_failed, _}, reason) or
               reason in [
                 :journal_temp_replaced,
                 :journal_temp_identity_mismatch,
                 :journal_target_replaced,
                 :journal_target_digest_mismatch
               ]

      # Owned temps from this attempt must be gone.
      owned_temps =
        root
        |> File.ls!()
        |> Enum.filter(&Regex.match?(~r/\A\.arbor-unit-journal-tmp-[0-9a-f]{32}\.json\z/, &1))
        |> Enum.reject(&(&1 == hostile_name))

      assert owned_temps == []

      # Unrelated/pre-seeded replacement-shaped file must be untouched.
      assert File.exists?(hostile_path)
      assert File.read!(hostile_path) == hostile_content
      assert File.lstat!(hostile_path).inode == hostile_inode

      # Published journal remains the prior snapshot (immutable flag cleared for read).
      {_, 0} = System.cmd("/usr/bin/chflags", ["nouchg", path])
      assert File.read!(path) == before

      status = Journal.status(name)
      assert status["status"] == "poisoned"
      refute String.contains?(inspect(status), path)
      refute String.contains?(inspect(status), token)
      refute String.contains?(inspect(status), hostile_path)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token

      GenServer.stop(pid)
    end

    test "security regression: cleanup never deletes a same-path temp replacement", %{
      root: root,
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      before = File.read!(path)
      test_pid = self()

      # Sealed test-only seam: at the cleanup boundary, move the owned temp inode
      # aside and install an unrelated private temp-shaped file at the same path.
      # Identity-bound cleanup must leave the replacement untouched.
      Application.put_env(@app, @test_only_temp_cleanup_replace_key, fn temp ->
        assert is_binary(temp.path)
        assert is_map(temp.identity)
        assert is_integer(temp.identity.inode)

        replacement_content = "hostile-same-path-replacement\n"
        aside = temp.path <> ".owned-aside"

        assert :ok = File.rename(temp.path, aside)
        write_private_file!(temp.path, replacement_content)
        replacement_inode = File.lstat!(temp.path).inode
        assert replacement_inode != temp.identity.inode

        send(test_pid, {:temp_path_replaced, temp.path, replacement_content, replacement_inode})
        :ok
      end)

      {_, 0} = System.cmd("/usr/bin/chflags", ["uchg", path])

      on_exit(fn ->
        _ = System.cmd("/usr/bin/chflags", ["nouchg", path])
        Application.delete_env(@app, @test_only_temp_cleanup_replace_key)
      end)

      assert {:error, {:apple_container_unit_journal_persist_failed, reason}} =
               Journal.reserve(@unit_b, @exec_b, name)

      assert match?({:journal_persist_failed, _}, reason) or
               reason in [
                 :journal_temp_replaced,
                 :journal_temp_identity_mismatch,
                 :journal_target_replaced,
                 :journal_target_digest_mismatch
               ]

      assert_receive {:temp_path_replaced, replaced_path, replacement_content, replacement_inode},
                     1_000

      # Replacement at the active temp pathname must survive; journal never
      # claimed or deleted it.
      assert File.exists?(replaced_path)
      assert File.read!(replaced_path) == replacement_content
      assert File.lstat!(replaced_path).inode == replacement_inode
      assert String.starts_with?(Path.basename(replaced_path), ".arbor-unit-journal-tmp-")

      # Owned inode was moved aside by the seam (not unlinked via path fallback).
      aside = replaced_path <> ".owned-aside"
      assert File.exists?(aside)

      {_, 0} = System.cmd("/usr/bin/chflags", ["nouchg", path])
      assert File.read!(path) == before

      status = Journal.status(name)
      assert status["status"] == "poisoned"
      refute String.contains?(inspect(status), path)
      refute String.contains?(inspect(status), token)
      refute String.contains?(inspect(status), replaced_path)
      refute String.contains?(inspect(status), replacement_content)

      assert {:ok, [entry]} = Journal.recovery_entries(name)
      assert entry.token == token

      # Cleanup residue from the test seam only (not journal-owned claims).
      _ = File.rm(replaced_path)
      _ = File.rm(aside)

      GenServer.stop(pid)
      _ = root
    end

    test "security regression: failure reasons and status never leak path digest or payload", %{
      root: root,
      path: path
    } do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      digest = :sys.get_state(pid).binding.target.digest

      assert :ok = File.chmod(root, 0o750)

      assert {:error, err} = Journal.reserve(@unit_b, @exec_b, name)
      err_text = inspect(err)
      status = Journal.status(name)
      status_text = inspect(status)

      formatted =
        Journal.format_status(%{
          state: :sys.get_state(pid),
          message: {:reserve, @unit_b, @exec_b},
          reason: err,
          log: [{:in, {:reserve, @unit_b, @exec_b}}]
        })

      formatted_text = inspect(formatted)

      for text <- [err_text, status_text, formatted_text] do
        refute String.contains?(text, path)
        refute String.contains?(text, root)
        refute String.contains?(text, token)
        refute String.contains?(text, digest)
        refute String.contains?(text, ".arbor-unit-journal-tmp-")
      end

      assert status["status"] == "poisoned"
      assert formatted.state.binding == :redacted
      assert formatted.state.path == :redacted

      GenServer.stop(pid)
    end
  end

  describe "security regression ordered JSON decode" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    test "security regression: duplicate root keys fail without replacement", %{path: path} do
      corrupt = ~s({"schema_version":1,"generation":0,"generation":99,"active":[]}\n)
      write_private_file!(path, corrupt)
      before = File.read!(path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_duplicate_key}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(path) == before
    end

    test "security regression: duplicate nested record keys fail without replacement", %{
      path: path
    } do
      token_a = String.duplicate("a", 64)
      token_b = String.duplicate("b", 64)

      corrupt =
        ~s({"schema_version":1,"generation":1,"active":[{"unit_name":"#{@unit_a}","execution_id":"exec-a","token":"#{token_a}","reserved_at_ms":1,"token":"#{token_b}"}]}\n)

      write_private_file!(path, corrupt)
      before = File.read!(path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_duplicate_key}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(path) == before
    end

    test "security regression: deep JSON is rejected before decoding its tree", %{path: path} do
      nesting = 100_000
      corrupt = String.duplicate("[", nesting) <> "0" <> String.duplicate("]", nesting)
      write_private_file!(path, corrupt)
      before = File.read!(path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_json_too_deep}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(path) == before
    end

    test "valid ordered snapshots still round-trip through restart", %{path: path} do
      write_private_file!(path, ~s({"active":[],"generation":0,"schema_version":1}\n))

      name1 = unique_name()
      assert {:ok, pid1} = start_journal!(name1, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name1)
      GenServer.stop(pid1)

      name2 = unique_name()
      assert {:ok, pid2} = start_journal!(name2, path)
      assert {:ok, [entry]} = Journal.recovery_entries(name2)
      assert entry.unit_name == @unit_a
      assert entry.token == token
      assert Journal.status(name2)["generation"] == 1
      GenServer.stop(pid2)
    end
  end

  # ---------------------------------------------------------------------------
  # Capacity 1,024
  # ---------------------------------------------------------------------------

  describe "capacity" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    test "loads a full 1,024 journal and rejects the next reserve without mutation", %{path: path} do
      max = Core.limits().max_active
      assert max == 1_024

      active =
        for i <- 0..(max - 1) do
          %{
            "unit_name" => unit_name_from_n(i),
            "execution_id" => "exec-#{i}",
            "token" => token_from_n(i),
            "reserved_at_ms" => i
          }
        end

      snapshot = %{
        "schema_version" => 1,
        "generation" => max,
        "active" => active
      }

      payload = Jason.encode!(snapshot) <> "\n"
      write_private_file!(path, payload)
      before = File.read!(path)

      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)

      status = Journal.status(name)
      assert status["status"] == "ready"
      assert status["active_count"] == max
      assert status["generation"] == max

      assert {:error, :journal_at_capacity} =
               Journal.reserve(unit_name_from_n(max), "exec-overflow", name)

      assert File.read!(path) == before
      assert {:ok, entries} = Journal.recovery_entries(name)
      assert length(entries) == max

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Status / format_status redaction
  # ---------------------------------------------------------------------------

  describe "redaction" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    test "status and format_status never leak tokens or path", %{path: path} do
      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)

      status = Journal.status(name)
      status_text = inspect(status)
      refute String.contains?(status_text, token)
      refute String.contains?(status_text, path)
      assert status["status"] == "ready"
      assert status["active_count"] == 1

      formatted =
        Journal.format_status(%{
          state: :sys.get_state(pid),
          message: {:reserve, @unit_a, @exec_a},
          reason: :normal,
          log: [{:in, {:reserve, @unit_a, @exec_a}}]
        })

      formatted_text = inspect(formatted)
      refute String.contains?(formatted_text, token)
      refute String.contains?(formatted_text, path)
      assert formatted.message == :redacted
      assert formatted.state.path == :redacted
      assert formatted.state.binding == :redacted
      assert formatted.state.journal == :redacted

      # Raw owner state may hold the binding; public/OTP status must not.
      raw = :sys.get_state(pid)
      assert is_map(raw.binding)
      assert is_binary(raw.binding.path)
      refute String.contains?(inspect(status), Integer.to_string(raw.binding.target.inode))

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Production config path integration (without Application wiring)
  # ---------------------------------------------------------------------------

  describe "config path production start" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    test "uses Config path when no explicit path opt is provided", %{path: path} do
      Application.put_env(@app, @config_key, path)
      name = unique_name()

      assert {:ok, pid} = Journal.start_link(name: name)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, token)
      assert File.exists?(path)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Startup stale-temp cleanup (bounded, post-lock, pre-load)
  # ---------------------------------------------------------------------------

  describe "security regression startup stale-temp cleanup" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip
    @describetag :security_regression

    test "security regression: valid stale temp is removed before existing journal load", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())
      before = File.read!(path)

      stale = reserved_temp_name(String.duplicate("a", 32))
      stale_path = Path.join(root, stale)
      write_private_file!(stale_path, "stale-exclusive-temp\n")
      assert File.exists?(stale_path)

      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)

      refute File.exists?(stale_path)
      assert File.read!(path) == before

      status = Journal.status(name)
      assert status["status"] == "ready"
      assert status["active_count"] == 0
      assert status["generation"] == 0
      assert {:ok, []} = Journal.recovery_entries(name)

      temps =
        root
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, ".arbor-unit-journal-tmp-"))

      assert temps == []
      refute String.contains?(inspect(status), stale)
      refute String.contains?(inspect(status), path)

      GenServer.stop(pid)
    end

    test "security regression: journal target cannot occupy the reserved temp namespace", %{
      root: root
    } do
      reserved_target =
        Path.join(root, reserved_temp_name(String.duplicate("0", 32)))

      bytes = empty_snapshot_json()
      write_private_file!(reserved_target, bytes)
      before = File.lstat!(reserved_target)

      assert {:error,
              {:apple_container_unit_journal_start_failed,
               :journal_target_uses_reserved_temp_namespace}} =
               start_link_result(name: unique_name(), path: reserved_target)

      assert File.read!(reserved_target) == bytes
      after_stat = File.lstat!(reserved_target)
      assert after_stat.inode == before.inode
      assert after_stat.size == before.size
    end

    test "security regression: malformed reserved-prefix name preserves every candidate", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())

      malformed = ".arbor-unit-journal-tmp-" <> String.duplicate("b", 31) <> ".json"
      valid = reserved_temp_name(String.duplicate("c", 32))
      malformed_path = Path.join(root, malformed)
      valid_path = Path.join(root, valid)
      write_private_file!(malformed_path, "malformed-prefix\n")
      write_private_file!(valid_path, "valid-should-remain\n")

      before_malformed = File.read!(malformed_path)
      before_valid = File.read!(valid_path)
      inode_m = File.lstat!(malformed_path).inode
      inode_v = File.lstat!(valid_path).inode

      assert {:error,
              {:apple_container_unit_journal_start_failed, :journal_startup_temp_name_malformed}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(malformed_path) == before_malformed
      assert File.read!(valid_path) == before_valid
      assert File.lstat!(malformed_path).inode == inode_m
      assert File.lstat!(valid_path).inode == inode_v
    end

    test "security regression: symlink reserved temp preserves every candidate and target", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())
      real = Path.join(root, "real-stale-target.json")
      write_private_file!(real, "symlink-target-content\n")
      before_real = File.read!(real)

      link_name = reserved_temp_name(String.duplicate("d", 32))
      link_path = Path.join(root, link_name)
      assert :ok = File.ln_s(real, link_path)

      valid = reserved_temp_name(String.duplicate("e", 32))
      valid_path = Path.join(root, valid)
      write_private_file!(valid_path, "sibling-valid-temp\n")
      before_valid = File.read!(valid_path)
      inode_v = File.lstat!(valid_path).inode

      assert {:error,
              {:apple_container_unit_journal_start_failed, :journal_startup_temp_symlink_rejected}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(real) == before_real
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link_path)
      assert File.exists?(link_path)
      assert File.read!(valid_path) == before_valid
      assert File.lstat!(valid_path).inode == inode_v
    end

    test "security regression: hardlinked reserved temp preserves every candidate", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())
      sibling = Path.join(root, "hardlink-sibling.json")
      write_private_file!(sibling, "hardlink-body\n")

      hard_name = reserved_temp_name(String.duplicate("f", 32))
      hard_path = Path.join(root, hard_name)
      assert :ok = File.ln(sibling, hard_path)
      before_hard = File.read!(hard_path)
      before_stat = File.lstat!(hard_path)
      assert before_stat.links == 2

      valid = reserved_temp_name(String.duplicate("1", 32))
      valid_path = Path.join(root, valid)
      write_private_file!(valid_path, "valid-sibling-temp\n")
      before_valid = File.read!(valid_path)
      inode_v = File.lstat!(valid_path).inode

      assert {:error,
              {:apple_container_unit_journal_start_failed,
               :journal_startup_temp_hardlink_rejected}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(hard_path) == before_hard
      assert File.read!(sibling) == before_hard
      assert File.lstat!(hard_path).inode == before_stat.inode
      assert File.lstat!(hard_path).links == 2
      assert File.read!(valid_path) == before_valid
      assert File.lstat!(valid_path).inode == inode_v
    end

    test "security regression: non-private reserved temp preserves every candidate", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())

      valid_path =
        Path.join(root, reserved_temp_name(String.duplicate("0", 32)))

      non_private_path =
        Path.join(root, reserved_temp_name(String.duplicate("f", 32)))

      write_private_file!(valid_path, "valid-private-temp\n")
      write_private_file!(non_private_path, "non-private-temp\n")
      assert :ok = File.chmod(non_private_path, 0o644)

      valid_before = File.lstat!(valid_path)
      non_private_before = File.lstat!(non_private_path)

      assert {:error,
              {:apple_container_unit_journal_start_failed, :journal_startup_temp_not_private}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(valid_path) == "valid-private-temp\n"
      assert File.lstat!(valid_path).inode == valid_before.inode
      assert File.read!(non_private_path) == "non-private-temp\n"
      assert File.lstat!(non_private_path).inode == non_private_before.inode
      assert (File.lstat!(non_private_path).mode &&& 0o777) == 0o644
    end

    test "security regression: foreign OS lock prevents startup cleanup", %{
      root: root,
      path: path
    } do
      port =
        Port.open(
          {:spawn_executable, ~c"/bin/sleep"},
          [:binary, :exit_status, args: [~c"60"]]
        )

      foreign_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) and pid > 0 -> Integer.to_string(pid)
          other -> flunk("expected live Port os_pid, got: #{inspect(other)}")
        end

      lock_path = journal_lock_path(path)

      on_exit(fn ->
        cleanup_foreign_os_pid(port, foreign_pid)
        _ = File.rm(lock_path)
      end)

      assert {:ok, %Executable{} = shlock} = ExecutablePolicy.resolve(@shlock_path)

      assert {:ok, %{exit_code: 0, timed_out: false}} =
               Executor.run_bound(
                 shlock,
                 ["-f", lock_path, "-p", foreign_pid],
                 clear_env: true,
                 env: %{},
                 cwd: "/",
                 timeout: 5_000,
                 max_output_bytes: 256
               )

      assert :ok = File.chmod(lock_path, 0o600)

      stale_path =
        Path.join(root, reserved_temp_name(String.duplicate("8", 32)))

      write_private_file!(stale_path, "must-survive-lock-denial\n")
      before = File.lstat!(stale_path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_lock_held}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(stale_path) == "must-survive-lock-denial\n"
      assert File.lstat!(stale_path).inode == before.inode
    end

    test "security regression: candidate overflow preserves every reserved-prefix entry", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())

      # Bound is 64; seed 65 exact-grammar private temps.
      seeded =
        for i <- 0..64 do
          hex =
            i
            |> Integer.to_string(16)
            |> String.downcase()
            |> String.pad_leading(32, "0")

          name = reserved_temp_name(hex)
          temp_path = Path.join(root, name)
          content = "overflow-#{i}\n"
          write_private_file!(temp_path, content)
          {temp_path, content, File.lstat!(temp_path).inode}
        end

      assert length(seeded) == 65

      assert {:error,
              {:apple_container_unit_journal_start_failed,
               :journal_startup_temp_candidate_overflow}} =
               start_link_result(name: unique_name(), path: path)

      for {temp_path, content, inode} <- seeded do
        assert File.exists?(temp_path)
        assert File.read!(temp_path) == content
        assert File.lstat!(temp_path).inode == inode
      end
    end

    test "security regression: unrelated non-prefix files survive startup cleanup", %{
      root: root,
      path: path
    } do
      write_private_file!(path, empty_snapshot_json())
      before_journal = File.read!(path)

      unrelated = [
        {"notes.txt", "plain\n"},
        {".hidden-other", "hidden\n"},
        {"arbor-unit-journal-tmp-not-prefixed.json", "wrong-prefix\n"},
        {"tmp-other.json", "other\n"}
      ]

      unrelated_state =
        for {name, content} <- unrelated do
          p = Path.join(root, name)
          write_private_file!(p, content)
          {p, content, File.lstat!(p).inode}
        end

      stale = reserved_temp_name(String.duplicate("9", 32))
      stale_path = Path.join(root, stale)
      write_private_file!(stale_path, "clean-me\n")

      name = unique_name()
      assert {:ok, pid} = start_journal!(name, path)

      refute File.exists?(stale_path)
      assert File.read!(path) == before_journal

      for {p, content, inode} <- unrelated_state do
        assert File.exists?(p)
        assert File.read!(p) == content
        assert File.lstat!(p).inode == inode
      end

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-shlock lock target rejection (no shlock mutation required)
  # ---------------------------------------------------------------------------

  describe "security regression pre-shlock lock target rejection" do
    @tag :security_regression
    test "security regression: malformed lock content is rejected without shlock mutation", %{
      path: path
    } do
      lock_path = journal_lock_path(path)
      write_private_file!(lock_path, "not-a-pid\n")
      before = File.read!(lock_path)
      before_stat = File.lstat!(lock_path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_lock_malformed}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(lock_path) == before
      after_stat = File.lstat!(lock_path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.size == before_stat.size
      assert after_stat.type == :regular
    end

    @tag :security_regression
    test "security regression: symlink lock is rejected without following or mutation", %{
      root: root,
      path: path
    } do
      real = Path.join(root, "real.lock")
      lock_path = journal_lock_path(path)
      write_private_file!(real, System.pid() <> "\n")
      assert :ok = File.ln_s(real, lock_path)
      before_real = File.read!(real)

      assert {:error,
              {:apple_container_unit_journal_start_failed, :journal_lock_symlink_rejected}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(real) == before_real
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(lock_path)
    end

    @tag :security_regression
    test "security regression: hardlinked lock is rejected without mutation", %{
      root: root,
      path: path
    } do
      lock_path = journal_lock_path(path)
      sibling = Path.join(root, "lock-sibling")
      write_private_file!(sibling, System.pid() <> "\n")
      assert :ok = File.ln(sibling, lock_path)
      before = File.read!(lock_path)
      before_stat = File.lstat!(lock_path)
      assert before_stat.links == 2

      assert {:error,
              {:apple_container_unit_journal_start_failed, :journal_lock_hardlink_rejected}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(lock_path) == before
      after_stat = File.lstat!(lock_path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.links == 2
    end

    @tag :security_regression
    test "security regression: oversize lock content is rejected without mutation", %{path: path} do
      lock_path = journal_lock_path(path)
      oversize = String.duplicate("9", 33)
      write_private_file!(lock_path, oversize)
      before = File.read!(lock_path)
      before_stat = File.lstat!(lock_path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_lock_malformed}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(lock_path) == before
      after_stat = File.lstat!(lock_path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.size == before_stat.size
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-BEAM singleton lock ownership (security regressions)
  # ---------------------------------------------------------------------------

  describe "security regression cross-BEAM singleton lock" do
    @describetag :requires_shlock
    @describetag skip: @shlock_skip

    @tag :security_regression
    test "security regression: second same-BEAM journal owner for same canonical path is denied",
         %{
           path: path
         } do
      name1 = unique_name()
      name2 = unique_name()

      assert {:ok, pid1} = start_journal!(name1, path)
      assert Process.alive?(pid1)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_path_already_claimed}} =
               start_link_result(name: name2, path: path)

      # First owner remains fully usable.
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name1)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, token)
      assert {:ok, [entry]} = Journal.recovery_entries(name1)
      assert entry.token == token
      assert Journal.status(name1)["status"] == "ready"

      GenServer.stop(pid1)
    end

    @tag :security_regression
    test "security regression: replacement in same BEAM adopts retained current-PID lock and round-trips",
         %{
           path: path
         } do
      name1 = unique_name()
      assert {:ok, pid1} = start_journal!(name1, path)
      assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name1)

      lock_path = journal_lock_path(path)
      assert File.exists?(lock_path)
      lock_before = File.read!(lock_path)
      assert String.trim_trailing(lock_before, "\n") == System.pid()

      GenServer.stop(pid1)
      # OS lock is retained across child stop; in-BEAM path claim is released.
      assert File.exists?(lock_path)
      assert File.read!(lock_path) == lock_before

      name2 = unique_name()
      assert {:ok, pid2} = start_journal!(name2, path)
      assert {:ok, [entry]} = Journal.recovery_entries(name2)
      assert entry.unit_name == @unit_a
      assert entry.execution_id == @exec_a
      assert entry.token == token
      assert Journal.status(name2)["status"] == "ready"
      assert Journal.status(name2)["active_count"] == 1

      # Still our PID after adopt; never deleted on the prior terminate.
      assert String.trim_trailing(File.read!(lock_path), "\n") == System.pid()

      GenServer.stop(pid2)
    end

    @tag :security_regression
    test "security regression: lock naming a different live OS PID denies startup without alteration",
         %{
           path: path
         } do
      # Direct Port-owned harmless process supplies a live foreign OS PID.
      # Production lock path stays shell-free via pinned shlock + Executor.
      port =
        Port.open(
          {:spawn_executable, ~c"/bin/sleep"},
          [:binary, :exit_status, args: [~c"60"]]
        )

      foreign_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) and pid > 0 ->
            Integer.to_string(pid)

          other ->
            flunk("expected live Port os_pid, got: #{inspect(other)}")
        end

      lock_path = journal_lock_path(path)

      # Always tear down the foreign holder and its lock, even after assert failures.
      on_exit(fn ->
        cleanup_foreign_os_pid(port, foreign_pid)
        _ = File.rm(lock_path)
      end)

      assert foreign_pid != System.pid()
      assert {:ok, %Executable{} = shlock} = ExecutablePolicy.resolve(@shlock_path)

      assert {:ok, %{exit_code: 0, timed_out: false}} =
               Executor.run_bound(
                 shlock,
                 ["-f", lock_path, "-p", foreign_pid],
                 clear_env: true,
                 env: %{},
                 cwd: "/",
                 timeout: 5_000,
                 max_output_bytes: 256
               )

      # Preflight requires private same-UID shape before interpreting live hold.
      assert :ok = File.chmod(lock_path, 0o600)
      before = File.read!(lock_path)
      assert String.trim_trailing(before, "\n") == foreign_pid
      before_stat = File.lstat!(lock_path)

      assert {:error, {:apple_container_unit_journal_start_failed, :journal_lock_held}} =
               start_link_result(name: unique_name(), path: path)

      assert File.read!(lock_path) == before
      after_stat = File.lstat!(lock_path)
      assert after_stat.inode == before_stat.inode
      assert after_stat.size == before_stat.size
    end

    @tag :security_regression
    test "security regression: stale foreign PID is reclaimable and /var aliases collapse", %{
      root: root,
      path: path
    } do
      # --- Stale foreign PID reclamation (when the platform shlock reclaims) ---
      port =
        Port.open(
          {:spawn_executable, ~c"/bin/sleep"},
          [:binary, :exit_status, args: [~c"60"]]
        )

      foreign_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) and pid > 0 -> Integer.to_string(pid)
          other -> flunk("expected live Port os_pid, got: #{inspect(other)}")
        end

      lock_path = journal_lock_path(path)

      on_exit(fn ->
        cleanup_foreign_os_pid(port, foreign_pid)
        _ = File.rm(lock_path)
      end)

      assert {:ok, %Executable{} = shlock} = ExecutablePolicy.resolve(@shlock_path)

      assert {:ok, %{exit_code: 0, timed_out: false}} =
               Executor.run_bound(
                 shlock,
                 ["-f", lock_path, "-p", foreign_pid],
                 clear_env: true,
                 env: %{},
                 cwd: "/",
                 timeout: 5_000,
                 max_output_bytes: 256
               )

      assert :ok = File.chmod(lock_path, 0o600)

      # Port.close alone is not a process-group kill; SIGKILL the foreign OS PID
      # so shlock's kill(0) probe observes death, then wait for mtime stability.
      cleanup_foreign_os_pid(port, foreign_pid)
      assert wait_os_pid_dead(foreign_pid, 50)
      Process.sleep(1_100)

      name = unique_name()

      case start_link_result(name: name, path: path) do
        {:ok, pid} ->
          assert String.trim_trailing(File.read!(lock_path), "\n") == System.pid()
          assert {:ok, token} = Journal.reserve(@unit_a, @exec_a, name)
          assert Regex.match?(~r/\A[0-9a-f]{64}\z/, token)
          GenServer.stop(pid)

        {:error, {:apple_container_unit_journal_start_failed, :journal_lock_held}} ->
          # Platform shlock may refuse reclaim under mtime races on some volumes;
          # the required adopt/same-BEAM/foreign-live cases are covered elsewhere.
          _ = File.rm(lock_path)

        other ->
          flunk("unexpected journal start after stale lock: #{inspect(other)}")
      end

      # --- /var versus /private/var aliasing collapses to one ownership domain ---
      private_root = alias_private_var_path(root)

      if is_binary(private_root) and private_root != root and File.dir?(private_root) do
        var_path = Path.join(root, "alias-journal.json")
        private_path = Path.join(private_root, "alias-journal.json")

        name_a = unique_name()
        assert {:ok, pid_a} = start_journal!(name_a, var_path)

        assert {:error,
                {:apple_container_unit_journal_start_failed, :journal_path_already_claimed}} =
                 start_link_result(name: unique_name(), path: private_path)

        assert {:ok, _} = Journal.reserve(@unit_b, @exec_b, name_a)
        GenServer.stop(pid_a)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_journal!(name, path) do
    assert {:ok, _} = Config.validate_unit_journal_path(path)
    Journal.start_link(name: name, path: path)
  end

  defp journal_lock_path(path) when is_binary(path) do
    # Mirrors production: lock sits beside the journal after parent canonicalize.
    # Tests may pass non-canonical spellings; resolve parent the same way start does.
    parent = Path.dirname(path)
    base = Path.basename(path)

    canonical_parent =
      case Arbor.Common.SafePath.resolve_real(parent) do
        {:ok, real} -> real
        _ -> parent
      end

    Path.join(canonical_parent, base) <> ".lock"
  end

  defp alias_private_var_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/private/var/") ->
        String.replace_prefix(path, "/private/var/", "/var/")

      String.starts_with?(path, "/var/") ->
        String.replace_prefix(path, "/var/", "/private/var/")

      true ->
        nil
    end
  end

  defp cleanup_foreign_os_pid(port, foreign_pid)
       when is_binary(foreign_pid) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end

    _ = System.cmd("/bin/kill", ["-9", foreign_pid], stderr_to_stdout: true)
    :ok
  end

  defp wait_os_pid_dead(pid_string, attempts)
       when is_binary(pid_string) and is_integer(attempts) and attempts > 0 do
    case System.cmd("/bin/kill", ["-0", pid_string], stderr_to_stdout: true) do
      {_out, 0} ->
        Process.sleep(20)
        wait_os_pid_dead(pid_string, attempts - 1)

      {_out, _status} ->
        true
    end
  end

  defp wait_os_pid_dead(_pid_string, 0), do: false

  # Init `{:stop, reason}` still links briefly; trap exits so expected start
  # failures surface as `{:error, reason}` instead of killing the test process.
  defp start_link_result(opts) do
    Process.flag(:trap_exit, true)
    result = Journal.start_link(opts)
    flush_exits()
    result
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp unique_name do
    :"unit_journal_test_#{System.unique_integer([:positive])}"
  end

  defp unique_private_root! do
    base = System.tmp_dir!() |> Path.expand()

    root =
      Path.join(
        base,
        "arbor-unit-journal-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir!(root)
    assert :ok = File.chmod(root, 0o700)
    root
  end

  defp reserved_temp_name(hex32) when is_binary(hex32) and byte_size(hex32) == 32 do
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, hex32)
    ".arbor-unit-journal-tmp-" <> hex32 <> ".json"
  end

  defp write_private_file!(path, content) when is_binary(content) do
    assert :ok = File.write(path, content)
    assert :ok = File.chmod(path, 0o644)
    # Enforce private mode after write so umask cannot leave group/other bits.
    assert :ok = File.chmod(path, 0o600)
    assert {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    assert (mode &&& 0o777) == 0o600
  end

  defp write_public_file!(path, content) when is_binary(content) do
    assert :ok = File.write(path, content)
    assert :ok = File.chmod(path, 0o644)
  end

  defp empty_snapshot_json do
    Jason.encode!(%{"schema_version" => 1, "generation" => 0, "active" => []}) <> "\n"
  end

  # Mirrors the production bound target shape: file identity (no times) + SHA-256.
  defp bound_target_from_path!(path) when is_binary(path) do
    bytes = File.read!(path)

    %File.Stat{
      type: :regular,
      major_device: major_device,
      inode: inode,
      uid: uid,
      gid: gid,
      mode: mode,
      links: links,
      size: size
    } = File.lstat!(path, time: :posix)

    assert size == byte_size(bytes)

    %{
      type: :regular,
      major_device: major_device,
      inode: inode,
      uid: uid,
      gid: gid,
      mode: mode,
      links: links,
      size: size,
      digest: sha256_hex(bytes)
    }
  end

  defp sha256_hex(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  # Flip one payload byte while preserving exact size (same-inode mutation).
  defp mutate_same_size!(bytes) when is_binary(bytes) and byte_size(bytes) > 0 do
    size = byte_size(bytes)
    # Prefer mutating a non-newline body byte so size and trailing newline stay.
    index =
      cond do
        size >= 2 and binary_part(bytes, size - 1, 1) == "\n" -> size - 2
        true -> size - 1
      end

    <<prefix::binary-size(index), byte, suffix::binary>> = bytes
    flipped = bxor(byte, 0x01)
    <<prefix::binary, flipped, suffix::binary>>
  end

  defp unit_name_from_n(n) when is_integer(n) and n >= 0 do
    hex =
      n
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")

    "arbor-v1-" <> hex
  end

  defp token_from_n(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end

  defp restore_env(nil), do: Application.delete_env(@app, @config_key)
  defp restore_env(value), do: Application.put_env(@app, @config_key, value)

  defp restore_test_only_cleanup_hook(nil),
    do: Application.delete_env(@app, @test_only_temp_cleanup_replace_key)

  defp restore_test_only_cleanup_hook(value),
    do: Application.put_env(@app, @test_only_temp_cleanup_replace_key, value)
end
