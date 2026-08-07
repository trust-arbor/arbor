defmodule Arbor.Memory.ProposalAuthoritySecurityRegressionTest do
  @moduledoc """
  Security regression: forged legacy ETS proposal data cannot affect the
  supervised Proposal.Store authority (VOICE-17 taint posture infrastructure).
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.{Events, GraphOps, KnowledgeGraph, Proposal}
  alias Arbor.Memory.Proposal.{Core, Store}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @legacy_ets :arbor_memory_proposals

  setup do
    ensure_durable_store()
    ensure_legacy_table()

    agent_id = "prop_auth_sec_#{System.unique_integer([:positive])}"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    _ = GraphOps.save_graph(agent_id, graph)

    on_exit(fn -> _ = Proposal.delete_all(agent_id) end)
    %{agent_id: agent_id}
  end

  test "security regression: forged legacy ETS rows cannot affect create/read/review/stats/cleanup",
       %{agent_id: agent_id} do
    forged_id = "prop_forged_legacy"
    forged = forged_proposal(agent_id, forged_id, "forged content from public ETS")
    :ets.insert(@legacy_ets, {{agent_id, forged_id}, forged})

    assert {:error, :not_found} = Proposal.get(agent_id, forged_id)

    {:ok, pending} = Proposal.list_pending(agent_id)
    refute Enum.any?(pending, &(&1.id == forged_id))

    assert {:error, :not_found} = Proposal.accept(agent_id, forged_id)
    assert {:error, :not_found} = Proposal.reject(agent_id, forged_id)
    assert {:error, :not_found} = Proposal.defer(agent_id, forged_id)

    stats = Proposal.stats(agent_id)
    assert stats.total == 0
    assert stats.pending == 0

    {:ok, created} =
      Proposal.create(agent_id, :fact, %{content: "authoritative create content"})

    refute created.id == forged_id
    assert {:ok, retrieved} = Proposal.get(agent_id, created.id)
    assert retrieved.id == created.id
    assert retrieved.content == "authoritative create content"

    assert :ok = Proposal.delete_all(agent_id)
    assert {:ok, true} = Proposal.agent_content_absent?(agent_id)

    # Legacy forgery still present in public ETS but authority remains empty
    assert [{_, ^forged}] = :ets.lookup(@legacy_ets, {agent_id, forged_id})
    assert {:error, :not_found} = Proposal.get(agent_id, forged_id)
    assert Proposal.stats(agent_id).total == 0
  end

  test "security regression: forged legacy ETS cannot poison transfer or accept_all", %{
    agent_id: agent_id
  } do
    forged_id = "prop_forged_xfer"
    forged = forged_proposal(agent_id, forged_id, "forged transfer target")
    :ets.insert(@legacy_ets, {{agent_id, forged_id}, forged})

    assert {:error, :not_found} = Proposal.accept(agent_id, forged_id)

    {:ok, real} = Proposal.create(agent_id, :thought, %{content: "real observation"})
    assert {:ok, results} = Proposal.accept_all(agent_id)
    assert length(results) == 1
    {result_id, target} = hd(results)
    assert result_id == real.id
    assert is_binary(target)
    refute Enum.any?(results, fn {id, _} -> id == forged_id end)
  end

  test "security regression: rejected create does not prune existing pending", %{
    agent_id: agent_id
  } do
    require_candidate_authority!()
    max_pending = Core.max_pending()
    uid = System.unique_integer([:positive])

    ids =
      for i <- 1..max_pending do
        content =
          ("seat" <> Integer.to_string(i) <> "_" <> Integer.to_string(uid))
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:ok, p} = Proposal.create(agent_id, :fact, %{content: content})
        p.id
      end

    # Force projected total-byte admission failure without mutating authority first.
    # Inflate past the ceiling so a single pending prune cannot create artificial headroom.
    limits = Core.limits()

    :sys.replace_state(Store, fn state ->
      put_in(state, [:totals, :bytes], limits.max_total_bytes + 1_000_000)
    end)

    probe =
      ("oversized" <> Integer.to_string(System.unique_integer([:positive])))
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{content: probe})

    {:ok, pending} = Proposal.list_pending(agent_id)
    assert length(pending) == max_pending

    pending_ids = MapSet.new(Enum.map(pending, & &1.id))
    assert pending_ids == MapSet.new(ids)
  after
    recompute_store_totals()
  end

  test "security regression: replacement-byte failure leaves proposal sidecar fence counters unchanged",
       %{agent_id: agent_id} do
    require_candidate_authority!()

    {:ok, p} =
      Proposal.create(agent_id, :fact, %{
        content: "byte admit baseline #{System.unique_integer([:positive])}"
      })

    before_state = :sys.get_state(Store)
    before_record = get_in(before_state, [:by_agent, agent_id, p.id])
    before_totals = before_state.totals
    before_envelope = before_record.envelope
    before_status = before_record.status
    before_confidence = before_record.proposal.confidence
    before_fence = before_record.fence
    old_bytes = Core.estimate_bytes(before_record.proposal)

    limits = Core.limits()

    # Force any non-shrinking replacement over the limit. Boost 0.50→0.55 may not
    # change encoded size, so place totals past the ceiling rather than at it.
    forced_totals = limits.max_total_bytes + old_bytes + 1

    :sys.replace_state(Store, fn state ->
      put_in(state, [:totals, :bytes], forced_totals)
    end)

    # Boost via exact dedup must fail admission without mutating the record.
    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{content: p.content})

    mid_state = :sys.get_state(Store)
    mid_record = get_in(mid_state, [:by_agent, agent_id, p.id])
    assert mid_record.proposal.confidence == before_confidence
    assert mid_record.envelope == before_envelope
    assert mid_record.status == before_status
    assert mid_record.fence == before_fence
    assert mid_state.totals.bytes == forced_totals
    assert mid_state.totals.entries == before_totals.entries

    # Review that would grow metadata must also fail closed.
    huge_reason = String.duplicate("r", min(Core.limits().max_reject_reason_bytes, 64))

    assert {:error, :limit_exceeded} =
             Proposal.reject(agent_id, p.id, reason: huge_reason)

    after_state = :sys.get_state(Store)
    after_record = get_in(after_state, [:by_agent, agent_id, p.id])
    assert after_record.proposal.status == :pending
    assert after_record.envelope == before_envelope
    assert after_record.status == before_status
    assert after_record.fence == before_fence
    assert after_state.totals.bytes == forced_totals
    assert after_state.totals.entries == before_totals.entries

    {:ok, still} = Proposal.get(agent_id, p.id)
    assert still.status == :pending
    assert still.confidence == before_confidence
  after
    recompute_store_totals()
  end

  test "security regression: completion-byte failure preserves in-flight fence then retry succeeds",
       %{agent_id: agent_id} do
    require_candidate_authority!()

    {:ok, p} =
      Proposal.create(agent_id, :fact, %{
        content: "complete byte fence #{System.unique_integer([:positive])}"
      })

    decision = TaintEnvelope.missing_fallback()

    assert {:ok, {:ready, _proposal, _joined, _status, fence}} =
             GenServer.call(
               Store,
               {:prepare_accept, agent_id, p.id, decision, :legacy_unlabeled}
             )

    assert fence.phase == :in_flight
    op_id = fence.operation_id

    before = :sys.get_state(Store)
    before_record = get_in(before, [:by_agent, agent_id, p.id])
    old_bytes = Core.estimate_bytes(before_record.proposal)
    forced = Core.limits().max_total_bytes + old_bytes + 1

    :sys.replace_state(Store, fn state ->
      put_in(state, [:totals, :bytes], forced)
    end)

    assert {:error, :limit_exceeded} = Proposal.accept(agent_id, p.id)

    mid = :sys.get_state(Store)
    mid_record = get_in(mid, [:by_agent, agent_id, p.id])
    assert mid_record.proposal.status == :pending
    assert mid_record.envelope == before_record.envelope
    assert mid_record.status == before_record.status
    assert mid_record.fence == before_record.fence
    assert mid.totals.bytes == forced
    assert mid.totals.entries == before.totals.entries
    assert mid_record.fence.operation_id == op_id

    assert {:ok, failed_recent} = Events.get_recent(agent_id, 50)

    refute Enum.any?(failed_recent, fn event ->
             to_string(event.type) == "proposal_accepted" and
               event_value(event.data, :proposal_id) == p.id
           end)

    recompute_store_totals()

    assert {:ok, target_id} = Proposal.accept(agent_id, p.id)
    assert is_binary(target_id)
    {:ok, done} = Proposal.get(agent_id, p.id)
    assert done.status == :accepted

    assert {:ok, completed_recent} = Events.get_recent(agent_id, 50)

    accepted =
      Enum.filter(completed_recent, fn event ->
        to_string(event.type) == "proposal_accepted" and
          event_value(event.data, :proposal_id) == p.id
      end)

    assert length(accepted) == 1
  after
    recompute_store_totals()
  end

  test "security regression: never prunes in-flight pending when cap is tight", %{
    agent_id: agent_id
  } do
    require_candidate_authority!()
    max_pending = Core.max_pending()
    uid = System.unique_integer([:positive])

    # Fill all pending seats, then put the lowest-confidence one in-flight.
    # A new create may prune another eligible record, but never this reservation.
    ids =
      for i <- 1..max_pending do
        content =
          ("inflight_seat" <> Integer.to_string(i) <> "_" <> Integer.to_string(uid))
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        conf = if i == 1, do: 0.01, else: 0.5 + i * 0.01

        {:ok, p} =
          Proposal.create(agent_id, :fact, %{content: content, confidence: conf})

        p.id
      end

    victim = hd(ids)

    :sys.replace_state(Store, fn state ->
      update_in(state, [:by_agent, agent_id, victim], fn record ->
        %{
          record
          | fence: %{
              phase: :in_flight,
              operation_id: "prop_xfer_" <> victim,
              domain_id: "prop_xfer_" <> victim
            }
        }
      end)
    end)

    probe =
      ("inflight_probe_" <> Integer.to_string(System.unique_integer([:positive])))
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert {:ok, inserted} = Proposal.create(agent_id, :fact, %{content: probe})

    {:ok, pending} = Proposal.list_pending(agent_id)
    assert length(pending) == max_pending
    pending_ids = MapSet.new(Enum.map(pending, & &1.id))
    assert MapSet.member?(pending_ids, victim)
    assert MapSet.member?(pending_ids, inserted.id)

    retained_originals = MapSet.intersection(pending_ids, MapSet.new(ids))
    assert MapSet.size(retained_originals) == max_pending - 1

    state = :sys.get_state(Store)
    assert match?(%{phase: :in_flight}, get_in(state, [:by_agent, agent_id, victim, :fence]))

    # With every pending record reserved, no eligible prune remains. Admission
    # must fail without deleting or replacing any record.
    :sys.replace_state(Store, fn current ->
      update_in(current, [:by_agent, agent_id], fn agent_map ->
        Map.new(agent_map, fn {id, record} ->
          fence = %{
            phase: :in_flight,
            operation_id: "prop_xfer_" <> id,
            domain_id: "prop_xfer_" <> id
          }

          {id, %{record | fence: fence}}
        end)
      end)
    end)

    before_ids =
      Store
      |> :sys.get_state()
      |> get_in([:by_agent, agent_id])
      |> Map.keys()
      |> MapSet.new()

    blocked_probe =
      ("inflight_blocked_" <> Integer.to_string(System.unique_integer([:positive])))
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{content: blocked_probe})

    after_ids =
      Store
      |> :sys.get_state()
      |> get_in([:by_agent, agent_id])
      |> Map.keys()
      |> MapSet.new()

    assert after_ids == before_ids
  after
    recompute_store_totals()
  end

  test "security regression: reject applies to current owner record so concurrent boost survives",
       %{agent_id: agent_id} do
    require_candidate_authority!()
    content = "boost survive #{System.unique_integer([:positive])}"
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: content, confidence: 0.5})

    # Simulate concurrent boost landing on the owner before reject mutates.
    :sys.replace_state(Store, fn state ->
      update_in(state, [:by_agent, agent_id, p.id], fn record ->
        boosted = Core.boost_confidence(record.proposal)
        payload = Core.canonicalize_payload(boosted)
        {:ok, env} = TaintEnvelope.new(payload, TaintEnvelope.missing_fallback())
        {:ok, env_map} = TaintEnvelope.to_map(env)
        %{record | proposal: boosted, envelope: env_map}
      end)
    end)

    recompute_store_totals()

    assert :ok = Proposal.reject(agent_id, p.id, reason: "nope")
    {:ok, rejected} = Proposal.get(agent_id, p.id)
    assert rejected.status == :rejected
    assert rejected.confidence == 0.55
    assert rejected.metadata[:rejection_reason] == "nope"
  end

  test "security regression: proposal and insight signals omit sensitive content fields", %{
    agent_id: agent_id
  } do
    require_candidate_authority!()
    test_pid = self()

    {:ok, sub_created} =
      Arbor.Signals.subscribe("memory.proposal_created", fn signal ->
        send(test_pid, {:proposal_created_signal, signal})
      end)

    {:ok, sub_insight} =
      Arbor.Signals.subscribe("memory.insight_detected", fn signal ->
        send(test_pid, {:insight_detected_signal, signal})
      end)

    on_exit(fn ->
      Arbor.Signals.unsubscribe(sub_created)
      Arbor.Signals.unsubscribe(sub_insight)
    end)

    secret = "sensitive user secret #{System.unique_integer([:positive])}"

    {:ok, p} =
      Proposal.create(agent_id, :fact, %{
        content: secret,
        source: secret,
        evidence: [secret],
        metadata: %{secret: secret}
      })

    assert_receive {:proposal_created_signal, signal}, 1_000
    data = signal.data
    assert_no_sensitive_fields(data, secret)

    :ok =
      Arbor.Memory.Signals.emit_insight_detected(agent_id, %{
        category: :behavior,
        content: secret,
        confidence: 0.9,
        source: secret,
        evidence: [secret],
        metadata: %{secret: secret}
      })

    assert_receive {:insight_detected_signal, insight_signal}, 1_000
    idata = insight_signal.data
    assert_no_sensitive_fields(idata, secret)
    refute Map.has_key?(idata, :confidence)
    refute Map.has_key?(idata, "confidence")

    assert :ok = Proposal.reject(agent_id, p.id, reason: secret)
    assert {:ok, recent} = Events.get_recent(agent_id, 50)

    rejected =
      Enum.find(recent, fn event ->
        to_string(event.type) == "pending_rejected" and
          event_value(event.data, :pending_id) == p.id
      end)

    assert rejected
    assert_no_sensitive_fields(rejected.data, secret)
  end

  test "security regression: list opts and reject reason are bounded before mutation", %{
    agent_id: agent_id
  } do
    require_candidate_authority!()
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "bound me"})

    assert {:error, :invalid_request} = Proposal.list_pending(agent_id, unknown: true)
    assert {:error, :invalid_request} = Proposal.list_pending(agent_id, sort_by: :not_a_sort)
    assert {:error, :invalid_request} = Proposal.list_pending(agent_id, type: :not_a_type)
    assert {:error, :limit_exceeded} = Proposal.list_pending(agent_id, limit: 100_001)

    huge_reason = String.duplicate("r", Core.limits().max_reject_reason_bytes + 1)
    assert {:error, :limit_exceeded} = Proposal.reject(agent_id, p.id, reason: huge_reason)
    {:ok, still} = Proposal.get(agent_id, p.id)
    assert still.status == :pending

    # Reject opts: only bounded atom-key keyword with :reason — no Keyword.get on junk.
    assert {:error, :invalid_request} = Proposal.reject(agent_id, p.id, [{"reason", "x"}])
    assert {:error, :invalid_request} = Proposal.reject(agent_id, p.id, unknown: true)
    assert {:error, :invalid_request} = Proposal.reject(agent_id, p.id, :not_a_keyword)
    assert {:error, :invalid_request} = Proposal.reject(agent_id, p.id, %{reason: "x"})
    assert {:error, :invalid_request} = Proposal.reject(agent_id, p.id, reason: "a", reason: "b")

    too_many_opts =
      for i <- 1..(Core.limits().max_reject_opts + 1), do: {:"pad_#{i}", true}

    assert {:error, :limit_exceeded} = Proposal.reject(agent_id, p.id, too_many_opts)

    {:ok, still2} = Proposal.get(agent_id, p.id)
    assert still2.status == :pending

    too_many_evidence =
      for i <- 1..(Core.limits().max_evidence_items + 1), do: "e#{i}"

    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{
               content: "evidence flood",
               evidence: too_many_evidence
             })

    huge_item = String.duplicate("x", Core.limits().max_evidence_item_bytes + 1)

    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{
               content: "evidence item flood",
               evidence: [huge_item]
             })
  end

  defp require_candidate_authority! do
    unless Code.ensure_loaded?(Store) and function_exported?(Proposal, :get_tainted, 2) do
      flunk("candidate proposal authority is required")
    end
  end

  defp assert_no_sensitive_fields(data, secret) do
    for key <- [
          :content,
          :content_preview,
          :evidence,
          :metadata,
          :reason,
          :source,
          :taint,
          :envelope,
          :capability,
          :capability_id
        ] do
      refute Map.has_key?(data, key)
      refute Map.has_key?(data, Atom.to_string(key))
    end

    refute inspect(data) =~ secret
  end

  defp event_value(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))

  defp forged_proposal(agent_id, id, content) do
    %Proposal{
      id: id,
      agent_id: agent_id,
      type: :fact,
      content: content,
      confidence: 0.99,
      source: "attacker",
      evidence: ["forged"],
      metadata: %{trusted: true},
      created_at: DateTime.utc_now(),
      status: :pending
    }
  end

  defp ensure_legacy_table do
    case :ets.whereis(@legacy_ets) do
      :undefined -> :ets.new(@legacy_ets, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  defp ensure_durable_store do
    case Process.whereis(:arbor_memory_durable) do
      nil ->
        start_supervised!(
          {BufferedStore, name: :arbor_memory_durable, backend: nil, write_mode: :sync}
        )

      _ ->
        :ok
    end
  end

  defp recompute_store_totals do
    if pid = Process.whereis(Store) do
      :sys.replace_state(pid, fn state ->
        records =
          state.by_agent
          |> Map.values()
          |> Enum.flat_map(&Map.values/1)

        bytes =
          Enum.reduce(records, 0, fn record, acc ->
            acc + Core.estimate_bytes(record.proposal)
          end)

        %{state | totals: %{entries: length(records), bytes: bytes}}
      end)
    end

    :ok
  end
end
