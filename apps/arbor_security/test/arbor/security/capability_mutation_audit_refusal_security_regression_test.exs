defmodule Arbor.Security.CapabilityMutationAuditRefusalSecurityRegressionTest do
  @moduledoc """
  Security regressions for journal refusals at the capability mutation facade
  (Floor-and-Ledger v3, slice 3; spec section 4.5).

  A reduction the journal refuses still executes (exact CAD, `:degraded`), but
  on the parent 52a2cc3fa it did so silently: no log line, no event, no count
  and no reason (306 unjournaled revocations went unnoticed on the live node).
  A refused grant was `{:error, :audit_unavailable}` with no reason and a stale
  `capability_mutation_audit_status/0`. The public result atoms are unchanged.

  Runs unchanged against the parent: only public facades, the journal owner's
  start options and a journal file written with an encoder that exists on both
  commits.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration
  @moduletag security: :regression

  alias Arbor.Common.SafePath
  alias Arbor.Security
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.Contracts.AuditJournal

  @degraded [:arbor, :security, :audit_journal, :degraded_reduction]
  @refused [:arbor, :security, :audit_journal, :refused]

  setup do
    original = Process.whereis(AuditJournalOwner)
    principal = "agent_refusal_#{System.unique_integer([:positive])}"
    handler = "cma-refusal-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [@degraded, @refused],
        &__MODULE__.forward_event/4,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      :ok = AuditJournalOwner.clear_test_fixture()
      current = Process.whereis(AuditJournalOwner)

      if current != original do
        if current, do: Process.unregister(AuditJournalOwner)
        Process.register(original, AuditJournalOwner)
      end

      case Security.list_capabilities(principal) do
        {:ok, caps} -> Enum.each(caps, &Security.revoke_fixture(&1.id))
        _ -> :ok
      end
    end)

    %{original: original, principal: principal}
  end

  @doc false
  def forward_event(event, measurements, metadata, pid),
    do: send(pid, {:audit_event, event, measurements, metadata})

  test "security regression: degraded reductions log and count, rate limited, with telemetry every time",
       ctx do
    journal = swap_owner!(ctx, operational_root())
    {:ok, before} = Security.capability_mutation_audit_status()
    n0 = Map.get(before, :degraded_reductions, 0)
    count = max(12, 100 - n0)

    caps =
      for n <- 1..count do
        assert {:ok, cap} =
                 Security.grant_fixture(
                   principal: ctx.principal,
                   resource: "arbor://memory/read/degraded/#{n}"
                 )

        cap
      end

    # The journal is missing: every reduction still executes, unjournaled.
    true = Process.unregister(AuditJournalOwner)

    log =
      try do
        capture_log([level: :warning], fn ->
          Enum.each(caps, fn cap -> assert :ok = Security.revoke_fixture(cap.id) end)
        end)
      after
        Process.register(journal, AuditJournalOwner)
      end

    assert {:ok, []} = Security.list_capabilities(ctx.principal)

    # Parent 52a2cc3fa: silent — no telemetry, no warning, no count.
    events = drain(@degraded)
    assert length(events) == count

    assert Enum.all?(events, fn {measurements, metadata} ->
             measurements.count == 1 and metadata.reason == :unavailable
           end)

    assert Enum.map(events, fn {m, _} -> m.total end) == Enum.to_list((n0 + 1)..(n0 + count))

    warned =
      ~r/degraded (\d+), reason unavailable/
      |> Regex.scan(log)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)

    expected = Enum.filter((n0 + 1)..(n0 + count), &(&1 <= 10 or rem(&1, 100) == 0))
    assert warned == expected
    assert length(warned) < count

    assert {:ok, status} = Security.capability_mutation_audit_status()
    assert status.operation == :revoke
    assert status.effect == :applied
    assert status.audit == :degraded
    assert status.reason == :unavailable
    assert status.degraded_reductions == n0 + count
  end

  test "security regression: a capacity refusal is reported with its reason class and a reduction at the hard cap degrades loudly",
       ctx do
    # A healthy journal grants the capability that is revoked later.
    healthy = swap_owner!(ctx, operational_root())

    assert {:ok, cap} =
             Security.grant_fixture(principal: ctx.principal, resource: "arbor://memory/read/cap")

    # 3072 retained identities that no publication can reclaim (effect_rejected
    # terminals are never retired): every increase is refused by capacity.
    full = replace_owner!(healthy, operational_root(rejected_terminals(3072)))
    drain(@refused)

    refusal_log =
      capture_log([level: :warning], fn ->
        assert {:error, :audit_unavailable} =
                 Security.grant_fixture(
                   principal: ctx.principal,
                   resource: "arbor://memory/write/cap"
                 )
      end)

    # Parent 52a2cc3fa: no event and a stale status without a reason.
    assert [{%{count: 1}, %{operation: :grant, reason: :capacity}}] = drain(@refused)
    assert {:ok, status} = Security.capability_mutation_audit_status()
    assert %{operation: :grant, effect: :not_applied, audit: :refused, reason: :capacity} = status

    # The refused grant is counted and, rate limited per CapabilityStore
    # process, logged with the journal's exact reason: never a bare
    # :audit_unavailable in the log.
    assert is_integer(status.refused_grants) and status.refused_grants >= 1

    if status.refused_grants <= 10 or rem(status.refused_grants, 100) == 0 do
      assert refusal_log =~ "refused by the authority audit journal"
      assert refusal_log =~ "reason soft_capacity_exhausted, class capacity"
    end

    # At 4096 retained identities even reductions are refused by capacity: the
    # reduction still executes, unjournaled, and is signalled.
    replace_owner!(full, operational_root(rejected_terminals(4096)))

    log =
      capture_log([level: :warning], fn ->
        assert :ok = Security.revoke_fixture(cap.id)
      end)

    assert [{%{count: 1}, %{reason: :capacity}}] = drain(@degraded)
    assert {:ok, status} = Security.capability_mutation_audit_status()
    assert %{operation: :revoke, effect: :applied, audit: :degraded, reason: :capacity} = status

    if status.degraded_reductions <= 10 or rem(status.degraded_reductions, 100) == 0,
      do: assert(log =~ "reason capacity")

    assert {:ok, []} = Security.list_capabilities(ctx.principal)
  end

  # ---------------------------------------------------------------------------

  defp drain(event, acc \\ []) do
    receive do
      {:audit_event, ^event, measurements, metadata} ->
        drain(event, [{measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp swap_owner!(_ctx, root) do
    true = Process.unregister(AuditJournalOwner)
    start_owner!(root)
  end

  defp replace_owner!(current, root) do
    true = Process.unregister(AuditJournalOwner)
    GenServer.stop(current)
    start_owner!(root)
  end

  defp start_owner!(root) do
    {:ok, journal} =
      AuditJournalOwner.start_link(mode: :durable, root: root, capacity_profile: :operational)

    Process.unlink(journal)
    :ok = AuditJournalOwner.install_test_fixture(journal)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
    end)

    journal
  end

  defp operational_root(terminals \\ nil) do
    root = unique_root()

    if terminals do
      snapshot = %{
        "version" => 2,
        "kind" => AuditJournal.operational_snapshot_kind(),
        "source" => %{
          "committed_digest" => String.duplicate("ab", 32),
          "committed_frames" => 40,
          "committed_offset" => 100_000
        },
        "pending_manifest" => %{},
        "terminals" => terminals,
        "capacity_profile" => "operational"
      }

      {:ok, bytes, _replay} = FileCore.encode_compacted(snapshot, [])
      path = Path.join(root, "audit_journal.v1.log")
      File.write!(path, bytes)
      File.chmod!(path, 0o600)
    end

    root
  end

  defp rejected_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:op, n}),
       "effect_rejected|authority_increase|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_rejected:#{sha({:r, n})}"}
    end)
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp unique_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cma-refusal-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
