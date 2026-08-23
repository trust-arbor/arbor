defmodule Arbor.Security.AuditJournalFileSecurityRegressionTest do
  @moduledoc """
  Path fail-closed and admission-bound security regression for P1C-B2A,
  plus B2C2 atomic-publication regressions.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @t1 "2026-08-20T12:00:01Z"
  @magic <<"AJL1">>

  setup do
    AuditJournalFile.__test_inject__(:clear)
    root = unique_root()
    on_exit(fn -> AuditJournalFile.__test_inject__(:clear) end)
    %{root: root}
  end

  test "security regression: relative root is rejected", %{root: _root} do
    assert {:error, :relative_path} = AuditJournalFile.open(root: "relative-root")
  end

  test "security regression: relative path is rejected", %{root: root} do
    assert {:error, :relative_path} =
             AuditJournalFile.open(root: root, path: "audit_journal.v1.log")
  end

  test "security regression: parent traversal escapes the supplied root", %{root: root} do
    outside = Path.expand(Path.join(root, ".."))
    escape = Path.join(outside, "escaped-ajf.log")

    assert {:error, :path_escape} = AuditJournalFile.open(root: root, path: escape)
  end

  test "security regression: filesystem root is not a Security bound" do
    assert {:error, :root_invalid} = AuditJournalFile.open(root: "/")
  end

  test "security regression: lexical lookalike directory is not contained", %{root: root} do
    parent = Path.dirname(root)
    evil = Path.join(parent, Path.basename(root) <> "-evil")
    File.mkdir_p!(evil)
    File.chmod!(evil, 0o700)
    {:ok, evil_real} = SafePath.resolve_real(evil)
    File.chmod!(evil_real, 0o700)
    on_exit(fn -> File.rm_rf(evil_real) end)

    path = Path.join(evil_real, "audit_journal.v1.log")
    assert {:error, :path_escape} = AuditJournalFile.open(root: root, path: path)
  end

  test "security regression: file symlink is rejected", %{root: root} do
    target = Path.join(root, "target.log")
    File.write!(target, <<>>)
    File.chmod!(target, 0o600)
    link = Path.join(root, "audit_journal.v1.log")
    File.ln_s!(target, link)

    assert {:error, :symlink_rejected} = AuditJournalFile.open(root: root)
  end

  test "security regression: parent symlink is rejected", %{root: root} do
    real_dir = Path.join(root, "real")
    File.mkdir_p!(real_dir)
    File.chmod!(real_dir, 0o700)
    link_dir = Path.join(root, "link")
    File.ln_s!(real_dir, link_dir)

    path = Path.join(link_dir, "audit_journal.v1.log")
    assert {:error, :symlink_rejected} = AuditJournalFile.open(root: root, path: path)
  end

  test "security regression: directory target is not_regular", %{root: root} do
    path = Path.join(root, "audit_journal.v1.log")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)

    assert {:error, :not_regular} = AuditJournalFile.open(root: root)
  end

  test "security regression: hard-linked target is rejected", %{root: root} do
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    other = Path.join(root, "hardlink.log")
    File.ln!(path, other)

    assert {:error, :hardlink_rejected} = AuditJournalFile.open(root: root)
  end

  test "security regression: file mode 0644 is insecure_mode", %{root: root} do
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)
    File.chmod!(path, 0o644)

    assert {:error, :insecure_mode} = AuditJournalFile.open(root: root)
  end

  test "security regression: root mode 0755 is insecure_mode" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ajf-open-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp)
    {:ok, root} = SafePath.resolve_real(tmp)
    File.chmod!(root, 0o755)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, :insecure_mode} = AuditJournalFile.open(root: root)
  end

  test "security regression: oversized declared length is oversized_frame not torn_tail", %{
    root: root
  } do
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    header =
      @magic <>
        <<1_000_000::32-big>> <>
        AuditJournalFileCore.genesis_digest() <> AuditJournalFileCore.genesis_digest()

    assert byte_size(header) == 72
    File.write!(path, header)
    File.chmod!(path, 0o600)

    assert {:error, :oversized_frame} = AuditJournalFile.open(root: root)
  end

  test "security regression: impossible incomplete length prefix is oversized_frame not torn", %{
    root: root
  } do
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    residue = @magic <> <<0, 0, 0x81>>
    File.write!(path, residue)
    File.chmod!(path, 0o600)

    assert {:error, :oversized_frame} = AuditJournalFile.open(root: root)
  end

  test "security regression: non-canonical payload never enters reducer state", %{root: root} do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    {:ok, canonical} = AuditJournal.canonical_record_bytes(prepared)
    variant = canonical <> " "

    {:ok, frame, _digest} =
      AuditJournalFileCore.encode_frame(variant, AuditJournalFileCore.genesis_digest())

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    File.write!(path, frame)
    File.chmod!(path, 0o600)

    assert {:error, :non_canonical} = AuditJournalFile.open(root: root)
  end

  test "security regression: schema-invalid payload never enters reducer state", %{
    root: root
  } do
    {:ok, frame, _digest} =
      AuditJournalFileCore.encode_frame(~s({"nope":true}), AuditJournalFileCore.genesis_digest())

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    File.write!(path, frame)
    File.chmod!(path, 0o600)

    assert {:error, :malformed} = AuditJournalFile.open(root: root)
  end

  test "security regression: ancestor-symlink child cannot escape the canonical root", %{
    root: root
  } do
    outside =
      Path.join(
        System.tmp_dir!(),
        "ajf-out-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    File.mkdir_p!(outside)
    File.chmod!(outside, 0o700)
    {:ok, outside_real} = SafePath.resolve_real(outside)
    File.chmod!(outside_real, 0o700)
    on_exit(fn -> File.rm_rf(outside_real) end)

    link = Path.join(root, "escape")
    File.ln_s!(outside_real, link)
    path = Path.join(link, "audit_journal.v1.log")

    assert {:error, :symlink_rejected} = AuditJournalFile.open(root: root, path: path)
  end

  test "security regression: post-sync minor-device mismatch is commit_uncertain", %{
    root: root
  } do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    size_before = File.lstat!(path).size

    AuditJournalFile.__test_inject__(:post_sync_lstat_minor_device_delta, 1)

    assert {:error, {:commit_uncertain, :identity_changed}} =
             AuditJournalFile.append(handle, prepared)

    AuditJournalFile.__test_inject__(:clear)

    assert File.lstat!(path).size > size_before
    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert %{committed_frames: 1} = AuditJournalFile.evidence(reopened)
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "security regression: compact/1 is exported for publication" do
    assert Code.ensure_loaded?(AuditJournalFile)
    assert function_exported?(AuditJournalFile, :compact, 1)
  end

  test "security regression: source same-size rewrite does not publish snapshot", %{root: root} do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    before = File.read!(handle.path)
    arm_compact_inject(:compact_rewrite_source_same_size)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    assert {:error, {:not_published, reason}} = result
    assert reason in [:digest_mismatch, :source_tip_mismatch, :core_mismatch]
    refute compact_published?(handle.path, before)
    refute_candidate_file(handle)
    assert_old_handle_fd_invalid(handle)
  end

  test "security regression: source inode replacement does not publish snapshot", %{root: root} do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    arm_compact_inject(:compact_replace_source_inode)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    assert {:error, {:not_published, reason}} = result
    assert reason in [:identity_changed, :size_mismatch, :source_tip_mismatch]
    on_disk = File.read!(handle.path)
    refute snapshot_payload?(on_disk)
    refute_candidate_file(handle)
    assert_old_handle_fd_invalid(handle)
  end

  test "security regression: candidate substitution does not rename attacker bytes", %{root: root} do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    before = File.read!(handle.path)
    arm_compact_inject(:compact_substitute_candidate)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    assert {:error, {:not_published, reason}} = result

    assert reason in [
             :digest_mismatch,
             :identity_changed,
             :size_mismatch,
             :candidate_proof_failed
           ]

    assert File.read!(handle.path) == before
    refute_candidate_file(handle)
  end

  test "security regression: post-rename failure is publish_uncertain not a definite miss", %{
    root: root
  } do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    arm_compact_inject(:compact_rename_after_effect)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    refute match?({:ok, _}, result)
    refute match?({:error, {:not_published, _}}, result)
    assert {:error, {:publish_uncertain, _reason}} = result
    assert_old_handle_fd_invalid(handle)
    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert AuditJournalCore.capacity(reopened.core)["used_entries"] == 2
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "security regression: directory finalization failure after rename is publish_uncertain", %{
    root: root
  } do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    arm_compact_inject(:compact_dir_sync, :eio)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    refute match?({:ok, _}, result)
    refute match?({:error, {:not_published, _}}, result)
    assert {:error, {:publish_uncertain, :dir_sync_failed}} = result
    assert_old_handle_fd_invalid(handle)
  end

  test "security regression: published-file reopen failure is publish_uncertain", %{root: root} do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    arm_compact_inject(:compact_reopen_error, :eio)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    refute match?({:ok, _}, result)
    refute match?({:error, {:not_published, _}}, result)
    assert {:error, {:publish_uncertain, :reopen_failed}} = result
    assert_old_handle_fd_invalid(handle)
  end

  test "security regression: published-file replay failure is publish_uncertain", %{root: root} do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    arm_compact_inject(:compact_replay_error, :eio)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    refute match?({:ok, _}, result)
    refute match?({:error, {:not_published, _}}, result)
    assert {:error, {:publish_uncertain, :replay_mismatch}} = result
    assert_old_handle_fd_invalid(handle)
  end

  test "security regression: rename before effect is not_published and leaves the target", %{
    root: root
  } do
    assert function_exported?(AuditJournalFile, :compact, 1)
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    before = File.read!(handle.path)
    arm_compact_inject(:compact_rename_before_effect)
    result = apply(AuditJournalFile, :compact, [handle])
    AuditJournalFile.__test_inject__(:clear)
    assert {:error, {:not_published, _reason}} = result
    assert File.read!(handle.path) == before
    refute_candidate_file(handle)
  end

  test "security regression: open of snapshot-first log restores compacted core", %{root: root} do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    assert {:ok, folded} = AuditJournalCore.fold([prepared])

    source = %{
      "committed_digest" => Base.encode16(AuditJournalFileCore.genesis_digest(), case: :lower),
      "committed_frames" => 1,
      "committed_offset" => 1
    }

    assert {:ok, compacted, snapshot, pending} = AuditJournalCore.compact(folded, source)
    bytes = encode_snapshot_log(snapshot, pending)

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)

    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert reopened.core === compacted
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "security regression: open of snapshot-first effect_applied pending restores core", %{
    root: root
  } do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    applied = applied_record(intent, @t1)
    assert {:ok, folded} = AuditJournalCore.fold([prepared, applied])

    source = %{
      "committed_digest" => Base.encode16(AuditJournalFileCore.genesis_digest(), case: :lower),
      "committed_frames" => 2,
      "committed_offset" => 2
    }

    assert {:ok, compacted, snapshot, pending} = AuditJournalCore.compact(folded, source)
    assert Enum.map(pending, & &1["record_type"]) == ["prepared", "effect_applied"]
    bytes = encode_snapshot_log(snapshot, pending)

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)

    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert reopened.core === compacted
    assert :ok = AuditJournalFile.close(reopened)
  end

  defp arm_compact_inject(kind) do
    apply(AuditJournalFile, :__test_inject__, [kind])
  end

  defp arm_compact_inject(kind, value) do
    apply(AuditJournalFile, :__test_inject__, [kind, value])
  end

  defp assert_old_handle_fd_invalid(handle) do
    assert {:error, _reason} = :file.sync(handle.fd)
  end

  defp refute_candidate_file(handle) do
    name = "." <> Path.basename(handle.path) <> ".compact"
    refute File.exists?(Path.join(Path.dirname(handle.path), name))
  end

  defp snapshot_payload?(bytes) when is_binary(bytes) do
    {:ok, empty} = AuditJournalFileCore.new()

    case AuditJournalFileCore.consume(empty, bytes) do
      {:ok, replay} -> Map.get(replay, :snapshot) != nil
      {:error, _reason} -> false
    end
  end

  defp compact_published?(path, before) do
    on_disk = File.read!(path)
    on_disk != before and snapshot_payload?(on_disk)
  end

  defp encode_snapshot_log(snapshot, pending) do
    {:ok, snap_bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)

    {:ok, frame, digest} =
      AuditJournalFileCore.encode_frame(snap_bytes, AuditJournalFileCore.genesis_digest())

    Enum.reduce(pending, {frame, digest}, fn record, {acc, pred} ->
      {:ok, rec_bytes} = AuditJournal.canonical_record_bytes(record)
      {:ok, rec_frame, next} = AuditJournalFileCore.encode_frame(rec_bytes, pred)
      {acc <> rec_frame, next}
    end)
    |> elem(0)
  end

  defp unique_root do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ajf-sec-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp)
    File.chmod!(tmp, 0o700)
    {:ok, root} = SafePath.resolve_real(tmp)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

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
      "after_fingerprint" => %{
        "kind" => "live",
        "record_id" => "rec_1",
        "generation" => 1,
        "revision" => 1,
        "capability_digest" => @digest
      },
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
end
