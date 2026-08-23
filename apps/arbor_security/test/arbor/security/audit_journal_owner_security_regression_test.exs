defmodule Arbor.Security.AuditJournalOwnerSecurityRegressionTest do
  @moduledoc """
  Public-behavior security regression for P1C-B2B audit-journal owner.

  Parent (owner/facade absent) fails to load/call these APIs. Candidate must pass.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @t1 "2026-08-20T12:00:01Z"
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
    name = :"aj_owner_sec_#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_named(name) end)
    %{name: name}
  end

  test "security regression: public status and pending are bounded JSON-clean with no opts arities" do
    assert {:ok, status} = Arbor.Security.audit_journal_status()
    assert {:ok, pending} = Arbor.Security.audit_journal_pending_operations()
    assert MapSet.new(Map.keys(status)) == @status_keys
    assert is_list(pending)
    assert length(pending) <= 48
    assert Jason.encode!(status)
    assert Jason.encode!(pending)
    assert status["oldest_pending_age_seconds"] in 0..31_536_000
    assert status["last_error"] in ~w(none disabled torn_tail not_committed commit_uncertain poisoned)
    assert status["reason"] in ~w(none disabled activation_only torn_tail poisoned)

    for key <- @forbidden do
      refute Map.has_key?(status, key)
    end

    refute function_exported?(Arbor.Security, :audit_journal_status, 1)
    refute function_exported?(Arbor.Security, :audit_journal_pending_operations, 1)
    refute function_exported?(Arbor.Security, :audit_journal_append, 1)
    refute function_exported?(Arbor.Security, :append_audit_journal_record, 1)
  end

  test "security regression: disabled append is an error not success", %{name: name} do
    root = unique_root()
    prepared = prepared(1)
    assert {:ok, pid} = Owner.start_link(mode: :disabled, name: name)
    assert {:error, :journal_disabled} = Owner.append(pid, prepared)
    refute match?({:ok, _}, Owner.append(pid, prepared))

    assert {:ok, disabled} = Owner.status(pid)
    assert {:ok, durable} =
             Owner.start_link(mode: :ephemeral, name: :"#{name}_ephemeral")

    on_exit(fn -> stop_named(:"#{name}_ephemeral") end)
    assert {:ok, empty_ephemeral} = Owner.status(durable)

    assert disabled["durability"] == "dormant"
    assert disabled["availability"] == "dormant"
    assert disabled["reason"] == "disabled"
    assert disabled["last_error"] == "disabled"
    assert disabled["serving"] == false
    refute disabled["mode"] == empty_ephemeral["mode"] and
             disabled["availability"] == empty_ephemeral["availability"]

    refute File.exists?(Path.join(root, "audit_journal.v1.log"))
  end

  test "security regression: activation_only reason never claims a durable log", %{name: name} do
    root = unique_root()
    assert {:ok, pid} = Owner.start_link(mode: :disabled, reason: :activation_only, name: name)
    assert {:error, :journal_disabled} = Owner.append(pid, prepared(1))
    assert {:ok, status} = Owner.status(pid)
    assert status["mode"] == "disabled"
    assert status["durability"] == "dormant"
    assert status["reason"] == "activation_only"
    assert status["last_error"] == "disabled"
    refute File.exists?(Path.join(root, "audit_journal.v1.log"))
  end

  test "security regression: caller cannot select path file_module callback or backend", %{
    name: name
  } do
    root = unique_root()

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :durable, root: root, path: Path.join(root, "x.log"), name: name)

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :ephemeral, file_module: :attacker, name: name)

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :ephemeral, callback: fn -> :ok end, name: name)

    assert {:error, :invalid_opts} =
             Owner.start_link(mode: :ephemeral, backend: :memory, name: name)
  end

  test "security regression: commit-uncertain never succeeds and last_error is redacted", %{
    name: name
  } do
    root = unique_root()
    {prepared, applied} = prepared_applied()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert :ok = Owner.__test_inject__(pid, :post_sync_proof_error, :proof_failed)
    result = Owner.append(pid, applied)
    assert :ok = Owner.__test_inject__(pid, :clear)

    refute match?({:ok, _}, result)
    assert {:error, {:commit_uncertain, :proof_failed}} = result
    assert {:ok, status} = Owner.status(pid)
    assert status["last_error"] == "commit_uncertain"
    refute status["last_error"] == "proof_failed"
    refute inspect(status) =~ "proof_failed"
  end

  test "security regression: not_committed keeps the outer error and never succeeds", %{
    name: name
  } do
    root = unique_root()
    {prepared, applied} = prepared_applied()
    assert {:ok, pid} = Owner.start_link(mode: :durable, root: root, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert :ok = Owner.__test_inject__(pid, :write_error, :injected_write)
    result = Owner.append(pid, applied)
    assert :ok = Owner.__test_inject__(pid, :clear)

    refute match?({:ok, _}, result)
    assert {:error, {:not_committed, :injected_write}} = result
    assert {:error, :journal_poisoned} = Owner.append(pid, applied)
  end

  test "security regression: duplicate and conflict semantics through owner append", %{name: name} do
    {prepared, applied} = prepared_applied()
    assert {:ok, pid} = Owner.start_link(mode: :ephemeral, name: name)
    assert {:ok, :committed} = Owner.append(pid, prepared)
    assert {:ok, :idempotent} = Owner.append(pid, prepared)
    assert {:ok, :committed} = Owner.append(pid, applied)

    other = Map.put(applied, "occurred_at", "2026-08-20T12:00:09Z")
    assert {:error, :operation_conflict} = Owner.append(pid, other)
    assert {:ok, status} = Owner.status(pid)
    assert status["entry_count"] == 2
  end

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
        "ajo-sec-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp)
    File.chmod!(tmp, 0o700)
    {:ok, root} = SafePath.resolve_real(tmp)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp prepared_applied do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
    {prepared_record(intent), applied_record(intent)}
  end

  defp prepared(n) do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
    prepared_record(intent)
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

  defp applied_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => @t1,
      "observation" => %{
        "kind" => "applied",
        "after_fingerprint" => intent["after_fingerprint"]
      }
    }
  end
end
