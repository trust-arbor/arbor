defmodule Arbor.Security.AuditJournalFileSecurityRegressionTest do
  @moduledoc """
  Path fail-closed and admission-bound security regression for P1C-B2A.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
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
      @magic <> <<1_000_000::32-big>> <>
        AuditJournalFileCore.genesis_digest() <> AuditJournalFileCore.genesis_digest()

    assert byte_size(header) == 72
    File.write!(path, header)
    File.chmod!(path, 0o600)

    assert {:error, :oversized_frame} = AuditJournalFile.open(root: root)
  end

  test "security regression: non-canonical payload never enters reducer state", %{root: root} do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    prepared = prepared_record(intent)
    {:ok, canonical} = AuditJournal.canonical_record_bytes(prepared)
    variant = canonical <> " "
    {:ok, frame, _digest} = AuditJournalFileCore.encode_frame(variant, AuditJournalFileCore.genesis_digest())

    assert {:ok, handle} = AuditJournalFile.open(root: root)
    path = handle.path
    assert :ok = AuditJournalFile.close(handle)

    File.write!(path, frame)
    File.chmod!(path, 0o600)

    assert {:error, :non_canonical} = AuditJournalFile.open(root: root)
  end

  test "security regression: schema-invalid payload never enters reducer state", %{root: root} do
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
end
