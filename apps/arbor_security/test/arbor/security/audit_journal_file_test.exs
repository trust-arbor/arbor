defmodule Arbor.Security.AuditJournalFileTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @t1 "2026-08-20T12:00:01Z"

  setup do
    AuditJournalFile.__test_inject__(:clear)
    root = unique_root()
    on_exit(fn -> AuditJournalFile.__test_inject__(:clear) end)
    %{root: root}
  end

  test "append prepared then applied survives close/reopen with the same projection", %{
    root: root
  } do
    {prepared, applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert_file_identity(handle)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    assert {:ok, handle} = AuditJournalFile.append(handle, applied)
    before = snapshot(handle)
    assert :ok = AuditJournalFile.close(handle)

    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert snapshot(reopened) == before
    assert_file_identity(reopened)
    assert {:ok, folded} = AuditJournalCore.fold([prepared, applied])
    assert reopened.core |> AuditJournalCore.show() == AuditJournalCore.show(folded)
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "file identity records major_device, minor_device, and inode", %{root: root} do
    {prepared, applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert_file_identity(handle)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    assert_file_identity(handle)
    assert {:ok, handle} = AuditJournalFile.append(handle, applied)
    assert_file_identity(handle)
    assert :ok = AuditJournalFile.close(handle)

    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert_file_identity(reopened)
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "idempotent re-append does not grow the file", %{root: root} do
    {prepared, _applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    size = AuditJournalFile.evidence(handle).file_size
    assert {:ok, handle, :idempotent} = AuditJournalFile.append(handle, prepared)
    assert AuditJournalFile.evidence(handle).file_size == size
    assert :ok = AuditJournalFile.close(handle)
  end

  test "write_error inject leaves the file unchanged and is not_committed", %{root: root} do
    {prepared, applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    size = AuditJournalFile.evidence(handle).file_size
    path = handle.path

    AuditJournalFile.__test_inject__(:write_error, :injected_write)
    assert {:error, {:not_committed, :injected_write}} = AuditJournalFile.append(handle, applied)
    AuditJournalFile.__test_inject__(:clear)

    assert File.lstat!(path).size == size
    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    assert AuditJournalFile.evidence(reopened).committed_frames == 1
    assert AuditJournalFile.evidence(reopened).torn_tail == nil
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "partial_write inject of a magic prefix reopens as torn_tail of the prefix", %{
    root: root
  } do
    {prepared, applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    prefix = snapshot(handle)

    AuditJournalFile.__test_inject__(:partial_write, 3)
    assert {:error, {:not_committed, :write_failed}} = AuditJournalFile.append(handle, applied)
    AuditJournalFile.__test_inject__(:clear)

    assert {:ok, reopened} = AuditJournalFile.open(root: root)
    evidence = AuditJournalFile.evidence(reopened)
    assert evidence.committed_frames == 1
    assert evidence.torn_tail == %{offset: prefix.committed_offset, byte_size: 3}
    assert AuditJournalCore.show(reopened.core) == prefix.projection
    assert {:error, {:not_committed, :torn_tail}} = AuditJournalFile.append(reopened, applied)
    assert :ok = AuditJournalFile.close(reopened)
  end

  test "partial_write at or above frame size is commit_uncertain", %{root: root} do
    {prepared, _applied, _delivered} = grant_lifecycle()
    {:ok, bytes} = AuditJournal.canonical_record_bytes(prepared)

    {:ok, frame, _digest} =
      AuditJournalFileCore.encode_frame(bytes, AuditJournalFileCore.genesis_digest())

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path

    AuditJournalFile.__test_inject__(:partial_write, byte_size(frame))
    result = AuditJournalFile.append(handle, prepared)
    AuditJournalFile.__test_inject__(:clear)

    refute match?({:error, {:not_committed, _}}, result)
    assert {:error, {:commit_uncertain, :write_failed}} = result
    assert File.lstat!(path).size == 0

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    AuditJournalFile.__test_inject__(:partial_write, byte_size(frame) + 1)
    result = AuditJournalFile.append(handle, prepared)
    AuditJournalFile.__test_inject__(:clear)

    refute match?({:error, {:not_committed, _}}, result)
    assert {:error, {:commit_uncertain, :write_failed}} = result
    assert File.lstat!(path).size == 0

    on_disk = File.read!(path)
    assert {:ok, empty} = AuditJournalFileCore.new()
    assert {:ok, replayed} = AuditJournalFileCore.consume(empty, on_disk)
    shown = AuditJournalFileCore.show(replayed)
    complete? = shown.evidence.torn_tail == nil and shown.evidence.committed_frames >= 1
    refute complete?
  end

  test "partial_write of wrong-magic residue reopens as malformed_header", %{root: root} do
    {prepared, _applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    File.write!(path, "XXXX", [:append, :binary])

    assert {:error, :malformed_header} = AuditJournalFile.open(root: root)
  end

  test "sync_error inject is commit_uncertain and does not return ok", %{root: root} do
    {prepared, applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)

    AuditJournalFile.__test_inject__(:sync_error, :eio)
    result = AuditJournalFile.append(handle, applied)
    AuditJournalFile.__test_inject__(:clear)

    refute match?({:ok, _}, result)
    refute match?({:ok, _, _}, result)
    assert {:error, {:commit_uncertain, :sync_failed}} = result

    case AuditJournalFile.open(root: root) do
      {:ok, reopened} ->
        frames = AuditJournalFile.evidence(reopened).committed_frames
        assert frames in [1, 2]
        assert :ok = AuditJournalFile.close(reopened)

      {:error, reason} ->
        assert reason in [:malformed_header, :digest_mismatch, :predecessor_mismatch]
    end
  end

  test "post_sync_proof_error inject is commit_uncertain", %{root: root} do
    {prepared, _applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    AuditJournalFile.__test_inject__(:post_sync_proof_error, :proof_failed)
    result = AuditJournalFile.append(handle, prepared)
    AuditJournalFile.__test_inject__(:clear)

    assert {:error, {:commit_uncertain, :proof_failed}} = result
  end

  test "post_sync_chmod inject is commit_uncertain", %{root: root} do
    {prepared, _applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    AuditJournalFile.__test_inject__(:post_sync_chmod, 0o644)
    result = AuditJournalFile.append(handle, prepared)
    AuditJournalFile.__test_inject__(:clear)

    assert {:error, {:commit_uncertain, :insecure_mode}} = result
  end

  test "interior corrupt complete frame fails open instead of returning a prefix handle", %{
    root: root
  } do
    {prepared, applied, _delivered} = grant_lifecycle()

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    assert {:ok, handle} = AuditJournalFile.append(handle, prepared)
    assert {:ok, handle} = AuditJournalFile.append(handle, applied)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    bytes = File.read!(path)
    flipped = flip_byte(bytes, 40)
    File.write!(path, flipped)
    File.chmod!(path, 0o600)

    assert {:error, :digest_mismatch} = AuditJournalFile.open(root: root)
  end

  test "unknown options and missing root are rejected" do
    assert {:error, :invalid_opts} = AuditJournalFile.open([])
    assert {:error, :invalid_opts} = AuditJournalFile.open(root: "/tmp", codec: :json)
  end

  defp snapshot(handle) do
    %{
      projection: AuditJournalCore.show(handle.core),
      committed_offset: handle.offset,
      committed_digest: handle.digest,
      committed_frames: handle.frames
    }
  end

  defp assert_file_identity(handle) do
    stat = File.lstat!(handle.path)
    assert Map.has_key?(handle.identity, :major_device)
    assert Map.has_key?(handle.identity, :minor_device)
    assert Map.has_key?(handle.identity, :inode)
    assert handle.identity.major_device == stat.major_device
    assert handle.identity.minor_device == stat.minor_device
    assert handle.identity.inode == stat.inode
  end

  defp unique_root do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ajf-" <> Integer.to_string(:erlang.unique_integer([:positive]))
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
    {prepared_record(intent), applied_record(intent, @t1), delivered_record(intent, @t1)}
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
